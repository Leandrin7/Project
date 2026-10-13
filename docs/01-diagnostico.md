# 1. Diagnóstico: por que o PZ trava com muitos mods e zoom-out

> Marcação usada aqui: **[fato]** é comportamento da JVM ou do Lua/Kahlua, independente do jogo.
> **[PZ]** é arquitetura do jogo que conheço do B41/B42, mas que você deve confirmar no seu build
> com o playbook REA ([05-rea-playbook.md](05-rea-playbook.md), pergunta indicada).

## 1.1 Onde o tempo de um frame vai

```
 thread principal (lógica)            thread de render          threads auxiliares
 ───────────────────────────          ─────────────────         ─────────────────────
 IsoWorld/IsoCell.update              executa GL do frame       LightingJNI (nativo, lightingFPS)
  ├─ personagens (IA, animação)       anterior (sprites,        PolygonalMap2 (pathfinding)
  ├─ eventos Lua (OnTick,             modelos, FBOs)            WorldStreamer (chunks, disco)
  │   OnPlayerUpdate, OnZombieUpdate…)                          rede / áudio (FMOD)
  └─ monta o "render state" do frame ─┘
```

**[PZ]** O frame só fica pronto quando a thread principal termina **lógica + Lua + montagem do
estado de render**. É quase sempre ela o gargalo: GPU em 40–60% de uso com FPS baixo significa
CPU-bound na thread principal, e aí mexer em shader não resolve nada.

## 1.2 Zoom-out e "render distance"

O PZ não tem render distance no sentido 3D. A área carregada vem do **chunk map**, de tamanho fixo
em torno do jogador. O zoom-out só aumenta a **parte visível** dessa área:

| Efeito do zoom-out | Escala | Por quê |
|---|---|---|
| Squares visíveis por andar | **∝ zoom²** | a tela cobre zoom× mais tiles em X e em Y |
| Objetos/sprites desenhados | ∝ zoom² × andares × objetos/square | piso, paredes, móveis, itens, vegetação, cadáveres |
| Personagens visíveis (modelo 3D + animação) | ∝ zoom² × densidade | cada zumbi visível exige skinning + draw |
| Buffer offscreen do mundo **[PZ, Q2]** | ∝ zoom² em pixels | o mundo é renderizado numa textura escalada pelo zoom |
| Cutaway / esconder telhado / iluminação de squares | ∝ squares visíveis | trabalho de CPU por square |

Passar de 100% para 200% de zoom-out são **4×** os squares e potencialmente **4×** os pixels do
buffer do mundo. Com tilesets de alta resolução de mods, isso também é 4× de textura amostrada por
frame.

**"Frustum culling" no PZ** **[PZ]**: é culling 2D por retângulo de tela sobre a grade iso, por
square e por andar. É barato e funciona; o problema é que ele não reduz o que está *legitimamente*
visível. Por isso as alavancas reais são:
1. limitar o zoom-out máximo (`zoomLevels1x/2x`, [04](04-motor-render.md));
2. baratear cada square (sombras de cadáver, poças, neblina, compressão de textura);
3. tirar trabalho da thread principal (Lua dos mods, a seguir).

### O zoom aumenta a simulação de horda?

**Não diretamente.** **[PZ]** IA, pathfinding e população dependem da área *carregada*, não do zoom.
O que o zoom aumenta é o número de zumbis **visíveis** (render + animação completa). Já a
**simulação de horda** pesa por três caminhos que não dependem do zoom:

- **Pathfinding** (`PolygonalMap2`, thread própria): hordas (rally, migração, som) disparam rajadas
  de pedidos de rota. Em CPU de 4 núcleos essa thread disputa núcleo com a principal e com o GC.
- **Update por zumbi** na thread principal: estado, colisão, alvo, animação.
- **Mods com `OnZombieUpdate`**: custo = zumbis carregados × handlers, **por tick, mesmo fora da
  tela** **[PZ, Q1]**. Com 400 zumbis e 6 mods são 2.400 chamadas Java→Lua por frame. Esse é o
  multiplicador que o ZPerf ataca.

## 1.3 Memória e Garbage Collector

### Por que o GC causa stutter mesmo com ZGC

**[fato]** O B41 já vem com `-XX:+UseZGC` no JRE 17, e o ZGC do JDK 17 **não é geracional**: cada
ciclo marca o heap inteiro. O PZ tem muito dado de vida longa (mundo, chunks, metadados de textura,
estado Lua dos mods) e uma taxa de alocação alta por frame. Quando a alocação supera o ciclo
concorrente:

1. ciclos de GC rodam um atrás do outro e roubam CPU das threads do jogo (FPS cai);
2. o heap enche antes do ciclo terminar, e a thread que tenta alocar **para** até haver memória livre.
   Isso é o **Allocation Stall**: picos de 10 a 500 ms, o stutter clássico.

O MXBean de GC não mostra o Allocation Stall, só o evento JFR `jdk.ZAllocationStall`. O agente
ZPerf grava esse evento em `stalls.csv`.

### De onde vem a alocação

| Fonte | Mecanismo | Escala com |
|---|---|---|
| **Lua dos mods (Kahlua)** | ver 1.4 | nº de mods × frequência dos eventos |
| Render state | objetos por sprite/modelo por frame **[PZ]** | squares e personagens visíveis (zoom) |
| Streaming de chunks | `IsoGridSquare`/objetos ao carregar **[PZ]** | velocidade de deslocamento (carro!) |
| Texturas de mods | staging em direct buffers / LWJGL (off-heap) | tamanho dos tilesets |

### Heap x off-heap

Texturas vão para a VRAM pelo driver. O caminho até lá (staging, cópias do driver, natives do LWJGL,
Bullet, iluminação, FMOD) é memória **nativa**, fora do `-Xmx`. Um `-Xmx` grande demais rouba RAM
desse caminho: o driver começa a paginar e o resultado é hitch ao entrar em área nova ou ao dar
zoom-out. Por isso o heap tem teto (tabela em [02](02-jvm.md)) e não deve ser "o máximo possível".

## 1.4 Kahlua: por que Lua "gera lixo Java"

**[fato]** O PZ roda Lua 5.1 no **Kahlua**, um interpretador escrito em Java:

| Construção Lua | Custo na JVM |
|---|---|
| `local t = {}` | objeto Java da tabela + arrays internos de hash/array |
| número (`x + 1`) | `java.lang.Double` boxed; o JIT elimina parte disso por escape analysis, mas não quando o valor vai para uma tabela ou upvalue |
| `function() ... end` dentro de loop/handler | `LuaClosure` + upvalues novos a cada execução |
| `a .. "," .. b` | `String` nova (e às vezes um `StringBuilder`) |
| `obj:metodo(x)` (Java exposto) | marshalling de argumentos, lookup do método exposto, boxing do retorno |
| `...` (varargs) | tabela/array temporário |
| `pairs`/`ipairs` em lista Java | conversões; prefira `size()`/`get(i)` |

Um mod que, a cada tick, faz `for` nos zumbis criando `{x=..., y=...}` e chaves `x..","..y` gera
facilmente dezenas de MB/s. Somando 10 mods assim, o GC fica no limite.

## 1.5 Como confirmar no SEU jogo (5 minutos)

1. Instale o agente ([02 §5](02-jvm.md#5-medindo-o-agente-zperf)) e o mod ZPerf ([03](03-mod-zperf.md)).
2. Jogue 10 minutos no cenário que trava (horda + zoom-out + carro).
3. Leia:
   - `stalls.csv` com linhas → GC não acompanha: aumente o heap ou reduza a alocação (mods);
   - `gc.csv` com `kind=pause` acima de 10 ms → troque o perfil de GC;
   - `hiccups.csv` com picos que **não** batem com GC → SO/disco/antivírus;
   - `hotspots.txt`: "Lua ativo em X%". Acima de ~30% da thread principal, os mods são o gargalo,
     e a seção "handler raiz" mostra **qual arquivo de qual mod**;
   - `console.txt` com `[ZPerf] top handlers` → ms/s por handler, medido no lado Lua.
