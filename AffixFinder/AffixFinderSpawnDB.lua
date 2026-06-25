-- AffixFinder bundled spawn/map data provider.
-- Loaded through AffixFinder.toc AFTER the generated data files
-- (AffixFinderMapData.lua / AffixFinderSpawnData.lua) and BEFORE AffixFinderWarp.lua.
--
-- This is the dependency-free fallback for the farm-density metric. Everything
-- the density math needs from Questie is STATIC data + pure arithmetic (see the
-- analysis in README/CLAUDE): NPC spawn coordinates, a per-uiMap yard scale, and
-- a couple of areaId/zone lookups. The generated data files bundle that data;
-- this file reimplements the one piece of Questie LOGIC density used -- HBD's
-- 0-1 map-point -> world-yard conversion (six lines of arithmetic over the
-- UiMapData scale table) -- and exposes plain bundle accessors.
--
-- AffixFinderWarp.lua prefers the live Questie modules when present (so Questie
-- users pay zero extra memory and pick up Questie's updates) and falls back to
-- I.SpawnDB only when Questie is absent. None of these accessors are reached
-- when Questie is loaded, so they add no cost on a Questie client.

local AF = _G.AffixFinder
local I = AF._internal

AF._internal.Bundle = AF._internal.Bundle or {}
local B = AF._internal.Bundle

local SpawnDB = {}
I.SpawnDB = SpawnDB

local decode = loadstring or load  -- WoW 5.1 has loadstring; standalone 5.2+ uses load

-- B.npcSpawns maps npcId -> a STRING holding only that mob's serialized spawns
-- ({[zoneID]={{x,y},...}}). We decode ONE mob's string on demand and do NOT
-- retain the result: density memoizes only its grade (AF.mobDensity) and the map
-- pin reads coords once per click, so the decoded coordinate tree is transient.
-- This keeps the resident footprint to the strings themselves (~the file size)
-- rather than the multi-MB fully-built table tree. Questie clients never reach
-- here at all. A decode failure is non-fatal (returns nil -> unknown density).
local function decodeSpawns(s)
    if type(s) ~= "string" or not decode then
        return nil
    end
    local chunk = decode("return " .. s)
    if not chunk then
        return nil
    end
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" then
        return t
    end
    return nil
end

-- True once the generated spawn data is present. The map data can exist without
-- the spawn data, so they are reported separately.
function SpawnDB.hasSpawns()
    return type(B.npcSpawns) == "table"
end

function SpawnDB.hasMapData()
    return type(B.UiMapData) == "table"
end

-- The full decoded spawn table, built fresh and NOT retained. For diagnostics
-- and tests only -- production density goes one mob at a time via npcSpawns.
function SpawnDB.allSpawns()
    local out = {}
    for id, s in pairs(B.npcSpawns or {}) do
        out[id] = decodeSpawns(s)
    end
    return out
end

-- Bundled spawns for an NPC: {[zoneID] = {{x,y},...}} in 0-100 map percent,
-- exactly the shape QuestieDB:QueryNPCSingle(id, "spawns") returns. Decoded on
-- demand from the mob's string; nil if the mob is not bundled.
function SpawnDB.npcSpawns(npcId)
    local t = B.npcSpawns
    return t and decodeSpawns(t[npcId]) or nil
end

-- The whole UiMapData scale table, for building the name/instance indexes.
-- [uiMapId] = { width, height, left, top, instance=, name= }.
function SpawnDB.uiMapData()
    return B.UiMapData
end

-- areaId -> uiMapId (open-world zones; dungeon containers have no entry, by
-- design -- same as Questie's ZoneDB.areaIdToUiMapId).
function SpawnDB.areaUiMapId(areaId)
    local t = B.areaIdToUiMapId
    return t and t[tonumber(areaId)] or nil
end

-- dungeon container areaId -> name (the only field questieAreaName reads from
-- ZoneDB:GetDungeons(), used to bridge a container AreaId to a yard-scaled map).
function SpawnDB.dungeonName(areaId)
    local t = B.dungeonNames
    return t and t[tonumber(areaId)] or nil
end

-- Reimplementation of QuestieCompat.HBD:GetWorldCoordinatesFromZone: convert a
-- 0-1 map point to world yards using the uiMap's scale row. Pure arithmetic
-- over UiMapData (left - width*x, top - height*y); see Questie's Compat/HBD.lua.
-- x01, y01 are 0-1 (NOT 0-100). Returns (worldX, worldY, instanceId), or nil
-- when the uiMap is unknown or has a degenerate (zero) scale.
function SpawnDB.worldFromZone(x01, y01, uiMapId)
    local data = B.UiMapData and B.UiMapData[tonumber(uiMapId)]
    if type(data) ~= "table" then
        return nil
    end
    local width, height, left, top = data[1], data[2], data[3], data[4]
    if not width or width == 0 or not height or height == 0 then
        return nil
    end
    if not x01 or not y01 then
        return nil
    end
    return left - width * x01, top - height * y01, data.instance
end
