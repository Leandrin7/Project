# 3. Mod ZPerf (Lua): profiler, LOD de zumbis, scheduler e pooling

## Instalação

```bash
python tools/build_mod.py --install     # copia para ~/Zomboid/mods/ZPerf (layout B41 + B42)
```
Ative o mod **ZPerf** no menu Mods (ou no `Mods=` do servidor). No `console.txt`
(`~/Zomboid/console.txt`) deve aparecer:

```
[ZPerf] bootstrap ok; intercept: EveryHours=profile, ..., OnTick=profile, OnZombieUpdate=lod
```

Essa linha precisa vir **antes** do carregamento dos arquivos dos outros mods. O arquivo se chama
`!!ZPerf_Bootstrap.lua` porque o PZ carrega os `.lua` ordenados por caminho e `!` vem antes de
letras e dígitos (confirme com REA, Q6). Handlers registrados antes do bootstrap (vanilla, ou um
mod que também use `!!`) simplesmente não são medidos nem agrupados. Nada quebra.

## O que ele faz

### a) Profiler por mod/arquivo
O bootstrap troca `Events.<X>.Add/Remove` por versões que embrulham cada handler. A cada
`reportSeconds` (60 s), o `console.txt` recebe (exemplo ilustrativo de formato):

```
[ZPerf] ---- top handlers (60s) ----
[ZPerf]  1.    41.2 ms/s     3600 calls  OnTick           media/lua/client/SomeLootMod/Scanner.lua
[ZPerf]  2.    18.7 ms/s   215000 calls  OnZombieUpdate   media/lua/shared/SomeZedMod/Zeds.lua
```
`ms/s` é o custo em ms por segundo de jogo. A 60 FPS o orçamento inteiro do frame é 16,7 ms, então
**41 ms/s ≈ 0,7 ms por frame**. Esse número aponta o mod a otimizar ou remover.

O timer Lua do PZ tem resolução de 1 ms, então o profiler mede 1 a cada `sampleEvery` chamadas e
extrapola (estimativa estatística, sem viés). Para precisão real por função, use o agente Java
(seção "Lua: função folha" no `hotspots.txt`).

Console de debug (jogo com `-debug`): `ZPerfReport()`, `ZPerfLOD()`, `ZPerfSet("zombieLOD.interval", {1,2,6})`.

### b) LOD de `OnZombieUpdate`
Todos os `Events.OnZombieUpdate.Add(fn)` viram **um** dispatcher registrado no Java, o que já
corta o número de travessias Java→Lua de N handlers para 1. Depois, por zumbi:

| tier | condição | intervalo padrão |
|---|---|---|
| 1 | ≤ `nearTiles` (15) de um jogador local, visível ou não | todo tick |
| 2 | na tela (com margem de 160 px) **ou** ≤ `farTiles` (45) | a cada 3 ticks |
| 3 | fora da tela **e** > `farTiles` | a cada 10 ticks |

- A IA, o pathfinding e a animação **vanilla** (Java) não mudam. O LOD só reduz a frequência da
  lógica Lua dos mods.
- A primeira atualização de cada zumbi roda na hora, com fase espalhada (`seq % intervalo`), para
  não concentrar todos no mesmo tick.
- Erro num handler é logado e não interrompe os outros, o mesmo comportamento do vanilla por handler.
- **Multiplayer**: no servidor o padrão é repassar sem throttle (`lodOnServer=false`), porque lá não
  existe "tela". No cliente o LOD vale para os handlers client-side.
- **Exceção por mod**: um handler que *precisa* rodar todo tick (ex.: reaplica velocidade ou stats
  do zumbi que o jogo reseta a cada update) entra em `fullRateSources`:

```lua
-- arquivo que ordene ANTES de "!!ZPerf_Bootstrap.lua": media/lua/shared/!!!ZPerfUser.lua
-- (três "!": o 3º caractere '!' < 'Z'), ou edite direto ZPerf/Config.lua
ZPerfUserConfig = { zombieLOD = { fullRateSources = { "SomeZedMod/Zeds.lua" } } }
```

Teste em ambiente controlado (`tests/lua/test_zperf.lua`): com 300 ticks e um zumbi por tier, os
handlers rodaram 300 / 100 / 100 / 30 vezes (tier 1 / tier 2 na tela / tier 2 fora da tela / tier 3).
O ganho real depende da distribuição dos zumbis. Numa horda típica, a maior parte fica nos tiers 2 e 3.

### c) Scheduler para rotinas pesadas
```lua
require "ZPerf/Scheduler"
local S, Focus = ZPerf.Scheduler, ZPerf.Focus

-- 1) taxa limitada + reduzida quando longe do jogador
S.every(60, recalcularGeradores, {
    name = "MeuMod.geradores",
    when = function() return Focus.nearestDist2(baseX, baseY) < 60 * 60 end,
    idleInterval = 1800,          -- longe: a cada 30 s
})

-- 2) varredura fatiada: 40 zumbis por tick em vez de todos de uma vez
S.sliced({
    name = "MeuMod.varredura", perTick = 40, restTicks = 30,
    list = function() return getCell():getZombieList() end,
    each = function(z) ... end,
    onPass = function(total) ... end,
})

-- 3) trabalho pontual dentro de um orçamento por tick (budgetMs = 2)
S.defer(function() reconstruirIndice() end, nil, "MeuMod.indice")
```
Tudo que passa pelo scheduler aparece no profiler com o `name` informado.

### d) Pooling e utilitários anti-GC
```lua
local Pool, T = ZPerf.Pool, ZPerf.TableUtil
local Vec = Pool.new(function() return { x = 0, y = 0, z = 0 } end, nil, 512)
local v = Vec:acquire() ... Vec:release(v)

local arena = Pool.newArena(Vec)   -- devolve tudo de uma vez no fim do tick
T.wipe(t)                          -- esvazia mantendo o objeto
T.coordKey(x, y, z)                -- chave numérica em vez de x..","..y..","..z
T.forEachJava(lista, fn)           -- itera java.util.List sem tabela intermediária
```
Exemplo completo de refatoração (antes/depois): `media/lua/client/ZPerf/Examples.lua`
(ativo só com `ZPerfUserConfig = { examples = true }`).

## Checklist para autores de mods (o que mais reduz GC e CPU)

| Evite | Prefira |
|---|---|
| `Events.OnTick.Add` para algo que muda por minuto | `EveryOneMinute` ou `S.every(n)` |
| `OnPlayerUpdate` para UI | `OnTick` com throttle ou evento específico |
| `{}` / closures dentro de handlers quentes | tabela de trabalho reutilizada + `T.wipe`, funções locais no topo do arquivo |
| `x .. "," .. y` como chave | `T.coordKey(x, y, z)` |
| varrer `getCell():getObjectList()` / zumbis inteiro num tick | `S.sliced` |
| `getPlayer()`, `getCell()`, `getGameTime()` repetidos no loop | cache local no início do handler |
| `ipairs`/`pairs` sobre listas Java | `for i = 0, list:size()-1 do local o = list:get(i)` |
| `getModData()` em todo update de zumbi | só quando o dado muda; modData é serializado no save |
| `print` em caminho quente | `if DEBUG then` |
| `table.insert(t, v)` em loop quente | `n = n + 1; t[n] = v` |

## B42

O build gera `ZPerf/42/` + `ZPerf/common/` além da raiz (B41), e um mesmo diretório serve as duas
versões. Os eventos usados (`OnTick`, `OnZombieUpdate`, `EveryOneMinute`...) existem nos dois
builds. Os globais `isoToScreenX/Y`, `getPlayerScreen*` e `getFilenameOfClosure` são usados com
fallback: se algum não existir, o LOD vira só por distância e o profiler mostra `function: 0x...`
em vez do arquivo. Confirme com REA, Q4.

## Limitações honestas
- O ZPerf **não acelera o renderer nem a IA vanilla**. Ele ataca o custo que os mods adicionam e dá
  visibilidade. Para render, veja [04](04-motor-render.md).
- O throttle muda a semântica de handlers que assumem "todo tick". Use `fullRateSources`.
- O código foi testado com um stub da API do PZ em Lua 5.1 (`tests/lua`), **não** dentro do jogo
  neste ambiente. Faça o primeiro teste num save descartável e confira o `console.txt`.
