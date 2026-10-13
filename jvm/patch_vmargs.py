#!/usr/bin/env python3
"""Aplica um perfil de GC/heap no ProjectZomboid64.json (lista "vmArgs").

Exemplos:
  python patch_vmargs.py --game-dir "C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid" --dry-run
  python patch_vmargs.py --game-dir ~/.steam/steam/steamapps/common/ProjectZomboid --profile auto --heap auto
  python patch_vmargs.py --game-dir ... --agent zperf-agent.jar --gc-log
  python patch_vmargs.py --game-dir ... --restore

Só remove/substitui flags que este script gerencia (GC, heap, pretouch, logs, agente ZPerf);
todo o resto (java.library.path, steam, debug...) é preservado na ordem original.
Um backup "<json>.zperf-backup" é criado na primeira execução.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

MANAGED = [re.compile(p) for p in (
    r"^-Xm[sxn]\d",
    r"^-XX:[+-]Use(ZGC|G1GC|ShenandoahGC|ParallelGC|SerialGC|ConcMarkSweepGC)$",
    r"^-XX:[+-]ZGenerational$",
    r"^-XX:Z\w+=",
    r"^-XX:G1\w+=",
    r"^-XX:Shenandoah\w+=",
    r"^-XX:(MaxGCPauseMillis|InitiatingHeapOccupancyPercent|SoftMaxHeapSize|ConcGCThreads|ParallelGCThreads)=",
    r"^-XX:[+-](AlwaysPreTouch|ParallelRefProcEnabled|UnlockExperimentalVMOptions|PerfDisableSharedMem|UseStringDeduplication|UseTransparentHugePages|UseLargePages|ExplicitGCInvokesConcurrent)$",
    r"^-Xlog:gc",
    r"^-XX:StartFlightRecording",
    r"^-javaagent:.*zperf-agent[^/\\]*\.jar",
)]

PROFILES = ("auto", "zgc", "zgc-gen", "g1", "shenandoah")


def is_managed(arg: str) -> bool:
    return any(p.search(arg) for p in MANAGED)


def total_ram_gb() -> float | None:
    try:
        system = platform.system()
        if system == "Linux":
            with open("/proc/meminfo", encoding="ascii") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        return int(line.split()[1]) / (1024 * 1024)
        elif system == "Windows":
            import ctypes

            class MemStatus(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

            st = MemStatus()
            st.dwLength = ctypes.sizeof(MemStatus)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
            return st.ullTotalPhys / (1024 ** 3)
        elif system == "Darwin":
            out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, check=True)
            return int(out.stdout.strip()) / (1024 ** 3)
    except Exception:  # noqa: BLE001 - detecção é melhor esforço
        return None
    return None


def auto_heap_gb(ram_gb: float) -> int:
    """Heap Java. O resto da RAM é do driver de vídeo, LWJGL/natives, SO e apps abertos."""
    for limit, heap in ((8.5, 3), (12.5, 5), (16.5, 8), (24.5, 10), (32.5, 12)):
        if ram_gb <= limit:
            return heap
    return 16


def java_major_from_release(game_dir: Path) -> int | None:
    for jre in ("jre64", "jre", "jre64/Contents/Home"):
        release = game_dir / jre / "release"
        if release.is_file():
            m = re.search(r'JAVA_VERSION="(\d+)', release.read_text(errors="replace"))
            if m:
                return int(m.group(1))
    return None


def resolve_profile(profile: str, java_major: int) -> str:
    if profile != "auto":
        return profile
    return "zgc-gen" if java_major >= 21 else "zgc"


def profile_args(profile: str, heap_gb: int, java_major: int, thp: bool = False) -> list[str]:
    heap = [f"-Xms{heap_gb}g", f"-Xmx{heap_gb}g"]
    common_tail = ["-XX:+AlwaysPreTouch", "-XX:+PerfDisableSharedMem"]
    if thp:
        common_tail.append("-XX:+UseTransparentHugePages")
    if profile == "zgc":
        # ZGC não-geracional (JDK 15-22). Pausas < 1 ms; o risco é "Allocation Stall"
        # quando a taxa de alocação supera o ciclo concorrente -> heap com folga + spike tolerance.
        return heap + ["-XX:+UseZGC", "-XX:ZAllocationSpikeTolerance=5"] + common_tail
    if profile == "zgc-gen":
        if java_major < 21:
            raise SystemExit("zgc-gen requer JDK 21+ (o JRE do jogo é %d)" % java_major)
        gen = ["-XX:+ZGenerational"] if java_major < 23 else []  # padrão a partir do 23
        return heap + ["-XX:+UseZGC"] + gen + common_tail
    if profile == "g1":
        return heap + [
            "-XX:+UseG1GC",
            "-XX:MaxGCPauseMillis=10",
            "-XX:+UnlockExperimentalVMOptions",
            "-XX:G1NewSizePercent=30",
            "-XX:G1MaxNewSizePercent=50",
            "-XX:G1ReservePercent=15",
            "-XX:InitiatingHeapOccupancyPercent=20",
            "-XX:G1HeapRegionSize=16m",
            "-XX:G1MixedGCCountTarget=4",
            "-XX:+ParallelRefProcEnabled",
        ] + common_tail
    if profile == "shenandoah":
        return heap + ["-XX:+UseShenandoahGC"] + common_tail
    raise SystemExit(f"perfil desconhecido: {profile}")


def diagnostics_args(gc_log: bool, jfr: bool, agent: str | None) -> list[str]:
    out = []
    if gc_log:
        # caminho relativo: ':' de "C:\" quebraria o parser do -Xlog
        out.append("-Xlog:gc*,safepoint:file=zperf-gc.log:time,uptime,level,tags:filecount=5,filesize=20m")
    if jfr:
        out.append("-XX:StartFlightRecording=filename=zperf.jfr,settings=profile,maxsize=512m,dumponexit=true")
    if agent:
        out.append(f"-javaagent:{agent}")
    return out


def patch_vmargs(vmargs: list[str], new_args: list[str]) -> list[str]:
    kept = [a for a in vmargs if not is_managed(a)]
    return kept + new_args


def find_json(game_dir: Path) -> Path:
    for name in ("ProjectZomboid64.json", "ProjectZomboid32.json"):
        p = game_dir / name
        if p.is_file():
            return p
    raise SystemExit(f"ProjectZomboid64.json não encontrado em {game_dir} (use --json)")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game-dir", type=Path)
    ap.add_argument("--json", type=Path, help="caminho explícito do ProjectZomboid64.json")
    ap.add_argument("--profile", choices=PROFILES, default="auto")
    ap.add_argument("--heap", default="auto", help="auto ou N/Ng (ex.: 10g)")
    ap.add_argument("--java-version", type=int, help="força a versão do JRE do jogo")
    ap.add_argument("--thp", action="store_true", help="Linux: -XX:+UseTransparentHugePages")
    ap.add_argument("--gc-log", action="store_true", help="grava zperf-gc.log (rotativo)")
    ap.add_argument("--jfr", action="store_true", help="grava zperf.jfr ao sair (perfil completo)")
    ap.add_argument("--agent", help="caminho do zperf-agent.jar (opcional =args)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--restore", action="store_true", help="restaura o backup original")
    a = ap.parse_args(argv)

    if not a.json and not a.game_dir:
        ap.error("informe --game-dir ou --json")
    path = a.json or find_json(a.game_dir.expanduser())
    game_dir = a.game_dir.expanduser() if a.game_dir else path.parent
    backup = path.with_name(path.name + ".zperf-backup")

    if a.restore:
        if not backup.exists():
            raise SystemExit("sem backup para restaurar")
        shutil.copy2(backup, path)
        print(f"restaurado {path}")
        return 0

    data = json.loads(path.read_text(encoding="utf-8"))
    vmargs = data.get("vmArgs")
    if not isinstance(vmargs, list):
        raise SystemExit("JSON sem lista 'vmArgs'")

    java_major = a.java_version or java_major_from_release(game_dir) or 17
    profile = resolve_profile(a.profile, java_major)

    if a.heap == "auto":
        ram = total_ram_gb()
        heap_gb = auto_heap_gb(ram) if ram else 8
        print(f"RAM detectada: {ram:.1f} GB -> heap {heap_gb} GB" if ram else "RAM desconhecida -> heap 8 GB")
        if ram and ram <= 8.5:
            print("AVISO: com 8 GB de RAM, mods pesados vão disputar memória com o driver; reduza mods.")
    else:
        heap_gb = int(a.heap.lower().rstrip("g"))

    new_args = profile_args(profile, heap_gb, java_major, a.thp) + diagnostics_args(a.gc_log, a.jfr, a.agent)
    patched = patch_vmargs(vmargs, new_args)

    print(f"JRE {java_major}, perfil {profile}")
    for arg in vmargs:
        if arg not in patched:
            print(f"  - {arg}")
    for arg in patched:
        if arg not in vmargs:
            print(f"  + {arg}")

    if a.dry_run:
        return 0
    if not backup.exists():
        shutil.copy2(path, backup)
        print(f"backup: {backup}")
    data["vmArgs"] = patched
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=4) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    print(f"gravado {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
