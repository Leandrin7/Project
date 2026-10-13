-- Exemplos de refatoração (desligados por padrão: ZPerfUserConfig = { examples = true }).
-- Cada bloco mostra o padrão "ANTES" (comentado) e o "DEPOIS" com ZPerf.
require "ZPerf/Config"
require "ZPerf/Pool"
require "ZPerf/TableUtil"
require "ZPerf/Scheduler"
require "ZPerf/Focus"

if not ZPerf.Config.examples then return end

local Scheduler, Focus, Pool, T = ZPerf.Scheduler, ZPerf.Focus, ZPerf.Pool, ZPerf.TableUtil

---------------------------------------------------------------------------
-- 1) Varredura de zumbis a cada tick -> fatiada + reuso de tabelas
---------------------------------------------------------------------------
-- ANTES: 60x/s cria 1 tabela por zumbi + 1 lista + 1 string por chave.
--   Events.OnTick.Add(function()
--       local hot = {}
--       local zs = getCell():getZombieList()
--       for i = 0, zs:size() - 1 do
--           local z = zs:get(i)
--           hot[z:getX() .. "," .. z:getY()] = { x = z:getX(), y = z:getY(), hp = z:getHealth() }
--       end
--       MeuMod.hot = hot
--   end)

local Info = Pool.new(function() return { x = 0, y = 0, hp = 0 } end, nil, 1024)
local building, building_n = {}, 0     -- buffer em construção (reutilizado)
local current = {}                     -- última passada completa (lida pelo resto do mod)

Scheduler.sliced({
    name = "Examples.zombieScan",
    perTick = 40,                      -- ~40 zumbis por tick em vez de todos
    restTicks = 30,                    -- descansa 0,5 s entre passadas
    list = function()
        local cell = getCell()
        return cell and cell:getZombieList()
    end,
    each = function(z)
        local info = Info:acquire()
        info.x, info.y, info.hp = z:getX(), z:getY(), z:getHealth()
        building_n = building_n + 1
        building[building_n] = info
    end,
    onPass = function()
        -- devolve a geração anterior ao pool e troca os buffers (double-buffer)
        Info:releaseAll(current)
        current, building = building, current
        building_n = 0
        ZPerf.ExamplesHot = current
    end,
})

---------------------------------------------------------------------------
-- 2) Rotina pesada ligada a um lugar do mapa -> taxa reduzida longe do jogador
---------------------------------------------------------------------------
local BASE_X, BASE_Y, RADIUS2 = 10600, 9600, 60 * 60
local function processarGeradoresDaBase()
    -- ... lógica cara (varrer squares, recalcular energia, etc.)
end
Scheduler.every(60, processarGeradoresDaBase, {
    name = "Examples.baseGenerators",
    when = function() return Focus.nearestDist2(BASE_X, BASE_Y) <= RADIUS2 end,
    idleInterval = 60 * 30,            -- longe: 1x a cada ~30 s
})

---------------------------------------------------------------------------
-- 3) Cache por coordenada sem concatenar strings
---------------------------------------------------------------------------
local squareCache = {}
function ZPerf.ExampleMarkSquare(x, y, z)
    squareCache[T.coordKey(x, y, z)] = true      -- em vez de x..","..y..","..z
end
Scheduler.every(60 * 60, function() T.wipe(squareCache) end, { name = "Examples.cacheReset" })

---------------------------------------------------------------------------
-- 4) Handler de OnZombieUpdate: escreva como sempre; o ZPerf aplica o LOD.
--    Se seu handler PRECISA rodar todo tick, adicione o arquivo em
--    ZPerfUserConfig.zombieLOD.fullRateSources.
---------------------------------------------------------------------------
local tmp = {}                         -- tabela de trabalho reutilizada
Events.OnZombieUpdate.Add(function(z)
    T.wipe(tmp)
    -- ... use tmp como scratch em vez de criar {} por chamada
end)

ZPerf.log("examples carregados")
