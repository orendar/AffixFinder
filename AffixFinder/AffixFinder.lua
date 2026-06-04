local ADDON_NAME = "AffixFinder"
local PREFIX = "|cff7fffd4AffixFinder|r"

local AF = {}
_G.AffixFinder = AF

AF.defaultScope = "character"
AF.defaultZoneLimit = 10

-- True while a chunked discovery/aggregation pass is running, so overlapping
-- commands are rejected instead of stacking work.
AF.busy = false

-- In-memory session caches (NEVER persisted -- persisting the item graph would
-- blow the memory budget and stall logout serializing it; see the memory model
-- in README.md).
--   affixedItemIds : list of item ids that have a random affix. Static for the
--                    session; found once by scanning the whole id space.
--   zoneData       : aggregated results keyed by scope+forge. Each entry holds
--                    the per-zone totals and per-mob EV the views format from.
AF.affixedItemIds = nil
AF.zoneData = {}

-- Specific-resist mode caches (same transient model: aggregates only, never
-- persisted). resistData is keyed by scope+element; resistIndexByElement maps a
-- resist element to its GetItemAffixMask bit index, resolved once from
-- ItemAttuneAffix (see the specific-resist section below).
AF.resistData = {}
AF.resistIndexByElement = nil

-- ---------------------------------------------------------------------------
-- Configuration (persisted in SavedVariables by AffixFinderConfig.lua). Only a
-- few scalars are stored -- never the item graph or source data -- so this has
-- no effect on the addon's memory footprint or logout time.
--   rescanInterval : minutes an automatic rescan of a given filter is rate-
--                    limited to after a change is detected (0 = rescan on every
--                    detected change, the original behaviour).
--   minSpawns      : default minimum reported mob spawn count for the Mobs view.
--   includeMythics : whether mythic items count toward the affix calculations.
--   automaticWarp  : T3-gated map-opening helper from the Mobs view. Enabled by
--                    default; mob clicks still place the latest-target pin.
AF.configDefaults = {
    rescanInterval = 60,
    minSpawns = 5,
    includeMythics = false,
    automaticWarp = true,
}
AF.config = {}
for k, v in pairs(AF.configDefaults) do
    AF.config[k] = v
end

function AF.GetConfig(key)
    local value = AF.config[key]
    if value == nil then
        return AF.configDefaults[key]
    end
    return value
end

local FORGE_FLAGS = {
    tf = { minLevel = 1, label = "TF+" },
    wf = { minLevel = 2, label = "WF+" },
    lf = { minLevel = 3, label = "LF" },
}

-- Exposed so the UI can present the same scope/forge filters the slash command
-- accepts without duplicating the table. Keys are the slash tokens (tf/wf/lf).
AF.FORGE_FLAGS = FORGE_FLAGS

-- ItemLocGetSourceAt row classification (file-locals, mirroring qtRunner).
--   srcType   1 = creature loot, 2 = quest reward, 9 = vendor, 5..13 = crafting
--   srcObjType 0 = creature/NPC
local OBJTYPE_CREATURE = 0

-- srcType values that mean "not obtained by killing", even on a creature.
local NON_KILL_SRC_TYPES = {
    [2] = true,
    [5] = true, [6] = true, [7] = true, [8] = true,
    [9] = true,
    [10] = true, [11] = true, [12] = true, [13] = true,
}

local function chat(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. ": " .. tostring(message))
end

-- Aggregated results depend on live attunement progress; mark them stale when
-- the player attunes something. They are NOT dropped immediately -- the rescan
-- interval (see AF.ComputeZoneData) decides when a stale slice is actually
-- recomputed, so automatic rescans are rate-limited per filter. The affixed-id
-- list is static and kept.
function AF.ClearDynamicData()
    for _, data in pairs(AF.zoneData) do
        data.dirty = true
    end
    for _, data in pairs(AF.resistData or {}) do
        data.dirty = true
    end
end

-- Full reset: also re-discover the affixed-item list (use after a data reload).
-- Drops the cross-session persisted id list too, so a server data reload that
-- left MAX_ITEMID unchanged (fingerprint still "matching") is forced to rescan.
function AF.ClearAll()
    AF.affixedItemIds = nil
    AF.zoneData = {}
    AF.resistData = {}
    if type(_G.AffixFinderDB) == "table" then
        _G.AffixFinderDB.affixCache = nil
    end
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

local function safeFirst(fn, ...)
    local ok, value = safeCall(fn, ...)
    if ok then
        return value
    end
    return nil
end

local function isCustomReady()
    if type(ItemLocIsLoaded) == "function" then
        local loaded = safeFirst(ItemLocIsLoaded)
        if not loaded then
            return false, "item location data is not loaded yet"
        end
    end

    if type(GetItemAffixMask) ~= "function" then
        return false, "GetItemAffixMask is unavailable"
    end
    if type(GetItemTagsCustom) ~= "function" then
        return false, "GetItemTagsCustom is unavailable"
    end
    if type(CanAttuneItemHelper) ~= "function" then
        return false, "CanAttuneItemHelper is unavailable"
    end
    if type(IsAttunableBySomeone) ~= "function" then
        return false, "IsAttunableBySomeone is unavailable"
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Bit / mask helpers
-- ---------------------------------------------------------------------------

local function bitAnd(a, b)
    if bit and bit.band then
        return bit.band(a or 0, b or 0)
    end
    a = a or 0
    b = b or 0
    local result = 0
    local place = 1
    while a > 0 and b > 0 do
        if (a % 2) == 1 and (b % 2) == 1 then
            result = result + place
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        place = place * 2
    end
    return result
end

local function bitNot32(a)
    if bit and bit.bnot then
        return bit.bnot(a or 0)
    end
    return 4294967295 - (a or 0)
end

local function countBits32(value)
    value = value or 0
    if value < 0 then
        value = value + 4294967296
    end
    local count = 0
    while value > 0 do
        if value % 2 == 1 then
            count = count + 1
        end
        value = math.floor(value / 2)
    end
    return count
end

local function maskRemaining(possibleMask, attunedMask)
    return bitAnd(possibleMask or 0, bitNot32(attunedMask or 0))
end

-- ---------------------------------------------------------------------------
-- Breakdown / text helpers
-- ---------------------------------------------------------------------------

local function addBreakdownCount(tbl, key, amount)
    key = key or "Unknown"
    tbl[key] = (tbl[key] or 0) + (amount or 1)
end

local function sortedBreakdown(tbl)
    local rows = {}
    for key, value in pairs(tbl or {}) do
        rows[#rows + 1] = { key = key, value = value }
    end
    table.sort(rows, function(a, b)
        if a.value ~= b.value then
            return a.value > b.value
        end
        return a.key < b.key
    end)
    return rows
end

-- Exposed so the UI can render the same per-category breakdowns as the chat
-- "breakdown" option (sorted by count, highest first).
AF.SortedBreakdown = sortedBreakdown

local function printBreakdown(title, tbl)
    local rows = sortedBreakdown(tbl)
    if #rows == 0 then
        chat(title .. ": none")
        return
    end
    local parts = {}
    for _, row in ipairs(rows) do
        parts[#parts + 1] = row.key .. " " .. row.value
    end
    chat(title .. ": " .. table.concat(parts, ", "))
end

local function titleCase(text)
    if not text or text == "" then
        return nil
    end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    text = string.gsub(text, "%s+", " ")
    text = string.lower(text)
    return string.gsub(text, "(%a)([%w']*)", function(first, rest)
        return string.upper(first) .. rest
    end)
end

local function normalizeWeaponSubtype(subType, equipLoc)
    local s = string.lower(subType or "")
    local twoHand = equipLoc == "INVTYPE_2HWEAPON" or string.find(s, "two") or string.find(s, "2")
    local oneHand = equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND"
        or equipLoc == "INVTYPE_WEAPONOFFHAND" or string.find(s, "one") or string.find(s, "1")

    if string.find(s, "axe") then return twoHand and "Two-handed axe" or "One-handed axe" end
    if string.find(s, "mace") then return twoHand and "Two-handed mace" or "One-handed mace" end
    if string.find(s, "sword") then return twoHand and "Two-handed sword" or "One-handed sword" end
    if string.find(s, "staff") or string.find(s, "staves") then return "Staff" end
    if string.find(s, "polearm") then return "Polearm" end
    if string.find(s, "dagger") then return "Dagger" end
    if string.find(s, "fist") then return "Fist weapon" end
    if string.find(s, "bow") and not string.find(s, "cross") then return "Bow" end
    if string.find(s, "crossbow") then return "Crossbow" end
    if string.find(s, "gun") then return "Gun" end
    if string.find(s, "thrown") then return "Thrown" end
    if string.find(s, "wand") then return "Wand" end
    if string.find(s, "fishing") then return "Fishing pole" end

    if oneHand then return "One-handed weapon" end
    if twoHand then return "Two-handed weapon" end
    return titleCase(subType) or "Weapon"
end

-- Classifies an item into a display category from its already-extracted
-- GetItemInfoCustom fields (the caller fetches them once and shares them with
-- getItemClasses below, so we never double-call the API).
local function getItemCategory(itemType, itemSubType, itemEquipLoc)
    if itemEquipLoc == "INVTYPE_CLOAK" then return "Cloak"
    elseif itemEquipLoc == "INVTYPE_FINGER" then return "Ring"
    elseif itemEquipLoc == "INVTYPE_TRINKET" then return "Trinket"
    elseif itemEquipLoc == "INVTYPE_NECK" then return "Neck"
    elseif itemEquipLoc == "INVTYPE_HOLDABLE" then return "Off-hand"
    elseif itemEquipLoc == "INVTYPE_SHIELD" then return "Shield"
    elseif itemEquipLoc == "INVTYPE_RELIC" then return titleCase(itemSubType) or "Relic"
    end

    local typeText = string.lower(itemType or "")
    local subText = string.lower(itemSubType or "")
    if typeText == "armor" or itemType == ARMOR then
        if string.find(subText, "cloth") then return "Cloth" end
        if string.find(subText, "leather") then return "Leather" end
        if string.find(subText, "mail") then return "Mail" end
        if string.find(subText, "plate") then return "Plate" end
        if string.find(subText, "shield") then return "Shield" end
        return titleCase(itemSubType) or "Armor"
    end
    if typeText == "weapon" or itemType == WEAPON then
        return normalizeWeaponSubtype(itemSubType, itemEquipLoc)
    end
    return titleCase(itemSubType) or titleCase(itemType) or "Unknown"
end

-- ---------------------------------------------------------------------------
-- Per-class attuneability (account scope)
-- ---------------------------------------------------------------------------
-- There is no per-class server API (CanAttuneItemHelper only answers for the
-- *current* character), so which classes an item is "for" is derived
-- statically from WotLK 3.3.5 proficiencies: armor material, weapon type, slot.
--
-- Armor uses the "spec" model, made level-aware by the level-40 armor upgrade:
--   * Warrior/Paladin wear mail until 40, then plate.
--   * Hunter/Shaman  wear leather until 40, then mail.
-- So a MAIL piece with required level < 40 is a Warrior/Paladin leveling item
-- (Hunters/Shamans can't equip mail until 40); MAIL at level >= 40 is
-- Hunter/Shaman. Likewise LEATHER < 40 also serves Hunter/Shaman on top of the
-- always-on Rogue/Druid. PLATE is always Warrior/Paladin/DK; CLOTH is the three
-- pure casters.
--
-- *** The tables below are the single place to fix a wrong proficiency. ***
-- (WEAPON_CLASSES.thrown including Hunter is confirmed correct in-game.)

AF.CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
                   "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local CLASS_DISPLAY_FALLBACK = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
    PRIEST = "Priest", DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman",
    MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}

function AF.ClassDisplayName(token)
    local loc = _G.LOCALIZED_CLASS_NAMES_MALE
    if loc and loc[token] then return loc[token] end
    return CLASS_DISPLAY_FALLBACK[token] or tostring(token)
end

function AF.ClassColorCode(token)
    local c = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[token]
    if not c then return "" end
    return string.format("|cff%02x%02x%02x",
        math.floor((c.r or 1) * 255), math.floor((c.g or 1) * 255), math.floor((c.b or 1) * 255))
end

local function classSet(...)
    local t = {}
    for i = 1, select("#", ...) do
        t[(select(i, ...))] = true
    end
    return t
end

-- All returned sets are shared constants (read-only at fold time), so
-- classifying an item allocates nothing.
local ALL_CLASSES_SET  = classSet("WARRIOR","PALADIN","HUNTER","ROGUE","PRIEST","DEATHKNIGHT","SHAMAN","MAGE","WARLOCK","DRUID")
local SHIELD_CLASSES   = classSet("WARRIOR","PALADIN","SHAMAN")
local HOLDABLE_CLASSES = ALL_CLASSES_SET  -- held-in-off-hand (orbs etc.): every class in WotLK
local EMPTY_CLASSES    = {}

local ARMOR_CLOTH        = classSet("MAGE","PRIEST","WARLOCK")
local ARMOR_LEATHER_LOW  = classSet("ROGUE","DRUID","HUNTER","SHAMAN")
local ARMOR_LEATHER_HIGH = classSet("ROGUE","DRUID")
local ARMOR_MAIL_LOW     = classSet("WARRIOR","PALADIN")
local ARMOR_MAIL_HIGH    = classSet("HUNTER","SHAMAN")
local ARMOR_PLATE        = classSet("WARRIOR","PALADIN","DEATHKNIGHT")

local RELIC_CLASS_SETS = {
    idol   = classSet("DRUID"),
    libram = classSet("PALADIN"),
    totem  = classSet("SHAMAN"),
    sigil  = classSet("DEATHKNIGHT"),
}

-- WotLK 3.3.5 weapon proficiencies, keyed by canonical weapon type.
local WEAPON_CLASSES = {
    dagger   = classSet("WARRIOR","HUNTER","ROGUE","PRIEST","SHAMAN","MAGE","WARLOCK","DRUID"),
    sword1h  = classSet("WARRIOR","PALADIN","HUNTER","ROGUE","MAGE","WARLOCK","DEATHKNIGHT"),
    sword2h  = classSet("WARRIOR","PALADIN","HUNTER","DEATHKNIGHT"),
    axe1h    = classSet("WARRIOR","PALADIN","HUNTER","ROGUE","SHAMAN","DEATHKNIGHT"),
    axe2h    = classSet("WARRIOR","PALADIN","HUNTER","SHAMAN","DEATHKNIGHT"),
    mace1h   = classSet("WARRIOR","PALADIN","ROGUE","PRIEST","SHAMAN","DRUID","DEATHKNIGHT"),
    mace2h   = classSet("WARRIOR","PALADIN","SHAMAN","DRUID","DEATHKNIGHT"),
    polearm  = classSet("WARRIOR","PALADIN","HUNTER","DEATHKNIGHT","DRUID"),
    staff    = classSet("WARRIOR","HUNTER","PRIEST","SHAMAN","MAGE","WARLOCK","DRUID"),
    fist     = classSet("WARRIOR","HUNTER","ROGUE","SHAMAN","DRUID"),
    bow      = classSet("WARRIOR","HUNTER","ROGUE"),
    crossbow = classSet("WARRIOR","HUNTER","ROGUE"),
    gun      = classSet("WARRIOR","HUNTER","ROGUE"),
    thrown   = classSet("WARRIOR","ROGUE","HUNTER"),
    wand     = classSet("PRIEST","MAGE","WARLOCK"),
    fishing  = EMPTY_CLASSES,  -- no stats / never attuned
}

local ARMOR_TIER_LEVEL = 40  -- the level at which mail/plate (etc.) proficiency unlocks

local function weaponKey(s, equipLoc)
    local twoHand = equipLoc == "INVTYPE_2HWEAPON" or string.find(s, "two")
    if string.find(s, "crossbow") then return "crossbow" end
    if string.find(s, "bow") then return "bow" end
    if string.find(s, "gun") then return "gun" end
    if string.find(s, "thrown") then return "thrown" end
    if string.find(s, "wand") then return "wand" end
    if string.find(s, "dagger") then return "dagger" end
    if string.find(s, "staff") or string.find(s, "staves") then return "staff" end
    if string.find(s, "polearm") then return "polearm" end
    if string.find(s, "fist") then return "fist" end
    if string.find(s, "fishing") then return "fishing" end
    if string.find(s, "axe") then return twoHand and "axe2h" or "axe1h" end
    if string.find(s, "mace") then return twoHand and "mace2h" or "mace1h" end
    if string.find(s, "sword") then return twoHand and "sword2h" or "sword1h" end
    return nil
end

local COUNTED_WEAPON_AFFIX_KEYS = {
    bow = true,
    crossbow = true,
    gun = true,
    thrown = true,
    wand = true,
}

-- Synastria melee weapons attune a fixed weapon-stat amount; their random
-- affixes do not contribute attuned stats. Count ranged weapons and wands, but
-- drop melee weapons everywhere affix value is computed.
local function isIgnoredMeleeWeapon(itemType, itemSubType, itemEquipLoc)
    local typeText = string.lower(tostring(itemType or ""))
    local weaponConstant = _G and _G.WEAPON
    if not (typeText == "weapon" or (weaponConstant ~= nil and itemType == weaponConstant)) then
        return false
    end
    local key = weaponKey(string.lower(itemSubType or ""), itemEquipLoc)
    return not (key and COUNTED_WEAPON_AFFIX_KEYS[key])
end

-- Returns a shared set { [classToken] = true } of the classes a WotLK item is
-- "for", or EMPTY_CLASSES if none (fishing pole, tabard, ...). reqLevel makes
-- the armor-material mapping level-aware (see the header above).
local function getItemClasses(itemType, itemSubType, itemEquipLoc, reqLevel)
    reqLevel = tonumber(reqLevel) or 0

    -- Jewelry + cloak: equippable by every class regardless of material.
    if itemEquipLoc == "INVTYPE_FINGER" or itemEquipLoc == "INVTYPE_NECK"
        or itemEquipLoc == "INVTYPE_TRINKET" or itemEquipLoc == "INVTYPE_CLOAK" then
        return ALL_CLASSES_SET
    end
    if itemEquipLoc == "INVTYPE_SHIELD" then return SHIELD_CLASSES end
    if itemEquipLoc == "INVTYPE_HOLDABLE" then return HOLDABLE_CLASSES end
    if itemEquipLoc == "INVTYPE_RELIC" then
        local s = string.lower(itemSubType or "")
        for key, classes in pairs(RELIC_CLASS_SETS) do
            if string.find(s, key) then return classes end
        end
        return EMPTY_CLASSES
    end

    local typeText = string.lower(itemType or "")
    local subText = string.lower(itemSubType or "")

    if typeText == "weapon" or itemType == WEAPON then
        local key = weaponKey(subText, itemEquipLoc)
        return (key and WEAPON_CLASSES[key]) or EMPTY_CLASSES
    end

    if typeText == "armor" or itemType == ARMOR then
        if string.find(subText, "cloth") then
            return ARMOR_CLOTH
        elseif string.find(subText, "leather") then
            return (reqLevel < ARMOR_TIER_LEVEL) and ARMOR_LEATHER_LOW or ARMOR_LEATHER_HIGH
        elseif string.find(subText, "mail") then
            return (reqLevel < ARMOR_TIER_LEVEL) and ARMOR_MAIL_LOW or ARMOR_MAIL_HIGH
        elseif string.find(subText, "plate") then
            return ARMOR_PLATE
        end
        return EMPTY_CLASSES  -- shields handled above; misc armor -> none
    end

    return EMPTY_CLASSES
end

-- ---------------------------------------------------------------------------
-- Zone-name helpers (for the current-zone view)
-- ---------------------------------------------------------------------------

local function getZoneId()
    local zoneId = safeFirst(_G.Custom_GetCurrentZoneOur)
    if zoneId ~= nil then
        return zoneId
    end
    return safeFirst(_G.Custom_GetCurrentZone)
end

local function getZoneName(zoneId)
    if zoneId ~= nil and type(_G.Custom_GetZoneName) == "function" then
        local name = safeFirst(_G.Custom_GetZoneName, zoneId)
        if name and name ~= "" then
            return name
        end
    end
    if type(GetRealZoneText) == "function" then
        local name = GetRealZoneText()
        if name and name ~= "" then
            return name
        end
    end
    if type(GetZoneText) == "function" then
        local name = GetZoneText()
        if name and name ~= "" then
            return name
        end
    end
    return "current zone"
end

-- Exposed for the UI: the player's current zone name as used to match zone data.
function AF.GetCurrentZoneName()
    return getZoneName(getZoneId())
end

-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Affix / attunement queries
-- ---------------------------------------------------------------------------

local function itemHasRandomAffix(itemId)
    local ok, _, tags2 = safeCall(GetItemTagsCustom, itemId)
    if ok and bitAnd(tags2 or 0, 1) ~= 0 then
        return true
    end
    if type(GetItemAffixMask) == "function" then
        local mok, possible1, possible2 = safeCall(GetItemAffixMask, itemId)
        if mok and ((possible1 or 0) ~= 0 or (possible2 or 0) ~= 0) then
            return true
        end
    end
    return false
end

local function itemMatchesScope(itemId, scope)
    local canCharacter = (safeFirst(CanAttuneItemHelper, itemId) or 0) > 0
    if scope == "character" then
        return canCharacter
    end
    local canSomeone = (safeFirst(IsAttunableBySomeone, itemId) or 0) ~= 0
    return canSomeone
end

local function getMaskAffixCounts(itemId, forgeLevel)
    local ok, possible1, possible2, attuned1, attuned2
    if forgeLevel then
        ok, possible1, possible2, attuned1, attuned2 = safeCall(GetItemAffixMask, itemId, forgeLevel)
    else
        ok, possible1, possible2, attuned1, attuned2 = safeCall(GetItemAffixMask, itemId)
    end
    if not ok then
        return 0, 0
    end
    local left1 = maskRemaining(possible1, attuned1)
    local left2 = maskRemaining(possible2, attuned2)
    local possible = countBits32(possible1) + countBits32(possible2)
    local left = countBits32(left1) + countBits32(left2)
    return possible, left
end

local function getAffixCounts(itemId, forgeFilter)
    if not forgeFilter then
        return getMaskAffixCounts(itemId)
    end
    local possible, left = 0, 0
    for level = forgeFilter.minLevel, 3 do
        local p, l = getMaskAffixCounts(itemId, level)
        possible = possible + p
        left = left + l
    end
    return possible, left
end

local function getDropProbability(chance, dropsPerThousand)
    -- `chance` is a drop percentage (0-100); a 1% drop must map to 0.01.
    local pct = tonumber(chance)
    if pct and pct > 0 then
        return math.min(pct / 100, 1)
    end
    local dpt = tonumber(dropsPerThousand)
    if dpt and dpt > 0 then
        return math.min(dpt / 1000, 1)
    end
    return 0
end

local function itemIsUnattuned(itemId, forgeFilter)
    if forgeFilter then
        if type(GetItemAttuneForge) == "function" then
            local forge = safeFirst(GetItemAttuneForge, itemId)
            if type(forge) == "number" then
                return forge < forgeFilter.minLevel
            end
        end
        local progress = safeFirst(GetItemAttuneProgress, itemId, nil, forgeFilter.minLevel)
        if type(progress) == "number" then
            return progress < 100
        end
        if type(HasAttunedAnyVariantEx) == "function" then
            return not safeFirst(HasAttunedAnyVariantEx, itemId, forgeFilter.minLevel)
        end
    elseif type(HasAttunedAnyVariantOfItem) == "function" then
        return not safeFirst(HasAttunedAnyVariantOfItem, itemId)
    end

    if type(GetItemAttuneForge) == "function" then
        local forge = safeFirst(GetItemAttuneForge, itemId)
        if type(forge) == "number" then
            return forge < 0
        end
    end
    local progress = safeFirst(GetItemAttuneProgress, itemId, nil, nil)
    if type(progress) == "number" then
        return progress < 100
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Source-row helpers
-- ---------------------------------------------------------------------------

local function trim(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

local function isActionableSourceZone(zoneName)
    zoneName = trim(zoneName)
    if zoneName == "" or zoneName == "?" or zoneName == "??" then
        return false
    end
    local lowered = string.lower(zoneName)
    if lowered == "unknown" or lowered == "unknown zone" then
        return false
    end
    return true
end

local function textContainsAny(text, needles)
    text = string.lower(tostring(text or ""))
    for _, needle in ipairs(needles) do
        if string.find(text, needle, 1, true) then
            return true
        end
    end
    return false
end

-- A farmable kill: the source object is a creature (srcObjType == 0) and the
-- source type is not a non-kill way of getting the item (vendor/quest/craft).
-- See the project notes: srcObjType == 0 alone also matches vendors/quest
-- givers, and srcType == 1 alone also matches lootable chests, so we need both.
local function isCreatureSource(srcType, srcObjType, objName)
    local snum = tonumber(srcType)
    local onum = tonumber(srcObjType)
    if onum ~= nil then
        if onum ~= OBJTYPE_CREATURE then
            return false
        end
        if snum ~= nil and NON_KILL_SRC_TYPES[snum] then
            return false
        end
        return true
    end

    -- Fallback for the unexpected case of non-numeric fields.
    local st = string.lower(tostring(srcType or ""))
    local ot = string.lower(tostring(srcObjType or ""))
    local nm = string.lower(tostring(objName or ""))
    if textContainsAny(st, { "vendor" }) then
        return false
    end
    if textContainsAny(st, { "cache", "chest", "container", "object", "fishing", "mill", "prospect", "craft", "quest", "disenchant" })
        or textContainsAny(ot, { "cache", "chest", "container", "object", "gameobject" })
        or string.find(nm, "cache", 1, true)
        or string.find(nm, "chest", 1, true)
    then
        return false
    end
    return textContainsAny(st, { "creature", "npc", "mob", "boss", "skin", "pickpocket" })
        or textContainsAny(ot, { "creature", "npc", "mob", "boss" })
        or textContainsAny(nm, { "[boss]", "boss " })
end

-- Returns the distinct killable mobs that drop this item, one entry per
-- (zone, NPC). Multiple rows for the same NPC are merged (max chance / spawn
-- count). Not cached: it is read once per item during an aggregation pass and
-- folded straight into the small per-zone/per-mob totals, then discarded.
local function getCreatureSources(itemId)
    local sources = {}
    if type(ItemLocGetSourceCount) ~= "function" or type(ItemLocGetSourceAt) ~= "function" then
        return sources
    end

    local byKey = {}
    local sourceCount = safeFirst(ItemLocGetSourceCount, itemId) or 0
    for sourceIndex = 1, sourceCount do
        local ok, srcType, srcObjType, srcObjId, chance, dropsPerThousand, objName, zoneName, spawnedCount =
            safeCall(ItemLocGetSourceAt, itemId, sourceIndex)
        zoneName = ok and trim(zoneName) or ""
        local npcId = tonumber(srcObjId) or 0

        if ok and npcId > 0 and isActionableSourceZone(zoneName)
            and isCreatureSource(srcType, srcObjType, objName)
        then
            local dropProbability = getDropProbability(chance, dropsPerThousand)
            if dropProbability > 0 then
                local spawns = tonumber(spawnedCount) or 0
                local key = zoneName .. ":" .. npcId
                local entry = byKey[key]
                if not entry then
                    entry = {
                        zoneName = zoneName,
                        npcId = npcId,
                        npcName = (objName and objName ~= "" and tostring(objName)) or ("NPC #" .. npcId),
                        dropProbability = dropProbability,
                        spawnedCount = spawns,
                    }
                    byKey[key] = entry
                    sources[#sources + 1] = entry
                else
                    if dropProbability > entry.dropProbability then
                        entry.dropProbability = dropProbability
                    end
                    if spawns > entry.spawnedCount then
                        entry.spawnedCount = spawns
                    end
                    if string.find(entry.npcName, "^NPC #") and objName and objName ~= "" then
                        entry.npcName = tostring(objName)
                    end
                end
            end
        end
    end

    return sources
end

-- Bind-on-pickup check. The second return of GetItemTagsCustom carries the
-- bind flag in bit 0x80 (same tag word the affix bit lives in); ScootsCraft
-- reads BoP the same way. Anything not flagged BoP is treated as BoE for the
-- bind filter (BoA/unbound affixed mob drops are vanishingly rare here).
local function itemIsBop(itemId)
    local ok, _, tags2 = safeCall(GetItemTagsCustom, itemId)
    if not ok then
        return false
    end
    return bitAnd(tags2 or 0, 0x80) ~= 0
end

-- Mythic items are flagged in the FIRST GetItemTagsCustom return (bit 0x80).
-- (itemIsBop above reads the *second* return's 0x80 for BoP -- different return
-- word, same bit position.) Mythic content is hard to farm, so by default these
-- items are excluded from the rankings; the setting flips that.
local function itemIsMythic(itemId)
    local ok, tags1 = safeCall(GetItemTagsCustom, itemId)
    if not ok then
        return false
    end
    return bitAnd(tags1 or 0, 0x80) ~= 0
end

-- bindFilter is "bop", "boe", or nil (both).
local function itemMatchesBind(itemId, bindFilter)
    if not bindFilter then
        return true
    end
    local bop = itemIsBop(itemId)
    if bindFilter == "bop" then
        return bop
    end
    return not bop
end

-- Computes an affixed item's value for a scope/forge/bind, or nil if it does
-- not count. Shared by every aggregation pass. includeMythics false drops mythic
-- items entirely (so they never reach the zone/mob totals).
local function affixedItemValue(itemId, scope, forgeFilter, bindFilter, includeMythics, wantClasses)
    if not itemMatchesScope(itemId, scope) then
        return nil
    end
    if not itemMatchesBind(itemId, bindFilter) then
        return nil
    end
    if not includeMythics and itemIsMythic(itemId) then
        return nil
    end
    -- One GetItemInfoCustom call feeds the melee-weapon exclusion, display
    -- category, and (account scope only) per-class attribution.
    local reqLevel, itemType, itemSubType, itemEquipLoc
    if type(GetItemInfoCustom) == "function" then
        local ok, _, _, _, _, rl, it, ist, _, eq = safeCall(GetItemInfoCustom, itemId)
        if ok then
            reqLevel, itemType, itemSubType, itemEquipLoc = rl, it, ist, eq
        end
    end
    if isIgnoredMeleeWeapon(itemType, itemSubType, itemEquipLoc) then
        return nil
    end

    -- No itemHasRandomAffix gate here: this is only ever called over
    -- AF.affixedItemIds (every id is already known affixed), and getAffixCounts
    -- below returns possible <= 0 for anything without a usable affix mask.
    local possible, left = getAffixCounts(itemId, forgeFilter)
    if possible <= 0 then
        return nil
    end

    return {
        possible = possible,
        affixesLeft = left,
        valuePerDrop = (left > 0) and (left / possible) or 0,
        unattuned = itemIsUnattuned(itemId, forgeFilter),
        category = getItemCategory(itemType, itemSubType, itemEquipLoc),
        classes = wantClasses and getItemClasses(itemType, itemSubType, itemEquipLoc, reqLevel) or nil,
    }
end

-- ---------------------------------------------------------------------------
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
    -- Honour the mythic setting for consistency with the affix views. (In
    -- practice mythic items drop only from mythic dungeons and aren't expected
    -- to carry resist affixes, so this rarely changes the ranking -- but the
    -- behaviour should match the rest of the addon rather than silently differ.)
    if not includeMythics and itemIsMythic(itemId) then
        return nil
    end
    if type(GetItemInfoCustom) == "function" then
        local ok, _, _, _, _, _, itemType, itemSubType, _, itemEquipLoc = safeCall(GetItemInfoCustom, itemId)
        if ok and isIgnoredMeleeWeapon(itemType, itemSubType, itemEquipLoc) then
            return nil
        end
    end
    local tok, _, tags2 = safeCall(GetItemTagsCustom, itemId)
    if not tok or bitAnd(tags2 or 0, 0x2) == 0 then
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

-- ---------------------------------------------------------------------------
-- Chunked execution engine
-- ---------------------------------------------------------------------------

local tickerFrame = CreateFrame("Frame")
local profileMs = (type(debugprofilestop) == "function") and debugprofilestop or nil

-- Runs stepFn(i) for i = 1..total across frames, capped per frame by a time
-- budget (budgetMs) so the client stays responsive regardless of per-item cost,
-- then calls doneFn(). progressFn(done, total) is called occasionally.
local function runChunked(total, stepFn, doneFn, progressFn, budgetMs, perFrameCap)
    total = total or 0
    budgetMs = budgetMs or 6
    perFrameCap = perFrameCap or 5000
    if total <= 0 then
        doneFn()
        return
    end

    local i = 0
    local lastProgressAt = 0
    tickerFrame:SetScript("OnUpdate", function(self)
        local startMs = profileMs and profileMs()
        local processed = 0
        while i < total do
            i = i + 1
            stepFn(i)
            processed = processed + 1
            if processed >= perFrameCap then
                break
            end
            if startMs and (profileMs() - startMs) >= budgetMs then
                break
            end
        end
        if progressFn and i < total and (i - lastProgressAt) >= 1000 then
            lastProgressAt = i
            progressFn(i, total)
        end
        if i >= total then
            self:SetScript("OnUpdate", nil)
            if progressFn then
                progressFn(total, total)
            end
            doneFn()
        end
    end)
end

local function beginTask()
    if AF.busy then
        return false
    end
    AF.busy = true
    return true
end

local function endTask()
    AF.busy = false
end

-- Shared cache + staleness + busy-guard wrapper for the compute functions.
--   store    : the cache table (AF.zoneData or AF.resistData)
--   key      : cache key string
--   build    : build(finish) runs the (chunked) scan and calls finish(data) with
--              the freshly built slice (or finish(nil, err) on failure). finish
--              stamps computedAt/dirty and stores the slice, then releases the
--              busy guard and forwards to onComplete.
--   onComplete(data) / onComplete(nil, err)
--
-- A non-dirty cached slice is returned immediately; a dirty one is reused until
-- the configured rescanInterval has elapsed since it was built (0 = always
-- recompute), then dropped and rebuilt. A manual ClearAll removes the entry,
-- bypassing the interval. This is the one place that policy lives.
local function computeWithCache(store, key, build, onComplete)
    onComplete = onComplete or function() end

    local cached = store[key]
    if cached then
        if not cached.dirty then
            onComplete(cached)
            return
        end
        local interval = (tonumber(AF.GetConfig("rescanInterval")) or 0) * 60
        if interval > 0 and (time() - (cached.computedAt or 0)) < interval then
            onComplete(cached)
            return
        end
        store[key] = nil
    end

    if not beginTask() then
        onComplete(nil, "busy")
        return
    end

    local function finish(data, err)
        endTask()
        if data then
            data.computedAt = time()
            data.dirty = false
            store[key] = data
        end
        onComplete(data, err)
    end

    build(finish)
end

local function makeProgress(label)
    local halfPrinted = false
    local finished = false
    chat("Scan " .. tostring(label) .. " started.")
    return function(done, total)
        total = tonumber(total) or 0
        done = tonumber(done) or 0
        if total > 0 and not halfPrinted and done >= (total / 2) then
            halfPrinted = true
            chat("Scan " .. tostring(label) .. " at 50%.")
        end
        if total > 0 and not finished and done >= total then
            finished = true
            chat("Scan " .. tostring(label) .. " finished.")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Discovery + aggregation
-- ---------------------------------------------------------------------------

-- Finds (once per session) the item ids that have a random affix. This is the
-- only pass that touches the whole id space; it is static so later commands
-- reuse it. Calls onReady(ids) or onReady(nil, errorText).
-- The affixed-id list is static for a given server-data version, so it is
-- cached across sessions in AffixFinderDB.affixCache, fingerprinted by
-- MAX_ITEMID. This skips the (only) whole-id-space pass on every session after
-- the first. It is a list of integers (not the item graph), so it has none of
-- the memory/logout cost the graph would. AF.ClearAll() wipes it for the rare
-- server-data-reload case (where MAX_ITEMID may not have changed).
local function loadPersistedAffixIds()
    local db = _G.AffixFinderDB
    local cache = type(db) == "table" and db.affixCache
    if type(cache) == "table" and cache.max == MAX_ITEMID and type(cache.ids) == "table" then
        return cache.ids
    end
    return nil
end

local function persistAffixIds(ids)
    local db = _G.AffixFinderDB
    if type(db) ~= "table" then
        db = {}
        _G.AffixFinderDB = db
    end
    -- Store the same reference (static, never mutated) so there is no copy cost.
    db.affixCache = { max = MAX_ITEMID, ids = ids }
end

local function ensureAffixedIds(onReady)
    local ready, reason = isCustomReady()
    if not ready then
        onReady(nil, reason)
        return
    end
    if type(MAX_ITEMID) ~= "number" then
        onReady(nil, "MAX_ITEMID is unavailable")
        return
    end
    if AF.affixedItemIds then
        onReady(AF.affixedItemIds)
        return
    end

    -- Reuse the persisted list when its fingerprint still matches, skipping the
    -- whole-id-space scan entirely.
    local persisted = loadPersistedAffixIds()
    if persisted then
        AF.affixedItemIds = persisted
        onReady(persisted)
        return
    end

    local ids = {}
    local progress = makeProgress("affixed items")
    runChunked(MAX_ITEMID, function(itemId)
        if itemHasRandomAffix(itemId) then
            ids[#ids + 1] = itemId
        end
    end, function()
        AF.affixedItemIds = ids
        persistAffixIds(ids)
        onReady(ids)
    end, progress)
end

local function newZoneRow(zoneName)
    return {
        zoneName = zoneName,
        candidateItems = 0,
        unattunedAffixedItems = 0,
        affixedItemsWithAffixesLeft = 0,
        totalAffixesLeft = 0,
        breakdown = {
            unattunedAffixedItems = {},
            affixedItemsWithAffixesLeft = {},
            totalAffixesLeft = {},
        },
        -- Account scope only: per-class sub-tallies (classToken -> tally with
        -- the same shape as the top-level zone counts). Empty in character scope.
        byClass = {},
    }
end

-- One per-class zone tally, mirroring the top-level zone counts so the UI can
-- format a single class exactly like the account-wide view.
local function newClassZoneTally()
    return {
        unattunedAffixedItems = 0,
        affixedItemsWithAffixesLeft = 0,
        totalAffixesLeft = 0,
        breakdown = {
            unattunedAffixedItems = {},
            affixedItemsWithAffixesLeft = {},
            totalAffixesLeft = {},
        },
    }
end

local function scopeForgeKey(scope, forgeFilter, bindFilter, includeMythics)
    return tostring(scope)
        .. ":" .. (forgeFilter and tostring(forgeFilter.minLevel) or "base")
        .. ":" .. (bindFilter and tostring(bindFilter) or "any")
        .. ":" .. (includeMythics and "myth" or "nomyth")
end

-- Produces (and caches in memory) the aggregated data for a scope/forge/bind:
-- the per-zone affix totals and the per-mob expected value. All zone/EV/current
-- views format from this; only the source graph is transient. Async: calls
-- onComplete(data) or onComplete(nil, errorText). bindFilter is "bop", "boe",
-- or nil (both).
function AF.ComputeZoneData(scope, forgeFilter, bindFilter, onComplete)
    onComplete = onComplete or function() end
    local includeMythics = AF.GetConfig("includeMythics") and true or false
    local key = scopeForgeKey(scope, forgeFilter, bindFilter, includeMythics)

    computeWithCache(AF.zoneData, key, function(finish)
    ensureAffixedIds(function(ids, err)
        if not ids then
            finish(nil, err)
            return
        end

        local rowsByZone = {}
        local rows = {}
        local mobsByKey = {}
        local affixedItemsScanned = 0
        local progress = makeProgress("mob sources")
        -- Per-class breakdown only matters in account scope (character scope is
        -- already a single class); skip the work otherwise.
        local perClass = (scope == "account")

        runChunked(#ids, function(i)
            local itemId = ids[i]
            local value = affixedItemValue(itemId, scope, forgeFilter, bindFilter, includeMythics, perClass)
            if not value then
                return
            end
            local sources = getCreatureSources(itemId)
            if #sources == 0 then
                return
            end
            affixedItemsScanned = affixedItemsScanned + 1

            local affixesLeft = value.affixesLeft
            local valuePerDrop = value.valuePerDrop
            local unattuned = value.unattuned
            local category = value.category
            local classes = value.classes

            local seenZone = {}
            for s = 1, #sources do
                local src = sources[s]
                local zoneName = src.zoneName

                -- Per-zone counts: count the item once per distinct zone.
                if not seenZone[zoneName] then
                    seenZone[zoneName] = true
                    local row = rowsByZone[zoneName]
                    if not row then
                        row = newZoneRow(zoneName)
                        rowsByZone[zoneName] = row
                        rows[#rows + 1] = row
                    end
                    row.candidateItems = row.candidateItems + 1
                    if unattuned then
                        row.unattunedAffixedItems = row.unattunedAffixedItems + 1
                        addBreakdownCount(row.breakdown.unattunedAffixedItems, category, 1)
                    end
                    if affixesLeft > 0 then
                        row.affixedItemsWithAffixesLeft = row.affixedItemsWithAffixesLeft + 1
                        row.totalAffixesLeft = row.totalAffixesLeft + affixesLeft
                        addBreakdownCount(row.breakdown.affixedItemsWithAffixesLeft, category, 1)
                        addBreakdownCount(row.breakdown.totalAffixesLeft, category, affixesLeft)
                    end

                    -- Mirror the same counts into each class this item is for.
                    if classes then
                        for c in pairs(classes) do
                            local ct = row.byClass[c]
                            if not ct then
                                ct = newClassZoneTally()
                                row.byClass[c] = ct
                            end
                            if unattuned then
                                ct.unattunedAffixedItems = ct.unattunedAffixedItems + 1
                                addBreakdownCount(ct.breakdown.unattunedAffixedItems, category, 1)
                            end
                            if affixesLeft > 0 then
                                ct.affixedItemsWithAffixesLeft = ct.affixedItemsWithAffixesLeft + 1
                                ct.totalAffixesLeft = ct.totalAffixesLeft + affixesLeft
                                addBreakdownCount(ct.breakdown.affixedItemsWithAffixesLeft, category, 1)
                                addBreakdownCount(ct.breakdown.totalAffixesLeft, category, affixesLeft)
                            end
                        end
                    end
                end

                -- Per-mob EV (only meaningful while affixes remain).
                if affixesLeft > 0 then
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
                            -- Account scope only: per-class EV/items/affixes for
                            -- this mob (classToken -> tally). Empty otherwise.
                            byClass = {},
                        }
                        mobsByKey[mobKey] = mob
                    end
                    local evDelta = src.dropProbability * valuePerDrop
                    mob.evPerKill = mob.evPerKill + evDelta
                    mob.itemsDropped = mob.itemsDropped + 1
                    mob.affixesLeft = mob.affixesLeft + affixesLeft
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
                            mc.affixesLeft = mc.affixesLeft + affixesLeft
                        end
                    end
                end
            end
        end, function()
            finish({
                scope = scope,
                forgeFilter = forgeFilter,
                bindFilter = bindFilter,
                includeMythics = includeMythics,
                rows = rows,
                rowsByZone = rowsByZone,
                mobsByKey = mobsByKey,
                affixedItemsScanned = affixedItemsScanned,
            })
        end, progress)
    end)
    end, onComplete)
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
                        byClass = {},
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

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

local EV_MODE_LABELS = {
    best = "best mob",
    avg = "avg mob",
    total = "all mobs",
}

local function reportScanError(err, what)
    if err == "busy" then
        chat("Busy: a scan is already running. Try again in a moment.")
    else
        chat("Cannot " .. what .. " yet: " .. tostring(err) .. ". Try again after entering the world.")
    end
end

-- Exposed for the UI / current-zone view: find a zone row by exact then
-- case-insensitive name match.
function AF.FindZoneRow(data, zoneName)
    local row = data.rowsByZone[zoneName]
    if row then
        return row
    end
    local lowered = string.lower(zoneName)
    for name, candidate in pairs(data.rowsByZone) do
        if string.lower(name) == lowered then
            return candidate
        end
    end
    return nil
end
local findZoneRow = AF.FindZoneRow

-- ", BoP" / ", BoE" / "" for captions. Exposed so the UI labels identically.
local BIND_LABELS = { bop = "BoP", boe = "BoE" }
function AF.BindLabel(bindFilter)
    return bindFilter and BIND_LABELS[bindFilter] or nil
end
local function bindLabelText(bindFilter)
    local label = AF.BindLabel(bindFilter)
    return label and (", " .. label) or ""
end

-- "scope, TF+, BoE" -- the scope/forge/bind portion every chat caption opens
-- with. The callers wrap this with view-specific context (zone name, counts).
local function filterCaption(scope, forgeFilter, bindFilter)
    return scope
        .. (forgeFilter and (", " .. forgeFilter.label) or "")
        .. bindLabelText(bindFilter)
end

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
            "Molten Core", "Onyxia's Lair", "Blackwing Lair", "Zul'Gurub",
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
            "Naxxramas", "The Obsidian Sanctum", "The Eye of Eternity",
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

-- Expansion for a bundled warp-zone index (see WARP_ZONE_INDEX). TBC: Quel'Danas
-- /Eversong/Ghostlands (0-2), Silvermoon (28), Draenei isles + Exodar (50-52),
-- Outland (53-60). WotLK: all Northrend (61-71). Everything else is classic.
local TBC_WARP_INDICES = {
    [0] = true, [1] = true, [2] = true, [28] = true,
    [50] = true, [51] = true, [52] = true, [53] = true, [54] = true,
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

-- Returns the zones that still have remaining affix value, sorted the same way
-- the chat ranking prints them (most affixes left first). Shared by the chat
-- command and the UI so both rank identically.
--
-- classToken (optional, account scope) restricts the numbers to a single class:
-- each emitted row carries that class's sub-tallies under the same field names,
-- and zones with nothing left for that class are dropped. nil = account totals.
function AF.BuildZoneRankings(data, classToken)
    local rows = {}
    for _, row in ipairs(data.rows) do
        if classToken then
            local ct = row.byClass and row.byClass[classToken]
            if ct and ct.totalAffixesLeft > 0 then
                rows[#rows + 1] = {
                    zoneName = row.zoneName,
                    totalAffixesLeft = ct.totalAffixesLeft,
                    affixedItemsWithAffixesLeft = ct.affixedItemsWithAffixesLeft,
                    unattunedAffixedItems = ct.unattunedAffixedItems,
                    breakdown = ct.breakdown,
                }
            end
        elseif row.totalAffixesLeft > 0 then
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b)
        if a.totalAffixesLeft ~= b.totalAffixesLeft then
            return a.totalAffixesLeft > b.totalAffixesLeft
        end
        if a.affixedItemsWithAffixesLeft ~= b.affixedItemsWithAffixesLeft then
            return a.affixedItemsWithAffixesLeft > b.affixedItemsWithAffixesLeft
        end
        return tostring(a.zoneName or "") < tostring(b.zoneName or "")
    end)
    return rows
end

-- Returns the individual mobs (one entry per NPC, already deduped per zone)
-- whose spawn count meets minSpawns, sorted by expected useful-affix drops per
-- kill, best-first. Each mob carries: zoneName, npcName, spawnedCount,
-- evPerKill, itemsDropped (affixed items it drops that still have affixes), and
-- affixesLeft (total remaining affixes across those items). These are per-mob
-- totals -- nothing is summed across mobs -- so the values stay intuitive.
--
-- classToken (optional, account scope) restricts every per-mob value to a
-- single class (and drops mobs that drop nothing for that class). nil = account.
function AF.BuildMobList(data, minSpawns, classToken)
    minSpawns = tonumber(minSpawns) or 1
    if minSpawns < 0 then
        minSpawns = 0
    end
    local mobs = {}
    for _, mob in pairs(data.mobsByKey) do
        if mob.spawnedCount >= minSpawns then
            if classToken then
                local mc = mob.byClass and mob.byClass[classToken]
                if mc and mc.affixesLeft > 0 then
                    mobs[#mobs + 1] = {
                        zoneName = mob.zoneName,
                        npcId = mob.npcId,
                        npcName = mob.npcName,
                        spawnedCount = mob.spawnedCount,
                        evPerKill = mc.evPerKill,
                        itemsDropped = mc.itemsDropped,
                        affixesLeft = mc.affixesLeft,
                    }
                end
            else
                mobs[#mobs + 1] = mob
            end
        end
    end
    table.sort(mobs, function(a, b)
        if a.evPerKill ~= b.evPerKill then
            return a.evPerKill > b.evPerKill
        end
        return tostring(a.npcName or "") < tostring(b.npcName or "")
    end)
    return mobs
end

-- Ranks the classes by how much affix value the account can still attune on
-- them (account scope only), summed over the zones that pass zonePassFn (the
-- UI's display-time category/expansion filter), so the ranking respects the
-- same filters as the other panels. zonePassFn(zoneName) -> bool; pass nil to
-- include every zone. Returns an array sorted by remaining affixes, best-first.
function AF.BuildClassRankings(data, zonePassFn)
    local totals = {}
    for _, row in ipairs(data.rows) do
        if (not zonePassFn) or zonePassFn(row.zoneName) then
            if row.byClass then
                for token, ct in pairs(row.byClass) do
                    if ct.totalAffixesLeft > 0 then
                        local t = totals[token]
                        if not t then
                            t = { classToken = token, totalAffixesLeft = 0,
                                  affixedItemsWithAffixesLeft = 0, unattunedAffixedItems = 0 }
                            totals[token] = t
                        end
                        t.totalAffixesLeft = t.totalAffixesLeft + ct.totalAffixesLeft
                        t.affixedItemsWithAffixesLeft = t.affixedItemsWithAffixesLeft + ct.affixedItemsWithAffixesLeft
                        t.unattunedAffixedItems = t.unattunedAffixedItems + ct.unattunedAffixedItems
                    end
                end
            end
        end
    end

    local rows = {}
    for _, t in pairs(totals) do
        t.className = AF.ClassDisplayName(t.classToken)
        rows[#rows + 1] = t
    end
    table.sort(rows, function(a, b)
        if a.totalAffixesLeft ~= b.totalAffixesLeft then
            return a.totalAffixesLeft > b.totalAffixesLeft
        end
        return tostring(a.className or "") < tostring(b.className or "")
    end)
    return rows
end

-- Groups the per-mob expected-value data into per-zone scores for a given
-- EV mode (best/avg/total) and minimum mob spawn count, sorted best-first.
-- Returns: zones (sorted array), zonesDiscovered, mobsBelowThreshold.
-- Pure formatting over already-computed data, so changing mode/threshold never
-- triggers a rescan. Shared by the chat command and the UI.
function AF.BuildZoneEV(data, evMode, minSpawns)
    evMode = evMode or "best"
    minSpawns = tonumber(minSpawns) or 1
    if minSpawns < 0 then
        minSpawns = 0
    end

    local zonesByName = {}
    local zones = {}
    local discovered = {}
    local zonesDiscovered = 0
    local mobsBelowThreshold = 0
    for _, mob in pairs(data.mobsByKey) do
        if not discovered[mob.zoneName] then
            discovered[mob.zoneName] = true
            zonesDiscovered = zonesDiscovered + 1
        end
        if mob.spawnedCount >= minSpawns then
            local zone = zonesByName[mob.zoneName]
            if not zone then
                zone = {
                    zoneName = mob.zoneName,
                    qualifyingMobs = 0,
                    bestEvPer1000 = 0,
                    totalEvPer1000 = 0,
                    totalAffixesLeft = 0,
                    bestMobName = nil,
                    bestMobNpcId = nil,  -- so a view can pin the best mob (Resist tab)
                    bestMobSpawns = 0,
                    bestMobItems = 0,
                }
                zonesByName[mob.zoneName] = zone
                zones[#zones + 1] = zone
            end
            local evPer1000 = mob.evPerKill * 1000
            zone.qualifyingMobs = zone.qualifyingMobs + 1
            zone.totalEvPer1000 = zone.totalEvPer1000 + evPer1000
            zone.totalAffixesLeft = zone.totalAffixesLeft + mob.affixesLeft
            if evPer1000 > zone.bestEvPer1000 then
                zone.bestEvPer1000 = evPer1000
                zone.bestMobName = mob.npcName
                zone.bestMobNpcId = mob.npcId
                zone.bestMobSpawns = mob.spawnedCount
                zone.bestMobItems = mob.itemsDropped
            end
        else
            mobsBelowThreshold = mobsBelowThreshold + 1
        end
    end

    for _, zone in ipairs(zones) do
        if evMode == "avg" then
            zone.score = zone.totalEvPer1000 / zone.qualifyingMobs
        elseif evMode == "total" then
            zone.score = zone.totalEvPer1000
        else
            zone.score = zone.bestEvPer1000
        end
    end
    table.sort(zones, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        if a.totalAffixesLeft ~= b.totalAffixesLeft then
            return a.totalAffixesLeft > b.totalAffixesLeft
        end
        return tostring(a.zoneName or "") < tostring(b.zoneName or "")
    end)

    return zones, zonesDiscovered, mobsBelowThreshold
end

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
-- cross-referenced in-game. Run /af affixdbg <itemId|link> [maxBits].
local function printAffixDebug(options)
    local itemId = tonumber(options.debugItemId)
    if not itemId or itemId <= 0 then
        chat("Usage: /af affixdbg <itemId|link> [maxBits]")
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

    local mok, p1, p2, a1, a2, activeIndex = safeCall(GetItemAffixMask, itemId)
    if not mok then
        chat("GetItemAffixMask unavailable; cannot list affix bits.")
        return
    end
    chat(string.format("Mask: p1=%s p2=%s a1=%s a2=%s activeIndex=%s",
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

-- ---------------------------------------------------------------------------
-- Command handling
-- ---------------------------------------------------------------------------

local function parseOptions(msg)
    local options = {
        mode = "current",
        scope = "character",
        forgeFilter = nil,
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
        elseif token == "affixdbg" or token == "maskdbg" then
            options.mode = "affixdbg"
            options.affixDbg = true
        elseif token == "affixid" or token == "affixprobe" then
            options.mode = "affixid"
            options.affixDbg = true
        elseif token == "resistval" or token == "resval" then
            options.mode = "resistval"
            options.affixDbg = true
        elseif token == "resist" or token == "res" then
            options.mode = "resist"
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
            elseif options.ev or options.mode == "resist" then
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
        else
            options.error = token
            return options
        end
    end

    return options
end

local function printUsage()
    chat("Window: /af ui (filterable browser) -- Settings: /af config (Interface > AddOns)")
    chat("Usage: /af [zones [ev ...]] [character|char|c|account|acc|a] [tf|wf|lf] [bop|boe|both] [breakdown] [limit]")
    chat("Current zone: /af, /af acc, /af acc tf breakdown")
    chat("Zone rankings: /af zones, /af zones acc, /af zones acc wf 15")
    chat("Expected value: /af zones ev [best|avg|total] N [limit] (N = min mob spawn count)")
    chat("  e.g. /af zones ev 5, /af zones acc ev total 10, /af zones ev avg 1 20")
    chat("Specific resist: /af resist <fire|nature|frost|shadow|arcane> [char|acc] [best|avg|total] [N] [limit]")
    chat("  e.g. /af resist fire, /af resist frost acc 5, /af resist arcane total 1 15")
    chat("Debug: /af debug <itemId|link> [maxRows], /af zonedbg (zone classification)")
    chat("  /af zonedump [char|acc] [tf|wf|lf] [bop|boe|both] [sampleRows] (current-zone item gates)")
    chat("  /af warp (current-zone T3 warp-tier probe for the map-warp assist)")
    chat("  /af affixdbg <itemId|link> [maxBits] (affix mask <-> stat mapping probe)")
    chat("  /af affixid <item link> (rolled affix id + ItemAttuneAffix key scheme)")
    chat("  /af resistval <item link> (actual resist amount + scaling probe)")
    chat("Maintenance: /af clearcache (reset + rediscover), /af mem (memory report)")
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
    elseif options.mode == "resistval" then
        printResistValue(options)
    elseif options.mode == "resist" then
        printResistRankings(options)
    elseif options.mode == "zonedbg" then
        printZoneClassification(options)
    elseif options.mode == "zonedump" then
        printZoneItemDump(options)
    elseif options.mode == "warpdbg" then
        printWarpDebug()
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
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "CHAT_MSG_SYSTEM" then
        -- Attuning changes how many affixes are left; drop cached aggregates.
        if type(arg1) == "string" and string.find(arg1, "You have attuned with", 1, true) then
            AF.ClearDynamicData()
        end
    end
end)
