-- AffixFinder specific-resistance model and scan.
-- Loaded through AffixFinder.toc; public APIs live on AF, implementation details on AF._internal.

local AF = _G.AffixFinder
local I = AF._internal

local Scan = I.Scan
local safeCall = I.safeCall
local isCustomReady = I.isCustomReady
local bitAnd = Scan.bitAnd
local countBits32 = Scan.countBits32
local computeWithCache = Scan.computeWithCache
local ensureAffixedIds = Scan.ensureAffixedIds
local getCreatureSources = Scan.getCreatureSources
local isIgnoredMeleeWeaponId = Scan.isIgnoredMeleeWeaponId
local itemMatchesScope = Scan.itemMatchesScope
local makeProgress = Scan.makeProgress
local newZoneRow = Scan.newZoneRow
local runChunked = Scan.runChunked

-- Specific-resist mode (farm one chosen resistance)
-- ---------------------------------------------------------------------------
-- Synastria resist attunement grants a flat 20%-per-forge-level of the item's
-- resist, identical across all items, so the magnitude is a constant factor that
-- cancels in any ranking. We therefore rank purely by how often the chosen resist
-- would roll on a killable drop: per source that is
--   dropProbability * (1 / possibleAffixCount)
-- counted only while the item can still roll the resist and has not attuned it.
--
-- Resist school stat-type ids and the mask-bit == ItemAttuneAffix.index mapping
-- are confirmed in-game.
AF.RESIST_ELEMENTS = {
    fire   = { label = "Fire",   statType = 51 },
    nature = { label = "Nature", statType = 52 },
    frost  = { label = "Frost",  statType = 53 },
    shadow = { label = "Shadow", statType = 54 },
    arcane = { label = "Arcane", statType = 55 },
}

-- Resolves element -> mask bit index by reading ItemAttuneAffix once: the
-- attunable (prop=true) entry whose single granted stat is the school's type id.
-- Matched by stat id, not name, so it is locale-independent.
local function buildResistIndex()
    local map = {}
    local iaa = _G.ItemAttuneAffix
    if type(iaa) ~= "table" then
        return map
    end
    local typeToElement = {}
    for token, info in pairs(AF.RESIST_ELEMENTS) do
        typeToElement[info.statType] = token
    end
    for _, entry in pairs(iaa) do
        if type(entry) == "table" and entry.prop and type(entry.index) == "number"
            and type(entry.stats) == "table" then
            local count, onlyType = 0, nil
            for _, statType in pairs(entry.stats) do
                count = count + 1
                onlyType = statType
            end
            if count == 1 then
                local token = typeToElement[onlyType]
                if token and map[token] == nil then
                    map[token] = entry.index
                end
            end
        end
    end
    return map
end

-- element token -> mask bit index, or nil if it cannot be resolved (e.g.
-- ItemAttuneAffix not loaded yet). Cached for the session once non-empty.
function AF.GetResistIndex(element)
    if not AF.resistIndexByElement or next(AF.resistIndexByElement) == nil then
        AF.resistIndexByElement = buildResistIndex()
    end
    return AF.resistIndexByElement[element]
end

-- True if global bit `index` (0..63) is set across the two 32-bit mask words.
local function maskHasBit(mask1, mask2, index)
    if index < 32 then
        return bitAnd(mask1 or 0, 2 ^ index) ~= 0
    end
    return bitAnd(mask2 or 0, 2 ^ (index - 32)) ~= 0
end

-- Synastria attunement grants 20% of an affix's value per forge level; a base
-- (unforged) attune therefore grants 20% of the item's resist. We rank by the
-- resist actually gained, so this fraction is folded into the per-item weight.
local RESIST_ATTUNE_FRACTION = 0.20

-- Estimated BASE (pre-attune) resist points an item's resist affix grants at a
-- given item level. The exact amount lives in the rolled suffix tier and is NOT
-- readable from an item id at scan time (no itemId->value API; the mask only
-- gives the affix family), so it is estimated from item level.
--
-- Calibration points from real in-game GetItemStats samples. Crucially this MIXES
-- the two regimes by item level, which is correct: low item levels roll pure
-- "of X Resistance" (Classic); higher item levels roll "of X Protection" hybrids
-- (TBC/WotLK) that grant LESS resist -- and item level is what decides which an
-- item uses, so one item-level->value table captures both. Slot adds spread (a
-- shield at ilvl 174 gave only 37), so treat it as approximate. The high end is
-- still thin on samples; this is the single place to extend/retune the curve.
local RESIST_CALIBRATION = {
    { 23, 6 }, { 34, 10 }, { 58, 26 }, { 63, 27 },  -- pure resistance (Classic)
    { 158, 42 }, { 182, 71 },                        -- protection hybrids (WotLK)
}

local function estimateBaseResist(ilvl)
    ilvl = tonumber(ilvl) or 1
    if ilvl < 1 then
        ilvl = 1
    end
    local pts = RESIST_CALIBRATION
    if ilvl <= pts[1][1] then
        -- Below the first point: scale linearly down from it to the origin.
        return pts[1][2] * ilvl / pts[1][1]
    end
    for i = 2, #pts do
        if ilvl <= pts[i][1] then
            local a, b = pts[i - 1], pts[i]
            local t = (ilvl - a[1]) / (b[1] - a[1])
            return a[2] + t * (b[2] - a[2])
        end
    end
    -- Above the last point: extrapolate along a BROAD trend (third-from-last to
    -- last) rather than the short, noisy final segment, pending more high-ilvl
    -- samples.
    local lo = pts[math.max(1, #pts - 2)]
    local hi = pts[#pts]
    local slope = (hi[2] - lo[2]) / (hi[1] - lo[1])
    return hi[2] + slope * (ilvl - hi[1])
end

local function itemLevelOf(itemId)
    if type(GetItemInfoCustom) == "function" then
        -- name, link, quality, itemLevel, reqLevel, ...
        local ok, _, _, _, ilvl, reqLevel = safeCall(GetItemInfoCustom, itemId)
        if ok then
            return tonumber(ilvl) or tonumber(reqLevel) or 1
        end
    end
    return 1
end

-- Per-item slice for resist mode, or nil if the item does not contribute the
-- chosen resist for this scope. The item must be able to roll the resist
-- (possible bit set, tag 0x2 = "can roll resist") and must not have attuned it
-- yet. valuePerDrop is the expected resist GAINED from one drop:
--   P(rolls this resist) * (resist attuned at base forge)
--   = (1 / possibleAffixCount) * (20% * estimatedBaseResist(itemLevel))
-- resistGain is the per-attune resist (for display); itemLevel is carried so the
-- caller can show what drove the estimate.
local function affixedResistValue(itemId, scope, elementIndex, includeMythics)
    if not itemMatchesScope(itemId, scope) then
        return nil
    end
    if isIgnoredMeleeWeaponId(itemId) then
        return nil
    end
    -- One GetItemTagsCustom read covers both tag gates: can-roll-resist (2nd
    -- return's bit 0x2) and the mythic setting (1st return's bit 0x80). The
    -- mythic gate exists for consistency with the affix views -- in practice
    -- mythic items drop only from mythic dungeons and aren't expected to carry
    -- resist affixes, so it rarely changes the ranking, but the behaviour
    -- should match the rest of the addon rather than silently differ.
    local tok, tags1, tags2 = safeCall(GetItemTagsCustom, itemId)
    if not tok or bitAnd(tags2 or 0, 0x2) == 0 then
        return nil
    end
    if not includeMythics and bitAnd(tags1 or 0, 0x80) ~= 0 then
        return nil
    end
    local mok, p1, p2, a1, a2 = safeCall(GetItemAffixMask, itemId)
    if not mok then
        return nil
    end
    if not maskHasBit(p1, p2, elementIndex) then
        return nil  -- this item cannot roll the chosen resist
    end
    if maskHasBit(a1, a2, elementIndex) then
        return nil  -- the chosen resist is already attuned on this item
    end
    local possible = countBits32(p1) + countBits32(p2)
    if possible <= 0 then
        return nil
    end
    local itemLevel = itemLevelOf(itemId)
    local resistGain = RESIST_ATTUNE_FRACTION * estimateBaseResist(itemLevel)
    return {
        valuePerDrop = (1 / possible) * resistGain,
        resistGain = resistGain,
        itemLevel = itemLevel,
    }
end


-- Builds (and memory-caches) the per-zone/per-mob data for one resist element,
-- producing the SAME slice shape as AF.ComputeZoneData so AF.BuildZoneEV /
-- AF.BuildMobList format it unchanged. Per mob, evPerKill is the expected number
-- of chosen-resist rolls per kill; itemsDropped/affixesLeft count the qualifying
-- (rollable, unattuned) items. Async: onComplete(data) or onComplete(nil, err).
function AF.ComputeResistData(scope, element, onComplete)
    onComplete = onComplete or function() end

    local ready, reason = isCustomReady()
    if not ready then
        onComplete(nil, reason)
        return
    end
    local elementIndex = AF.GetResistIndex(element)
    if elementIndex == nil then
        onComplete(nil, "could not resolve the '" .. tostring(element)
            .. "' resist (ItemAttuneAffix not ready?)")
        return
    end

    local includeMythics = AF.GetConfig("includeMythics") and true or false
    local key = tostring(scope) .. ":" .. tostring(element)
        .. ":" .. (includeMythics and "myth" or "nomyth")

    computeWithCache(AF.resistData, key, function(finish)
    ensureAffixedIds(function(ids, err)
        if not ids then
            finish(nil, err)
            return
        end

        local rowsByZone = {}
        local rows = {}
        local mobsByKey = {}
        local itemsScanned = 0
        local progress = makeProgress(element .. " resist sources")

        runChunked(#ids, function(i)
            local itemId = ids[i]
            local value = affixedResistValue(itemId, scope, elementIndex, includeMythics)
            if not value then
                return
            end
            local sources = getCreatureSources(itemId)
            if #sources == 0 then
                return
            end
            itemsScanned = itemsScanned + 1
            local valuePerDrop = value.valuePerDrop

            local seenZone = {}
            for s = 1, #sources do
                local src = sources[s]
                local zoneName = src.zoneName

                if not seenZone[zoneName] then
                    seenZone[zoneName] = true
                    local row = rowsByZone[zoneName]
                    if not row then
                        row = newZoneRow(zoneName)
                        rowsByZone[zoneName] = row
                        rows[#rows + 1] = row
                    end
                    row.candidateItems = row.candidateItems + 1
                    row.affixedItemsWithAffixesLeft = row.affixedItemsWithAffixesLeft + 1
                    row.totalAffixesLeft = row.totalAffixesLeft + 1
                end

                local npcId = src.npcId
                local mobKey = zoneName .. ":" .. npcId
                local mob = mobsByKey[mobKey]
                if not mob then
                    mob = {
                        zoneName = zoneName,
                        npcId = npcId,
                        npcName = src.npcName,
                        spawnedCount = src.spawnedCount,
                        evPerKill = 0,
                        itemsDropped = 0,
                        affixesLeft = 0,
                    }
                    mobsByKey[mobKey] = mob
                end
                mob.evPerKill = mob.evPerKill + src.dropProbability * valuePerDrop
                mob.itemsDropped = mob.itemsDropped + 1
                mob.affixesLeft = mob.affixesLeft + 1
                if src.spawnedCount > mob.spawnedCount then
                    mob.spawnedCount = src.spawnedCount
                end
            end
        end, function()
            finish({
                scope = scope,
                element = element,
                includeMythics = includeMythics,
                rows = rows,
                rowsByZone = rowsByZone,
                mobsByKey = mobsByKey,
                affixedItemsScanned = itemsScanned,
            })
        end, progress)
    end)
    end, onComplete)
end
