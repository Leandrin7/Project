-- Atalhos para o console de debug (-debug, F11 / aba Lua):
--   ZPerfReport()       -> imprime top handlers agora
--   ZPerfLOD()          -> estatísticas do LOD de zumbis
--   ZPerfSet("zombieLOD.interval", {1, 2, 6})
require "ZPerf/Config"

function ZPerfReport()
    return ZPerf.Profiler.report()
end

function ZPerfLOD()
    local L = ZPerf.ZombieLOD
    local s = L.stats
    local tracked = 0
    for _ in pairs(L.nextDue) do tracked = tracked + 1 end
    ZPerf.log("LOD handlers full=%d lod=%d tracked=%d calls=%d ran=%d skipped=%d tiers=%d/%d/%d",
        L.nFull, L.nThr, tracked, s.calls, s.ran, s.skipped, s.tiers[1], s.tiers[2], s.tiers[3])
end

-- Altera config em runtime (só campos lidos dinamicamente; near/far são lidos no load).
function ZPerfSet(path, value)
    local t = ZPerf.Config
    local keys = {}
    for k in string.gmatch(path, "[^%.]+") do keys[#keys + 1] = k end
    for i = 1, #keys - 1 do t = t[keys[i]] end
    t[keys[#keys]] = value
    ZPerf.log("%s alterado", path)
end
