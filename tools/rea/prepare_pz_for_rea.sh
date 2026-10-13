#!/usr/bin/env bash
# Prepara as classes Java do Project Zomboid para o REA (morluto/rea).
#
# O provider Java do REA é o JADX headless e ele só admite um ".apk" (DEX dentro de ZIP).
# O PZ é bytecode JVM: B42 traz projectzomboid.jar; B41 traz .class soltos (zombie/, se/...).
# Então: (1) empacota em JAR, (2) converte para DEX com d8 (Android build-tools),
# (3) embrulha em pz-classes.apk. Nada é executado: é só transformação de arquivo.
#
# Uso: prepare_pz_for_rea.sh <pasta-do-jogo> [saida]
# Requer: jar (JDK 17+), d8 (ANDROID_HOME/build-tools/<versão>/d8 ou variável D8), zip
# Opcional: ANDROID_JAR=/caminho/android.jar (API 26+) para o desugaring do d8.
set -euo pipefail

GAME_DIR=${1:?pasta do jogo}
OUT=${2:-./pz-rea}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

find_d8() {
    if [[ -n "${D8:-}" ]]; then echo "$D8"; return; fi
    if command -v d8 >/dev/null; then command -v d8; return; fi
    local sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
    if [[ -n "$sdk" ]]; then
        ls -d "$sdk"/build-tools/*/d8 2>/dev/null | sort -V | tail -1
    fi
}

if [[ -f "$GAME_DIR/projectzomboid.jar" ]]; then
    JAR="$GAME_DIR/projectzomboid.jar"
    echo "B42+: usando $JAR"
else
    echo "B41: empacotando .class soltos"
    JAR="$OUT/pz-b41.jar"
    # diretórios de topo que contêm .class (zombie, se, fmod, astar, ...)
    mapfile -t ROOTS < <(cd "$GAME_DIR" && find . -mindepth 2 -name '*.class' -print \
        | cut -d/ -f2 | sort -u)
    [[ ${#ROOTS[@]} -gt 0 ]] || { echo "nenhum .class em $GAME_DIR"; exit 1; }
    args=()
    for r in "${ROOTS[@]}"; do args+=(-C "$GAME_DIR" "$r"); done
    jar --create --file "$JAR" "${args[@]}"
fi

D8_BIN=$(find_d8)
if [[ -z "$D8_BIN" ]]; then
    cat <<EOF
d8 não encontrado. Instale Android command-line tools (sdkmanager "build-tools;34.0.0")
ou use o caminho sem REA:  jadx -d "$OUT/src" "$JAR"   |   javap -c -p -classpath "$JAR" <classe>
EOF
    exit 2
fi

LIBS=()
[[ -n "${ANDROID_JAR:-}" ]] && LIBS+=(--lib "$ANDROID_JAR")
# dependências do jogo como classpath reduzem avisos de tipos ausentes
CP=()
while IFS= read -r j; do CP+=(--classpath "$j"); done < <(find "$GAME_DIR" -maxdepth 2 -name '*.jar' ! -name 'projectzomboid.jar')

rm -f "$OUT"/classes*.dex
"$D8_BIN" --release --min-api 26 "${LIBS[@]}" "${CP[@]}" --output "$OUT" "$JAR"
(cd "$OUT" && rm -f pz-classes.apk && zip -q pz-classes.apk classes*.dex)
echo
echo "pronto: $OUT/pz-classes.apk"
echo "teste:  rea search-android-classes \"$OUT/pz-classes.apk\" IsoZombie"
