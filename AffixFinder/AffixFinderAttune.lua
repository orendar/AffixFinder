-- AffixFinder new-attunables model and scan.
-- Loaded through AffixFinder.toc; public APIs live on AF, implementation details on AF._internal.

local AF = _G.AffixFinder
local I = AF._internal

local safeCall = I.safeCall
local safeFirst = I.safeFirst
local Scan = I.Scan
local addBreakdownCount = Scan.addBreakdownCount
local bestCreatureSource = Scan.bestCreatureSource
local computeWithCache = Scan.computeWithCache
local ensureAttunableIds = Scan.ensureAttunableIds
local foldSourcesIntoTally = Scan.foldSourcesIntoTally
local getCreatureSources = Scan.getCreatureSources
local getItemCategory = Scan.getItemCategory
local getItemClasses = Scan.getItemClasses
local itemIsUnattuned = Scan.itemIsUnattuned
local itemMatchesScope = Scan.itemMatchesScope
local itemPassesTagFilters = Scan.itemPassesTagFilters
local makeProgress = Scan.makeProgress
local newClassZoneTally = Scan.newClassZoneTally
local newZoneRow = Scan.newZoneRow
local runChunked = Scan.runChunked
local scopeForgeKey = Scan.scopeForgeKey

-- New-attunables mode ("what should I kill for items I haven't attuned AT ALL")
-- ---------------------------------------------------------------------------
-- The affix views treat an item as interesting while it has affixes LEFT; the
-- game, however, counts an item as attuned once ANY attunement completes (one
-- affix is enough, and non-affixed items attune as a whole). This mode ranks
-- farm targets for items that are still unattuned in THAT binary sense:
-- non-affixed items never attuned, plus affixed items with zero affixes
-- attuned. Affix multiplicity is deliberately ignored -- every qualifying item
-- is worth exactly one new attune, so valuePerDrop is 1 and a mob's evPerKill
-- is simply the sum of its qualifying items' drop chances.
--
-- Forge is an optional threshold on what "unattuned" means: the base filter
-- keeps the game's binary sense (no variant ever attuned -- a forged attune
-- also attunes base, and itemIsUnattuned at the base filter honours that via
-- HasAttunedAnyVariantOfItem), while TF+/WF+/LF narrow it to items not yet
-- attuned AT any included forge level (itemIsUnattuned's threshold semantics
-- -- attunement is account-wide at every level, like the rest of the system).
-- A forged target only lands on the drops that ROLL forged, so evPerKill is
-- weighted by AF.GetForgeDropChance, exactly like the affix scan's EV.
--
-- MELEE WEAPONS COUNT here, unlike every affix gate: the melee exclusion exists
-- because melee RANDOM AFFIXES grant no attuned stats, but attuning the weapon
-- itself still grants its fixed weapon-stat amount -- an unattuned melee weapon
-- is exactly the "new attunable" this mode hunts. (This is an attunement-count
-- gate, not an affix gate, so the cross-cutting melee invariant the affix
-- gates owe deliberately does not apply.)

-- The candidate-id discovery (ensureAttunableIds) and its level-stamped
-- persistence live in AffixFinderScan.lua, next to the affix discovery: the
-- two share one chunked id-space pass when both lists are missing.

-- Per-item slice for new-attunables mode, or nil if the item does not count:
-- it must match the scope and bind filters, pass the mythic setting, and be
-- unattuned under the forge threshold (base filter = the game's binary sense:
-- no variant ever attuned). No melee exclusion and no affix logic -- see the
-- header.
local function newAttunableValue(itemId, scope, forgeFilter, bindFilter, includeMythics, wantClasses)
    if not itemMatchesScope(itemId, scope) then
        return nil
    end
    if not itemPassesTagFilters(itemId, bindFilter, includeMythics) then
        return nil
    end
    if not itemIsUnattuned(itemId, forgeFilter) then
        return nil
    end
    local reqLevel, itemType, itemSubType, itemEquipLoc
    if type(GetItemInfoCustom) == "function" then
        local ok, _, _, _, _, rl, it, ist, _, eq = safeCall(GetItemInfoCustom, itemId)
        if ok then
            reqLevel, itemType, itemSubType, itemEquipLoc = rl, it, ist, eq
        end
    end
    return {
        category = getItemCategory(itemType, itemSubType, itemEquipLoc),
        classes = wantClasses and getItemClasses(itemType, itemSubType, itemEquipLoc, reqLevel) or nil,
    }
end

-- Builds (and memory-caches in AF.attuneData) the per-zone/per-mob data for
-- new attunables, producing the SAME slice shape as AF.ComputeZoneData so
-- AF.BuildZoneEV / AF.BuildMobList / AF.BuildInstanceRankings format it
-- unchanged. Per mob, evPerKill is the expected NEW ITEM ATTUNES per kill
-- (forge-rarity-weighted under a forged threshold); itemsDropped/affixesLeft
-- both count the qualifying (unattuned) items, since each is worth exactly
-- one attune. Async: onComplete(data) or onComplete(nil, errorText).
-- forgeFilter is an AF.FORGE_FLAGS entry or nil (base); bindFilter is "bop",
-- "boe", or nil (both).
function AF.ComputeAttuneData(scope, forgeFilter, bindFilter, onComplete)
    onComplete = onComplete or function() end
    local includeMythics = AF.GetConfig("includeMythics") and true or false
    local key = scopeForgeKey(scope, forgeFilter, bindFilter, includeMythics)

    computeWithCache(AF.attuneData, key, function(finish)
    ensureAttunableIds(function(ids, err)
        if not ids then
            finish(nil, err)
            return
        end

        local rowsByZone = {}
        local rows = {}
        local mobsByKey = {}
        -- Kill-denominator tally for the Instances builder: every attunable
        -- item's killable droppers, gated or not (they still die in a clear).
        -- Like ComputeZoneData's, it depends ONLY on the candidate id list,
        -- so it is built once per list and shared through AF.killTallies; on
        -- a cache hit the value gate runs FIRST and attuned/filtered items
        -- skip their source walk -- on developed accounts most attunable
        -- items are already attuned, so this is most of the scan.
        local tallyCached = AF.killTallies.attune
        local building = not (tallyCached and tallyCached.ids == ids)
        local killsByZoneNpc = building and {} or tallyCached.kills
        local zoneIdsByName = building and {} or tallyCached.zoneIds
        local itemsById = {}
        local itemsScanned = 0
        local progress = makeProgress("new-attunable sources")
        local perClass = (scope == "account")
        -- Forge rarity (EV only, never counts): under a forged threshold an
        -- attune only lands on the drops that roll AT an included forge
        -- level. Snapshot per scan, exactly like ComputeZoneData; the base
        -- filter's chance is 1, so the binary mode's EV is unchanged.
        local forgePower = AF.GetForgePower()
        local forgeDropChance = AF.GetForgeDropChance(forgeFilter, forgePower)

        runChunked(#ids, function(i)
            local itemId = ids[i]
            local sources
            if building then
                -- Tally pass: sources come before the value gate so the kill
                -- tally sees every attunable item's droppers, not just the
                -- unattuned ones.
                sources = getCreatureSources(itemId)
                foldSourcesIntoTally(sources, killsByZoneNpc, zoneIdsByName)
                if #sources == 0 then
                    return
                end
            end
            local value = newAttunableValue(itemId, scope, forgeFilter, bindFilter, includeMythics, perClass)
            if not value then
                return
            end
            if not sources then
                sources = getCreatureSources(itemId)
                if #sources == 0 then
                    return
                end
            end
            itemsScanned = itemsScanned + 1

            local category = value.category
            local classes = value.classes

            -- One record per qualifying item; mobs carry the id lists, so the
            -- Items-style builders can read this slice too. possible/affixesLeft
            -- are 1: a new attunable is worth exactly one attune.
            if not itemsById[itemId] then
                itemsById[itemId] = {
                    itemId = itemId,
                    category = category,
                    possible = 1,
                    affixesLeft = 1,
                    unattuned = true,
                    classes = classes,
                }
            end

            local seenZone = {}
            for s = 1, #sources do
                local src = sources[s]
                local zoneName = src.zoneName

                -- Per-zone counts: count the item once per distinct zone. The
                -- standard zone-row fields keep their names (so the shared
                -- builders work) but all count UNATTUNED ITEMS here.
                if not seenZone[zoneName] then
                    seenZone[zoneName] = true
                    local row = rowsByZone[zoneName]
                    if not row then
                        row = newZoneRow(zoneName)
                        rowsByZone[zoneName] = row
                        rows[#rows + 1] = row
                    end
                    row.candidateItems = row.candidateItems + 1
                    row.unattunedAffixedItems = row.unattunedAffixedItems + 1
                    row.affixedItemsWithAffixesLeft = row.affixedItemsWithAffixesLeft + 1
                    row.totalAffixesLeft = row.totalAffixesLeft + 1
                    addBreakdownCount(row.breakdown.unattunedAffixedItems, category, 1)
                    addBreakdownCount(row.breakdown.affixedItemsWithAffixesLeft, category, 1)
                    addBreakdownCount(row.breakdown.totalAffixesLeft, category, 1)

                    if classes then
                        for c in pairs(classes) do
                            local ct = row.byClass[c]
                            if not ct then
                                ct = newClassZoneTally()
                                row.byClass[c] = ct
                            end
                            ct.unattunedAffixedItems = ct.unattunedAffixedItems + 1
                            ct.affixedItemsWithAffixesLeft = ct.affixedItemsWithAffixesLeft + 1
                            ct.totalAffixesLeft = ct.totalAffixesLeft + 1
                            addBreakdownCount(ct.breakdown.unattunedAffixedItems, category, 1)
                            addBreakdownCount(ct.breakdown.affixedItemsWithAffixesLeft, category, 1)
                            addBreakdownCount(ct.breakdown.totalAffixesLeft, category, 1)
                        end
                    end
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
                        items = {},
                        byClass = {},
                    }
                    mobsByKey[mobKey] = mob
                end
                -- valuePerDrop is 1 (one new attune per drop), so the EV delta
                -- is the drop chance, weighted by how rarely a drop rolls at
                -- the threshold's forge levels (1 for the base filter).
                local evDelta = src.dropProbability * forgeDropChance
                mob.evPerKill = mob.evPerKill + evDelta
                mob.itemsDropped = mob.itemsDropped + 1
                mob.affixesLeft = mob.affixesLeft + 1
                mob.items[#mob.items + 1] = itemId
                if src.spawnedCount > mob.spawnedCount then
                    mob.spawnedCount = src.spawnedCount
                end

                if classes then
                    for c in pairs(classes) do
                        local mc = mob.byClass[c]
                        if not mc then
                            mc = { evPerKill = 0, itemsDropped = 0, affixesLeft = 0 }
                            mob.byClass[c] = mc
                        end
                        mc.evPerKill = mc.evPerKill + evDelta
                        mc.itemsDropped = mc.itemsDropped + 1
                        mc.affixesLeft = mc.affixesLeft + 1
                    end
                end
            end
        end, function()
            if building then
                AF.killTallies.attune = {
                    ids = ids,
                    kills = killsByZoneNpc,
                    zoneIds = zoneIdsByName,
                }
            end
            finish({
                mode = "attune",
                scope = scope,
                forgeFilter = forgeFilter,
                bindFilter = bindFilter,
                includeMythics = includeMythics,
                forgePower = forgePower,
                forgeDropChance = forgeDropChance,
                rows = rows,
                rowsByZone = rowsByZone,
                mobsByKey = mobsByKey,
                itemsById = itemsById,
                killsByZoneNpc = killsByZoneNpc,
                zoneIdsByName = zoneIdsByName,
                affixedItemsScanned = itemsScanned,
            })
        end, progress)
    end)
    end, onComplete)
end

-- On-demand whole-item attunement snapshot for ONE item (no stored state) --
-- the tooltip's new-attunables primitive, complementing AF.GetItemAffixInfo
-- the way ComputeAttuneData complements ComputeZoneData. Returns nil when the
-- item is not attunable by anyone on the account (or the API is missing), so
-- callers stay silent on junk. NO melee exclusion, like every gate in this
-- mode: attuning a melee weapon still grants its fixed weapon-stat amount.
-- `unattuned` is the game's binary sense (no variant ever attuned); when it is
-- true, `bestSource` is the densest killable source meeting the spawn
-- threshold (minSpawns, default = the configured minimum), like the affix
-- tooltip's.
function AF.GetItemAttuneStatus(itemId, minSpawns)
    itemId = tonumber(itemId)
    if not itemId or type(IsAttunableBySomeone) ~= "function" then
        return nil
    end
    if (safeFirst(IsAttunableBySomeone, itemId) or 0) == 0 then
        return nil
    end
    local status = {
        itemId = itemId,
        unattuned = itemIsUnattuned(itemId),
        canCharacter = (safeFirst(CanAttuneItemHelper, itemId) or 0) > 0,
    }
    if status.unattuned then
        status.bestSource = bestCreatureSource(getCreatureSources(itemId), minSpawns)
    end
    return status
end

I.Attune = {
    newAttunableValue = newAttunableValue,
}
