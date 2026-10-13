#!/usr/bin/env python3
"""Monta dist/ZPerf compatível com B41 (raiz) e B42 (42/ + common/) no mesmo diretório.

  python tools/build_mod.py                  # gera dist/ZPerf
  python tools/build_mod.py --install        # copia para ~/Zomboid/mods/ZPerf
"""
import argparse
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "mod" / "ZPerf"


def build(dest: Path) -> Path:
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    # B41: mod.info + media na raiz
    shutil.copy2(SRC / "mod.info", dest / "mod.info")
    shutil.copytree(SRC / "media", dest / "media")
    # B42: pasta por versão + common obrigatória
    (dest / "common").mkdir()
    (dest / "42").mkdir()
    shutil.copy2(SRC / "mod.info", dest / "42" / "mod.info")
    shutil.copytree(SRC / "media", dest / "42" / "media")
    return dest


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--install", action="store_true")
    a = ap.parse_args()
    out = build(ROOT / "dist" / "ZPerf")
    print(f"gerado {out}")
    if a.install:
        target = Path.home() / "Zomboid" / "mods" / "ZPerf"
        build(target)
        print(f"instalado em {target}")


if __name__ == "__main__":
    main()
