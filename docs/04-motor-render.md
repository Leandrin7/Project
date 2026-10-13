# 4. Motor e renderizador: o que dá para ajustar

> Não existe `optionsof.ini` no Project Zomboid. As configurações de cliente ficam em
> `~/Zomboid/options.ini` (Windows: `C:\Users\<você>\Zomboid\options.ini`). Feche o jogo antes de
> editar, porque ele regrava o arquivo ao sair.

## 1. Script
```bash
python config/tune_options.py --list              # chaves de desempenho no SEU arquivo
python config/tune_options.py --max-zoom 150 --dry-run
python config/tune_options.py --max-zoom 150      # aplica (backup: options.ini.zperf-backup)
python config/tune_options.py --restore
```
O script **nunca cria chave**: aplica `config/options-perf.ini` só nas chaves que já existem
(os nomes mudam entre B41 e B42) e lista as ignoradas.

## 2. Alavancas em ordem de impacto (zoom-out + mods)

| # | Ajuste | Onde | Efeito | Confiança |
|---|---|---|---|---|
| 1 | **Limitar o zoom-out máximo** (ex.: 150% em vez de 200%) | `zoomLevels1x` / `zoomLevels2x` (`--max-zoom`) | 200%→150% = **~44% menos squares** visíveis (1,5² / 2² = 0,56) | chave alta; confirme no menu que o maior nível sumiu |
| 2 | Sombras de cadáver off | `corpseShadows=false` | corta draw calls com hordas mortas | alta |
| 3 | Compressão de textura | `textureCompression=true` | menos VRAM/banda com tilesets de mods | alta |
| 4 | Iluminação | `lightingFPS=15` (≥10); qualidade no menu | thread nativa de luz + upload por square | alta (FPS) / verificar escala (qualidade) |
| 5 | Poças, reflexos, céu, neblina | `perfPuddles`, `perfReflections`, `perfSkybox`, `fogQuality` | shaders de tela cheia, custo de GPU que cresce com o zoom | escala varia: use o menu ou REA Q5 |
| 6 | Texturas 2x de tiles | `texture2x=false` | VRAM ÷4 nos tiles; custa nitidez em zoom-in | média |
| 7 | VSync off + teto de FPS | `vsync=false`, `frameRate=N` | frametime estável, sem cair de 60 para 30 | alta |

**Diagnóstico de GPU x CPU**: abra o overlay (Steam/Adrenalin/GeForce). GPU abaixo de 70% com FPS
baixo significa CPU-bound na thread principal, e aí os itens 5 e 6 quase não mudam nada: o foco
são os mods (ZPerf) e o GC. GPU em 95–100% (4K, zoom máximo) é o caso em que 1, 5 e 6 dão ganho.

## 3. Shaders
Os shaders do jogo ficam em `media/shaders`. Um mod pode sobrescrevê-los, mas **não recomendo** como
otimização. O custo dominante do PZ está na CPU (montagem de sprites e draw calls na thread
principal), não no fragment shader. Desligar os efeitos pelas opções (item 5) dá o mesmo ganho de GPU
sem quebrar a cada atualização do jogo.

## 4. Sandbox e servidor (simulação de horda)

| Ajuste | Onde | Efeito |
|---|---|---|
| População | Sandbox → Zombie Config → `PopulationMultiplier` | custo linear em update, pathfinding e mods com `OnZombieUpdate` |
| Tamanho de grupo / rally | `RallyGroupSize`, `RallyTravelDistance` | hordas menores = rajadas menores de pathfinding |
| Respawn | `RespawnHours`, `RespawnMultiplier` | menos zumbis recriados em áreas já limpas |
| MP: sync de zumbis | `server.ini` (B41): `ZombieUpdateMaxHighPriority`, `ZombieUpdateRadiusHighPriority`/`LowPriority`, `ZombieUpdateDelta` (se existirem no seu build) | banda e CPU do servidor por cliente |

## 5. Sistema operacional (causas comuns de hiccup que não são GC)
- **Antivírus**: exclua `~/Zomboid` (saves, chunks, logs) e a pasta do jogo da varredura em tempo
  real. Gravação de chunk escaneada a cada escrita é a causa nº 1 de hitch ao dirigir.
- **SSD** para jogo e saves (streaming de chunk).
- **Plano de energia** de alto desempenho; driver NVIDIA: "Power management mode = Prefer maximum
  performance". "Threaded optimization" (OpenGL) muda conforme a máquina: teste On e Off com o
  `hotspots.txt` aberto.
- Se `hiccups.csv` mostra picos sem GC correspondente em `gc.csv`, o problema é do SO, do disco ou do
  antivírus, não da JVM.
