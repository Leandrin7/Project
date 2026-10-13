#!/usr/bin/env bash
# Teste ponta a ponta do agente: "jogo" falso com layout Kahlua, 87,5% do tempo Lua em ModHeavy.
set -euo pipefail
cd "$(dirname "$0")"
../../java-agent/build.sh >/dev/null
rm -rf build && mkdir build
javac --release 17 -d build $(find src -name '*.java')
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
timeout 60 java -Xmx32m -XX:+UseZGC \
    -javaagent:../../java-agent/dist/zperf-agent.jar=out=$OUT,reportSec=30,hiccupMs=5 \
    -cp build fakegame.Main 14 >/dev/null
D=$(ls -d "$OUT"/*)
fail() { echo "FAIL: $*"; exit 1; }
for f in gc.csv memory.csv hiccups.csv hiccup-histogram.csv stalls.csv hotspots.txt; do
    [[ -f "$D/$f" ]] || fail "falta $f"
done
[[ $(wc -l < "$D/gc.csv") -gt 1 ]] || fail "gc.csv vazio"
[[ $(wc -l < "$D/memory.csv") -gt 3 ]] || fail "memory.csv vazio"
grep -q "ModHeavy.lua:10" "$D/hotspots.txt" || fail "atribuição Lua ausente"
heavy=$(grep -m1 "ModHeavy.lua:10" "$D/hotspots.txt" | awk '{print $1}' | tr -d '%')
awk -v h="$heavy" 'BEGIN { exit !(h > 75 && h < 97) }' || fail "ModHeavy=$heavy% (esperado ~87%)"
echo "agent ok (ModHeavy=$heavy% das amostras Lua)"
