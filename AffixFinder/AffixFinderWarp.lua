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

-- Like isSameZoneName but ignores difficulty/size qualifiers, so the server's
-- "Gundrak (Normal)" / "Gundrak Heroic" / "Naxxramas 25" all match Questie's
-- plain "Gundrak" / "Naxxramas" zone. Uses ZoneClassify.normZoneKey (loaded
-- after this file, so resolved lazily); falls back to the exact match if it is
-- somehow unavailable.
local function isSameZoneNameLoose(a, b)
    local zc = I.ZoneClassify
    local norm = type(zc) == "table" and zc.normZoneKey
    if norm then
        local ka = norm(a)
        return ka ~= "" and ka == norm(b)
    end
    return isSameZoneName(a, b)
end

-- Area name for a Questie spawn-zone key, with a Questie fallback. The server's
-- Custom_GetZoneName does not reliably resolve dungeon CONTAINER AreaIds (e.g.
-- Gundrak's 4416 returns nil), but Questie's own ZoneDB dungeon table carries
-- the name -- so density can still bridge that key to a yard-scaled map.
local function questieAreaName(zoneDb, areaId)
    local name = zoneNameForId(areaId)
    if name and name ~= "" then
        return name
    end
    if type(zoneDb) == "table" and type(zoneDb.GetDungeons) == "function" then
        local dungeons = safeFirst(zoneDb.GetDungeons, zoneDb)
        local entry = type(dungeons) == "table" and dungeons[tonumber(areaId)]
        if type(entry) == "table" and entry[1] and entry[1] ~= "" then
            return entry[1]
        end
    end
    -- Dependency-free fallback: bundled dungeon container names.
    if I.SpawnDB then
        local bundled = I.SpawnDB.dungeonName(areaId)
        if bundled and bundled ~= "" then
            return bundled
        end
    end
    return name
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

local function getQuestieNpcSpawns(npcId)
    local db = importQuestieDB()
    local spawns
    if type(db) == "table" then
        if type(db.QueryNPCSingle) == "function" then
            spawns = safeFirst(db.QueryNPCSingle, npcId, "spawns")
        end
        if not spawns and type(db.GetNPC) == "function" then
            local npc = safeFirst(db.GetNPC, db, npcId)
            spawns = npc and npc.spawns
        end
    end
    -- Dependency-free fallback: bundled spawn data when Questie is absent.
    if not spawns and I.SpawnDB then
        spawns = I.SpawnDB.npcSpawns(npcId)
    end
    return spawns
end

-- The UiMapData yard-scale table: Questie's when loaded, else the bundle. Both
-- carry the same {width,height,left,top,instance,name} rows, so every reader
-- below is source-agnostic.
local function getUiMapData()
    local compat = rawget(_G, "QuestieCompat")
    local mapData = type(compat) == "table" and compat.UiMapData
    if type(mapData) == "table" then
        return mapData
    end
    return I.SpawnDB and I.SpawnDB.uiMapData() or nil
end

-- Convert a 0-1 map point to world yards via Questie's HBD when present, else
-- the bundled reimplementation (identical arithmetic). Returns safeCall-style
-- (ok, worldX, worldY, instanceId) so callers handle both paths uniformly.
local function worldFromZone(x01, y01, uiMapId)
    local compat = rawget(_G, "QuestieCompat")
    local hbd = type(compat) == "table" and compat.HBD
    if type(hbd) == "table" and type(hbd.GetWorldCoordinatesFromZone) == "function" then
        return safeCall(hbd.GetWorldCoordinatesFromZone, hbd, x01, y01, uiMapId)
    end
    if I.SpawnDB then
        local x, y, instance = I.SpawnDB.worldFromZone(x01, y01, uiMapId)
        if x and y then
            return true, x, y, instance
        end
    end
    return false
end

local function getQuestieMobCoordinates(entry)
    return pickQuestieSpawn(getQuestieNpcSpawns(entry.npcId), entry.zoneName)
end

-- QuestieCompat.UiMapData is keyed by uiMapId, each entry carrying the map's
-- yard scale plus a `name`/`instance`. Build name -> {uiMapId,...} and
-- instance -> {uiMapId,...} indexes once (the data is static) so a zone with no
-- areaIdToUiMapId entry can still be matched to a yard-scaled map. Returns nil
-- (without caching) until QuestieCompat is loaded, so a too-early call simply
-- retries later.
local uiMapIndex
local function buildUiMapIndex()
    if uiMapIndex then
        return uiMapIndex
    end
    local mapData = getUiMapData()
    if type(mapData) ~= "table" then
        return nil
    end
    local byName, byInstance = {}, {}
    local function push(index, key, uiMapId)
        local list = index[key]
        if not list then
            list = {}
            index[key] = list
        end
        list[#list + 1] = uiMapId
    end
    for uiMapId, data in pairs(mapData) do
        uiMapId = tonumber(uiMapId)
        if uiMapId and type(data) == "table" then
            local k = normLookupText(data.name)
            if k ~= "" then
                push(byName, k, uiMapId)
            end
            local inst = tonumber(data.instance)
            if inst and inst > 0 then
                push(byInstance, inst, uiMapId)
            end
        end
    end
    uiMapIndex = { byName = byName, byInstance = byInstance }
    return uiMapIndex
end

local function uiMapIdsByName(name)
    local key = normLookupText(name)
    local index = key ~= "" and buildUiMapIndex()
    return index and index.byName[key]
end

local function uiMapIdsByInstance(instanceId)
    instanceId = tonumber(instanceId)
    local index = instanceId and buildUiMapIndex()
    return index and index.byInstance[instanceId]
end

-- Usable UiMapIds for a zone, best scale first. The direct areaId -> uiMapId
-- lookup covers open-world zones; dungeon CONTAINER AreaIds (e.g. Gundrak's
-- 4416, the id its spawns are keyed under) have NO areaIdToUiMapId entry, so
-- they are resolved against UiMapData -- by the server's instance map id when
-- known, else by zone name. That is the only path giving instances a world-yard
-- scale (the lesson Gundrak taught: Questie's GetParentZoneId maps a dungeon to
-- its OUTDOOR parent, never to a floor, so a container-to-floor walk finds
-- nothing).
local function questieUiMapCandidates(zoneDb, zoneId, instanceId)
    zoneId = tonumber(zoneId)
    local candidates, seen = {}, {}
    local function add(uiMapId)
        uiMapId = tonumber(uiMapId)
        if uiMapId and not seen[uiMapId] then
            seen[uiMapId] = true
            candidates[#candidates + 1] = uiMapId
        end
    end
    local function addAll(list)
        if list then
            for _, uiMapId in ipairs(list) do
                add(uiMapId)
            end
        end
    end

    if type(zoneDb) == "table" and type(zoneDb.GetUiMapIdByAreaId) == "function" then
        add(safeFirst(zoneDb.GetUiMapIdByAreaId, zoneDb, zoneId))
    elseif I.SpawnDB then
        add(I.SpawnDB.areaUiMapId(zoneId))
    end
    addAll(uiMapIdsByInstance(instanceId))
    addAll(uiMapIdsByName(questieAreaName(zoneDb, zoneId)))
    return candidates
end

local function questieZoneInstanceId(zoneDb, zoneId)
    local mapData = getUiMapData()
    if type(mapData) ~= "table" then
        return nil
    end
    for _, uiMapId in ipairs(questieUiMapCandidates(zoneDb, zoneId)) do
        local data = mapData[uiMapId]
        local instanceId = type(data) == "table" and tonumber(data.instance)
        if instanceId then
            return instanceId
        end
    end
    return nil
end

-- Convert 0-100 map coordinates to world yards. Uses Questie's HBD layer when
-- present, else the bundled reimplementation (worldFromZone), so density grades
-- work with no dependency. Farm-density grades use yards so one grade means
-- roughly the same pull size in every zone. The raw map points remain available
-- for diagnostics and as an ungraded fallback.
local function questieWorldPoints(points, zoneId, zoneDb, instanceId)
    zoneDb = zoneDb or importQuestieModule("ZoneDB")

    for _, uiMapId in ipairs(questieUiMapCandidates(zoneDb, zoneId, instanceId)) do
        local world, instanceId, valid = {}, nil, true
        for _, point in ipairs(points) do
            local ok, x, y, instance =
                worldFromZone(point[1] / 100, point[2] / 100, uiMapId)
            if not ok or not tonumber(x) or not tonumber(y)
                or (instanceId ~= nil and instance ~= instanceId)
            then
                valid = false
                break
            end
            instanceId = instanceId or instance
            world[#world + 1] = { tonumber(x), tonumber(y) }
        end
        if valid then
            return world, uiMapId, instanceId
        end
    end
    return nil
end

-- ALL Questie-known spawn points for an NPC, matched by source zone ID first
-- and instance map ID / exact zone name after that. A failed match returns nil:
-- geometry from some other zone must never receive a confident farm-density
-- grade. Coordinates are percent-of-zone-map (0-100); (-1,-1) dungeon
-- placeholders are dropped. When Questie's map layer supports the zone,
-- metricPoints are world yards.
local function questieSpawnPoints(npcId, zoneName, sourceZoneId)
    local spawns = getQuestieNpcSpawns(npcId)
    if type(spawns) ~= "table" then
        return nil
    end

    local wantedKey = normLookupText(zoneName)
    local zoneDb = importQuestieModule("ZoneDB")
    local bestZoneId, bestSpawns, matchedBy
    for zoneId, zoneSpawns in pairs(spawns) do
        if type(zoneSpawns) == "table" and zoneSpawns[1] then
            if sourceZoneId ~= nil and tonumber(zoneId) == tonumber(sourceZoneId) then
                bestZoneId, bestSpawns, matchedBy = zoneId, zoneSpawns, "zone id"
                break
            end
        end
    end
    local sourceInstanceId = tonumber(sourceZoneId)
    sourceInstanceId = sourceInstanceId and sourceInstanceId >= 32768
        and (sourceInstanceId - 32768) or nil
    if not bestSpawns and sourceInstanceId then
        for zoneId, zoneSpawns in pairs(spawns) do
            if type(zoneSpawns) == "table" and zoneSpawns[1]
                and questieZoneInstanceId(zoneDb, zoneId) == sourceInstanceId
            then
                bestZoneId, bestSpawns, matchedBy = zoneId, zoneSpawns, "instance id"
                break
            end
        end
    end
    if not bestSpawns and wantedKey ~= "" then
        for zoneId, zoneSpawns in pairs(spawns) do
            if type(zoneSpawns) == "table" and zoneSpawns[1]
                and isSameZoneNameLoose(questieAreaName(zoneDb, zoneId), zoneName)
            then
                bestZoneId, bestSpawns, matchedBy = zoneId, zoneSpawns, "zone name"
                break
            end
        end
    end
    local zoneId = bestZoneId
    local zoneSpawns = bestSpawns
    if not zoneSpawns then
        return nil
    end

    local points = {}
    for _, spawn in ipairs(zoneSpawns) do
        local x, y = tonumber(spawn[1]), tonumber(spawn[2])
        if x and y and x >= 0 and y >= 0 then
            points[#points + 1] = { x, y }
        end
    end
    if #points == 0 then
        return nil
    end
    local worldPoints, uiMapId, instanceId =
        questieWorldPoints(points, zoneId, zoneDb, sourceInstanceId)
    return {
        points = points,
        metricPoints = worldPoints or points,
        unit = worldPoints and "yards" or "map",
        zoneId = zoneId,
        zoneName = questieAreaName(zoneDb, zoneId),
        matchedZone = true,
        matchedBy = matchedBy,
        uiMapId = uiMapId,
        instanceId = instanceId,
    }
end

-- ---------------------------------------------------------------------------
-- Farm density (how big a pull the spawn geometry can deliver)
-- ---------------------------------------------------------------------------
-- The headline score answers the question players actually ask: "to farm the N
-- mobs I want (campSize = the min-spawns setting), how many AoE pulls does it
-- take?" We find the densest spot -- the most spawns inside one pull circle of
-- radius PULL_RADIUS -- as `pullCount`, then `pullsNeeded = ceil(N / pullCount)`
-- (repeating that best spot, the way a camp is actually ground out as respawns
-- refill it). The grade is RELATIVE to the player's N: 1 pull = excellent, 2 =
-- good, 3 = fair, 4+ = poor. So a tight ZF-beetle swarm that hands you all N at
-- once is excellent, while a scattered mob you grab two-at-a-time is poor.
--
-- Caveat by design: gathering N never needs more than N pulls, so a small N
-- compresses the scale (at N=2 the worst case is 2 pulls = good). It is well
-- spread from N~5 up; the default and the typical use are in that range.
--
-- The circle's center is NOT pinned to a spawn: from each seed we take a couple
-- of mean-shift steps (recenter on the centroid of whatever is currently in the
-- circle) so it settles where a player would actually stand -- between the mobs,
-- not on the edge one.
--
-- pullCount is a COUNT, not a span: a ring/line whose members are far from EACH
-- OTHER has few sharing any one circle and grades low, unlike a centroid-radius
-- score that called any centered-but-spread pack "excellent". Respawn timing is
-- excluded (the client cannot observe it) and spawns outside the best circle do
-- not poison the result. Production grades require world-yard coordinates;
-- percent-of-map geometry stays useful for tests/diagnostics but is not trusted
-- by the list filter.
--
-- spawnGeometry(points, campSize) returns nil for no points, else { points,
-- sampled, meanGap, maxGap, spanX, spanY, spanDiag, clusters, clusterSizes
-- (desc), largestClusterSpan, routeLen, walkPerKill, shape, unit,
-- camp = { requested, size, pullCount, pullsNeeded, pullRadius, center, grade,
-- short, confident } | nil (campSize < 2) }.
--
-- Supporting whole-pack shape still uses the same distance unit as the input.
local SPAWN_GAP_TIGHT = 3
local SPAWN_GAP_MEDIUM = 7
local SPAWN_CLUSTER_LINK = 6
local SPAWN_CAMP_SPAN = 12
local SPAWN_GEOMETRY_CAP = 200  -- cap supporting whole-pack shape; pull search uses all points
-- The pull circle's radius: how far from where you stand a mob can be and still
-- get balled into one AoE pull. Yards is the production contract; the map-%
-- value is for unscaled diagnostics and pure geometry tests only. THE knob to
-- retune if grades feel generous/harsh in game.
local PULL_RADIUS_YARDS = 20
local PULL_RADIUS_MAP = 3
local PULL_RECENTER_STEPS = 2  -- mean-shift iterations toward the densest spot

local DENSITY_RANK = { poor = 0, fair = 1, good = 2, excellent = 3 }
-- Exposed so views can map a saved rank back to its label (0=any is the
-- filter's "off" value, not a grade).
AF.DENSITY_GRADE_BY_RANK = { [1] = "fair", [2] = "good", [3] = "excellent" }

-- Pulls (of the densest circle) to gather the requested N -> grade. 1 = all N at
-- once, then one band per extra pull. These three boundaries are the tuning knob.
local function pullsGrade(pullsNeeded)
    if pullsNeeded <= 1 then
        return "excellent"
    elseif pullsNeeded <= 2 then
        return "good"
    elseif pullsNeeded <= 3 then
        return "fair"
    end
    return "poor"
end

-- Count spawns within `radius` of (cx, cy) and the centroid of those spawns
-- (for the next mean-shift step).
local function pullCircle(points, n, cx, cy, radius, maybeYield)
    local r2 = radius * radius
    local count, sumX, sumY = 0, 0, 0
    for j = 1, n do
        if j % 100 == 0 then
            maybeYield()
        end
        local dx, dy = points[j][1] - cx, points[j][2] - cy
        if dx * dx + dy * dy <= r2 then
            count = count + 1
            sumX = sumX + points[j][1]
            sumY = sumY + points[j][2]
        end
    end
    return count, sumX, sumY
end

-- Densest pull circle: from each spawn, mean-shift the circle toward the local
-- centroid a few steps and keep the best count seen. O(n^2) (the recenter steps
-- are a small constant factor), run inside the time-budgeted density coroutine.
-- `short` (fewer mapped points than requested) leaves the result unconfident:
-- too little Questie data to trust either way.
local function bestPull(points, n, requested, maybeYield, unit)
    requested = math.floor(tonumber(requested) or 0)
    if requested < 2 or n < 1 then
        return nil
    end
    local short = requested > n
    local pullRadius = unit == "yards" and PULL_RADIUS_YARDS or PULL_RADIUS_MAP
    local bestCount, bestCenter = 0, nil
    for seed = 1, n do
        maybeYield()
        local cx, cy = points[seed][1], points[seed][2]
        for step = 0, PULL_RECENTER_STEPS do
            local count, sumX, sumY = pullCircle(points, n, cx, cy, pullRadius, maybeYield)
            if count > bestCount then
                bestCount = count
                bestCenter = { cx, cy }
            end
            if step < PULL_RECENTER_STEPS and count > 0 then
                cx, cy = sumX / count, sumY / count
            end
        end
    end
    local confident = unit == "yards" and not short
    -- bestCount >= 1 always (a spawn counts itself), so this is finite.
    local pullsNeeded = math.ceil(requested / bestCount)
    return {
        requested = requested,
        size = n,
        pullCount = bestCount,
        pullsNeeded = pullsNeeded,
        pullRadius = pullRadius,
        center = bestCenter,
        grade = pullsGrade(pullsNeeded),
        short = short or nil,
        confident = confident or nil,
    }
end

-- `maybeYield` (optional) is called throughout the O(n^2) phases, including
-- every 100 candidates in the all-points camp search. The background worker
-- passes a function that yields its coroutine when the frame budget is spent,
-- so even ONE big mob cannot blow a frame.
-- Synchronous callers omit it.
local function noYield() end

local function spawnGeometry(points, campSize, maybeYield, unit)
    maybeYield = maybeYield or noYield
    unit = unit == "yards" and "yards" or "map"
    local n = #(points or {})
    if n == 0 then
        return nil
    end
    if n == 1 then
        return { points = 1, sampled = 1, meanGap = 0, maxGap = 0,
                 spanX = 0, spanY = 0, spanDiag = 0, clusters = 1,
                 clusterSizes = { 1 }, largestClusterSpan = 0, routeLen = 0,
                 walkPerKill = 0, shape = "single spawn", unit = unit,
                 camp = bestPull(points, 1, campSize, maybeYield, unit) }
    end
    local m = math.min(n, SPAWN_GEOMETRY_CAP)
    local gapTight = unit == "yards" and 40 or SPAWN_GAP_TIGHT
    local gapMedium = unit == "yards" and 90 or SPAWN_GAP_MEDIUM
    local clusterLink = unit == "yards" and 75 or SPAWN_CLUSTER_LINK
    local campSpan = unit == "yards" and 160 or SPAWN_CAMP_SPAN

    local function dist(i, j)
        local dx = points[i][1] - points[j][1]
        local dy = points[i][2] - points[j][2]
        return math.sqrt(dx * dx + dy * dy)
    end

    -- Nearest-neighbor gaps + bounding box in one pass.
    local sum, maxGap = 0, 0
    local minX, maxX = points[1][1], points[1][1]
    local minY, maxY = points[1][2], points[1][2]
    for i = 1, m do
        maybeYield()
        local x, y = points[i][1], points[i][2]
        if x < minX then minX = x end
        if x > maxX then maxX = x end
        if y < minY then minY = y end
        if y > maxY then maxY = y end
        local best
        for j = 1, m do
            if j ~= i then
                local d = dist(i, j)
                if not best or d < best then
                    best = d
                end
            end
        end
        sum = sum + best
        if best > maxGap then
            maxGap = best
        end
    end
    local meanGap = sum / m
    local spanX, spanY = maxX - minX, maxY - minY
    local spanDiag = math.sqrt(spanX * spanX + spanY * spanY)

    -- Single-linkage clusters: chain points within the local-density threshold.
    local clusterOf = {}
    local clusterCount = 0
    local clusterSizes = {}
    local largestClusterSpan = 0
    for i = 1, m do
        maybeYield()
        if not clusterOf[i] then
            clusterCount = clusterCount + 1
            local stack = { i }
            clusterOf[i] = clusterCount
            local members = {}
            while #stack > 0 do
                local cur = stack[#stack]
                stack[#stack] = nil
                members[#members + 1] = cur
                for j = 1, m do
                    if not clusterOf[j] and dist(cur, j) <= clusterLink then
                        clusterOf[j] = clusterCount
                        stack[#stack + 1] = j
                    end
                end
            end
            clusterSizes[#clusterSizes + 1] = #members
            local cMinX, cMaxX = points[members[1]][1], points[members[1]][1]
            local cMinY, cMaxY = points[members[1]][2], points[members[1]][2]
            for _, idx in ipairs(members) do
                local x, y = points[idx][1], points[idx][2]
                if x < cMinX then cMinX = x end
                if x > cMaxX then cMaxX = x end
                if y < cMinY then cMinY = y end
                if y > cMaxY then cMaxY = y end
            end
            local cdx, cdy = cMaxX - cMinX, cMaxY - cMinY
            local cSpan = math.sqrt(cdx * cdx + cdy * cdy)
            if cSpan > largestClusterSpan then
                largestClusterSpan = cSpan
            end
        end
    end
    table.sort(clusterSizes, function(a, b) return a > b end)

    -- Greedy nearest-neighbor lap through every point.
    local visited = { [1] = true }
    local current = 1
    local routeLen = 0
    for _ = 2, m do
        maybeYield()
        local best, bestD
        for j = 1, m do
            if not visited[j] then
                local d = dist(current, j)
                if not bestD or d < bestD then
                    best, bestD = j, d
                end
            end
        end
        routeLen = routeLen + bestD
        visited[best] = true
        current = best
    end

    local walkPerKill = routeLen / m

    -- The supporting shape description.
    local shape
    if spanDiag <= campSpan then
        shape = "tight camp"
    elseif clusterCount >= 2 and clusterCount <= 3
        and largestClusterSpan <= campSpan then
        shape = clusterCount .. " separate camps"
    elseif meanGap <= gapTight then
        shape = "locally dense but spread out"
    elseif meanGap <= gapMedium then
        shape = "medium spread"
    else
        shape = "sparse"
    end

    return {
        points = n, sampled = m,
        meanGap = meanGap, maxGap = maxGap,
        spanX = spanX, spanY = spanY, spanDiag = spanDiag,
        clusters = clusterCount, clusterSizes = clusterSizes,
        largestClusterSpan = largestClusterSpan,
        routeLen = routeLen,
        walkPerKill = walkPerKill,
        shape = shape,
        unit = unit,
        camp = bestPull(points, n, campSize, maybeYield, unit),
    }
end

-- Memoized per-mob density, the entry point views use. campSize ties the camp
-- metric to the caller's min-spawns threshold. Unknown density (Questie
-- absent / no data for the NPC) means "do not hide" -- missing data is not
-- evidence of sparseness. Results are the spawnGeometry table plus `rank` /
-- camp `rank` (0-3 vs AF.DENSITY_GRADE_BY_RANK) when the camp is confident.
-- The memo (AF.mobDensity) is keyed by npc/zone/sourceZoneId/campSize --
-- small scalars, in-memory only, never persisted; spawn data is static so
-- only ClearAll drops it (consistency, not correctness). `false` in the memo
-- = computed and known-missing (so it is never re-queued).
--
-- Three access paths, because computing geometry for a whole mob list in one
-- frame freezes the client for seconds:
--   AF.GetMobDensity     -- compute-on-miss; for one-offs (mobdbg, tooltips).
--   AF.PeekMobDensity    -- memo lookup ONLY, never computes. Returns
--                           (result|nil, stillUnknown): stillUnknown=true
--                           means "not computed yet" (queue it), false means
--                           the answer is final (incl. known-missing).
--   AF.RequestMobDensities -- queue {npcId, zoneName, zoneId, campSize} requests for
--                           a time-budgeted OnUpdate worker (own frame, so it
--                           never collides with the scans' chunker) and call
--                           every onDone callback once the queue drains.
--                           Already-memoized keys are skipped; duplicate
--                           queue entries are deduped.
AF.mobDensity = {}

local function densityKey(npcId, zoneName, sourceZoneId, campSize)
    return npcId .. ":" .. tostring(zoneName or "") .. ":"
        .. tostring(sourceZoneId or "") .. ":" .. campSize
end

local function computeAndMemoDensity(npcId, zoneName, sourceZoneId, campSize, maybeYield)
    local key = densityKey(npcId, zoneName, sourceZoneId, campSize)
    local memo = AF.mobDensity[key]
    if memo ~= nil then
        return memo
    end
    local info = questieSpawnPoints(npcId, zoneName, sourceZoneId)
    local geo = info
        and spawnGeometry(info.metricPoints, campSize, maybeYield, info.unit)
    if not geo then
        AF.mobDensity[key] = false
        return false
    end
    geo.matchedZone = info.matchedZone
    geo.matchedBy = info.matchedBy
    geo.zoneId = info.zoneId
    geo.zoneName = info.zoneName
    geo.uiMapId = info.uiMapId
    geo.instanceId = info.instanceId
    -- Only a full requested camp measured in world yards may drive filtering.
    -- Short camps and percent-map fallbacks stay visible as unknown.
    if geo.camp and geo.camp.confident then
        geo.camp.rank = DENSITY_RANK[geo.camp.grade]
    end
    AF.mobDensity[key] = geo
    return geo
end

function AF.GetMobDensity(npcId, zoneName, campSize, sourceZoneId)
    npcId = tonumber(npcId)
    if not npcId then
        return nil
    end
    local result = computeAndMemoDensity(
        npcId, zoneName, sourceZoneId, math.floor(tonumber(campSize) or 0))
    return result or nil
end

function AF.PeekMobDensity(npcId, zoneName, campSize, sourceZoneId)
    npcId = tonumber(npcId)
    if not npcId then
        return nil, false
    end
    local memo = AF.mobDensity[densityKey(
        npcId, zoneName, sourceZoneId, math.floor(tonumber(campSize) or 0))]
    if memo == nil then
        return nil, true
    end
    return memo or nil, false
end

local densityTicker = CreateFrame("Frame")
local densityRunning = false
local densityQueue = {}
local densityQueued = {}
local densityOnDone = {}
-- Chat progress like the scans ("Scan farm density started / at 50% /
-- finished"), so the background work is visible to the user. Only for runs
-- worth announcing (>= DENSITY_PROGRESS_MIN mobs) -- small top-up runs after
-- a filter tweak stay silent. The total is re-derived every step because the
-- queue can grow mid-run.
local densityProgress = nil
local densityProcessedRun = 0
local DENSITY_PROGRESS_MIN = 20
local densityProfileMs = (type(debugprofilestop) == "function") and debugprofilestop or nil
-- Same per-frame budget as the scans (the "Scan speed" setting): the
-- mid-item coroutine yielding already bounds any single computation, so
-- density can run at full scan rate without the stutter that motivated the
-- old half-rate clamp.
local function densityBudgetMs()
    return tonumber(AF.GetConfig("scanBudget")) or 10
end
local DENSITY_FRAME_CAP = 25    -- fallback cap when no profiling timer exists

local function densityFlushCallbacks()
    local callbacks = densityOnDone
    densityOnDone = {}
    for _, cb in ipairs(callbacks) do
        pcall(cb)
    end
end

-- The budget must bound even a SINGLE item's cost (a large mob's all-points
-- best-camp search can take far longer than one frame), so each
-- computation runs in a coroutine that yields whenever the CURRENT tick's
-- budget is spent. `tickBudgetHit` is a shared upvalue refreshed every tick:
-- a coroutine created in an earlier tick must consult THIS tick's deadline
-- when resumed, never the stale one it was created under.
local densityJob = nil   -- in-flight coroutine, resumed across ticks
local tickBudgetHit = nil

local function densityMaybeYield()
    if tickBudgetHit and tickBudgetHit() then
        coroutine.yield()
    end
end

local function densityTick()
    local startMs = densityProfileMs and densityProfileMs()
    if startMs then
        local budget = densityBudgetMs()
        tickBudgetHit = function()
            return (densityProfileMs() - startMs) >= budget
        end
    else
        tickBudgetHit = nil  -- no timer (tests): items run whole, capped below
    end

    local processed = 0
    while true do
        if not densityJob then
            local req = densityQueue[#densityQueue]
            if not req then
                break
            end
            densityQueue[#densityQueue] = nil
            densityQueued[req.key] = nil
            densityJob = coroutine.create(function()
                computeAndMemoDensity(
                    req.npcId, req.zoneName, req.zoneId, req.campSize, densityMaybeYield)
            end)
        end
        local ok = coroutine.resume(densityJob)
        if not ok or coroutine.status(densityJob) == "dead" then
            -- Finished -- or errored, in which case the memo stays unset and a
            -- later request may retry; either way this job is over.
            densityJob = nil
            processed = processed + 1
            densityProcessedRun = densityProcessedRun + 1
            if densityProgress then
                densityProgress(densityProcessedRun, densityProcessedRun + #densityQueue)
            end
        else
            break  -- yielded mid-item: this frame's budget is spent
        end
        if tickBudgetHit then
            if tickBudgetHit() then
                break
            end
        elseif processed >= DENSITY_FRAME_CAP then
            break
        end
    end
    tickBudgetHit = nil

    if #densityQueue == 0 and not densityJob then
        densityRunning = false
        densityProgress = nil  -- makeProgress already printed "finished"
        densityTicker:SetScript("OnUpdate", nil)
        densityFlushCallbacks()
    end
end

-- `quiet` suppresses the chat progress narration for THIS call (used by the
-- UI's background pre-warm, which the user did not explicitly ask for); a later
-- non-quiet request that crosses the threshold still narrates its own work.
function AF.RequestMobDensities(requests, onDone, quiet)
    for _, r in ipairs(requests or {}) do
        local npcId = tonumber(r.npcId)
        if npcId then
            local campSize = math.floor(tonumber(r.campSize) or 0)
            local zoneId = tonumber(r.zoneId)
            local key = densityKey(npcId, r.zoneName, zoneId, campSize)
            if AF.mobDensity[key] == nil and not densityQueued[key] then
                densityQueued[key] = true
                densityQueue[#densityQueue + 1] =
                    { key = key, npcId = npcId, zoneName = r.zoneName,
                      zoneId = zoneId, campSize = campSize }
            end
        end
    end
    if onDone then
        densityOnDone[#densityOnDone + 1] = onDone
    end
    local outstanding = #densityQueue
    if outstanding == 0 then
        -- Nothing left to compute; settle callbacks immediately.
        densityFlushCallbacks()
        return 0
    end
    if not densityRunning then
        densityProcessedRun = 0
        densityProgress = nil
    end
    -- Announce in chat once the run is big enough to be worth narrating --
    -- including when a running quiet run grows past the threshold. Created
    -- BEFORE the ticker starts: the first tick may already complete work.
    if not quiet
        and not densityProgress
        and (densityProcessedRun + outstanding) >= DENSITY_PROGRESS_MIN
        and type(I.Scan) == "table" and type(I.Scan.makeProgress) == "function" then
        densityProgress = I.Scan.makeProgress("farm density")
    end
    if not densityRunning then
        densityRunning = true
        densityTicker:SetScript("OnUpdate", densityTick)
    end
    return outstanding
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


-- Diagnostic: trace every step of dungeon/zone spawn resolution so /af mobdbg
-- can show exactly where farm density falls back to unknown. Returns an array
-- of human-readable lines.
local function debugSpawnResolution(npcId, zoneName, sourceZoneId)
    local out = {}
    local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    npcId = tonumber(npcId)
    local srcInstance = tonumber(sourceZoneId)
    srcInstance = srcInstance and srcInstance >= 32768 and (srcInstance - 32768) or nil
    add("inputs: npcId=%s zoneName=%s sourceZoneId=%s -> instance=%s",
        tostring(npcId), tostring(zoneName), tostring(sourceZoneId), tostring(srcInstance))

    local compat = rawget(_G, "QuestieCompat")
    local mapData = type(compat) == "table" and compat.UiMapData
    local hbd = type(compat) == "table" and compat.HBD
    local mapCount = 0
    if type(mapData) == "table" then for _ in pairs(mapData) do mapCount = mapCount + 1 end end
    add("env: QuestieLoader=%s QuestieCompat=%s UiMapData=%d HBD=%s",
        tostring(rawget(_G, "QuestieLoader") ~= nil), tostring(compat ~= nil), mapCount,
        tostring(type(hbd) == "table" and type(hbd.GetWorldCoordinatesFromZone) == "function"))

    local spawns = npcId and getQuestieNpcSpawns(npcId)
    if type(spawns) ~= "table" then
        -- Distinguish "id unknown to Questie" from "id known but has no spawns"
        -- (Questie can hold a spawn-less duplicate, e.g. Drakkari Frenzy (1)).
        local db = importQuestieDB()
        local hasQuery = type(db) == "table" and type(db.QueryNPCSingle) == "function"
        local qName = hasQuery and safeFirst(db.QueryNPCSingle, npcId, "name") or nil
        add("getQuestieNpcSpawns -> nil. db=%s QueryNPCSingle=%s GetNPC=%s",
            tostring(type(db)), tostring(hasQuery),
            tostring(type(db) == "table" and type(db.GetNPC) == "function"))
        add("  Questie name for id %s = %s (%s)", tostring(npcId), tostring(qName),
            qName and "id is in Questie but carries no spawns"
                or "id is NOT in Questie's NPC DB -- likely a server-specific creature id")
        return out
    end
    local zoneDb = importQuestieModule("ZoneDB")
    local dungeons = type(zoneDb) == "table" and type(zoneDb.GetDungeons) == "function"
        and safeFirst(zoneDb.GetDungeons, zoneDb) or nil
    for key, zoneSpawns in pairs(spawns) do
        if type(zoneSpawns) == "table" then
            local rawName = type(_G.Custom_GetZoneName) == "function"
                and safeFirst(_G.Custom_GetZoneName, key) or nil
            local dungeonName = type(dungeons) == "table" and dungeons[tonumber(key)]
                and dungeons[tonumber(key)][1] or nil
            local uiDirect = type(zoneDb) == "table" and type(zoneDb.GetUiMapIdByAreaId) == "function"
                and safeFirst(zoneDb.GetUiMapIdByAreaId, zoneDb, tonumber(key)) or nil
            local cands = questieUiMapCandidates(zoneDb, key, srcInstance)
            add("  key=%s pts=%d Custom_GetZoneName=%s GetDungeons.name=%s GetUiMapIdByAreaId=%s candidates=[%s] resolvedInstance=%s",
                tostring(key), #zoneSpawns, tostring(rawName), tostring(dungeonName),
                tostring(uiDirect), table.concat(cands, ","),
                tostring(questieZoneInstanceId(zoneDb, key)))
            add("    matches: byZoneId=%s byInstance=%s byLooseName(%s vs %s)=%s",
                tostring(tonumber(key) == tonumber(sourceZoneId)),
                tostring(srcInstance ~= nil and questieZoneInstanceId(zoneDb, key) == srcInstance),
                tostring(questieAreaName(zoneDb, key)), tostring(zoneName),
                tostring(isSameZoneNameLoose(questieAreaName(zoneDb, key), zoneName)))
        end
    end
    add("byInstance(%s)=[%s] byName(%s)=[%s]",
        tostring(srcInstance), table.concat(uiMapIdsByInstance(srcInstance) or {}, ","),
        tostring(zoneName), table.concat(uiMapIdsByName(zoneName) or {}, ","))

    local info = questieSpawnPoints(npcId, zoneName, sourceZoneId)
    if not info then
        add("questieSpawnPoints -> nil (NO MATCH -> density unavailable)")
    else
        add("questieSpawnPoints -> matchedBy=%s zoneId=%s unit=%s uiMapId=%s instanceId=%s pts=%d",
            tostring(info.matchedBy), tostring(info.zoneId), tostring(info.unit),
            tostring(info.uiMapId), tostring(info.instanceId), #(info.points or {}))
    end
    return out
end

I.Warp = {
    REQUIRED_WARP_TIER = REQUIRED_WARP_TIER,
    WARP_ZONE_INDEX = WARP_ZONE_INDEX,
    bundledWarpIndex = bundledWarpIndex,
    isSameZoneName = isSameZoneName,
    qtRunnerWarpIndex = qtRunnerWarpIndex,
    questieSpawnPoints = questieSpawnPoints,
    spawnGeometry = spawnGeometry,
    debugSpawnResolution = debugSpawnResolution,
}
