-- AffixFinder map markers and T3 warp assistance.
-- Loaded through AffixFinder.toc; public APIs live on AF, implementation details on AF._internal.

local AF = _G.AffixFinder
local I = AF._internal

local chat = I.chat
local safeCall = I.safeCall
local safeFirst = I.safeFirst
local OBJTYPE_CREATURE = I.OBJTYPE_CREATURE

-- Mob map-pin / t3 warp-assist helper
-- ---------------------------------------------------------------------------
-- Clicking a mob in the UI places one latest-target marker. The primary marker
-- is SERVER-SIDE tracking by npcId (Custom_AddTrackObjLoc, OBJTYPE_CREATURE):
-- the WoWExt server knows every creature's spawn points and renders the marker
-- on the world map + minimap itself, so it needs NO coordinate data and NO
-- Questie -- this is the path that always works (qtRunner uses the same API for
-- its quest/NPC tracking). Questie, when present, is an optional enhancement: it
-- supplies exact spawn coordinates for a precise manual pin and exact map
-- positioning. There is no server itemId/npcId -> coordinate API on this client,
-- so Questie is the only source of explicit coordinates. The optional t3 helper
-- opens the zone map (exact spot via Questie, else zoomed to the zone by name)
-- ONLY when the map click can actually take the player there: it is skipped for
-- dungeons/raids (no zone warps exist for instance content) and opens only when
-- hasZoneT3Warp confirms the player has the zone's T3 "click-anywhere" warp (a
-- T1/T2 warp can't reach the marked spot; a nil "can't tell" result also does not
-- open). The player still performs the in-game T3 click-to-warp action manually.

local function normLookupText(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "[^%w]+", "")
    return value
end

local function zoneNameForId(zoneId)
    if zoneId == nil then
        return nil
    end
    if type(_G.Custom_GetZoneName) == "function" then
        local name = safeFirst(_G.Custom_GetZoneName, zoneId)
        if name and name ~= "" then
            return name
        end
    end
    if type(C_Map) == "table" and type(C_Map.GetAreaInfo) == "function" then
        local name = safeFirst(C_Map.GetAreaInfo, zoneId)
        if name and name ~= "" then
            return name
        end
    end
    if type(GetMapNameByID) == "function" then
        local name = safeFirst(GetMapNameByID, zoneId)
        if name and name ~= "" then
            return name
        end
    end
    return nil
end

local function isSameZoneName(a, b)
    return normLookupText(a) ~= "" and normLookupText(a) == normLookupText(b)
end

local function unpackCoordinateResult(result, a, b, c)
    if type(result) == "table" then
        local x = tonumber(result.x or result[1])
        local y = tonumber(result.y or result[2])
        local zoneId = tonumber(result.zoneId or result.areaId or result.mapId or result[3])
        local zoneName = result.zoneName or result.zone
        if x and y then
            return x, y, zoneId, zoneName
        end
        return nil
    end

    local n1, n2, n3 = tonumber(result), tonumber(a), tonumber(b)
    if n1 and n2 and n1 <= 100 and n2 <= 100 then
        return n1, n2, tonumber(c), nil
    end
    if n1 and n2 and n3 and n2 <= 100 and n3 <= 100 then
        return n2, n3, n1, nil
    end
    return nil
end

local function getServerMobCoordinates(entry)
    local candidates = {
        "Custom_GetNpcCoords",
        "Custom_GetNpcLocation",
        "Custom_GetCreatureCoords",
        "Custom_GetCreatureLocation",
    }
    for _, name in ipairs(candidates) do
        local fn = _G[name]
        if type(fn) == "function" then
            local ok, a, b, c, d = safeCall(fn, entry.npcId, entry.zoneName)
            if ok then
                local x, y, zoneId, zoneName = unpackCoordinateResult(a, b, c, d)
                if x and y then
                    return {
                        x = x,
                        y = y,
                        zoneId = zoneId,
                        zoneName = zoneName or zoneNameForId(zoneId) or entry.zoneName,
                        source = name,
                    }
                end
            end
        end
    end
    return nil
end

local function importQuestieModule(name)
    if type(_G.QuestieLoader) == "table" and type(_G.QuestieLoader.ImportModule) == "function" then
        local ok, module = pcall(_G.QuestieLoader.ImportModule, _G.QuestieLoader, name)
        if ok and type(module) == "table" then
            return module
        end
    end
    return _G[name]
end

local function importQuestieDB()
    return importQuestieModule("QuestieDB")
end

local function getPlayerMapPosition()
    if type(GetPlayerMapPosition) == "function" then
        local x, y = GetPlayerMapPosition("player")
        x, y = tonumber(x), tonumber(y)
        if x and y and x > 0 and y > 0 then
            return x * 100, y * 100
        end
    end
    return nil
end

local function pickQuestieSpawn(spawns, wantedZoneName)
    local wantedKey = normLookupText(wantedZoneName)
    local bestZoneId, bestSpawns
    local fallbackZoneId, fallbackSpawns

    for zoneId, zoneSpawns in pairs(spawns or {}) do
        if type(zoneSpawns) == "table" and zoneSpawns[1] then
            fallbackZoneId = fallbackZoneId or zoneId
            fallbackSpawns = fallbackSpawns or zoneSpawns

            local questieZoneName = zoneNameForId(zoneId)
            if wantedKey ~= "" and isSameZoneName(questieZoneName, wantedZoneName) then
                bestZoneId, bestSpawns = zoneId, zoneSpawns
                break
            end
        end
    end

    local zoneId = bestZoneId or fallbackZoneId
    local zoneSpawns = bestSpawns or fallbackSpawns
    if not zoneSpawns then
        return nil
    end

    local playerX, playerY = nil, nil
    if isSameZoneName(AF.GetCurrentZoneName(), wantedZoneName) then
        playerX, playerY = getPlayerMapPosition()
    end

    local best, bestDist
    for _, spawn in ipairs(zoneSpawns) do
        local x, y = tonumber(spawn[1]), tonumber(spawn[2])
        if x and y and x >= 0 and y >= 0 then
            if playerX and playerY then
                local dx, dy = x - playerX, y - playerY
                local dist = dx * dx + dy * dy
                if not bestDist or dist < bestDist then
                    best, bestDist = spawn, dist
                end
            elseif not best then
                best = spawn
            end
        end
    end

    if not best then
        return nil
    end
    return {
        x = tonumber(best[1]),
        y = tonumber(best[2]),
        zoneId = zoneId,
        zoneName = zoneNameForId(zoneId) or wantedZoneName,
        source = "Questie",
    }
end

local function getQuestieMobCoordinates(entry)
    local db = importQuestieDB()
    if type(db) ~= "table" then
        return nil
    end

    local spawns
    if type(db.QueryNPCSingle) == "function" then
        spawns = safeFirst(db.QueryNPCSingle, entry.npcId, "spawns")
    end
    if not spawns and type(db.GetNPC) == "function" then
        local npc = safeFirst(db.GetNPC, db, entry.npcId)
        spawns = npc and npc.spawns
    end
    return pickQuestieSpawn(spawns, entry.zoneName)
end

function AF.ResolveMobWarpTarget(entry)
    if type(entry) ~= "table" or not entry.npcId then
        return nil, "missing NPC id"
    end

    local target = getServerMobCoordinates(entry) or getQuestieMobCoordinates(entry)
    if not target or not target.x or not target.y then
        return nil, "no coordinates found for " .. tostring(entry.npcName or ("NPC #" .. tostring(entry.npcId)))
    end
    target.npcId = entry.npcId
    target.npcName = entry.npcName
    target.zoneName = target.zoneName or entry.zoneName
    return target
end

-- Synastria zone warps come in three tiers, by how many times you unlocked the
-- zone's warp: T1 (1x) = fixed drop point, T2 / "warp mastery" (2x) = you set the
-- point, T3 / "warp attunement" (3x) = click ANYWHERE on the map to land there.
-- Only T3 makes opening the map useful, so the warp assist gates on T3, not on
-- merely owning a warp.
local REQUIRED_WARP_TIER = 3

-- zoneName -> warp spell index (0-based) passed to CustomHasTeleport. There is no
-- server API to map a zone name to its warp index, so we bundle the mapping
-- ourselves rather than depend on another addon being installed. (A loaded
-- qtRunner ships the same table in qtRunnerData.spells and is used only as an
-- optional supplement below, in case the server adds warps before this snapshot
-- is refreshed.) Indices are server-defined and stable; refresh if the server's
-- warp list changes.
local WARP_ZONE_INDEX = {
    ["Isle of Quel'Danas"] = 0, ["Eversong Woods"] = 1, ["Ghostlands"] = 2,
    ["Eastern Plaguelands"] = 3, ["Western Plaguelands"] = 4, ["Tirisfal Glades"] = 5,
    ["Undercity"] = 6, ["Silverpine Forest"] = 7, ["Alterac Mountains"] = 8,
    ["Hillsbrad Foothills"] = 9, ["The Hinterlands"] = 10, ["Arathi Highlands"] = 11,
    ["Wetlands"] = 12, ["Loch Modan"] = 13, ["Ironforge"] = 14, ["Dun Morogh"] = 15,
    ["Badlands"] = 16, ["Searing Gorge"] = 17, ["Burning Steppes"] = 18,
    ["Redridge Mountains"] = 19, ["Elwynn Forest"] = 20, ["Stormwind City"] = 21,
    ["Westfall"] = 22, ["Duskwood"] = 23, ["Deadwind Pass"] = 24,
    ["Swamp of Sorrows"] = 25, ["Blasted Lands"] = 26, ["Stranglethorn Vale"] = 27,
    ["Silvermoon City"] = 28, ["Silithus"] = 29, ["Un'Goro Crater"] = 30,
    ["Tanaris"] = 31, ["Thousand Needles"] = 32, ["Feralas"] = 33, ["Desolace"] = 34,
    ["Mulgore"] = 35, ["Thunder Bluff"] = 36, ["The Barrens"] = 37,
    ["Dustwallow Marsh"] = 38, ["Stonetalon Mountains"] = 39, ["Durotar"] = 40,
    ["Orgrimmar"] = 41, ["Ashenvale"] = 42, ["Azshara"] = 43, ["Winterspring"] = 44,
    ["Felwood"] = 45, ["Darkshore"] = 46, ["Moonglade"] = 47, ["Teldrassil"] = 48,
    ["Darnassus"] = 49, ["Azuremyst Isle"] = 50, ["The Exodar"] = 51,
    ["Bloodmyst Isle"] = 52, ["Hellfire Peninsula"] = 53, ["Zangarmarsh"] = 54,
    ["Nagrand"] = 55, ["Terokkar Forest"] = 56, ["Shadowmoon Valley"] = 57,
    ["Blade's Edge Mountains"] = 58, ["Netherstorm"] = 59, ["Shattrath City"] = 60,
    ["Howling Fjord"] = 61, ["Grizzly Hills"] = 62, ["Zul'Drak"] = 63,
    ["The Storm Peaks"] = 64, ["Crystalsong Forest"] = 65, ["Dalaran"] = 66,
    ["Icecrown"] = 67, ["Dragonblight"] = 68, ["Wintergrasp"] = 69,
    ["Sholazar Basin"] = 70, ["Borean Tundra"] = 71,
}

-- Lazily-built normalized (case/punctuation-insensitive) index over the bundled
-- table, so loot-data zone names that differ only in punctuation still match.
local warpIndexByNormKey

local function bundledWarpIndex(zoneName)
    local idx = WARP_ZONE_INDEX[zoneName]
    if idx ~= nil then
        return idx
    end
    if not warpIndexByNormKey then
        warpIndexByNormKey = {}
        for name, index in pairs(WARP_ZONE_INDEX) do
            warpIndexByNormKey[normLookupText(name)] = index
        end
    end
    return warpIndexByNormKey[normLookupText(zoneName)]
end

-- Optional supplement: a loaded qtRunner's (possibly newer) zone->index table.
local function qtRunnerWarpIndex(zoneName)
    local qtData = _G.qtRunnerData
    local spells = type(qtData) == "table" and qtData.spells
    if type(spells) ~= "table" then
        return nil
    end
    local idx = spells[zoneName]
    if idx ~= nil then
        return idx
    end
    local wanted = normLookupText(zoneName)
    for name, index in pairs(spells) do
        if normLookupText(name) == wanted then
            return index
        end
    end
    return nil
end

-- The zone's warp index from our bundled table, falling back to a loaded
-- qtRunner's table for anything we don't have. nil = the zone has no zone warp.
local function resolveWarpIndex(zoneName)
    if type(zoneName) ~= "string" or zoneName == "" then
        return nil
    end
    local idx = bundledWarpIndex(zoneName)
    if idx ~= nil then
        return idx
    end
    return qtRunnerWarpIndex(zoneName)
end

-- The raw warp tier the server reports for a zone, or nil if it can't be read
-- (no warp index, or no CustomHasTeleport). CustomHasTeleport(index) returns the
-- unlock count / tier: 0 none, 1 T1 (fixed point), 2 T2 (mastery), 3 T3
-- (attunement) -- confirmed in-game via `/af warp`. Returns (tier, warpIndex).
local function zoneWarpTier(zoneName)
    local warpIndex = resolveWarpIndex(zoneName)
    if warpIndex == nil or type(_G.CustomHasTeleport) ~= "function" then
        return nil, warpIndex
    end
    local ok, value = safeCall(_G.CustomHasTeleport, warpIndex)
    if not ok then
        return nil, warpIndex
    end
    return tonumber(value), warpIndex
end

-- Does the player have the T3 (click-anywhere) warp for this zone?
--   true  : tier >= 3 -- opening the map to a spot is useful
--   false : a lower tier (T1/T2) or none -- opening the map would not help
--   nil   : can't determine (no warp data / API) -- treat as "don't open"
local function hasZoneT3Warp(zoneName)
    local tier = zoneWarpTier(zoneName)
    if tier == nil then
        return nil
    end
    return tier >= REQUIRED_WARP_TIER
end

local function setTrackedMobTarget(target)
    if type(_G.Custom_AddTrackObjLoc) ~= "function" or not target.npcId then
        return false
    end

    local previousNpcId = AF._lastWarpAssistTrackedNpcId
    if previousNpcId and previousNpcId ~= target.npcId and type(_G.Custom_RemoveTrackObjLoc) == "function" then
        safeCall(_G.Custom_RemoveTrackObjLoc, OBJTYPE_CREATURE, previousNpcId)
    end

    local ok = safeCall(_G.Custom_AddTrackObjLoc, OBJTYPE_CREATURE, target.npcId)
    if ok then
        AF._lastWarpAssistTrackedNpcId = target.npcId
    end
    return ok and true or false
end

local WARP_PIN_TYPE = "affixfinder-warp"

local function showWorldMap()
    if _G.WorldMapFrame and type(_G.ShowUIPanel) == "function" then
        local ok = safeCall(_G.ShowUIPanel, _G.WorldMapFrame)
        if ok then
            return true
        end
    end
    if _G.WorldMapFrame and type(_G.WorldMapFrame.Show) == "function" then
        local ok = safeCall(_G.WorldMapFrame.Show, _G.WorldMapFrame)
        if ok then
            return true
        end
    end
    return false
end

local function openMapWithQuestie(target)
    if not target.zoneId then
        return false
    end

    local zoneDb = importQuestieModule("ZoneDB")
    if type(zoneDb) ~= "table" or type(zoneDb.GetUiMapIdByAreaId) ~= "function" then
        return false
    end

    local uiMapId = safeFirst(zoneDb.GetUiMapIdByAreaId, zoneDb, target.zoneId)
    if not uiMapId then
        return false
    end

    local compat = rawget(_G, "QuestieCompat")
    local mapFrame = type(compat) == "table" and compat.WorldMapFrame
    if type(mapFrame) == "table" and type(mapFrame.Show) == "function" then
        safeCall(mapFrame.Show, mapFrame)
    else
        showWorldMap()
    end

    if type(mapFrame) == "table" and type(mapFrame.SetMapID) == "function" then
        local ok = safeCall(mapFrame.SetMapID, mapFrame, uiMapId)
        if ok then
            return true
        end
    end

    return false
end

local function openMapByZoneName(zoneName)
    showWorldMap()
    if type(zoneName) ~= "string" or zoneName == "" or type(GetMapContinents) ~= "function"
        or type(GetMapZones) ~= "function" or type(SetMapZoom) ~= "function" then
        return false
    end

    local continents = { GetMapContinents() }
    for continentIndex = 1, #continents do
        local zones = { GetMapZones(continentIndex) }
        for zoneIndex, name in ipairs(zones) do
            if isSameZoneName(name, zoneName) then
                local ok = safeCall(SetMapZoom, continentIndex, zoneIndex)
                if ok then
                    if type(WorldMapFrame_Update) == "function" then
                        safeCall(WorldMapFrame_Update)
                    end
                    return true
                end
            end
        end
    end
    return false
end

local function drawQuestieWarpPin(target)
    if not target.zoneId or not target.x or not target.y or not target.npcId then
        return false
    end

    local questieMap = importQuestieModule("QuestieMap")
    if type(questieMap) ~= "table" or type(questieMap.DrawManualIcon) ~= "function" then
        return false
    end

    if type(questieMap.ResetManualFrames) == "function"
        and type(questieMap.manualFrames) == "table" and questieMap.manualFrames[WARP_PIN_TYPE] then
        safeCall(questieMap.ResetManualFrames, questieMap, WARP_PIN_TYPE)
    elseif type(questieMap.UnloadManualFrames) == "function" then
        safeCall(questieMap.UnloadManualFrames, questieMap, target.npcId, WARP_PIN_TYPE)
    end

    local title = tostring(target.npcName or "Mob") .. " (AffixFinder warp target)"
    local data = {
        id = target.npcId,
        Icon = "Interface\\WorldMap\\WorldMapPartyIcon",
        Type = "manual",
        spawnType = "monster",
        Name = tostring(target.npcName or ("NPC #" .. tostring(target.npcId))),
        IsObjectiveNote = false,
        GetIconScale = function()
            return 1.15
        end,
        ManualTooltipData = {
            Title = title,
            Body = {
                { "Zone:", tostring(target.zoneName or "?") },
                { "Coords:", string.format("%.1f, %.1f", target.x, target.y) },
            },
            disableShiftToRemove = true,
        },
    }

    local ok = safeCall(questieMap.DrawManualIcon, questieMap, data, target.zoneId, target.x, target.y, WARP_PIN_TYPE)
    return ok and true or false
end

-- Places the map/minimap marker for a mob. Two independent layers:
--   1. Server tracking (setTrackedMobTarget): needs only the npcId; the WoWExt
--      server knows the creature's spawn points and renders the marker itself.
--      This is the SAME mechanism qtRunner uses (Custom_AddTrackObjLoc with
--      OBJTYPE_CREATURE) and works with NO coordinate data and NO Questie.
--   2. A precise manual pin (drawQuestieWarpPin): a nicer pin at the exact spawn,
--      but it needs resolved coordinates -- i.e. Questie (or a server coord API,
--      which this client does not expose). Optional enhancement only.
-- `entry` carries npcId/npcName/zoneName; `target` is the resolved-coords table
-- (may be nil). markMode describes what was actually placed.
local function markMobTarget(entry, target)
    local tracked = setTrackedMobTarget(entry)
    local pinned = target and drawQuestieWarpPin(target) or false
    local mode
    if pinned then
        mode = tracked and "map pin + server tracker" or "map pin"
    elseif tracked then
        mode = "server tracker"
    else
        mode = "no map marker available"
    end
    return (pinned or tracked), mode
end

-- Opens the world map to the target. Prefers Questie's exact uiMap positioning
-- when coordinates were resolved, but always falls back to zooming the Blizzard
-- world map to the zone by name (no Questie needed) so warp assist still works.
local function openWarpAssistMap(target, zoneName)
    if target and openMapWithQuestie(target) then
        return true
    end
    if openMapByZoneName(zoneName or (target and target.zoneName)) then
        return true
    end
    return false, "could not open the world map to the target zone"
end

-- A "Zone 12.3, 45.6" / "Zone" location suffix for chat, depending on whether
-- precise coordinates were available.
local function locationText(zoneName, target)
    if target and target.x and target.y then
        return string.format("%s %.1f, %.1f", tostring(zoneName or "?"), target.x, target.y)
    end
    return tostring(zoneName or "?")
end

function AF.TryWarpToMob(entry)
    if type(entry) ~= "table" or not entry.npcId then
        chat("Mob pin: missing NPC id.")
        return false, "missing NPC id"
    end

    -- Optional: resolve precise coordinates (server coord API, else Questie). When
    -- this fails (e.g. no Questie), we still place the server's own tracker below.
    local target = AF.ResolveMobWarpTarget(entry)
    -- Classify and look up the warp against the AUTHORITATIVE loot-data zone
    -- (entry.zoneName) -- the same name the rankings/marker use. Questie's
    -- target.zoneName is derived from a spawn areaId in a different id space than
    -- WoWExt's zones, so it can resolve to a wrong/sub-zone name (e.g. a world zone
    -- read as a dungeon, which wrongly tripped the "no warp into a dungeon" path).
    -- target is used only for the precise pin + coordinates.
    local zoneName = entry.zoneName or (target and target.zoneName)
    -- Keep the pin's own label on the authoritative zone too (it only affects the
    -- pin tooltip; placement still uses target.zoneId/x/y).
    if target then
        target.zoneName = zoneName
    end

    local marked, markMode = markMobTarget(entry, target)
    local locText = locationText(zoneName, target)
    local mobName = tostring(entry.npcName or "mob")

    if not marked then
        chat(string.format("Mob pin failed: %s @ %s.", mobName, locText))
        return false, "could not mark"
    end

    if not AF.GetConfig("automaticWarp") then
        chat(string.format("Mob pin: %s @ %s.", mobName, locText))
        return true, { target = target, marked = marked }
    end

    -- T3 warp assist (opt-in). There are no zone warps INTO dungeons/raids, so for
    -- instance content we never open the map -- the marker is still placed so the
    -- player can find the mob once they walk in manually.
    local category = AF.ClassifyZone(zoneName)
    if category == "dungeon" or category == "raid" then
        chat(string.format("Mob pin: %s @ %s.", mobName, locText))
        return true, { target = target, marked = marked, opened = false, reason = "instance" }
    end

    -- Only open the map when we can CONFIRM the player has this zone's T3 (click-
    -- anywhere) warp -- a T1/T2 warp can't drop you on the marked spot, so opening
    -- the map wouldn't help. This keeps the assistant useful for players with a
    -- partial set of T3 warps: it opens for the zones they can T3 to and stays
    -- quiet for the rest. A nil result (warp data unavailable) -> don't open.
    local hasT3 = hasZoneT3Warp(zoneName)
    if not hasT3 then
        local why = (hasT3 == false) and "you don't have the T3 (click-anywhere) warp for this zone"
            or "could not confirm a T3 warp for this zone"
        chat(string.format("Mob pin: %s @ %s.", mobName, locText))
        return true, { target = target, marked = marked, opened = false, reason = why }
    end

    local opened, openErr = openWarpAssistMap(target, zoneName)
    if opened then
        chat(string.format("Mob pin: %s @ %s.", mobName, locText))
        return true, { target = target, marked = marked, opened = true }
    end

    chat(string.format("Mob pin: %s @ %s.", mobName, locText))
    return true, { target = target, marked = marked, opened = false, reason = openErr }
end


I.Warp = {
    REQUIRED_WARP_TIER = REQUIRED_WARP_TIER,
    WARP_ZONE_INDEX = WARP_ZONE_INDEX,
    bundledWarpIndex = bundledWarpIndex,
    isSameZoneName = isSameZoneName,
    qtRunnerWarpIndex = qtRunnerWarpIndex,
}
