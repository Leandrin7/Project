#!/usr/bin/env python3
"""Ajusta ~/Zomboid/options.ini a partir de um perfil (options-perf.ini).

  python tune_options.py --list                      # mostra chaves de desempenho atuais
  python tune_options.py --dry-run                   # o que mudaria
  python tune_options.py --max-zoom 150              # remove níveis de zoom-out acima de 150%
  python tune_options.py                             # aplica (backup em options.ini.zperf-backup)
  python tune_options.py --restore

Regras de segurança:
  * nunca cria chave nova: só altera chaves que já existem no seu options.ini
    (nomes mudam entre B41 e B42; chave ausente é reportada e ignorada);
  * feche o jogo antes: o PZ regrava options.ini ao sair.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PERF_HINT = re.compile(r"light|fps|frame|zoom|texture|shadow|puddle|fog|vsync|perf|quality|blood|corpse|"
                       r"tile|water|rain|weather|sky|model|aniso|mipmap|resolution|fullscreen", re.I)
ZOOM_KEYS = ("zoomLevels1x", "zoomLevels2x")


def default_options_path() -> Path:
    return Path.home() / "Zomboid" / "options.ini"


def parse_ini(text: str) -> list[tuple[str | None, str]]:
    """Lista de (chave, linha original). Linhas sem '=' têm chave None."""
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if "=" in stripped and not stripped.startswith((";", "#")):
            out.append((stripped.split("=", 1)[0].strip(), line))
        else:
            out.append((None, line))
    return out


def read_profile(path: Path) -> dict[str, str]:
    prof = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split(";", 1)[0].split("#", 1)[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            prof[k.strip()] = v.strip()
    return prof


def cap_zoom(value: str, max_pct: int) -> str:
    """'50;75;125;150;175;200' com max 150 -> '50;75;125;150'. Valores > 100 = mais afastado."""
    kept = []
    for part in value.split(";"):
        part = part.strip()
        if not part:
            continue
        try:
            if int(float(part)) > max_pct:
                continue
        except ValueError:
            pass
        kept.append(part)
    return ";".join(kept)


def apply(lines: list[tuple[str | None, str]], profile: dict[str, str], max_zoom: int | None):
    present = {k for k, _ in lines if k}
    changes, out = [], []
    for key, line in lines:
        if key is None:
            out.append(line)
            continue
        old = line.split("=", 1)[1].strip()
        new = old
        if key in profile:
            new = profile[key]
        if max_zoom is not None and key in ZOOM_KEYS:
            new = cap_zoom(new, max_zoom)
        if new != old:
            changes.append((key, old, new))
            out.append(f"{key}={new}")
        else:
            out.append(line)
    missing = sorted(k for k in profile if k not in present)
    return out, changes, missing


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--options", type=Path, default=default_options_path())
    ap.add_argument("--profile", type=Path, default=HERE / "options-perf.ini")
    ap.add_argument("--max-zoom", type=int, help="maior zoom-out permitido em %% (ex.: 150)")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--restore", action="store_true")
    a = ap.parse_args(argv)

    path = a.options.expanduser()
    backup = path.with_name(path.name + ".zperf-backup")
    if a.restore:
        shutil.copy2(backup, path)
        print(f"restaurado {path}")
        return 0
    if not path.is_file():
        raise SystemExit(f"não encontrado: {path} (rode o jogo uma vez ou use --options)")

    lines = parse_ini(path.read_text(encoding="utf-8", errors="replace"))
    if a.list:
        for key, line in lines:
            if key and PERF_HINT.search(key):
                print(line)
        return 0

    profile = read_profile(a.profile)
    out, changes, missing = apply(lines, profile, a.max_zoom)
    for key, old, new in changes:
        print(f"  {key}: {old} -> {new}")
    if missing:
        print("ignoradas (não existem neste options.ini/build): " + ", ".join(missing))
    if not changes:
        print("nada a mudar")
        return 0
    if a.dry_run:
        return 0
    if not backup.exists():
        shutil.copy2(path, backup)
        print(f"backup: {backup}")
    tmp = path.with_suffix(".ini.tmp")
    tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    print(f"gravado {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
