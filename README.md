# ZPerf: desempenho do Project Zomboid com muitos mods e zoom-out

Kit para atacar FPS baixo e stutter no Project Zomboid (B41/B42) em três camadas, com medição
antes e depois:

| Camada | O que é | Pasta |
|---|---|---|
| **JVM** | perfis de GC (ZGC tunado, G1, ZGC geracional), heap por RAM, patcher seguro do `ProjectZomboid64.json` | `jvm/` |
| **Medição** | agente Java só-leitura: pausas de GC, *Allocation Stalls*, hiccups, memória on/off-heap, hotspots de CPU/alocação e **qual mod Lua** ocupa a thread principal | `java-agent/` |
| **Mod Lua** | profiler por mod, LOD de `OnZombieUpdate` por distância/tela, scheduler com orçamento, object pooling | `mod/ZPerf/` |
| **Config** | `options.ini` (limite de zoom-out, sombras, texturas), sem criar chaves inválidas | `config/` |
| **REA** | playbook para confirmar no bytecode do seu build cada suposição sobre o motor | `tools/rea/`, `docs/05` |

## Documentação
1. [Diagnóstico (root cause)](docs/01-diagnostico.md): zoom², culling, horda, GC, Kahlua
2. [JVM: GC, heap, off-heap, agente](docs/02-jvm.md)
3. [Mod ZPerf: LOD, scheduler, pooling, checklist para autores](docs/03-mod-zperf.md)
4. [Motor e render: options.ini, zoom, sandbox, SO](docs/04-motor-render.md)
5. [Playbook REA](docs/05-rea-playbook.md)

## Início rápido (ordem recomendada)

```bash
# 0) medir primeiro (requer JDK 17+ só para compilar)
java-agent/build.sh && cp java-agent/dist/zperf-agent.jar "<jogo>/"
python jvm/patch_vmargs.py --game-dir "<jogo>" --agent zperf-agent.jar --dry-run   # revise
python jvm/patch_vmargs.py --game-dir "<jogo>" --agent zperf-agent.jar --gc-log

# 1) mod (profiler + LOD); ative "ZPerf" no menu Mods
python tools/build_mod.py --install

# 2) options.ini (com o jogo fechado)
python config/tune_options.py --max-zoom 150 --dry-run
python config/tune_options.py --max-zoom 150

# 3) jogue 10 min no cenário que trava e leia ~/Zomboid/zperf/<sessão>/ + console.txt
```
Tudo é reversível: `patch_vmargs.py --restore` e `tune_options.py --restore`. Para desativar o mod,
basta desmarcá-lo.

## Como ler o resultado

| Sintoma no arquivo | Causa | Ação |
|---|---|---|
| `stalls.csv` com linhas | GC não acompanha a alocação | heap maior → perfil `g1` ou JRE 21 + `zgc-gen` → cortar mods que alocam (ver `hotspots.txt`, seção Alocação) |
| `gc.csv` com `kind=pause` > 10 ms | GC STW | trocar perfil |
| `hotspots.txt`: "Lua ativo em > 30%" | mods na thread principal | `console.txt` → `[ZPerf] top handlers`; LOD/scheduler; remover o pior mod |
| `hiccups.csv` com picos **sem** GC | SO/disco/antivírus | exclusões do antivírus, SSD ([04 §5](docs/04-motor-render.md)) |
| Nada disso, GPU a 100% | render (zoom/4K) | `--max-zoom`, efeitos de tela, `texture2x=false` |

## Testes

```bash
./run_tests.sh      # requer lua5.1, python3, JDK 17+
```
- **Lua** (37 checks): stub da API do PZ (`tests/lua/pz_stub.lua`) cobrindo interceptação de
  `Events.*.Add/Remove`, dispatcher único, frequências por tier do LOD, `fullRateSources`, isolamento
  de erros, profiler, scheduler (`every`/`when`/`sliced`/`defer` com orçamento), pool e utilitários.
- **Python** (9): preservação de `vmArgs` não gerenciados, idempotência, ordem de
  `UnlockExperimentalVMOptions`, backup/restore, política de heap, `options.ini` sem chaves novas.
- **Java** (ponta a ponta): "jogo" falso com o layout do Kahlua; o agente atribui 87% das amostras
  Lua a `ModHeavy.lua` (esperado 87,5%) e grava todos os CSVs. A JVM encerra limpa.
- Os perfis de GC foram validados com `java <flags> -version` (JDK 21).

## O que foi e o que não foi verificado

- O REA foi estudado pelo código-fonte para montar o playbook. Ele **não foi executado contra o
  PZ** aqui: os binários do jogo não estão neste ambiente e a instalação de pacotes de terceiros foi
  bloqueada. Nomes de classes, campos e chaves do jogo estão marcados como **[PZ]** e mapeados para
  as perguntas Q1–Q6 de `tools/rea/questions.json`.
- Mod e agente degradam com segurança se algo divergir: funções globais ausentes viram fallback,
  e um layout Kahlua diferente desliga só o sampler Lua e loga os campos reais.
- Primeiro teste: save descartável, com o `console.txt` aberto.
