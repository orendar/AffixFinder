-- AffixFinder user-facing scan and ranking output.
-- Loaded through AffixFinder.toc; public APIs live on AF, implementation details on AF._internal.

local AF = _G.AffixFinder
local I = AF._internal

local chat = I.chat
local Scan = I.Scan
local EV_MODE_LABELS = Scan.EV_MODE_LABELS
local filterCaption = Scan.filterCaption
local findZoneRow = Scan.findZoneRow
local getZoneId = Scan.getZoneId
local getZoneName = Scan.getZoneName
local printBreakdown = Scan.printBreakdown
local reportScanError = Scan.reportScanError

local function printScan(options)
    local scope = options.scope or AF.defaultScope or "character"
    local forgeFilter = options.forgeFilter
    AF.ComputeZoneData(scope, forgeFilter, options.bindFilter, function(data, err)
        if not data then
            reportScanError(err, "scan the current zone")
            return
        end

        local zoneName = getZoneName(getZoneId())
        chat(zoneName .. " (" .. filterCaption(scope, forgeFilter, options.bindFilter) .. ", mob sources)")

        local row = findZoneRow(data, zoneName)
        if not row then
            chat("No affixes obtainable from killable mobs found in this zone.")
            return
        end
        chat("Unattuned affixed items: " .. row.unattunedAffixedItems)
        chat("Affixed items with affixes left to attune: " .. row.affixedItemsWithAffixesLeft)
        chat("Total affixes left to attune: " .. row.totalAffixesLeft)

        if options.breakdown then
            printBreakdown("Unattuned affixed items breakdown", row.breakdown.unattunedAffixedItems)
            printBreakdown("Affixed items with affixes left breakdown", row.breakdown.affixedItemsWithAffixesLeft)
            printBreakdown("Total affixes left breakdown", row.breakdown.totalAffixesLeft)
        end
    end)
end

local function printZoneRankings(options)
    local scope = options.scope or AF.defaultScope or "character"
    local forgeFilter = options.forgeFilter
    AF.ComputeZoneData(scope, forgeFilter, options.bindFilter, function(data, err)
        if not data then
            reportScanError(err, "scan zones")
            return
        end

        local limit = tonumber(options.limit) or AF.defaultZoneLimit
        if limit < 1 then
            limit = AF.defaultZoneLimit
        end

        local rows = AF.BuildZoneRankings(data)

        chat("Top zones by remaining affix value (" .. filterCaption(scope, forgeFilter, options.bindFilter)
            .. "; " .. #rows .. " zones, mob sources)")
        if #rows == 0 then
            chat("No remaining affix value found.")
            return
        end

        local shown = math.min(limit, #rows)
        for i = 1, shown do
            local row = rows[i]
            chat(i .. ". " .. row.zoneName .. ": " .. row.totalAffixesLeft .. " affixes left, "
                .. row.affixedItemsWithAffixesLeft .. " items with affixes left, "
                .. row.unattunedAffixedItems .. " unattuned affixed")
            if options.breakdown then
                printBreakdown("  " .. row.zoneName .. " affixes left breakdown", row.breakdown.totalAffixesLeft)
            end
        end
    end)
end

local function printZoneExpectedValue(options)
    local scope = options.scope or AF.defaultScope or "character"
    local forgeFilter = options.forgeFilter
    local evMode = options.evMode or "best"
    local minSpawns = tonumber(options.minSpawns) or 1
    if minSpawns < 0 then
        minSpawns = 0
    end

    AF.ComputeZoneData(scope, forgeFilter, options.bindFilter, function(data, err)
        if not data then
            reportScanError(err, "scan zone expected value")
            return
        end

        -- Score is computed at display time so the spawn threshold / mode /
        -- limit never trigger a re-scan; the UI shares this same builder.
        local zones, zonesDiscovered, mobsBelowThreshold = AF.BuildZoneEV(data, evMode, minSpawns)

        local limit = tonumber(options.limit) or AF.defaultZoneLimit
        if limit < 1 then
            limit = AF.defaultZoneLimit
        end
        local modeLabel = EV_MODE_LABELS[evMode] or evMode
        chat("Top zones by useful affix drops/1000 kills (" .. filterCaption(scope, forgeFilter, options.bindFilter)
            .. "; " .. modeLabel .. "; min spawns " .. minSpawns
            .. "; matched " .. #zones .. "/" .. zonesDiscovered .. " zones)")

        if #zones == 0 then
            chat("No qualifying mobs found. " .. mobsBelowThreshold
                .. " mob(s) were below the spawn threshold of " .. minSpawns
                .. " (lower N, e.g. /af zones ev 0, to include sparse mobs).")
            return
        end

        local shown = math.min(limit, #zones)
        for i = 1, shown do
            local zone = zones[i]
            local detail
            if evMode == "best" then
                detail = "best mob " .. tostring(zone.bestMobName or "?")
                    .. " (" .. tostring(zone.bestMobSpawns or 0) .. " spawns, "
                    .. tostring(zone.bestMobItems or 0) .. " items)"
            else
                detail = tostring(zone.qualifyingMobs or 0) .. " mobs"
            end
            chat(i .. ". " .. zone.zoneName .. ": "
                .. string.format("%.2f", zone.score or 0) .. " drops/1000 kills, " .. detail)
        end
    end)
end

-- Ranks zones by how often a chosen resist would roll on a killable drop
-- (attunes per 1000 kills), reusing the generic EV builder over the resist data
-- slice. Shares the spawn-threshold / mode / limit semantics of /af zones ev.
local function printResistRankings(options)
    local scope = options.scope or AF.defaultScope or "character"
    local element = options.resistElement
    if not element or not AF.RESIST_ELEMENTS[element] then
        chat("Usage: /af resist <fire|nature|frost|shadow|arcane> [character|account]"
            .. " [best|avg|total] [minSpawns] [limit]")
        return
    end
    local evMode = options.evMode or "best"
    local minSpawns = tonumber(options.minSpawns) or 1
    if minSpawns < 0 then
        minSpawns = 0
    end

    AF.ComputeResistData(scope, element, function(data, err)
        if not data then
            reportScanError(err, "scan " .. element .. " resist")
            return
        end

        local zones, zonesDiscovered, mobsBelowThreshold = AF.BuildZoneEV(data, evMode, minSpawns)
        local limit = tonumber(options.limit) or AF.defaultZoneLimit
        if limit < 1 then
            limit = AF.defaultZoneLimit
        end
        local label = AF.RESIST_ELEMENTS[element].label
        local modeLabel = EV_MODE_LABELS[evMode] or evMode
        chat(label .. " resist: top zones by ~" .. label .. " resistance/1000 kills (" .. scope
            .. "; " .. modeLabel .. "; min spawns " .. minSpawns
            .. "; matched " .. #zones .. "/" .. zonesDiscovered
            .. " zones; base-forge estimate from item level)")

        if #zones == 0 then
            chat("No qualifying mobs found (" .. mobsBelowThreshold
                .. " below the spawn threshold of " .. minSpawns .. "). All " .. label
                .. " resist sources may already be attuned, or none drop from killable mobs.")
            return
        end

        local shown = math.min(limit, #zones)
        for i = 1, shown do
            local zone = zones[i]
            -- The "items" counts are already resist-specific and unattuned (the
            -- per-item gate dropped everything else), so they read as "items
            -- dropping this still-needed resist".
            local detail
            if evMode == "best" then
                detail = "best mob " .. tostring(zone.bestMobName or "?")
                    .. " (" .. tostring(zone.bestMobSpawns or 0) .. " spawns, "
                    .. tostring(zone.bestMobItems or 0) .. " " .. label .. " items)"
            else
                detail = tostring(zone.qualifyingMobs or 0) .. " mobs"
            end
            chat(i .. ". " .. zone.zoneName .. ": ~"
                .. string.format("%.2f", zone.score or 0) .. " " .. label
                .. " resistance/1000 kills, " .. detail)
        end
    end)
end


I.Output = {
    printResistRankings = printResistRankings,
    printScan = printScan,
    printZoneExpectedValue = printZoneExpectedValue,
    printZoneRankings = printZoneRankings,
}
