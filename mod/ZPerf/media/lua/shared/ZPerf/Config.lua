-- ZPerf - configuração central.
-- Edite este arquivo, ou defina ZPerfUserConfig num arquivo que ordene antes do
-- bootstrap (ex.: media/lua/shared/!!!ZPerfUser.lua) para sobrescrever campos.
ZPerf = ZPerf or {}

local defaults = {
    debug = false,
    examples = false,        -- carrega client/ZPerf/Examples.lua (demonstração)

    -- Substitui Events.<X>.Add/Remove para instrumentar/agrupar handlers de outros mods.
    -- Precisa carregar ANTES dos outros mods (arquivo "!!ZPerf_Bootstrap.lua").
    interceptEvents = true,

    profiler = {
        enabled = true,
        -- Eventos cujos handlers são medidos. OnZombieUpdate é medido pelo dispatcher do LOD.
        events = {
            OnTick = true, OnTickEvenPaused = true, OnPlayerUpdate = true,
            OnRenderTick = true, OnPreUIDraw = true, OnPostUIDraw = true,
            OnZombieUpdate = true, OnObjectAdded = true,
            EveryOneMinute = true, EveryTenMinutes = true, EveryHours = true,
        },
        -- Mede 1 de cada N chamadas (timer em ms; amostragem mantém a estimativa sem viés).
        sampleEvery = 8,
        reportSeconds = 60,
        topN = 15,
    },

    zombieLOD = {
        enabled = true,
        lodOnServer = false,     -- servidor não tem "tela"; por padrão repassa sem throttle
        nearTiles = 15,          -- sempre taxa cheia dentro deste raio (ataque fora da tela)
        farTiles = 45,
        useScreenTest = true,    -- isoToScreenX/Y; se ausente, cai para só distância
        screenMarginPx = 160,
        -- Intervalo em ticks por tier: [1]=perto, [2]=na tela longe / fora da tela médio, [3]=fora da tela longe
        interval = { 1, 3, 10 },
        -- Substrings do arquivo-fonte do handler que NUNCA sofrem throttle
        -- (ex.: mods que reescrevem stats do zumbi a cada update).
        fullRateSources = {},
        sweepSeconds = 30,
    },

    scheduler = {
        budgetMs = 2,            -- orçamento por tick para fila de jobs/iterações fatiadas
    },
}

local function merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

ZPerf.Config = merge(defaults, ZPerfUserConfig or {})
ZPerf._merge = merge

function ZPerf.log(fmt, ...)
    print("[ZPerf] " .. string.format(fmt, ...))
end

function ZPerf.dlog(fmt, ...)
    if ZPerf.Config.debug then ZPerf.log(fmt, ...) end
end

return ZPerf.Config
