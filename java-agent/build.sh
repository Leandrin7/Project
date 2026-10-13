#!/usr/bin/env bash
# Compila o agente para Java 17 (JRE do PZ) e gera dist/zperf-agent.jar
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/classes dist
javac --release 17 -Xlint:all -Werror -d build/classes $(find src -name '*.java')
cat > build/MANIFEST.MF <<'MF'
Premain-Class: zperf.agent.ZPerfAgent
Agent-Class: zperf.agent.ZPerfAgent
Can-Redefine-Classes: false
Can-Retransform-Classes: false
MF
jar --create --file dist/zperf-agent.jar --manifest build/MANIFEST.MF -C build/classes .
echo "dist/zperf-agent.jar"
