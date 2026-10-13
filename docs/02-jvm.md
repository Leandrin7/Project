# 2. JVM: GC, heap e off-heap

Arquivo alvo: `ProjectZomboid64.json`, na pasta do jogo (cliente Windows/Linux e servidor Linux).
O servidor dedicado no Windows usa `StartServer64.bat`, onde as flags estão na linha do `java`.

## 1. Aplicar com o script (recomendado)

```bash
# ver o que mudaria
python jvm/patch_vmargs.py --game-dir "C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid" --dry-run
# aplicar: perfil automático pelo JRE do jogo + heap pela RAM + log de GC
python jvm/patch_vmargs.py --game-dir "<pasta do jogo>" --gc-log
# desfazer
python jvm/patch_vmargs.py --game-dir "<pasta do jogo>" --restore
```

O script lê a versão do JRE em `jre64/release`, remove **só** as flags que ele gerencia (GC, heap,
pretouch, logs, agente) e preserva `java.library.path`, `zomboid.steam` etc. Na primeira execução
ele cria `ProjectZomboid64.json.zperf-backup`. Todos os perfis foram validados com `java ... -version`
num JDK 21 (a JVM aceita as flags). As flags do perfil `zgc` também existem no JDK 17.

## 2. Perfis

### `zgc` (padrão para o JRE 17 do jogo)
```json
"-Xms10g", "-Xmx10g",
"-XX:+UseZGC",
"-XX:ZAllocationSpikeTolerance=5",
"-XX:+AlwaysPreTouch",
"-XX:+PerfDisableSharedMem"
```
- **Xms = Xmx**: sem redimensionar o heap durante o jogo. ZGC com folga grande evita Allocation Stall.
- **ZAllocationSpikeTolerance=5** (padrão 2): o ZGC presume picos de alocação maiores e começa o
  ciclo mais cedo. É exatamente o padrão do PZ: rajadas ao carregar chunks e a cada evento Lua pesado.
- **AlwaysPreTouch**: toca todas as páginas do heap no boot. O jogo demora alguns segundos a mais
  para abrir, mas some o page fault durante o jogo (micro-hitch na primeira vez que o heap cresce).
- **PerfDisableSharedMem**: a JVM deixa de escrever estatísticas num arquivo mmap
  (`hsperfdata`). Em disco lento ou com antivírus, essa escrita pode travar a JVM num safepoint.

### `g1` (alternativa: CPU de 4 a 6 núcleos, ou se `stalls.csv` continuar cheio)
```json
"-Xms10g", "-Xmx10g",
"-XX:+UseG1GC", "-XX:MaxGCPauseMillis=10",
"-XX:+UnlockExperimentalVMOptions",
"-XX:G1NewSizePercent=30", "-XX:G1MaxNewSizePercent=50",
"-XX:G1ReservePercent=15", "-XX:InitiatingHeapOccupancyPercent=20",
"-XX:G1HeapRegionSize=16m", "-XX:G1MixedGCCountTarget=4",
"-XX:+ParallelRefProcEnabled",
"-XX:+AlwaysPreTouch", "-XX:+PerfDisableSharedMem"
```
O G1 tem pausas STW curtas (5 a 15 ms) mas **previsíveis**, e não deixa threads concorrentes
disputando núcleo o tempo todo. A geração jovem grande (30 a 50%) absorve o lixo de vida curta do
Kahlua, e o IHOP baixo inicia a marcação cedo para evitar full GC.

### `zgc-gen` (só com JRE 21+)
`-XX:+UseZGC -XX:+ZGenerational` (no 23+ o generacional já é o padrão). Coleta jovem separada:
é o melhor encaixe para o padrão de alocação do PZ, mas exige trocar o JRE (ver §4).

### `shenandoah`
Disponível só se o JRE tiver sido compilado com ele (Temurin tem, Oracle não). Comportamento
parecido com o ZGC não-geracional. Use apenas para comparar.

### Qual escolher

| Situação | Perfil |
|---|---|
| JRE 17 do jogo, 6+ núcleos | `zgc` |
| 4 núcleos / notebook / `stalls.csv` com linhas mesmo com heap folgado | `g1` |
| Você trocou o JRE para 21+ | `zgc-gen` |

## 3. Tamanho do heap (`--heap auto`)

| RAM total | `-Xms/-Xmx` | Sobra para SO + driver + natives |
|---|---|---|
| 8 GB | 3g (reduza mods) | ~5 GB |
| 12 GB | 5g | ~7 GB |
| 16 GB | **8g** | ~8 GB |
| 24 GB | 10g | ~14 GB |
| 32 GB | **12g** | ~20 GB |
| 64 GB+ | 16g | resto |

Acima de 12 a 16 GB não há ganho para o cliente: o ZGC não-geracional marca o heap inteiro, então
heap maior deixa cada ciclo mais longo. O servidor dedicado com 32+ jogadores é outro caso: lá
16 a 24 GB fazem sentido.

**Off-heap (texturas e tilesets de mods):**
- `-XX:MaxDirectMemorySize` tem como padrão o valor de `-Xmx`, então não precisa mexer. O LWJGL
  aloca boa parte da memória nativa via `MemoryUtil` (malloc), que nem passa por esse limite.
- Quem limita o off-heap na prática é a **RAM livre**. Por isso a tabela acima reserva bastante.
- Para ver o off-heap real: `memory.csv` (direct buffers) mais o RSS do processo no gerenciador de
  tarefas. RSS − heap ≈ nativo + driver. Atenção: no Linux o ZGC do JDK 17 mapeia o heap 3× e o RSS
  aparece inflado, então use o PSS ou o "Private Bytes" no Windows.
- Linux: `--thp` adiciona `-XX:+UseTransparentHugePages` (menos TLB miss em heap grande; precisa
  de `/sys/kernel/mm/transparent_hugepage/enabled` = `madvise` ou `always`).

## 4. Trocar o JRE para 21+ (experimental)

1. Faça backup da pasta `jre64`.
2. Extraia um Temurin 21 (x64, JRE ou JDK) **no lugar** de `jre64`.
3. `python jvm/patch_vmargs.py --game-dir ... --profile zgc-gen`.

Riscos: o jogo não é suportado nesse JRE pelo estúdio; natives antigos podem falhar e mods Java
(raros) também. Se der erro no boot, restaure `jre64` e rode `--restore`. Dá o maior ganho isolado
contra Allocation Stall, mas teste antes num save descartável.

## 5. Medindo: o agente ZPerf

```bash
java-agent/build.sh            # requer JDK 17+; gera java-agent/dist/zperf-agent.jar
copie zperf-agent.jar para a pasta do jogo
python jvm/patch_vmargs.py --game-dir ... --agent zperf-agent.jar
```

Argumentos (`--agent "zperf-agent.jar=hiccupMs=25,reportSec=30"`):

| arg | padrão | efeito |
|---|---|---|
| `out` | `~/Zomboid/zperf` | pasta de saída (uma subpasta por sessão) |
| `hiccupMs` | 20 | registra pausas da JVM acima disso (Windows: mínimo 20) |
| `sample` | true | CPU e alocação via JFR (`ExecutionSample`, `ObjectAllocationSample`) |
| `lua` | true | amostra a pilha Lua do Kahlua (100 Hz com jitter) |
| `reportSec` | 30 | período de escrita do `hotspots.txt` |
| `luaManagerClass`, `luaThreadField` | `zombie.Lua.LuaManager`, `thread` | ajuste se o REA mostrar outro layout |

O agente é **somente leitura**: não altera bytecode. O overhead esperado é baixo (amostragem JFR a
10 ms mais o sampler Lua a ~100 Hz em threads de prioridade baixa), mas ainda não foi medido no
jogo real. Para conferir, compare o FPS com e sem `sample=false,lua=false`. Se o JRE do jogo vier sem os módulos
`jdk.jfr`/`jdk.management`, a parte afetada se desliga sozinha e o log `[ZPerf] ... desativado`
explica o motivo.

Diagnóstico extra sem agente:
- `--gc-log` grava `zperf-gc.log` (procure `Allocation Stall` e `Pause`);
- `--jfr` grava `zperf.jfr` ao sair (abra no JDK Mission Control).
