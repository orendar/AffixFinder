-- AffixFinder slash command parsing and event wiring.
-- Loaded through AffixFinder.toc; public APIs live on AF, implementation details on AF._internal.

local AF = _G.AffixFinder
local I = AF._internal

local chat = I.chat
local FORGE_NONE = I.FORGE_NONE
local FORGE_FLAGS = I.FORGE_FLAGS
local Output = I.Output
local Debug = I.Debug
local printScan = Output.printScan
local printAttuneRankings = Output.printAttuneRankings
local printInstanceRankings = Output.printInstanceRankings
local printZoneRankings = Output.printZoneRankings
local printZoneExpectedValue = Output.printZoneExpectedValue
local printResistRankings = Output.printResistRankings
local printZoneClassification = Debug.printZoneClassification
local printZoneItemDump = Debug.printZoneItemDump
local printDebugItem = Debug.printDebugItem
local printAffixDebug = Debug.printAffixDebug
local printSourceRawDump = Debug.printSourceRawDump
local printAffixIdProbe = Debug.printAffixIdProbe
local printResistValue = Debug.printResistValue
local printWarpDebug = Debug.printWarpDebug
local printMobDebug = Debug.printMobDebug
local printForgeDebug = Debug.printForgeDebug
local printMemReport = Debug.printMemReport
local printDropperDump = Debug.printDropperDump

-- ---------------------------------------------------------------------------
-- Command handling
-- ---------------------------------------------------------------------------

local function parseOptions(msg)
    local options = {
        mode = "current",
        scope = "character",
        forgeFilter = FORGE_NONE,
        bindFilter = nil,
        breakdown = false,
        clearCache = false,
        mem = false,
        limit = AF.defaultZoneLimit,
        ev = false,
        evMode = "best",
        minSpawns = AF.GetConfig("minSpawns"),
    }

    msg = msg or ""

    -- Accept a shift-clicked item link for /af debug; strip it before tokenizing.
    local linkItemId = tonumber(string.match(msg, "Hitem:(%d+)"))
    if linkItemId then
        options.debugItemId = linkItemId
        -- Keep the full link too; /af affixid needs it for CustomExtractItemAffix.
        options.itemLink = string.match(msg, "|c%x+|Hitem:.-|h.-|h|r")
        msg = string.gsub(msg, "|c%x+|H.-|h.-|h|r", " ")
    end

    local evNumbersSeen = 0

    for token in string.gmatch(string.lower(msg), "%S+") do
        if token == "ui" or token == "window" or token == "show" or token == "open" then
            options.ui = true
        elseif token == "config" or token == "options" or token == "settings" then
            options.config = true
        elseif token == "zones" or token == "zone" or token == "rank" or token == "rankings" then
            options.mode = "zones"
        elseif token == "instances" or token == "instance" or token == "inst" or token == "dungeons" or token == "raids" then
            options.mode = "instances"
        elseif token == "ev" or token == "value" or token == "expected" then
            options.mode = "zones"
            options.ev = true
        elseif token == "debug" or token == "dump" then
            options.mode = "debug"
            options.debug = true
        elseif token == "zonedbg" or token == "classify" or token == "zoneclass" then
            options.mode = "zonedbg"
        elseif token == "zonedump" or token == "zoneitems" or token == "itemdump" then
            options.mode = "zonedump"
        elseif token == "warp" or token == "warpdbg" then
            options.mode = "warpdbg"
        elseif token == "mobdbg" or token == "mob" or token == "whymob" then
            options.mode = "mobdbg"
        elseif token == "forgedbg" or token == "forgepower" or token == "fp" then
            options.mode = "forgedbg"
        elseif token == "dumpdroppers" or token == "dropperdump" then
            options.mode = "dumpdroppers"
        elseif token == "affixdbg" or token == "maskdbg" then
            options.mode = "affixdbg"
            options.affixDbg = true
        elseif token == "affixid" or token == "affixprobe" then
            options.mode = "affixid"
            options.affixDbg = true
        elseif token == "srcdbg" or token == "sourcedbg" or token == "srcraw" then
            options.mode = "srcdbg"
            options.affixDbg = true  -- numbers parse as itemId then maxRows
        elseif token == "resistval" or token == "resval" then
            options.mode = "resistval"
            options.affixDbg = true
        elseif token == "resist" or token == "res" then
            options.mode = "resist"
        elseif token == "attune" or token == "attunables" or token == "att" or token == "new" then
            -- A flag, not a mode: it combines with `instances` ("/af attune
            -- instances" and "/af instances attune" both rank full clears by
            -- new item attunes). Alone, it resolves to the attune mode after
            -- the loop.
            options.attune = true
        elseif AF.RESIST_ELEMENTS[token] then
            options.resistElement = token
        elseif token == "mem" or token == "memory" then
            options.mem = true
        elseif token == "best" then
            options.evMode = "best"
        elseif token == "avg" or token == "average" or token == "mean" then
            options.evMode = "avg"
        elseif token == "total" or token == "sum" then
            options.evMode = "total"
        elseif token == "clearcache" or token == "cacheclear" or token == "clear" or token == "rebuild" then
            options.clearCache = true
        elseif token == "account" or token == "acc" or token == "a" then
            options.scope = "account"
        elseif token == "character" or token == "char" or token == "c" then
            options.scope = "character"
        elseif FORGE_FLAGS[token] then
            options.forgeFilter = FORGE_FLAGS[token]
        elseif token == "bop" or token == "soulbound" then
            options.bindFilter = "bop"
        elseif token == "boe" then
            options.bindFilter = "boe"
        elseif token == "both" or token == "anybind" then
            options.bindFilter = nil
        elseif token == "breakdown" or token == "bd" then
            options.breakdown = true
        elseif string.find(token, "^%d+$") then
            local number = tonumber(token)
            if options.debug or options.affixDbg then
                if not options.debugItemId then
                    options.debugItemId = number
                else
                    options.limit = number or options.limit
                end
            elseif options.ev or options.mode == "resist"
                or (options.attune and options.mode ~= "instances") then
                evNumbersSeen = evNumbersSeen + 1
                if evNumbersSeen == 1 then
                    options.minSpawns = number or options.minSpawns
                else
                    options.limit = number or options.limit
                end
            else
                options.limit = number or options.limit
            end
        elseif token == "help" or token == "?" then
            options.help = true
        elseif options.mode == "mobdbg" then
            -- Mob names contain spaces: every token mobdbg doesn't recognize
            -- accumulates into the name (matching is case-insensitive, so the
            -- lowercasing above is harmless).
            options.mobName = options.mobName and (options.mobName .. " " .. token) or token
        else
            options.error = token
            return options
        end
    end

    -- A bare `attune` (no explicit view) means the attune zone rankings.
    if options.attune and options.mode == "current" then
        options.mode = "attune"
    end

    return options
end

local function printUsage()
    chat("Window: /af ui (filterable browser) -- Settings: /af config (Interface > AddOns)")
    chat("Usage: /af [zones [ev ...]] [character|char|c|account|acc|a] [none|tf|wf|lf] [bop|boe|both] [breakdown] [limit]")
    chat("Current zone: /af, /af acc, /af acc tf breakdown")
    chat("Zone rankings: /af zones, /af zones acc, /af zones acc wf 15")
    chat("Instances: /af instances [char|acc] [none|tf|wf|lf] [bop|boe|both] [limit] (full-clear value)")
    chat("Expected value: /af zones ev [best|avg|total] N [limit] (N = min mob spawn count)")
    chat("  e.g. /af zones ev 5, /af zones acc ev total 10, /af zones ev avg 1 20")
    chat("Specific resist: /af resist <fire|nature|frost|shadow|arcane> [char|acc] [best|avg|total] [N] [limit]")
    chat("  e.g. /af resist fire, /af resist frost acc 5, /af resist arcane total 1 15")
    chat("New attunables: /af attune [char|acc] [none|tf|wf|lf] [bop|boe|both] [best|avg|total] [N] [limit]")
    chat("  (items you haven't attuned, affixes ignored; a forge filter = not yet attuned at that level+)")
    chat("  /af attune instances [char|acc] [none|tf|wf|lf] [bop|boe|both] [limit] (full-clear new-item value)")
    chat("Debug: /af debug <itemId|link> [maxRows], /af zonedbg (zone classification)")
    chat("  /af mobdbg <mob name> [char|acc] [none|tf|wf|lf] [bop|boe] [bd] [maxItems] (why a mob ranks where it does;")
    chat("    incl. Questie spawn-pack geometry + difficulty-variant cross-check; bd dumps raw spawn coords)")
    chat("  /af zonedump [char|acc] [none|tf|wf|lf] [bop|boe|both] [sampleRows] (current-zone item gates)")
    chat("  /af warp (current-zone T3 warp-tier probe for the map-warp assist)")
    chat("  /af forgedbg (forge roll rates + prestige forge power used by EV math)")
    chat("  /af affixdbg <itemId|link> [none|tf|wf|lf] [maxBits] (forge-level affix mask probe)")
    chat("  /af affixid <item link> (rolled affix id + ItemAttuneAffix key scheme)")
    chat("  /af srcdbg <itemId|link> [maxRows] (raw source-row returns, incl. undocumented fields)")
    chat("  /af resistval <item link> (actual resist amount + scaling probe)")
    chat("Maintenance: /af clearcache (reset + rediscover), /af mem (memory report)")
    chat("Forge filters are thresholds: tf=TF/WF/LF, wf=WF/LF, lf=LF; suffixes are counted once.")
    chat("Counts cover affixes obtainable from killable mobs. First zone command")
    chat("scans for a few seconds, then results are cached until you attune or clear.")
end

SLASH_AFFIXFINDER1 = "/af"
SlashCmdList["AFFIXFINDER"] = function(msg)
    local options = parseOptions(msg)
    if options.help then
        printUsage()
        return
    end
    if options.ui then
        if type(AF.ToggleUI) == "function" then
            AF.ToggleUI()
        else
            chat("UI is unavailable (the UI module failed to load).")
        end
        return
    end
    if options.config then
        if type(AF.OpenOptions) == "function" then
            AF.OpenOptions()
        else
            chat("Options panel is unavailable (the config module failed to load).")
        end
        return
    end
    if options.error then
        chat("Unknown option: " .. options.error)
        printUsage()
        return
    end
    if options.mem then
        printMemReport()
        return
    end
    if options.clearCache then
        if AF.busy then
            chat("Busy: a scan is running. Try again in a moment.")
            return
        end
        AF.ClearAll()
        chat("Caches cleared. The next zone command will rediscover and rescan.")
        return
    end

    if options.debug then
        printDebugItem(options)
    elseif options.mode == "affixdbg" then
        printAffixDebug(options)
    elseif options.mode == "affixid" then
        printAffixIdProbe(options)
    elseif options.mode == "srcdbg" then
        printSourceRawDump(options)
    elseif options.mode == "resistval" then
        printResistValue(options)
    elseif options.mode == "resist" then
        printResistRankings(options)
    elseif options.mode == "attune" then
        printAttuneRankings(options)
    elseif options.mode == "zonedbg" then
        printZoneClassification(options)
    elseif options.mode == "zonedump" then
        printZoneItemDump(options)
    elseif options.mode == "mobdbg" then
        printMobDebug(options)
    elseif options.mode == "warpdbg" then
        printWarpDebug()
    elseif options.mode == "forgedbg" then
        printForgeDebug()
    elseif options.mode == "dumpdroppers" then
        printDropperDump(options)
    elseif options.mode == "instances" then
        printInstanceRankings(options)
    elseif options.mode == "zones" and options.ev then
        printZoneExpectedValue(options)
    elseif options.mode == "zones" then
        printZoneRankings(options)
    else
        printScan(options)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "CHAT_MSG_SYSTEM" then
        -- Attuning changes how many affixes are left; drop cached aggregates.
        if type(arg1) == "string" and string.find(arg1, "You have attuned with", 1, true) then
            AF.ClearDynamicData()
        end
    elseif event == "PLAYER_LEVEL_UP" then
        -- Leveling changes what is attunable: new items unlock for the
        -- attunable-candidate list, and character-scope CanAttuneItemHelper
        -- answers change. Mark every cached slice stale (the rescan interval
        -- rate-limits the recompute, exactly like attuning does); the
        -- candidate list itself re-validates lazily against its level stamp
        -- on the next scan (see AffixFinderAttune.lua), so no cache needs
        -- dropping here.
        AF.ClearDynamicData()
    end
end)
