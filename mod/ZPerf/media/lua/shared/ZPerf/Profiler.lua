-- Profiler de handlers de eventos Lua, por mod/arquivo.
-- Timer do PZ tem resolução de 1 ms, então medimos 1 de cada N chamadas e
-- extrapolamos: a fase aleatória em relação à borda do ms torna a média sem viés.
ZPerf = ZPerf or {}
require "ZPerf/Config"
require "ZPerf/Focus"

local P = { stats = {}, order = {}, lastReport = 0 }
local C = ZPerf.Config.profiler
local Focus = ZPerf.Focus
local nowMs = Focus.nowMs

local function sourceOf(fn)
    if getFilenameOfClosure then
        local ok, name = pcall(getFilenameOfClosure, fn)
        if ok and name then return tostring(name) end
    end
    return tostring(fn)
end
P.sourceOf = sourceOf

-- Uma entrada de estatística por (evento, handler).
function P.entry(eventName, fn)
    local e = {
        event = eventName,
        source = sourceOf(fn),
        calls = 0,      -- chamadas totais
        sampled = 0,    -- chamadas medidas
        ms = 0,         -- ms somados nas medidas
        errors = 0,
    }
    P.order[#P.order + 1] = e
    return e
end

local sampleEvery = C.sampleEvery

-- Executa fn (até 6 args, sem varargs: evita tabela extra no Kahlua).
-- Erros são logados e não propagados, como o LuaEventManager faz por handler.
function P.call(e, fn, a, b, c, d, f, g)
    local calls = e.calls + 1
    e.calls = calls
    if calls % sampleEvery ~= 0 then
        local ok, err = pcall(fn, a, b, c, d, f, g)
        if not ok then P.onError(e, err) end
        return
    end
    local t0 = nowMs()
    local ok, err = pcall(fn, a, b, c, d, f, g)
    e.ms = e.ms + (nowMs() - t0)
    e.sampled = e.sampled + 1
    if not ok then P.onError(e, err) end
end

function P.onError(e, err)
    e.errors = e.errors + 1
    if e.errors <= 5 or e.errors % 1000 == 0 then
        ZPerf.log("erro em %s (%s) #%d: %s", e.event, e.source, e.errors, tostring(err))
    end
end

-- Embrulha fn para registro direto no Events.<X> original.
function P.wrap(eventName, fn)
    local e = P.entry(eventName, fn)
    local call = P.call
    return function(a, b, c, d, f, g) call(e, fn, a, b, c, d, f, g) end, e
end

-- Custo estimado total em ms desde o último reset.
local function estMs(e)
    if e.sampled == 0 then return 0 end
    return e.ms * (e.calls / e.sampled)
end
P.estMs = estMs

function P.report(windowSec)
    local list = {}
    for i = 1, #P.order do
        local e = P.order[i]
        if e.calls > 0 then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return estMs(a) > estMs(b) end)
    windowSec = windowSec or C.reportSeconds
    ZPerf.log("---- top handlers (%ds) ----", windowSec)
    for i = 1, math.min(C.topN, #list) do
        local e = list[i]
        local ms = estMs(e)
        ZPerf.log("%2d. %7.1f ms/s  %8d calls  %-16s %s%s", i, ms / windowSec, e.calls,
            e.event, e.source, e.errors > 0 and ("  ERR=" .. e.errors) or "")
    end
    for i = 1, #P.order do
        local e = P.order[i]
        e.calls, e.sampled, e.ms = 0, 0, 0
    end
    return list
end

function P.maybeReport()
    local now = nowMs()
    if P.lastReport == 0 then P.lastReport = now return end
    local elapsed = now - P.lastReport
    if elapsed >= C.reportSeconds * 1000 then
        P.lastReport = now
        P.report(elapsed / 1000)
    end
end

ZPerf.Profiler = P
return P
