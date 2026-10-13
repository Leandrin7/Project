#!/usr/bin/env bash
# Requer: lua5.1 (+ luac5.1), python3, JDK 17+
set -euo pipefail
cd "$(dirname "$0")"
echo "== Lua: sintaxe"
find mod -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p
echo "== Lua: testes do mod"
lua5.1 tests/lua/test_zperf.lua
echo "== Python: scripts de JVM/options"
python3 -m unittest discover -s tests/python
echo "== Java: agente ponta a ponta"
tests/java/run.sh
echo "== mod: build"
python3 tools/build_mod.py
