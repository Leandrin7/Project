-- Rodar da raiz do repo:  lua5.1 tests/lua/test_zperf.lua
package.path = "mod/ZPerf/media/lua/shared/?.lua;mod/ZPerf/media/lua/client/?.lua;tests/lua/?.lua;" .. package.path
require "pz_stub"

local quiet = {}
local realPrint = print
print = function(s) quiet[#quiet + 1] = s end

-- config de teste: amostra toda chamada para medir de forma determinística
ZPerfUserConfig = {
    profiler = { sampleEvery = 1, reportSeconds = 10 },
    zombieLOD = { fullRateSources = { "media/lua/client/AlwaysOn.lua" } },
}
dofile("mod/ZPerf/media/lua/shared/!!ZPerf_Bootstrap.lua")

local failures, passed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
    else
        failures = failures + 1
        realPrint("FAIL: " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

-- 1) bootstrap registrou housekeeping no OnTick original
check("housekeeping registrado", Stub.count("OnTick") == 1)
check("OnZombieUpdate interceptado", ZPerf.intercepted.OnZombieUpdate == "lod")
check("OnTick com profiler", ZPerf.intercepted.OnTick == "profile")

-- 2) N handlers OnZombieUpdate => 1 callback no Java
local hits = { a = {}, b = {}, always = {} }
local function counter(tbl)
    return function(z) tbl[z] = (tbl[z] or 0) + 1 end
end
local hA = Stub.src(counter(hits.a), "media/lua/client/ModA.lua")
local hB = Stub.src(counter(hits.b), "media/lua/client/ModB.lua")
local hAlways = Stub.src(counter(hits.always), "media/lua/client/AlwaysOn.lua")
Events.OnZombieUpdate.Add(hA)
Events.OnZombieUpdate.Add(hB)
Events.OnZombieUpdate.Add(hAlways)
check("1 dispatcher no Java", Stub.count("OnZombieUpdate") == 1, Stub.count("OnZombieUpdate"))
check("2 throttled + 1 full", ZPerf.ZombieLOD.nThr == 2 and ZPerf.ZombieLOD.nFull == 1)

-- 3) LOD por tier
local near = Stub.newChar(105, 100)        -- 5 tiles -> tier 1
local onScreenFar = Stub.newChar(125, 100) -- 25 tiles, na tela -> tier 2
local offMid = Stub.newChar(100, 140)      -- 40 tiles, fora da tela, < far -> tier 2
local offFar = Stub.newChar(200, 200)      -- 141 tiles, fora da tela -> tier 3
local zs = { near, onScreenFar, offMid, offFar }
Stub.tick(1)  -- Focus precisa de 1 tick para conhecer os jogadores
check("classify near", ZPerf.ZombieLOD.classify(near) == 1)
check("classify onScreenFar", ZPerf.ZombieLOD.classify(onScreenFar) == 2, ZPerf.ZombieLOD.classify(onScreenFar))
check("classify offMid", ZPerf.ZombieLOD.classify(offMid) == 2, ZPerf.ZombieLOD.classify(offMid))
check("classify offFar", ZPerf.ZombieLOD.classify(offFar) == 3, ZPerf.ZombieLOD.classify(offFar))

Stub.tick(300, zs)
local function approx(v, target, tol) return v >= target - tol and v <= target + tol end
check("near todo tick", hits.a[near] == 300, hits.a[near])
check("tier2 ~1/3", approx(hits.a[onScreenFar], 100, 2), hits.a[onScreenFar])
check("tier2 off ~1/3", approx(hits.a[offMid], 100, 2), hits.a[offMid])
check("tier3 ~1/10", approx(hits.a[offFar], 30, 2), hits.a[offFar])
check("handler B = A", hits.b[offFar] == hits.a[offFar])
check("fullRate ignora LOD", hits.always[offFar] == 300, hits.always[offFar])

-- 4) erro num handler não derruba os outros
local boom = Stub.src(function() error("boom") end, "media/lua/client/Broken.lua")
Events.OnZombieUpdate.Add(boom)
local before = hits.b[near]
Stub.tick(5, { near })
check("handlers seguem após erro", hits.b[near] == before + 5)
check("erro contabilizado", ZPerf.ZombieLOD.byFn[boom].entry.errors == 5)

-- 5) Remove desfaz o registro; último Remove tira o dispatcher do Java
for _, h in ipairs({ hA, hB, hAlways, boom }) do Events.OnZombieUpdate.Remove(h) end
check("dispatcher removido", Stub.count("OnZombieUpdate") == 0)
check("lod vazio", ZPerf.ZombieLOD.count() == 0)

-- 6) profiler em OnTick: wrapper + Remove pelo fn original
local ticks = 0
local slow = Stub.src(function() ticks = ticks + 1; Stub.clock = Stub.clock + 3 end, "media/lua/client/SlowMod.lua")
Events.OnTick.Add(slow)
check("wrapper registrado", Stub.count("OnTick") == 2)
Stub.tick(10)
check("handler chamado via wrapper", ticks == 10)
local list = ZPerf.Profiler.report(1)
check("profiler acha SlowMod no topo", list[1] and list[1].source == "media/lua/client/SlowMod.lua", list[1] and list[1].source)
Events.OnTick.Remove(slow)
check("remove pelo fn original", Stub.count("OnTick") == 1)

-- 7) Scheduler.every com when/idleInterval
local S = ZPerf.Scheduler
local nearRuns, idleRuns = 0, 0
local gate = true
S.every(10, function() nearRuns = nearRuns + 1 end, { when = function() return gate end, idleInterval = 50, stagger = false })
Stub.tick(100)
check("every 10 ticks", approx(nearRuns, 10, 1), nearRuns)
local t2 = S.every(10, function() idleRuns = idleRuns + 1 end, { when = function() return false end, idleInterval = 50 })
Stub.tick(200)
check("idle reduz taxa", approx(idleRuns, 4, 1), idleRuns)
S.cancel(t2)
Stub.tick(100)
check("cancel", approx(idleRuns, 4, 1), idleRuns)

-- 8) Scheduler.sliced sobre java.util.List e array Lua
local items = {}
for i = 1, 100 do items[i] = i end
local seen, passes = 0, 0
S.sliced({ perTick = 30, list = function() return Stub.javaList(items) end,
           each = function() seen = seen + 1 end, onPass = function() passes = passes + 1 end })
Stub.tick(4)
check("sliced java 1 passada em 4 ticks", seen == 100 and passes == 1, seen .. "/" .. passes)
local seenLua = 0
S.sliced({ perTick = 50, restTicks = 10, list = function() return items end, each = function() seenLua = seenLua + 1 end })
Stub.tick(2)
check("sliced lua", seenLua == 100, seenLua)
Stub.tick(5)
check("sliced descansa", seenLua == 100, seenLua)

-- 9) defer respeita orçamento (budgetMs = 2; cada job custa 1 ms)
local done = 0
for _ = 1, 10 do S.defer(function() done = done + 1; Stub.clock = Stub.clock + 1 end) end
Stub.tick(1)
check("defer limitado por orçamento", done == 2, done)
Stub.tick(10)
check("defer drena", done == 10 and S.pending() == 0, done)

-- 10) Pool / TableUtil
local P = ZPerf.Pool.new(function() return { v = 0 } end, function(o) o.v = 0 end, 2)
local o1, o2, o3 = P:acquire(), P:acquire(), P:acquire()
o1.v = 5
P:release(o1); P:release(o2); P:release(o3)
local created, reused, free, dropped = P:stats()
check("pool cap", created == 3 and free == 2 and dropped == 1)
local r = P:acquire()
check("pool reusa e reseta", r.v == 0 and select(2, P:stats()) == 1)
local T = ZPerf.TableUtil
local keys, dup = {}, false
for x = -3, 3 do for y = -3, 3 do for z = -2, 2 do
    local k = T.coordKey(x * 1000, y * 1000, z)
    if keys[k] then dup = true end
    keys[k] = true
end end end
check("coordKey única", not dup)
local arr = { 1, 2, 3, 2, 4 }
check("removeValue", T.removeValue(arr, 2) == 2 and #arr == 3 and arr[3] == 4)
local w = { a = 1, b = 2, 1, 2 }
T.wipe(w)
check("wipe", next(w) == nil)

-- 11) sweep remove zumbis que pararam de atualizar
local tracked = 0
for _ in pairs(ZPerf.ZombieLOD.nextDue) do tracked = tracked + 1 end
local removed = ZPerf.ZombieLOD.sweep()
check("sweep", removed == tracked and tracked > 0, removed .. "/" .. tracked)

print = realPrint
print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
