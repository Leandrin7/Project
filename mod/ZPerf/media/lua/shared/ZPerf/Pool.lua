-- Object pool genérico para tabelas Lua de vida curta (vetores, eventos, resultados).
--
--   local VecPool = ZPerf.Pool.new(function() return {x=0, y=0, z=0} end,
--                                  function(v) v.x, v.y, v.z = 0, 0, 0 end, 256)
--   local v = VecPool:acquire() ... VecPool:release(v)
--
-- Regra de ouro: só faça pool de objetos criados em caminho quente (OnTick,
-- OnZombieUpdate, OnRenderTick). Pool de algo criado 1x por minuto só adiciona bugs.
ZPerf = ZPerf or {}
require "ZPerf/TableUtil"

local Pool = {}
Pool.__index = Pool

local wipe = ZPerf.TableUtil.wipe

-- factory(): cria um objeto novo.
-- reset(obj): opcional; padrão = wipe (esvazia a tabela).
-- maxSize: objetos além disso são descartados para o GC (evita pool "vazar").
function Pool.new(factory, reset, maxSize)
    return setmetatable({
        factory = factory or function() return {} end,
        reset = reset or wipe,
        maxSize = maxSize or 128,
        free = {},
        nFree = 0,
        created = 0,
        reused = 0,
        dropped = 0,
    }, Pool)
end

function Pool:acquire()
    local n = self.nFree
    if n > 0 then
        local obj = self.free[n]
        self.free[n] = nil
        self.nFree = n - 1
        self.reused = self.reused + 1
        return obj
    end
    self.created = self.created + 1
    return self.factory()
end

function Pool:release(obj)
    if obj == nil then return end
    if self.nFree >= self.maxSize then
        self.dropped = self.dropped + 1
        return
    end
    self.reset(obj)
    local n = self.nFree + 1
    self.free[n] = obj
    self.nFree = n
end

-- Libera um array de objetos e limpa o array (padrão "frame arena").
function Pool:releaseAll(arr, n)
    n = n or #arr
    for i = 1, n do
        self:release(arr[i])
        arr[i] = nil
    end
end

function Pool:stats()
    return self.created, self.reused, self.nFree, self.dropped
end

-- Arena por frame: acquire durante o tick, tudo devolvido no fim do tick.
-- Útil quando você não controla quando o objeto deixa de ser usado dentro do tick.
local Arena = {}
Arena.__index = Arena

function Pool.newArena(pool)
    return setmetatable({ pool = pool, live = {}, n = 0 }, Arena)
end

function Arena:acquire()
    local obj = self.pool:acquire()
    local n = self.n + 1
    self.live[n] = obj
    self.n = n
    return obj
end

function Arena:reset()
    self.pool:releaseAll(self.live, self.n)
    self.n = 0
end

ZPerf.Pool = Pool
return Pool
