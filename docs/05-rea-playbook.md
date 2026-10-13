# 5. Playbook REA: validar cada suposição contra o SEU build do PZ

[REA (morluto/rea)](https://github.com/morluto/rea) é um servidor MCP + CLI de engenharia reversa.
Aqui ele serve para **confirmar no bytecode real** os pontos marcados **[PZ]** em
[01](01-diagnostico.md) e os nomes que o mod e o agente assumem, em vez de confiar na memória.

## Por que é preciso converter o jogo

O provider Java do REA é o **JADX headless** e ele admite **apenas `.apk`**. O REA classifica pela
extensão e o snapshot vira `target.apk` (`src/domain/zipPackageFormat.ts`,
`src/android/JadxProvider.ts`). O PZ é bytecode JVM, então:

```
B42: projectzomboid.jar ─┐
B41: zombie/, se/ ... ───┴─► jar ─► d8 (DEX) ─► pz-classes.apk ─► REA (JADX)
```

## Passo a passo

1. **Instale e registre o REA no seu agente** (Node 22.19+/24.11+):
   ```bash
   npx rea-agents setup        # escolha Claude Code; reinicie o agente
   ```
2. **Provider JADX** (JDK 17+ completo):
   ```bash
   # baixe jadx-headless-mcp-0.7.1-all.jar (versão fixada pelo REA)
   export REA_JADX_MCP_JAR=/abs/jadx-headless-mcp-0.7.1-all.jar
   export JAVA_HOME=/abs/jdk-21
   ```
3. **Converta o jogo** (Android build-tools para o `d8`):
   ```bash
   export ANDROID_JAR=$ANDROID_HOME/platforms/android-34/android.jar   # desugaring
   tools/rea/prepare_pz_for_rea.sh "<pasta do jogo>" ./pz-rea
   rea search-android-classes ./pz-rea/pz-classes.apk IsoZombie
   ```
4. **Rode as perguntas** de [`tools/rea/questions.json`](../tools/rea/questions.json), pelo
   agente (MCP) ou pela CLI:
   ```bash
   APK=$(pwd)/pz-rea/pz-classes.apk
   rea inspect-android-method "$APK" zombie.characters.IsoZombie update
   rea trace-android-references "$APK" zombie.Lua.LuaEventManager --method-name triggerEvent
   rea inspect-android-class "$APK" se.krka.kahlua.vm.Coroutine
   rea inspect-android-method "$APK" zombie.core.Core saveOptions
   ```
   Prompt pronto para o agente:
   > Use o REA no APK `<caminho>` e responda Q1–Q6 de `tools/rea/questions.json`. Para cada uma,
   > mostre a evidência (método e trecho) e diga se a expectativa se confirma. Para Q3, liste os
   > nomes e tipos dos campos.

## O que fazer com cada resposta

| Pergunta | Se confirmar | Se divergir |
|---|---|---|
| Q1 `OnZombieUpdate` por zumbi/tick | LOD justificado; nada a mudar | Se o jogo já filtra por distância, reduza `interval` ou desligue `zombieLOD` |
| Q2 zoom → buffer/área | `--max-zoom` é a alavanca nº 1 | Ajuste a tabela de [04](04-motor-render.md) |
| Q3 layout Kahlua | Agente mostra "Lua: handler raiz" | Edite os nomes em `LuaSampler.java` (o log `[ZPerf] lua sampler: layout...` já lista os campos reais) |
| Q4 `isoToScreenX` | Teste de tela do LOD correto | Se não inclui o offset do jogador, some `getPlayerScreenLeft(i)` em `Focus.isOnScreen` |
| Q5 `Core.saveOptions` | Descomente chaves em `options-perf.ini` com a escala certa | Corrija os nomes |
| Q6 ordem de load | `!!ZPerf_Bootstrap.lua` roda antes | Renomeie conforme a regra real de ordenação |

## Sem Android SDK

Se você não quer instalar o `d8`, dá para responder as mesmas perguntas sem REA:
```bash
jadx -d ./pz-src projectzomboid.jar                       # JADX CLI aceita .jar direto
javap -p -classpath projectzomboid.jar se.krka.kahlua.vm.Coroutine   # só assinaturas/campos
```
O REA acrescenta evidência estruturada (hash do artefato, cobertura, limitações), útil para
registrar *por que* cada ajuste foi feito.

## Natives (opcional)

Iluminação (`LightingJNI`), pathfinding e população têm partes nativas (`.dll`/`.so` na pasta do
jogo). Com um provider nativo do REA (Ghidra/Hopper/IDA):
```bash
rea analyze "<jogo>/win64/<lib>.dll" --provider ghidra --json
rea search  "<jogo>/win64/<lib>.dll" "update" --provider ghidra --json
```
Isso serve para entender custo e threads. Não há ajuste prático a extrair dali além de `lightingFPS`.

## Status da verificação neste repositório

- **Feito**: leitura do código-fonte do REA para definir o fluxo (JADX/APK, nomes dos argumentos MCP
  `path`/`query`/`class_name`/`method_name`). O passo de empacotamento B41→JAR do script foi
  testado com classes de exemplo.
- **Não feito aqui**: rodar o REA contra o PZ. O ambiente não tem os binários do jogo (licença
  Steam) e a execução de pacotes de terceiros (npm/JADX) foi bloqueada pela política do sandbox.
  As perguntas acima são exatamente o que falta rodar na sua máquina.
