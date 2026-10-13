-- Stub mínimo da API Lua do Project Zomboid para testar o ZPerf fora do jogo.
-- Simula o lado Java: Events.<X>.Add/Remove guardam callbacks numa lista "Java".
Stub = { clock = 0, callbacks = {}, sources = {}, players = {} }

local function newEvent(name)
    local list = {}
    Stub.callbacks[name] = list
    return {
        Add = function(fn) list[#list + 1] = fn end,
        Remove = function(fn)
            for i = #list, 1, -1 do
                if list[i] == fn then table.remove(list, i) end
            end
        end,
    }
end

Events = {}
for _, n in ipairs({ "OnTick", "OnTickEvenPaused", "OnPlayerUpdate", "OnRenderTick", "OnPreUIDraw",
                     "OnPostUIDraw", "OnZombieUpdate", "OnObjectAdded", "EveryOneMinute",
                     "EveryTenMinutes", "EveryHours", "OnGameStart" }) do
    Events[n] = newEvent(n)
end

function Stub.fire(name, ...)
    local list = Stub.callbacks[name]
    for i = 1, #list do list[i](...) end
end

function Stub.count(name) return #Stub.callbacks[name] end

function getTimestampMs() return Stub.clock end
function isServer() return false end

-- fonte "do arquivo" de cada closure, como getFilenameOfClosure do PZ
function getFilenameOfClosure(fn) return Stub.sources[fn] or "unknown.lua" end
function Stub.src(fn, file) Stub.sources[fn] = file return fn end

local function newChar(x, y, z)
    local c = { x = x, y = y, z = z or 0, dead = false }
    function c:getX() return self.x end
    function c:getY() return self.y end
    function c:getZ() return self.z end
    function c:isDead() return self.dead end
    function c:getHealth() return 1 end
    return c
end
Stub.newChar = newChar

Stub.players[0] = newChar(100, 100, 0)
function getNumActivePlayers() return 1 end
function getSpecificPlayer(i) return Stub.players[i] end

function getPlayerScreenLeft() return 0 end
function getPlayerScreenTop() return 0 end
function getPlayerScreenWidth() return 1920 end
function getPlayerScreenHeight() return 1080 end

-- projeção isométrica de brinquedo: tile = 64x32 px, câmera no jogador
function isoToScreenX(i, x, y, z)
    local p = Stub.players[i]
    return 960 + ((x - p.x) - (y - p.y)) * 32
end
function isoToScreenY(i, x, y, z)
    local p = Stub.players[i]
    return 540 + ((x - p.x) + (y - p.y)) * 16 - z * 96
end

-- java.util.List fake (0-based). userdata, como um objeto Java exposto pelo Kahlua.
function Stub.javaList(items)
    local l = newproxy(true)
    local methods = {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end,
    }
    getmetatable(l).__index = methods
    return l
end

-- avança n ticks como o jogo faria: OnTick, depois OnZombieUpdate por zumbi
function Stub.tick(n, zombies)
    for _ = 1, n do
        Stub.clock = Stub.clock + 16
        Stub.fire("OnTick", 1)
        if zombies then
            for i = 1, #zombies do Stub.fire("OnZombieUpdate", zombies[i]) end
        end
    end
end
