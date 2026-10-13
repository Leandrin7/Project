-- ZPerf bootstrap. O prefixo "!!" faz este arquivo carregar antes dos outros
-- (o PZ ordena os .lua por caminho). Confira no console.txt a linha
-- "[ZPerf] bootstrap" ANTES dos arquivos dos mods que você quer medir/agrupar.
require "ZPerf/Config"
require "ZPerf/TableUtil"
require "ZPerf/Pool"
require "ZPerf/Focus"
require "ZPerf/Profiler"
require "ZPerf/ZombieLOD"
require "ZPerf/Scheduler"

if ZPerf._booted then return end
ZPerf._booted = true

local C = ZPerf.Config
local Focus, Profiler, LOD, Scheduler = ZPerf.Focus, ZPerf.Profiler, ZPerf.ZombieLOD, ZPerf.Scheduler

-- Housekeeping: registrado no OnTick ORIGINAL antes do patch, logo roda primeiro e sem wrapper.
local function housekeeping()
    Focus.update()
    LOD.maybeSweep()
    Scheduler.step()
    if C.profiler.enabled then Profiler.maybeReport() end
end
Events.OnTick.Add(housekeeping)

ZPerf.intercepted = {}

-- Troca Add/Remove de Events[name] para registrar um wrapper medido.
local function interceptProfiled(name)
    local ev = Events[name]
    if type(ev) ~= "table" or not ev.Add or not ev.Remove then return false end
    local add, remove = ev.Add, ev.Remove
    local map = {}
    ev.Add = function(fn)
        if type(fn) ~= "function" then return add(fn) end
        if map[fn] then return end
        local w = Profiler.wrap(name, fn)
        map[fn] = w
        return add(w)
    end
    ev.Remove = function(fn)
        local w = map[fn]
        if w then
            map[fn] = nil
            return remove(w)
        end
        return remove(fn)
    end
    ZPerf.intercepted[name] = "profile"
    return true
end

-- OnZombieUpdate: N handlers viram 1 dispatcher no Java + LOD por zumbi.
local function interceptZombieUpdate()
    local ev = Events.OnZombieUpdate
    if type(ev) ~= "table" or not ev.Add or not ev.Remove then return false end
    local add, remove = ev.Add, ev.Remove
    local registered = false
    local dispatch = LOD.dispatch
    ev.Add = function(fn)
        if type(fn) ~= "function" then return add(fn) end
        LOD.add(fn)
        if not registered then
            registered = true
            add(dispatch)
        end
    end
    ev.Remove = function(fn)
        if not LOD.remove(fn) then return remove(fn) end
        if registered and LOD.count() == 0 then
            registered = false
            remove(dispatch)
        end
    end
    ZPerf.intercepted.OnZombieUpdate = "lod"
    return true
end

if C.interceptEvents then
    local lodActive = LOD.isActive()
    if lodActive then interceptZombieUpdate() end
    if C.profiler.enabled then
        for name, on in pairs(C.profiler.events) do
            if on and not (name == "OnZombieUpdate" and lodActive) then
                interceptProfiled(name)
            end
        end
    end
end

local names = {}
for k, v in pairs(ZPerf.intercepted) do names[#names + 1] = k .. "=" .. v end
table.sort(names)
ZPerf.log("bootstrap ok; intercept: %s", table.concat(names, ", "))
