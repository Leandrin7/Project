-- Scheduler para rotinas pesadas de mods: taxa limitada, fase espalhada,
-- taxa reduzida quando o alvo está longe do jogador, iteração fatiada e fila com orçamento.
--
--   -- roda a cada 30 ticks; quando when() == false, só a cada 300
--   ZPerf.Scheduler.every(30, minhaRotina, { name = "MeuMod.scan",
--       when = function() return ZPerf.Focus.nearestDist2(bx, by) < 50 * 50 end,
--       idleInterval = 300 })
--
--   -- percorre a lista de zumbis 40 por tick em vez de tudo num tick só
--   ZPerf.Scheduler.sliced({ name = "MeuMod.zeds", perTick = 40, restTicks = 60,
--       list = function() return getCell():getZombieList() end,
--       each = function(z) ... end })
--
--   -- trabalho pontual executado dentro de budgetMs por tick
--   ZPerf.Scheduler.defer(function() reconstruirCache() end)
ZPerf = ZPerf or {}
require "ZPerf/Config"
require "ZPerf/Focus"
require "ZPerf/Profiler"

local Focus = ZPerf.Focus
local Profiler = ZPerf.Profiler
local PC = ZPerf.Config.profiler
local SC = ZPerf.Config.scheduler
local nowMs = Focus.nowMs

local S = { tasks = {}, nTasks = 0, queue = {}, qHead = 1, qTail = 0, seq = 0 }

local function run(entry, fn, a)
    if PC.enabled then
        Profiler.call(entry, fn, a)
    else
        local ok, err = pcall(fn, a)
        if not ok then Profiler.onError(entry, err) end
    end
end

function S.every(ticks, fn, opts)
    opts = opts or {}
    ticks = math.max(1, math.floor(ticks))
    S.seq = S.seq + 1
    local entry = Profiler.entry("ZPerf.every", fn)
    if opts.name then entry.source = opts.name end
    local phase = (opts.stagger == false) and 0 or (S.seq % ticks)
    local t = {
        fn = fn, entry = entry, interval = ticks,
        when = opts.when, idleInterval = opts.idleInterval or ticks * 6,
        next = Focus.frame + 1 + phase, lastRun = Focus.frame, active = true,
    }
    S.nTasks = S.nTasks + 1
    S.tasks[S.nTasks] = t
    return t
end

function S.cancel(t)
    if t then t.active = false end
end

function S.defer(fn, arg, name)
    local entry = Profiler.entry("ZPerf.defer", fn)
    if name then entry.source = name end
    S.qTail = S.qTail + 1
    S.queue[S.qTail] = { fn = fn, arg = arg, entry = entry }
end

-- Itera Lua array ou java.util.List em fatias de perTick itens por tick.
-- Itens inseridos/removidos durante a passada podem ser pulados ou vistos 2x.
function S.sliced(opts)
    local perTick = opts.perTick or 32
    local restTicks = opts.restTicks or 0
    local getList, each, onPass = opts.list, opts.each, opts.onPass
    local cursor, restUntil = 0, 0
    return S.every(1, function()
        local frame = Focus.frame
        if frame < restUntil then return end
        local list = getList()
        if list == nil then return end
        local isLua = type(list) == "table"
        local n = isLua and #list or list:size()
        local stop = math.min(n, cursor + perTick)
        for i = cursor, stop - 1 do
            local item
            if isLua then item = list[i + 1] else item = list:get(i) end
            if item ~= nil then each(item, i) end
        end
        cursor = stop
        if stop >= n then
            cursor = 0
            restUntil = frame + restTicks
            if onPass then onPass(n) end
        end
    end, { name = opts.name or "ZPerf.sliced", when = opts.when,
           idleInterval = opts.idleInterval, stagger = false })
end

function S.step()
    local frame = Focus.frame
    local tasks = S.tasks
    local i = 1
    while i <= S.nTasks do
        local t = tasks[i]
        if not t.active then
            tasks[i] = tasks[S.nTasks]
            tasks[S.nTasks] = nil
            S.nTasks = S.nTasks - 1
        else
            if frame >= t.next then
                t.next = frame + t.interval
                if t.when == nil or t.when() or (frame - t.lastRun) >= t.idleInterval then
                    t.lastRun = frame
                    run(t.entry, t.fn)
                end
            end
            i = i + 1
        end
    end

    if S.qHead <= S.qTail then
        local deadline = nowMs() + SC.budgetMs
        repeat
            local job = S.queue[S.qHead]
            S.queue[S.qHead] = nil
            S.qHead = S.qHead + 1
            run(job.entry, job.fn, job.arg)
        until S.qHead > S.qTail or nowMs() >= deadline
        if S.qHead > S.qTail then S.qHead, S.qTail = 1, 0 end
    end
end

function S.pending()
    return S.qTail - S.qHead + 1
end

ZPerf.Scheduler = S
return S
