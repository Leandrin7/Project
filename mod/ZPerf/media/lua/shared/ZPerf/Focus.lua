-- "Foco" do jogador: posições dos jogadores locais e retângulo de tela,
-- atualizados UMA vez por tick para que testes por entidade não chamem Java repetidamente.
ZPerf = ZPerf or {}
local F = {
    frame = 0,          -- contador de ticks (OnTick)
    n = 0,              -- jogadores locais vivos
    idx = {}, x = {}, y = {}, z = {},
    left = {}, top = {}, right = {}, bottom = {},
    hasScreenApi = false,
}

local HUGE = math.huge

-- Relógio em ms. getTimestampMs é global do PZ (LuaManager.GlobalObject).
function F.nowMs()
    if getTimestampMs then return getTimestampMs() end
    return os.time() * 1000
end

local function screenRect(i)
    if getPlayerScreenLeft then
        local l, t = getPlayerScreenLeft(i), getPlayerScreenTop(i)
        return l, t, l + getPlayerScreenWidth(i), t + getPlayerScreenHeight(i)
    end
    local core = getCore and getCore()
    if core then return 0, 0, core:getScreenWidth(), core:getScreenHeight() end
    return 0, 0, 1920, 1080
end

-- Chamado no início de cada tick pelo Bootstrap.
function F.update()
    F.frame = F.frame + 1
    local n = 0
    local count = getNumActivePlayers and getNumActivePlayers() or 0
    for i = 0, count - 1 do
        local p = getSpecificPlayer(i)
        if p and not p:isDead() then
            n = n + 1
            F.idx[n] = i
            F.x[n], F.y[n], F.z[n] = p:getX(), p:getY(), p:getZ()
            F.left[n], F.top[n], F.right[n], F.bottom[n] = screenRect(i)
        end
    end
    F.n = n
    F.hasScreenApi = isoToScreenX ~= nil and isoToScreenY ~= nil
end

-- Menor distância² até um jogador local. HUGE se não houver jogador.
function F.nearestDist2(x, y)
    local best = HUGE
    for k = 1, F.n do
        local dx, dy = x - F.x[k], y - F.y[k]
        local d2 = dx * dx + dy * dy
        if d2 < best then best = d2 end
    end
    return best
end

-- Ponto do mundo dentro da tela de algum jogador local (com margem em px).
function F.isOnScreen(x, y, z, margin)
    if not F.hasScreenApi then return true end -- sem API: não arrisca esconder nada
    margin = margin or 0
    for k = 1, F.n do
        local i = F.idx[k]
        local sx, sy = isoToScreenX(i, x, y, z), isoToScreenY(i, x, y, z)
        if sx >= F.left[k] - margin and sx <= F.right[k] + margin
            and sy >= F.top[k] - margin and sy <= F.bottom[k] + margin then
            return true
        end
    end
    return false
end

ZPerf.Focus = F
return F
