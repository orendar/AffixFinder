-- AffixFinder diagnostics and debug printers.
-- Loaded through AffixFinder.toc; public APIs live on AF, implementation details on AF._internal.

local AF = _G.AffixFinder
local I = AF._internal

local ADDON_NAME = I.ADDON_NAME
local chat = I.chat
local safeCall = I.safeCall
local safeFirst = I.safeFirst
local isCustomReady = I.isCustomReady
local Scan = I.Scan
local Warp = I.Warp
local ZoneClassify = I.ZoneClassify
local addBreakdownCount = Scan.addBreakdownCount
local affixedItemValue = Scan.affixedItemValue
local beginTask = Scan.beginTask
local bitAnd = Scan.bitAnd
local endTask = Scan.endTask
local ensureAffixedIds = Scan.ensureAffixedIds
local filterCaption = Scan.filterCaption
local getAffixCounts = Scan.getAffixCounts
local getAffixMasks = Scan.getAffixMasks
local getCreatureSources = Scan.getCreatureSources
local getDropProbability = Scan.getDropProbability
local getItemCategory = Scan.getItemCategory
local isCreatureSource = Scan.isCreatureSource
local isIgnoredMeleeWeapon = Scan.isIgnoredMeleeWeapon
local itemHasRandomAffix = Scan.itemHasRandomAffix
local itemIsMythic = Scan.itemIsMythic
local itemIsUnattuned = Scan.itemIsUnattuned
local itemMatchesBind = Scan.itemMatchesBind
local itemMatchesScope = Scan.itemMatchesScope
local makeProgress = Scan.makeProgress
local reportScanError = Scan.reportScanError
local runChunked = Scan.runChunked
local sortedBreakdown = Scan.sortedBreakdown
local REQUIRED_WARP_TIER = Warp.REQUIRED_WARP_TIER
local bundledWarpIndex = Warp.bundledWarpIndex
local isSameZoneName = Warp.isSameZoneName
local qtRunnerWarpIndex = Warp.qtRunnerWarpIndex
local normZoneKey = ZoneClassify.normZoneKey

-- Diagnostic: shows how the zones in the current data classify (category /
-- expansion), and lists the ones that came back "unknown" -- those are the
-- zones the Source/Expansion filters can't place, so they always show. Run
-- /af zonedbg (optionally with a scope/forge/bind) to see what is leaking.
local function printZoneClassification(options)
    local scope = options.scope or AF.defaultScope or "character"
    AF.ResetZoneClassification()  -- rebuild fresh in case the LFG DB just loaded
    AF.ComputeZoneData(scope, options.forgeFilter, options.bindFilter, function(data, err)
        if not data then
            reportScanError(err, "classify zones")
            return
        end

        local counts = {}
        local unknowns = {}
        for _, row in ipairs(data.rows) do
            local cat, exp = AF.ClassifyZone(row.zoneName)
            addBreakdownCount(counts, cat .. "/" .. exp, 1)
            if cat == "unknown" or exp == "unknown" then
                unknowns[#unknowns + 1] = row.zoneName .. "  (key: " .. normZoneKey(row.zoneName) .. ")"
            end
        end

        chat("Zone classification (" .. scope .. ", " .. #data.rows .. " zones):")
        for _, r in ipairs(sortedBreakdown(counts)) do
            chat("  " .. r.key .. " = " .. r.value)
        end
        table.sort(unknowns)
        chat("Unclassified/partial (" .. #unknowns .. ", these ignore the filters):")
        local shown = math.min(#unknowns, 50)
        for i = 1, shown do
            chat("  " .. unknowns[i])
        end
        if #unknowns > shown then
            chat("  ... +" .. (#unknowns - shown) .. " more")
        end
    end)
end

local function listClasses(classes)
    if not classes then
        return "-"
    end
    local parts = {}
    for _, token in ipairs(AF.CLASS_ORDER) do
        if classes[token] then
            parts[#parts + 1] = token
        end
    end
    return (#parts > 0) and table.concat(parts, "/") or "-"
end

local function sampleItemLine(itemId, value, extra)
    local name = safeFirst(GetItemInfoCustom, itemId)
    if (not name or name == "") and type(GetItemInfo) == "function" then
        name = (GetItemInfo(itemId))
    end
    local tagsOk, tags1, tags2 = safeCall(GetItemTagsCustom, itemId)
    if not tagsOk then
        tags1, tags2 = nil, nil
    end
    local classes = value and value.classes
    return string.format("%s %s | %s | p=%s left=%s | mythic=%s bop=%s | classes=%s%s",
        tostring(itemId), tostring(name or "?"),
        tostring(value and value.category or "?"),
        tostring(value and value.possible or "?"),
        tostring(value and value.affixesLeft or "?"),
        tostring(bitAnd(tags1 or 0, 0x80) ~= 0),
        tostring(bitAnd(tags2 or 0, 0x80) ~= 0),
        listClasses(classes),
        extra and (" | " .. extra) or "")
end

local function addSample(samples, key, line, limit)
    if not samples[key] then
        samples[key] = {}
    end
    if #samples[key] < limit then
        samples[key][#samples[key] + 1] = line
    end
end

-- Current-zone item-gate diagnostic. This deliberately does not reuse the final
-- aggregate row: it walks each gate in order so suspicious low counts can be
-- attributed to source rows, scope/bind/mythic filters, affix masks, or class
-- attribution. Run inside the instance: /af zonedump acc 8
local function printZoneItemDump(options)
    local ready, reason = isCustomReady()
    if not ready then
        reportScanError(reason, "dump zone items")
        return
    end
    if AF.busy then
        reportScanError("busy", "dump zone items")
        return
    end
    beginTask()

    local zoneName = AF.GetCurrentZoneName()
    local scope = options.scope or AF.defaultScope or "character"
    local includeMythics = AF.GetConfig("includeMythics") and true or false
    local sampleLimit = tonumber(options.limit) or 8
    if sampleLimit < 1 then sampleLimit = 8 end
    if sampleLimit > 25 then sampleLimit = 25 end

    ensureAffixedIds(function(ids, err)
        if not ids then
            endTask()
            reportScanError(err, "dump zone items")
            return
        end

        local counts = {
            affixedIds = #ids,
            rawZoneRows = 0,
            rawZoneItems = 0,
            creatureZoneItems = 0,
            includedCandidates = 0,
            withLeft = 0,
            totalAffixesLeft = 0,
            mythicItems = 0,
            bopItems = 0,
            scopeDrop = 0,
            bindDrop = 0,
            mythicSettingDrop = 0,
            meleeWeaponDrop = 0,
            noPossible = 0,
            noLeft = 0,
            hunter = 0,
            druid = 0,
            hunterOrDruid = 0,
        }
        local byCat = {}
        local samples = {}
        local progress = makeProgress("zone item dump")

        local function countCat(category, left)
            category = category or "Unknown"
            local row = byCat[category]
            if not row then
                row = { items = 0, affixes = 0 }
                byCat[category] = row
            end
            row.items = row.items + 1
            row.affixes = row.affixes + (left or 0)
        end

        runChunked(#ids, function(i)
            local itemId = ids[i]
            local rawRowsHere = 0
            if type(ItemLocGetSourceCount) == "function" and type(ItemLocGetSourceAt) == "function" then
                local sourceCount = safeFirst(ItemLocGetSourceCount, itemId) or 0
                for sourceIndex = 1, sourceCount do
                    local ok, srcType, srcObjType, srcObjId, _, _, objName, srcZoneName =
                        safeCall(ItemLocGetSourceAt, itemId, sourceIndex)
                    if ok and isSameZoneName(srcZoneName, zoneName) then
                        rawRowsHere = rawRowsHere + 1
                        if not isCreatureSource(srcType, srcObjType, objName) then
                            addSample(samples, "rawNonCreature", tostring(itemId) .. " @ "
                                .. tostring(srcZoneName or "") .. " src=" .. tostring(srcType)
                                .. " obj=" .. tostring(srcObjType) .. " mob=" .. tostring(objName or ""),
                                sampleLimit)
                        end
                    end
                end
            end
            if rawRowsHere == 0 then
                return
            end
            counts.rawZoneRows = counts.rawZoneRows + rawRowsHere
            counts.rawZoneItems = counts.rawZoneItems + 1

            local zoneSources = 0
            local sources = getCreatureSources(itemId)
            for s = 1, #sources do
                if isSameZoneName(sources[s].zoneName, zoneName) then
                    zoneSources = zoneSources + 1
                end
            end
            if zoneSources == 0 then
                addSample(samples, "noCreatureSource", tostring(itemId) .. " has raw zone rows but no counted killable source", sampleLimit)
                return
            end
            counts.creatureZoneItems = counts.creatureZoneItems + 1

            local tagsOk, tags1, tags2 = safeCall(GetItemTagsCustom, itemId)
            tags1, tags2 = tagsOk and tags1 or 0, tagsOk and tags2 or 0
            if bitAnd(tags1 or 0, 0x80) ~= 0 then counts.mythicItems = counts.mythicItems + 1 end
            if bitAnd(tags2 or 0, 0x80) ~= 0 then counts.bopItems = counts.bopItems + 1 end

            if not itemMatchesScope(itemId, scope) then
                counts.scopeDrop = counts.scopeDrop + 1
                addSample(samples, "scopeDrop", tostring(itemId) .. " CanAttune="
                    .. tostring(safeFirst(CanAttuneItemHelper, itemId)) .. " Someone="
                    .. tostring(safeFirst(IsAttunableBySomeone, itemId)), sampleLimit)
                return
            end
            if not itemMatchesBind(itemId, options.bindFilter) then
                counts.bindDrop = counts.bindDrop + 1
                addSample(samples, "bindDrop", tostring(itemId), sampleLimit)
                return
            end
            if not includeMythics and itemIsMythic(itemId) then
                counts.mythicSettingDrop = counts.mythicSettingDrop + 1
                addSample(samples, "mythicDrop", tostring(itemId), sampleLimit)
                return
            end

            local itemType, itemSubType, itemEquipLoc
            if type(GetItemInfoCustom) == "function" then
                local ok, _, _, _, _, _, it, ist, _, eq = safeCall(GetItemInfoCustom, itemId)
                if ok then
                    itemType, itemSubType, itemEquipLoc = it, ist, eq
                end
            end
            if isIgnoredMeleeWeapon(itemType, itemSubType, itemEquipLoc) then
                counts.meleeWeaponDrop = counts.meleeWeaponDrop + 1
                local category = getItemCategory(itemType, itemSubType, itemEquipLoc)
                addSample(samples, "meleeDrop", tostring(itemId) .. " | " .. tostring(category)
                    .. " | melee weapon ignored | sources=" .. zoneSources, sampleLimit)
                return
            end

            local value = affixedItemValue(itemId, scope, options.forgeFilter, options.bindFilter, includeMythics, true)
            if not value or (value.possible or 0) <= 0 then
                counts.noPossible = counts.noPossible + 1
                addSample(samples, "noPossible", sampleItemLine(itemId, value, "sources=" .. zoneSources), sampleLimit)
                return
            end

            counts.includedCandidates = counts.includedCandidates + 1
            if value.classes and value.classes.HUNTER then counts.hunter = counts.hunter + 1 end
            if value.classes and value.classes.DRUID then counts.druid = counts.druid + 1 end
            if value.classes and (value.classes.HUNTER or value.classes.DRUID) then
                counts.hunterOrDruid = counts.hunterOrDruid + 1
            end

            if (value.affixesLeft or 0) > 0 then
                counts.withLeft = counts.withLeft + 1
                counts.totalAffixesLeft = counts.totalAffixesLeft + value.affixesLeft
                countCat(value.category, value.affixesLeft)
                addSample(samples, "included", sampleItemLine(itemId, value, "sources=" .. zoneSources), sampleLimit)
            else
                counts.noLeft = counts.noLeft + 1
                addSample(samples, "noLeft", sampleItemLine(itemId, value, "sources=" .. zoneSources), sampleLimit)
            end
        end, function()
            endTask()
            chat("Zone dump: " .. tostring(zoneName) .. " (" .. filterCaption(scope, options.forgeFilter, options.bindFilter)
                .. ", mythics " .. (includeMythics and "on" or "off") .. ")")
            chat(string.format("  affixedIds=%d rawZoneItems=%d rawRows=%d killableZoneItems=%d",
                counts.affixedIds, counts.rawZoneItems, counts.rawZoneRows, counts.creatureZoneItems))
            chat(string.format("  candidates=%d itemsWithLeft=%d affixesLeft=%d noLeft=%d noPossible=%d",
                counts.includedCandidates, counts.withLeft, counts.totalAffixesLeft, counts.noLeft, counts.noPossible))
            chat(string.format("  drops: scope=%d bind=%d mythicSetting=%d meleeWeapon=%d | zone mythic=%d bop=%d",
                counts.scopeDrop, counts.bindDrop, counts.mythicSettingDrop,
                counts.meleeWeaponDrop, counts.mythicItems, counts.bopItems))
            chat(string.format("  static class attribution among candidates: Hunter=%d Druid=%d Hunter-or-Druid=%d",
                counts.hunter, counts.druid, counts.hunterOrDruid))

            local catRows = {}
            for category, cat in pairs(byCat) do
                catRows[#catRows + 1] = { category = category, items = cat.items, affixes = cat.affixes }
            end
            table.sort(catRows, function(a, b)
                if a.affixes ~= b.affixes then
                    return a.affixes > b.affixes
                end
                if a.items ~= b.items then
                    return a.items > b.items
                end
                return a.category < b.category
            end)
            for _, cat in ipairs(catRows) do
                chat(string.format("  %s: %d items, %d affixes left", cat.category, cat.items, cat.affixes))
            end

            local sampleOrder = {
                { "included", "included with affixes left" },
                { "noLeft", "included candidates with no affixes left" },
                { "noPossible", "killable zone items with no possible mask" },
                { "scopeDrop", "scope-gated killable zone items" },
                { "mythicDrop", "mythic-setting-gated items" },
                { "meleeDrop", "ignored melee weapons" },
                { "noCreatureSource", "raw zone rows without counted creature source" },
                { "rawNonCreature", "sample raw non-creature rows" },
            }
            for _, spec in ipairs(sampleOrder) do
                local rows = samples[spec[1]]
                if rows and #rows > 0 then
                    chat("  sample " .. spec[2] .. ":")
                    for i = 1, #rows do
                        chat("    " .. rows[i])
                    end
                end
            end
        end, progress)
    end)
end

-- Dumps the raw ItemLocGetSourceAt rows for one item (diagnostic).
local function printDebugItem(options)
    local itemId = tonumber(options.debugItemId)
    if not itemId or itemId <= 0 then
        chat("Usage: /af debug <itemId|link> [maxRows]")
        return
    end
    if type(ItemLocGetSourceCount) ~= "function" or type(ItemLocGetSourceAt) ~= "function" then
        chat("Item source location APIs are unavailable.")
        return
    end

    local name = safeFirst(GetItemInfoCustom, itemId)
    if (not name or name == "") and type(GetItemInfo) == "function" then
        name = (GetItemInfo(itemId))
    end
    chat("Debug item " .. itemId .. (name and name ~= "" and (" (" .. tostring(name) .. ")") or ""))

    local possible, left = getAffixCounts(itemId, options.forgeFilter)
    local valuePerDrop = (possible > 0) and (left / possible) or 0
    chat(string.format("hasAffix=%s possibleAffixes=%d affixesLeft=%d valuePerDrop=%.3f",
        tostring(itemHasRandomAffix(itemId)), possible, left, valuePerDrop))
    local forgeLevel = options.forgeFilter and options.forgeFilter.level or 0
    chat(string.format("forge=%s level=%d unattunedAtLevel=%s progress=%s highestAttunedForge=%s",
        tostring((options.forgeFilter and options.forgeFilter.label) or "None"),
        forgeLevel, tostring(itemIsUnattuned(itemId, options.forgeFilter)),
        tostring(safeFirst(GetItemAttuneProgress, itemId, nil, forgeLevel)),
        tostring(safeFirst(GetItemAttuneForge, itemId))))
    chat(string.format("CanAttuneItemHelper=%s IsAttunableBySomeone=%s",
        tostring(safeFirst(CanAttuneItemHelper, itemId)),
        tostring(safeFirst(IsAttunableBySomeone, itemId))))

    local count = safeFirst(ItemLocGetSourceCount, itemId) or 0
    chat("Source rows: " .. count)

    local maxRows = tonumber(options.limit)
    if not maxRows or maxRows < 1 then
        maxRows = 15
    end
    local shown = math.min(maxRows, count)
    for i = 1, shown do
        local ok, srcType, srcObjType, srcObjId, chance, dropsPerThousand, objName, zoneName, spawnedCount =
            safeCall(ItemLocGetSourceAt, itemId, i)
        if ok then
            chat(string.format("%d: src=%s obj=%s id=%s chance=%s dpt=%s spawns=%s mob=%s p=%.3f '%s' @ '%s'",
                i, tostring(srcType), tostring(srcObjType), tostring(srcObjId),
                tostring(chance), tostring(dropsPerThousand), tostring(spawnedCount),
                tostring(isCreatureSource(srcType, srcObjType, objName)),
                getDropProbability(chance, dropsPerThousand),
                tostring(objName or ""), tostring(zoneName or "")))
        else
            chat(i .. ": <error reading source row>")
        end
    end
    if count > shown then
        chat("... " .. (count - shown) .. " more row(s); pass a higher maxRows, e.g. /af debug "
            .. itemId .. " " .. count)
    end
end

-- Raw, position-by-position dump of EVERY return value of ItemLocGetSourceAt
-- (type-tagged, true return count via select('#')), beyond the 8 fields the
-- scan reads. Purpose: discover whether the API exposes extra fields (a zone
-- or map id) that could distinguish an instance's INTERIOR from the open-world
-- section sharing its name (e.g. the Deadmines entrance area) -- the zone NAME
-- alone cannot. /af srcdbg <itemId|link> [maxRows].
local function printSourceRawDump(options)
    local itemId = options.debugItemId
    if not itemId then
        chat("Usage: /af srcdbg <itemId|item link> [maxRows]")
        return
    end
    if type(ItemLocGetSourceCount) ~= "function" or type(ItemLocGetSourceAt) ~= "function" then
        chat("ItemLoc APIs are unavailable on this client.")
        return
    end

    local function formatRow(ok, ...)
        if not ok then
            return nil
        end
        local n = select("#", ...)
        local parts = {}
        for v = 1, n do
            local val = select(v, ...)
            parts[#parts + 1] = "[" .. v .. "]=" .. type(val) .. ":" .. tostring(val)
        end
        return n .. " returns: " .. table.concat(parts, "  ")
    end

    local count = safeFirst(ItemLocGetSourceCount, itemId) or 0
    local maxRows = tonumber(options.limit)
    if not maxRows or maxRows < 1 then
        maxRows = 10
    end
    chat("Raw ItemLocGetSourceAt dump for item " .. itemId .. " (" .. count .. " rows, showing up to " .. maxRows .. "):")
    local shown = math.min(count, maxRows)
    for i = 1, shown do
        local line = formatRow(safeCall(ItemLocGetSourceAt, itemId, i))
        chat("  row " .. i .. ": " .. (line or "<error reading source row>"))
    end
    if count > shown then
        chat("  ... " .. (count - shown) .. " more row(s); /af srcdbg " .. itemId .. " " .. count)
    end
end

-- Calls fn(globalBitIndex) for each set bit of a 32-bit mask. baseOffset places
-- the word in the 64-bit affix space (word1 -> 0, word2 -> 32) so the indices
-- line up with how GetItemAffixMask splits possible/attuned across two returns.
local function forEachSetBit(mask, baseOffset, fn)
    mask = mask or 0
    if mask < 0 then
        mask = mask + 4294967296
    end
    local bitPos = 0
    while mask > 0 do
        if mask % 2 == 1 then
            fn(baseOffset + bitPos)
        end
        mask = math.floor(mask / 2)
        bitPos = bitPos + 1
    end
end

-- Shallow, bounded stringifier for diagnostic dumps of unknown table shapes
-- (e.g. an ItemAttuneAffix .stats sub-table whose layout we have not validated).
local function describeValue(v, depth)
    if type(v) ~= "table" then
        return tostring(v)
    end
    if (depth or 0) <= 0 then
        return "{...}"
    end
    local parts = {}
    local n = 0
    for k, val in pairs(v) do
        n = n + 1
        if n > 16 then
            parts[#parts + 1] = "..."
            break
        end
        parts[#parts + 1] = tostring(k) .. "=" .. describeValue(val, depth - 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- Diagnostic for the planned per-affix (specific-resist) feature. Dumps, for one
-- item, everything needed to confirm the still-unvalidated mask-bit -> affix-id
-- -> stat-value mapping: the possible/attuned affix bits, then the
-- ItemAttuneAffix entries (samples + any "resist"-named rows) so the two can be
-- cross-referenced in-game. Run:
-- /af affixdbg <itemId|link> [none|tf|wf|lf] [maxBits].
local function printAffixDebug(options)
    local itemId = tonumber(options.debugItemId)
    if not itemId or itemId <= 0 then
        chat("Usage: /af affixdbg <itemId|link> [none|tf|wf|lf] [maxBits]")
        return
    end

    local name = safeFirst(GetItemInfoCustom, itemId)
    if (not name or name == "") and type(GetItemInfo) == "function" then
        name = (GetItemInfo(itemId))
    end
    chat("Affix debug " .. itemId .. (name and name ~= "" and (" (" .. tostring(name) .. ")") or ""))

    -- Tags carry the fast resist flags in the 2nd return: 0x1 has-affix,
    -- 0x2 affix can roll resist, 0x4 item has base resist when attuned.
    local tok, tags1, tags2 = safeCall(GetItemTagsCustom, itemId)
    if tok then
        chat(string.format("Tags: t1=%s t2=%s | hasAffix=%s canRollResist=%s baseResist=%s",
            tostring(tags1), tostring(tags2),
            tostring(bitAnd(tags2 or 0, 0x1) ~= 0),
            tostring(bitAnd(tags2 or 0, 0x2) ~= 0),
            tostring(bitAnd(tags2 or 0, 0x4) ~= 0)))
    else
        chat("Tags: GetItemTagsCustom unavailable")
    end

    local forgeFilter = options.forgeFilter
    local forgeLevel = forgeFilter and tonumber(forgeFilter.level) or 0
    local mok, p1, p2, a1, a2, activeIndex = getAffixMasks(itemId, forgeLevel)
    if not mok then
        chat("GetItemAffixMask unavailable; cannot list affix bits.")
        return
    end
    chat(string.format("%s mask (level %d): p1=%s p2=%s a1=%s a2=%s activeIndex=%s",
        tostring((forgeFilter and forgeFilter.label) or "None"), forgeLevel,
        tostring(p1), tostring(p2), tostring(a1), tostring(a2), tostring(activeIndex)))

    -- Global bit index: word1 -> 0..31, word2 -> 32..63. Record which possible
    -- bits are already attuned so the per-bit rows can flag them.
    local attunedSet = {}
    forEachSetBit(a1, 0, function(g) attunedSet[g] = true end)
    forEachSetBit(a2, 32, function(g) attunedSet[g] = true end)
    local possible = {}
    forEachSetBit(p1, 0, function(g) possible[#possible + 1] = g end)
    forEachSetBit(p2, 32, function(g) possible[#possible + 1] = g end)
    chat("Possible affix bits: " .. (#possible > 0 and table.concat(possible, ", ") or "none"))

    -- ItemAttuneAffix holds the affix names + granted stat values. The probe
    -- above showed bit N lines up with ItemAttuneAffix[N+1] (0-based bit ->
    -- 1-based array), so resolve each possible bit through that table. [N] is
    -- shown alongside as a fallback in case the offset differs on other items.
    local iaa = _G.ItemAttuneAffix
    if type(iaa) ~= "table" then
        chat("ItemAttuneAffix: unavailable (cannot map bits to stats here)")
        return
    end
    local function iaaAt(idx)
        local e = iaa[idx]
        if type(e) == "table" then
            return tostring(e.name), e.stats
        end
        return nil, nil
    end

    local maxBits = tonumber(options.limit)
    if not maxBits or maxBits < 1 then
        maxBits = 20
    end
    local shownBits = math.min(#possible, maxBits)
    chat("Possible bits resolved (hypothesis: bit N -> ItemAttuneAffix[N+1]):")
    for i = 1, shownBits do
        local g = possible[i]
        local n1, s1 = iaaAt(g + 1)
        local n0 = iaaAt(g)
        chat(string.format("  bit %d attuned=%s | [N+1]='%s' %s | [N]='%s'",
            g, tostring(attunedSet[g] and true or false),
            tostring(n1 or ""), describeValue(s1, 1), tostring(n0 or "")))
    end
    if #possible > shownBits then
        chat("  ... +" .. (#possible - shownBits) .. " more bit(s); pass a higher maxBits")
    end

    chat("ItemAttuneAffix: #=" .. tostring(#iaa))
    local sampled = 0
    for k, entry in pairs(iaa) do
        if sampled >= 3 then
            break
        end
        if type(entry) == "table" then
            chat(string.format("  [%s] name='%s' ex=%s index=%s prop=%s stats=%s",
                tostring(k), tostring(entry.name), tostring(entry.ex),
                tostring(entry.index), tostring(entry.prop),
                describeValue(entry.stats, 1)))
            sampled = sampled + 1
        end
    end
    -- Global resist-ish entries (name carries Resistance/Protection). Comparing
    -- their stats across elements reveals which stats key is the resist amount.
    local function looksResist(nm)
        nm = string.lower(nm or "")
        return string.find(nm, "resist", 1, true) or string.find(nm, "protection", 1, true)
    end
    chat("ItemAttuneAffix resist/protection entries:")
    local resistShown = 0
    for k, entry in pairs(iaa) do
        if type(entry) == "table" and type(entry.name) == "string" and looksResist(entry.name) then
            if resistShown < 15 then
                chat(string.format("  [%s] name='%s' ex=%s stats=%s",
                    tostring(k), tostring(entry.name), tostring(entry.ex),
                    describeValue(entry.stats, 1)))
            end
            resistShown = resistShown + 1
        end
    end
    if resistShown == 0 then
        chat("  none found by name (stats may encode resist numerically; inspect samples)")
    elseif resistShown > 15 then
        chat("  ... +" .. (resistShown - 15) .. " more")
    end
end

-- Ground-truth probe for the affix-id space. A concrete item LINK is required so
-- CustomExtractItemAffix can read the item's actually-rolled affix id -- a
-- known-valid id we can anchor the name/progress APIs and the ItemAttuneAffix key
-- scheme against (the mask-bit order does NOT match the table's array order).
-- Run /af affixid <item link>.
local function printAffixIdProbe(options)
    local link = options.itemLink
    if not link then
        chat("Usage: /af affixid <item link> (shift-click an item into the command).")
        chat("  A link is required: CustomExtractItemAffix reads the rolled affix id from it.")
        return
    end

    local itemId = safeFirst(CustomExtractItemId, link)
        or tonumber(options.debugItemId)
        or tonumber(string.match(link, "Hitem:(%d+)"))
    if not itemId then
        chat("Could not extract an item id from the link.")
        return
    end

    local rolled = safeFirst(CustomExtractItemAffix, link)
    chat(string.format("affixid probe: item %d, rolled affixId=%s", itemId, tostring(rolled)))
    if not rolled or rolled == 0 then
        chat("  Link has no rolled affix (affixId 0). Use a link that has a suffix.")
        return
    end

    -- What the id space looks like through the name/progress APIs.
    chat(string.format("  name(item,%s)='%s' progress(item,%s)=%s linkProgress=%s",
        tostring(rolled), tostring(safeFirst(GetAttuneAffixName, itemId, rolled)),
        tostring(rolled), tostring(safeFirst(GetItemAttuneProgress, itemId, rolled)),
        tostring(safeFirst(GetItemLinkAttuneProgress, link))))

    -- Where does this affixId live in ItemAttuneAffix? Test direct key, then scan
    -- for an entry whose key / ex / index equals it or whose name matches.
    local iaa = _G.ItemAttuneAffix
    if type(iaa) ~= "table" then
        chat("  ItemAttuneAffix unavailable; cannot resolve the key scheme.")
        return
    end
    local direct = iaa[rolled]
    if type(direct) == "table" then
        chat(string.format("  ItemAttuneAffix[%s] (direct) name='%s' ex=%s index=%s stats=%s",
            tostring(rolled), tostring(direct.name), tostring(direct.ex),
            tostring(direct.index), describeValue(direct.stats, 1)))
    else
        chat("  ItemAttuneAffix[" .. tostring(rolled) .. "] (direct) = nil")
    end

    local rolledName = safeFirst(GetAttuneAffixName, itemId, rolled)
    rolledName = (type(rolledName) == "string" and rolledName ~= "") and string.lower(rolledName) or nil
    local hits = 0
    for k, e in pairs(iaa) do
        if type(e) == "table" then
            local match = (k == rolled) or (e.ex == rolled) or (e.index == rolled)
                or (rolledName and type(e.name) == "string" and string.lower(e.name) == rolledName)
            if match and hits < 8 then
                hits = hits + 1
                chat(string.format("  match: key=%s name='%s' ex=%s index=%s prop=%s stats=%s",
                    tostring(k), tostring(e.name), tostring(e.ex),
                    tostring(e.index), tostring(e.prop), describeValue(e.stats, 1)))
            end
        end
    end
    if hits == 0 then
        chat("  rolled affixId matched no entry by key/ex/index/name -- inspect the id space above")
    end

    -- Confirm the mapping: a ItemAttuneAffix entry's `index` field is the mask bit
    -- position. The rolled affix matched index=27 and bit 27 is set, so verify
    -- every resist family's index also lands in this item's possible bits (it can
    -- roll all 5 resistances). inPossible=true for all 5 => mapping confirmed.
    local mok, p1, p2, a1, a2 = safeCall(GetItemAffixMask, itemId)
    local possibleSet, attunedSet = {}, {}
    if mok then
        forEachSetBit(p1, 0, function(g) possibleSet[g] = true end)
        forEachSetBit(p2, 32, function(g) possibleSet[g] = true end)
        forEachSetBit(a1, 0, function(g) attunedSet[g] = true end)
        forEachSetBit(a2, 32, function(g) attunedSet[g] = true end)
    else
        chat("  (GetItemAffixMask unavailable; cannot cross-check index vs mask)")
    end
    chat("Resist families vs mask (index should equal a possible bit):")
    for k, e in pairs(iaa) do
        if type(e) == "table" and type(e.name) == "string"
            and (string.find(string.lower(e.name), "resist", 1, true)
                 or string.find(string.lower(e.name), "protection", 1, true)) then
            local idx = e.index
            local inPos = (type(idx) == "number") and possibleSet[idx] or false
            local att = (type(idx) == "number") and attunedSet[idx] or false
            chat(string.format("  '%s' key=%s index=%s prop=%s stats=%s | inPossible=%s attuned=%s",
                tostring(e.name), tostring(k), tostring(idx), tostring(e.prop),
                describeValue(e.stats, 1), tostring(inPos and true or false),
                tostring(att and true or false)))
        end
    end
end

-- Diagnostic for the resist MAGNITUDE question. Prints the actual resistance an
-- item's rolled suffix grants (GetItemStats over the real link) and its item
-- level, then tests whether that value can be reproduced from itemId + suffix
-- alone (a synthetic link) -- i.e. whether a scan can compute real resist per
-- item to weight the ranking. Run on several resist items of DIFFERENT item
-- levels to see how the amount scales: /af resistval <item link>.
local function printResistValue(options)
    local link = options.itemLink
    if not link then
        chat("Usage: /af resistval <item link> (shift-click a resist item that rolled a resist).")
        return
    end

    local itemId = safeFirst(CustomExtractItemId, link) or tonumber(string.match(link, "Hitem:(%d+)"))
    if not itemId then
        chat("Could not extract an item id from the link.")
        return
    end

    -- GetItemInfoCustom: name, link, quality, itemLevel, reqLevel, ...
    local ok, name, _, _, ilvl, reqLevel = safeCall(GetItemInfoCustom, itemId)
    if not ok then
        name, ilvl, reqLevel = nil, nil, nil
    end
    chat(string.format("resistval: item %d '%s' ilvl=%s reqLevel=%s",
        itemId, tostring(name), tostring(ilvl), tostring(reqLevel)))

    -- Tags so we can see whether Protection (hybrid) items carry canRollResist
    -- (0x2) -- i.e. whether the scan's 0x2 filter includes or excludes them.
    local tok, _, tags2 = safeCall(GetItemTagsCustom, itemId)
    if tok then
        chat(string.format("  tags2=%s canRollResist=%s baseResist=%s",
            tostring(tags2), tostring(bitAnd(tags2 or 0, 0x2) ~= 0),
            tostring(bitAnd(tags2 or 0, 0x4) ~= 0)))
    end

    -- Raw Hitem fields, so the suffix id (field 7) and unique/seed (field 8) show.
    local payload = string.match(link, "Hitem:([%-%d:]+)")
    local fields = {}
    if payload then
        for v in string.gmatch(payload .. ":", "([%-%d]*):") do
            fields[#fields + 1] = v
        end
    end
    local suffixId = fields[7]
    local uniqueId = fields[8]
    chat("  link fields: id=" .. tostring(fields[1]) .. " suffixId=" .. tostring(suffixId)
        .. " unique=" .. tostring(uniqueId))

    local function dumpStats(tag, theLink)
        if type(GetItemStats) ~= "function" then
            chat("  " .. tag .. ": GetItemStats unavailable")
            return
        end
        local stats = {}
        pcall(GetItemStats, theLink, stats)
        local any = false
        for k, v in pairs(stats) do
            if string.find(k, "RESISTANCE", 1, true) then
                chat(string.format("  %s: %s = %s", tag, k, tostring(v)))
                any = true
            end
        end
        if not any then
            chat("  " .. tag .. ": (no resistance stats)")
        end
    end

    -- Ground truth: the resist on the actual rolled item.
    dumpStats("real link", link)

    -- Feasibility: can we get the same number from itemId + suffix during a scan,
    -- with and without the per-instance seed?
    if suffixId and suffixId ~= "" and suffixId ~= "0" then
        dumpStats("synth suffix-only", "item:" .. itemId .. ":0:0:0:0:0:" .. suffixId .. ":0:0")
        dumpStats("synth suffix+seed",
            "item:" .. itemId .. ":0:0:0:0:0:" .. suffixId .. ":" .. tostring(uniqueId or 0) .. ":0")
    else
        chat("  (link carries no random suffix; use a link that rolled a resist)")
    end

    -- Probe itemId-addressable Synastria custom-data fields for a stored value.
    if type(GetCustomGameData) == "function" then
        for _, typeId in ipairs({ 15, 11, 13, 31 }) do
            chat("  GetCustomGameData(" .. typeId .. ", item) = "
                .. tostring(safeFirst(GetCustomGameData, typeId, itemId)))
        end
    end
end

local function countEntries(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do
        n = n + 1
    end
    return n
end

-- Diagnostic for the warp-tier check the t3 assist depends on. For the current
-- zone, resolves the warp index (bundled table, qtRunner supplement) and prints
-- the CustomHasTeleport tier. Run /af warp.
local function printWarpDebug()
    local zoneName = AF.GetCurrentZoneName()
    chat("Warp debug -- current zone: " .. tostring(zoneName) .. " (key: " .. normZoneKey(zoneName) .. ")")
    local cat, exp = AF.ClassifyZone(zoneName)
    local instNote = (cat == "dungeon" or cat == "raid")
        and "  (warp assist won't open the map for instances)" or ""
    chat("  classified as: " .. tostring(cat) .. " / " .. tostring(exp) .. instNote)

    local warpIndex = bundledWarpIndex(zoneName)
    local source = "bundled table"
    if warpIndex == nil then
        warpIndex = qtRunnerWarpIndex(zoneName)
        source = "qtRunner"
    end
    if warpIndex == nil then
        chat("  No warp index for this zone -- it has no zone warp (instances and a few zones never do).")
        return
    end
    chat("  warp index = " .. tostring(warpIndex) .. " (from " .. source .. ")")

    if type(_G.CustomHasTeleport) ~= "function" then
        chat("  CustomHasTeleport is unavailable; cannot read the tier.")
        return
    end
    local ok, value = safeCall(_G.CustomHasTeleport, warpIndex)
    if not ok then
        chat("  CustomHasTeleport call failed.")
        return
    end
    local tier = tonumber(value)
    chat(string.format("  CustomHasTeleport(%s) = %s  (0 none, 1 T1, 2 T2, 3 T3)",
        tostring(warpIndex), tostring(value)))
    chat(string.format("  T3 gate is >= %d -> warp assist opens the map: %s",
        REQUIRED_WARP_TIER, tostring(tier ~= nil and tier >= REQUIRED_WARP_TIER)))
end

local function printMemReport()
    local addonKb
    if type(UpdateAddOnMemoryUsage) == "function" and type(GetAddOnMemoryUsage) == "function" then
        UpdateAddOnMemoryUsage()
        addonKb = GetAddOnMemoryUsage(ADDON_NAME)
    end

    local luaBefore = collectgarbage("count")
    collectgarbage("collect")
    local luaAfter = collectgarbage("count")

    chat(string.format("Lua total: %.1f MB before GC, %.1f MB after GC", luaBefore / 1024, luaAfter / 1024))
    if addonKb then
        chat(string.format("This addon attributed: %.1f MB", addonKb / 1024))
    end

    chat("Affixed item ids: " .. (AF.affixedItemIds and #AF.affixedItemIds or 0)
        .. " (" .. (AF.affixedItemIds and "discovered" or "not yet discovered") .. ")")

    local combos = 0
    local totalRows = 0
    local totalMobs = 0
    for _, data in pairs(AF.zoneData) do
        combos = combos + 1
        totalRows = totalRows + #data.rows
        totalMobs = totalMobs + countEntries(data.mobsByKey)
    end
    chat("Cached scope/forge/bind results: " .. combos
        .. " (" .. totalRows .. " zone rows, " .. totalMobs .. " mob aggregates)")
end


I.Debug = {
    printAffixDebug = printAffixDebug,
    printAffixIdProbe = printAffixIdProbe,
    printDebugItem = printDebugItem,
    printSourceRawDump = printSourceRawDump,
    printMemReport = printMemReport,
    printResistValue = printResistValue,
    printWarpDebug = printWarpDebug,
    printZoneClassification = printZoneClassification,
    printZoneItemDump = printZoneItemDump,
}
