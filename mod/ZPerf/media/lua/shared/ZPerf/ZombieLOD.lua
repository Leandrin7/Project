-- LOD de atualização Lua para zumbis.
--
-- Problema: cada mod que faz Events.OnZombieUpdate.Add(fn) custa
--   (nº de zumbis carregados) x (nº de handlers) travessias Java->Lua POR TICK,
-- inclusive para zumbis a 40 tiles, fora da tela. Com 400 zumbis e 6 mods = 2400
-- chamadas Kahlua por frame, cada uma alocando (Doubles, frames, args).
--
-- Solução: o Bootstrap captura os Add() de OnZombieUpdate e registra UM dispatcher
-- no Java. O dispatcher chama os handlers só quando o zumbi está "vencido" no seu tier:
--   tier 1: até nearTiles de um jogador local            -> a cada interval[1] ticks
--   tier 2: na tela (ou até farTiles fora da tela)       -> a cada interval[2] ticks
--   tier 3: fora da tela e além de farTiles               -> a cada interval[3] ticks
-- Isso NÃO altera a IA/pathfinding vanilla (Java); só a lógica Lua dos mods.
ZPerf = ZPerf or {}
require "ZPerf/Config"
require "ZPerf/Focus"
require "ZPerf/Profiler"
require "ZPerf/TableUtil"

local C = ZPerf.Config.zombieLOD
local PC = ZPerf.Config.profiler
local Focus = ZPerf.Focus
local Profiler = ZPerf.Profiler
local removeValue = ZPerf.TableUtil.removeValue

local L = {
    full = {}, nFull = 0,          -- handlers sem throttle
    thr = {}, nThr = 0,            -- handlers com throttle
    byFn = {},                     -- fn -> handler record
    nextDue = {},                  -- zombie -> frame em que volta a rodar
    seq = 0,
    lastSweepFrame = 0,
    stats = { calls = 0, ran = 0, skipped = 0, tiers = { 0, 0, 0 } },
}

local near2 = C.nearTiles * C.nearTiles
local far2 = C.farTiles * C.farTiles

function L.isActive()
    if not C.enabled then return false end
    if isServer and isServer() and not C.lodOnServer then return false end
    return true
end

local function isFullRate(source)
    local list = C.fullRateSources
    for i = 1, #list do
        if string.find(source, list[i], 1, true) then return true end
    end
    return false
end

function L.count()
    return L.nFull + L.nThr
end

-- Retorna true se este foi o primeiro handler (o Bootstrap registra o dispatcher).
function L.add(fn)
    if L.byFn[fn] then return false end
    local wasEmpty = L.count() == 0
    local h = { fn = fn, entry = Profiler.entry("OnZombieUpdate", fn) }
    h.full = isFullRate(h.entry.source)
    L.byFn[fn] = h
    if h.full then
        L.nFull = L.nFull + 1
        L.full[L.nFull] = h
    else
        L.nThr = L.nThr + 1
        L.thr[L.nThr] = h
    end
    ZPerf.dlog("OnZombieUpdate += %s (%s)", h.entry.source, h.full and "full" or "lod")
    return wasEmpty
end

-- Retorna true se fn era nosso (o Bootstrap decide se remove o dispatcher).
function L.remove(fn)
    local h = L.byFn[fn]
    if not h then return false end
    L.byFn[fn] = nil
    if h.full then
        L.nFull = L.nFull - removeValue(L.full, h)
    else
        L.nThr = L.nThr - removeValue(L.thr, h)
    end
    return true
end

local function invoke(h, z)
    if PC.enabled then
        Profiler.call(h.entry, h.fn, z)
    else
        local ok, err = pcall(h.fn, z)
        if not ok then Profiler.onError(h.entry, err) end
    end
end

-- Visibilidade plugável (ex.: trocar por um teste de linha de visão).
L.isOnScreen = function(z, x, y)
    return Focus.isOnScreen(x, y, z:getZ(), C.screenMarginPx)
end

function L.classify(z)
    local x, y = z:getX(), z:getY()
    local d2 = Focus.nearestDist2(x, y)
    if d2 <= near2 then return 1 end
    if C.useScreenTest and L.isOnScreen(z, x, y) then return 2 end
    if d2 <= far2 then return 2 end
    return 3
end

function L.dispatch(z)
    local full = L.full
    for i = 1, L.nFull do invoke(full[i], z) end

    local nThr = L.nThr
    if nThr == 0 then return end

    local stats = L.stats
    stats.calls = stats.calls + 1
    local frame = Focus.frame
    local due = L.nextDue[z]
    if due ~= nil and frame < due then
        stats.skipped = stats.skipped + 1
        return
    end

    local thr = L.thr
    for i = 1, nThr do invoke(thr[i], z) end
    stats.ran = stats.ran + 1

    local tier = L.classify(z)
    stats.tiers[tier] = stats.tiers[tier] + 1
    local iv = C.interval[tier]
    if due == nil then
        -- primeira vez: espalha a fase para não concentrar todos no mesmo tick
        L.seq = L.seq + 1
        L.nextDue[z] = frame + 1 + (L.seq % iv)
    else
        L.nextDue[z] = frame + iv
    end
end

-- Remove zumbis que pararam de receber update (descarregados/reciclados/mortos).
-- Critério puramente Lua (sem chamadas Java) para custar ~nada.
function L.sweep()
    local frame = Focus.frame
    local staleBefore = frame - 4 * C.interval[3] - 60
    local removed = 0
    for z, due in pairs(L.nextDue) do
        if due < staleBefore then
            L.nextDue[z] = nil
            removed = removed + 1
        end
    end
    return removed
end

function L.maybeSweep(ticksPerSecondHint)
    local frame = Focus.frame
    local every = C.sweepSeconds * (ticksPerSecondHint or 60)
    if frame - L.lastSweepFrame >= every then
        L.lastSweepFrame = frame
        local removed = L.sweep()
        if ZPerf.Config.debug then
            local s = L.stats
            ZPerf.log("LOD: calls=%d ran=%d skipped=%d tiers=%d/%d/%d swept=%d",
                s.calls, s.ran, s.skipped, s.tiers[1], s.tiers[2], s.tiers[3], removed)
        end
        local s = L.stats
        s.calls, s.ran, s.skipped = 0, 0, 0
        s.tiers[1], s.tiers[2], s.tiers[3] = 0, 0, 0
    end
end

ZPerf.ZombieLOD = L
return L
