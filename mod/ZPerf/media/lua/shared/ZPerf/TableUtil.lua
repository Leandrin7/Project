-- Utilitários para reduzir alocação no heap Java.
-- No PZ o Lua roda no Kahlua (Lua 5.1 em Java): cada tabela é um objeto Java,
-- cada closure também, e números são java.lang.Double. "Lixo Lua" = lixo do GC da JVM.
ZPerf = ZPerf or {}
local T = {}

local next, pairs, type = next, pairs, type

-- Esvazia a tabela mantendo o objeto (sem nova alocação).
-- Atribuir nil a campos existentes durante pairs() é permitido em Lua 5.1.
local nativeWipe = table.wipe
function T.wipe(t)
    if nativeWipe then
        nativeWipe(t)
        return t
    end
    for k in pairs(t) do t[k] = nil end
    return t
end

-- Limpa só a parte array [1..n] (mais barato que wipe para listas).
function T.clearArray(t, n)
    n = n or #t
    for i = n, 1, -1 do t[i] = nil end
    return t
end

function T.isEmpty(t)
    return next(t) == nil
end

-- Chave numérica para coordenadas: evita x..","..y (String nova por chamada).
-- Válido para |x|,|y| < 2^20 e z em [-32, 31] (B42 tem níveis negativos).
local SHIFT_Y, SHIFT_Z = 2 ^ 21, 2 ^ 42
function T.coordKey(x, y, z)
    return (z or 0) * SHIFT_Z + (y + 2 ^ 20) * SHIFT_Y + (x + 2 ^ 20)
end

-- Itera um java.util.List (ArrayList do PZ) sem criar tabela intermediária.
-- fn(item, idx0) retorna true para interromper.
function T.forEachJava(list, fn)
    if not list then return end
    local n = list:size()
    for i = 0, n - 1 do
        if fn(list:get(i), i) then return end
    end
end

-- Remove de um array Lua por swap-com-o-último (O(1), não preserva ordem).
function T.swapRemove(t, i)
    local n = #t
    t[i] = t[n]
    t[n] = nil
end

-- Remove todas as ocorrências de v de um array preservando ordem.
function T.removeValue(t, v)
    local j = 1
    local n = #t
    for i = 1, n do
        local x = t[i]
        if x ~= v then
            t[j] = x
            j = j + 1
        end
    end
    for i = j, n do t[i] = nil end
    return n - j + 1
end

ZPerf.TableUtil = T
return T
