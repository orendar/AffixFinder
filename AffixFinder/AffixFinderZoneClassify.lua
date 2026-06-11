-- AffixFinder zone category and expansion classification.
-- Loaded through AffixFinder.toc; public APIs live on AF, implementation details on AF._internal.

local AF = _G.AffixFinder
local I = AF._internal

local WARP_ZONE_INDEX = I.Warp.WARP_ZONE_INDEX

-- ---------------------------------------------------------------------------
-- Zone classification (source type + expansion) for the UI's zone filters
-- ---------------------------------------------------------------------------
-- AF.ClassifyZone(zoneName) -> category, expansion
--   category  : "dungeon" | "raid" | "world" | "unknown"
--   expansion : "classic" | "tbc" | "wotlk" | "unknown"
--
-- Sources, in order of authority:
--   1. The client's LFG dungeon database (GetLFGDungeonInfo) -- gives the exact
--      localized instance name, its type (dungeon vs raid) and its expansion.
--      This is the reliable source for 5-man dungeons across all expansions.
--   2. Static instance name lists below -- cover raids (the LFG DB does not list
--      raids in 3.3.5) and act as a fallback for any dungeon the LFG DB misses.
--   3. The continent map (GetMapContinents/GetMapZones) -- open-world zones and
--      their expansion.
-- Anything we still cannot place stays "unknown", and the UI treats unknown as
-- matching every filter so it never silently hides data it can't classify.
-- This is a pure property of the zone, so the UI filters on it at display time
-- (no rescan) -- unlike scope/forge/bind, which change which items count.
--
-- Names are matched by a normalized key: lowercased, punctuation turned into
-- spaces (so apostrophes/hyphens/colons can't cause a miss, e.g. "Ahn'kahet:
-- The Old Kingdom", "Azjol-Nerub", "Magisters' Terrace"), and trailing
-- difficulty/size qualifiers stripped. The server's loot data names instances
-- per difficulty -- "Utgarde Keep", "Utgarde Keep Heroic", "Naxxramas 10",
-- "Icecrown Citadel 25 Heroic" -- so without this collapse every variant except
-- the plain one fell through to "unknown" (which is why classic content, having
-- no variants, matched while TBC/WotLK did not).

-- Tokens that mark a difficulty/size variant rather than the instance. Covers
-- words ("Heroic", "Mythic"), bare/compact size+letter codes are handled by a
-- pattern below ("10", "25", "10n", "25h", "10hc"...).
local DIFFICULTY_TOKENS = {
    heroic = true, normal = true, mythic = true,
    man = true, player = true, players = true,
    h = true, n = true, m = true, hc = true, nm = true,
}

local function isQualifierToken(tok)
    if not tok then return false end
    if DIFFICULTY_TOKENS[tok] then return true end
    -- A leading number optionally followed by a short letter code: 10, 25,
    -- 10n, 25h, 10hc, 25nm (server difficulty codes). No instance word looks
    -- like this, so stripping it is safe.
    return string.find(tok, "^%d+%a?%a?$") ~= nil
end

local function normZoneKey(name)
    name = string.lower(tostring(name or ""))
    name = string.gsub(name, "[^%w%s]", " ")  -- punctuation -> space (apostrophes, hyphens, colons, parens)
    name = string.gsub(name, "%s+", " ")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")

    -- Drop difficulty/size qualifiers from both ends ("Heroic Utgarde Keep",
    -- "Naxxramas 25", "10 man Icecrown Citadel"), keeping at least one word so a
    -- base name is never emptied. No real zone name starts or ends with these.
    local tokens = {}
    for w in string.gmatch(name, "%S+") do
        tokens[#tokens + 1] = w
    end
    while #tokens > 1 and isQualifierToken(tokens[#tokens]) do
        tokens[#tokens] = nil
    end
    while #tokens > 1 and isQualifierToken(tokens[1]) do
        table.remove(tokens, 1)
    end
    return table.concat(tokens, " ")
end

-- Display-name counterpart of normZoneKey: strips the same difficulty/size
-- qualifiers from a raw zone name while preserving its case and punctuation
-- ("Naxxramas 25" -> "Naxxramas", "Utgarde Keep Heroic" -> "Utgarde Keep").
-- Used by the Instances view to label a folded variant row with the generic
-- instance name instead of an arbitrary variant's.
local function stripZoneQualifiers(name)
    local tokens = {}
    for w in string.gmatch(tostring(name or ""), "%S+") do
        tokens[#tokens + 1] = w
    end
    local function isQual(tok)
        return isQualifierToken(string.lower(string.gsub(tok, "[^%w]", "")))
    end
    while #tokens > 1 and isQual(tokens[#tokens]) do
        tokens[#tokens] = nil
    end
    while #tokens > 1 and isQual(tokens[1]) do
        table.remove(tokens, 1)
    end
    return table.concat(tokens, " ")
end

local INSTANCES = {
    classic = {
        dungeon = {
            "Ragefire Chasm", "Wailing Caverns", "The Deadmines", "Shadowfang Keep",
            "Blackfathom Deeps", "The Stockade", "Gnomeregan", "Razorfen Kraul",
            "Scarlet Monastery", "Razorfen Downs", "Uldaman", "Zul'Farrak",
            "Maraudon", "Sunken Temple", "Temple of Atal'Hakkar",
            "Blackrock Depths", "Blackrock Spire", "Lower Blackrock Spire",
            "Upper Blackrock Spire", "Dire Maul", "Stratholme", "Scholomance",
        },
        raid = {
            "Molten Core", "Blackwing Lair", "Zul'Gurub",
            "Ruins of Ahn'Qiraj", "Temple of Ahn'Qiraj", "Ahn'Qiraj",
            "Ahn'Qiraj Temple", "Ahn'Qiraj Ruins",  -- server's word order
        },
    },
    tbc = {
        dungeon = {
            "Hellfire Ramparts", "Ramparts", "The Blood Furnace", "The Shattered Halls",
            "The Slave Pens", "The Underbog", "The Steamvault",
            "Mana-Tombs", "Auchenai Crypts", "Sethekk Halls", "Shadow Labyrinth",
            "The Mechanar", "The Botanica", "The Arcatraz",
            "Old Hillsbrad Foothills", "The Escape from Durnholde",  -- CoT, same instance
            "The Black Morass", "The Opening of the Dark Portal",    -- CoT, same instance
            "Magisters' Terrace", "Magister's Terrace",              -- both apostrophe forms
        },
        raid = {
            "Karazhan", "Gruul's Lair", "Magtheridon's Lair",
            "Serpentshrine Cavern", "Tempest Keep", "The Eye",
            "Hyjal Summit", "Battle for Mount Hyjal", "Black Temple",
            "Sunwell Plateau", "The Sunwell", "Zul'Aman",
        },
    },
    wotlk = {
        dungeon = {
            "Utgarde Keep", "Utgarde Pinnacle", "The Nexus", "The Oculus",
            "Azjol-Nerub", "Ahn'kahet: The Old Kingdom", "Ahn'kahet",
            "Drak'Tharon Keep", "Gundrak", "Halls of Stone", "Halls of Lightning",
            "The Violet Hold", "The Culling of Stratholme", "Trial of the Champion",
            "The Forge of Souls", "Pit of Saron", "Halls of Reflection",
        },
        raid = {
            "Naxxramas", "Onyxia's Lair",  -- 3.3.5 has the level-80 revamp, not the classic raid
            "The Obsidian Sanctum", "The Eye of Eternity",
            "Vault of Archavon", "Ulduar", "Trial of the Crusader",
            "Icecrown Citadel", "The Ruby Sanctum",
        },
    },
}

-- Battlegrounds and continent names that the loot data uses as a "zone" but the
-- continent map does not list. Classified as world so they obey the filters.
local WORLD_EXTRA = {
    classic = {
        "Alterac Valley", "Warsong Gulch", "Arathi Basin",
        "Eastern Kingdoms", "Kalimdor",
    },
    tbc = { "Eye of the Storm", "Outland" },
    wotlk = {
        "Strand of the Ancients", "Isle of Conquest", "Wintergrasp", "Northrend",
        "Ebon Hold", "The Frozen Sea", "The North Sea",  -- DK start + Northrend waters
    },
}

-- Lazily built: normalized zoneName -> { category, expansion }, plus an array of
-- instance keys (longest-first) for suffix matching against hub-prefixed names.
local zoneClass
local zoneInstanceKeys

local function continentExpansion(index)
    -- 3.3.5a continents: 1 Eastern Kingdoms, 2 Kalimdor (classic),
    -- 3 Outland (tbc), 4 Northrend (wotlk).
    if index == 3 then
        return "tbc"
    elseif index == 4 then
        return "wotlk"
    end
    return "classic"
end

-- GetLFGDungeonInfo expansionLevel -> our expansion key.
local LFG_EXPANSION = { [0] = "classic", [1] = "tbc", [2] = "wotlk" }

-- Expansion for a bundled warp-zone index (see WARP_ZONE_INDEX). TBC: Isle of
-- Quel'Danas (0, level-70 daily content) and Outland (53-60). WotLK: all
-- Northrend (61-71). Everything else is classic -- deliberately INCLUDING the
-- Blood Elf / Draenei starting zones (Eversong, Ghostlands, Silvermoon,
-- Azuremyst, Bloodmyst, Exodar; indices 1-2, 28, 50-52): the expansion filter
-- is a level-bracket filter for farming, and those are 1-20 content, so users
-- expect them under Classic with the other starting zones.
local TBC_WARP_INDICES = {
    [0] = true, [53] = true, [54] = true,
    [55] = true, [56] = true, [57] = true, [58] = true, [59] = true, [60] = true,
}
local function warpZoneExpansion(index)
    if TBC_WARP_INDICES[index] then return "tbc" end
    if index >= 61 then return "wotlk" end
    return "classic"
end

local function buildZoneClassification()
    local map = {}

    -- Static instance names (raids, plus a fallback for dungeons).
    for expansion, byCategory in pairs(INSTANCES) do
        for category, names in pairs(byCategory) do
            for _, name in ipairs(names) do
                map[normZoneKey(name)] = { category = category, expansion = expansion }
            end
        end
    end

    -- Authoritative dungeon/raid names from the client's LFG database. These
    -- overwrite the static entries (same normalized key) with the client's exact
    -- localized strings. IDs are sparse; iterating a generous range is cheap and
    -- happens once. Returns: name, typeID, subtypeID, ..., expansionLevel(9th).
    if type(GetLFGDungeonInfo) == "function" then
        for id = 1, 1000 do
            local name, _, subtypeID, _, _, _, _, _, expansionLevel = GetLFGDungeonInfo(id)
            local expansion = type(expansionLevel) == "number" and LFG_EXPANSION[expansionLevel]
            if type(name) == "string" and name ~= "" and expansion then
                local category
                if subtypeID == 3 then          -- LFG_SUBTYPEID_RAID
                    category = "raid"
                elseif subtypeID == 1 or subtypeID == 2 then  -- DUNGEON / HEROIC
                    category = "dungeon"
                end
                if category then
                    map[normZoneKey(name)] = { category = category, expansion = expansion }
                end
            end
        end
    end

    -- Battlegrounds / continent names the loot data uses but the map omits. These
    -- are curated open-world names, so (like the continent map below) they override
    -- any instance classification for the same key from the custom-server LFG pass.
    for expansion, names in pairs(WORLD_EXTRA) do
        for _, name in ipairs(names) do
            local key = normZoneKey(name)
            local existing = map[key]
            if not existing or existing.category ~= "world" then
                map[key] = { category = "world", expansion = expansion }
            end
        end
    end

    -- Open-world zones from the continent map. A zone the continent map lists is
    -- by definition open world, so it OVERRIDES any instance (dungeon/raid)
    -- classification for the same normalized key. This is essential on a custom
    -- server: Synastria registers open-world zones in the LFG database (e.g. warp
    -- destinations), so the LFG pass above can mark a world zone like Teldrassil as
    -- a "dungeon" -- the continent map is the authority that corrects it. Real
    -- dungeons/raids are never continent-map zones, so legit instances are safe.
    if type(GetMapContinents) == "function" and type(GetMapZones) == "function" then
        local continents = { GetMapContinents() }
        for ci = 1, #continents do
            local expansion = continentExpansion(ci)
            local zones = { GetMapZones(ci) }
            for _, zname in ipairs(zones) do
                if type(zname) == "string" and zname ~= "" then
                    local key = normZoneKey(zname)
                    local existing = map[key]
                    if not existing or existing.category ~= "world" then
                        map[key] = { category = "world", expansion = expansion }
                    end
                end
            end
        end
    end

    -- Server-warp zones are ALWAYS open world: the warp list is outdoor zones and
    -- cities, never instances. Seed them authoritatively from the bundled table
    -- (always available -- no API/timing dependency), overriding any earlier
    -- instance classification. This is the reliable fix for custom-server LFG
    -- entries naming world zones, and for clients where GetMapZones doesn't list a
    -- zone (e.g. Teldrassil) so the continent-map override above couldn't catch it.
    for name, index in pairs(WARP_ZONE_INDEX) do
        map[normZoneKey(name)] = { category = "world", expansion = warpZoneExpansion(index) }
    end

    -- Curated exceptions with the last word. Verified in-game via /af srcdbg:
    -- the loot data names the Deadmines INSTANCE INTERIOR "Deadmines" (zone id
    -- 32804 = 0x8000 + map 36) while "The Deadmines" is the OPEN-WORLD section
    -- around the entrance in Westfall (AreaTable id 1581) -- which Synastria's
    -- own world data correctly marks as world above, and that world entry
    -- drops "the deadmines" from the suffix list below, so the bare interior
    -- name needs its own entry to avoid falling through to unknown. (The
    -- static INSTANCES list keeps "The Deadmines" for vanilla-ish clients
    -- without the world pollution; in-game the world passes override it,
    -- which is the correct outcome for the outdoor section.)
    local INSTANCE_OVERRIDES = {
        { name = "Deadmines", category = "dungeon", expansion = "classic" },
    }
    for _, o in ipairs(INSTANCE_OVERRIDES) do
        map[normZoneKey(o.name)] = { category = o.category, expansion = o.expansion }
    end

    -- Suffix-match list: the loot data prefixes many instances with their hub,
    -- e.g. "Auchindoun: Auchenai Crypts", "Coilfang: Serpentshrine Cavern". The
    -- instance name is the tail of the key, so collect every instance key
    -- (longest-first) and also a "the"-less variant to catch "Deadmines" vs
    -- "The Deadmines" / "Stormwind Stockade" vs "The Stockade".
    local instanceKeys = {}
    for key, entry in pairs(map) do
        if entry.category ~= "world" then
            -- "the"-less variant, but only if it stays distinctive enough to be
            -- a safe suffix (skips "The Eye" -> "eye").
            local alt = string.match(key, "^the (.+)$")
            if alt and #alt < 5 then
                alt = nil
            end
            instanceKeys[#instanceKeys + 1] = {
                key = key, alt = alt,
                category = entry.category, expansion = entry.expansion,
            }
        end
    end
    table.sort(instanceKeys, function(a, b) return #a.key > #b.key end)

    return map, instanceKeys
end

-- True when `key` is exactly `suffix` or ends with " " .. suffix (word boundary).
local function keyEndsWith(key, suffix)
    if not suffix or suffix == "" or #key < #suffix then
        return false
    end
    if key == suffix then
        return true
    end
    return string.sub(key, #key - #suffix) == (" " .. suffix)
end

function AF.ClassifyZone(zoneName)
    if not zoneClass then
        zoneClass, zoneInstanceKeys = buildZoneClassification()
    end
    local key = normZoneKey(zoneName)
    local entry = zoneClass[key]
    if entry then
        return entry.category, entry.expansion
    end
    -- Fallback: hub-prefixed / "the"-less instance names. Longest key first so
    -- e.g. "...culling of stratholme" wins over bare "stratholme".
    for _, inst in ipairs(zoneInstanceKeys) do
        if keyEndsWith(key, inst.key) or keyEndsWith(key, inst.alt) then
            return inst.category, inst.expansion
        end
    end
    return "unknown", "unknown"
end

-- Drops the cached classification so the next ClassifyZone rebuilds it (e.g.
-- after the LFG database finishes loading). Used by the /af zonedbg diagnostic.
function AF.ResetZoneClassification()
    zoneClass = nil
    zoneInstanceKeys = nil
end


I.ZoneClassify = {
    normZoneKey = normZoneKey,
    stripZoneQualifiers = stripZoneQualifiers,
}
