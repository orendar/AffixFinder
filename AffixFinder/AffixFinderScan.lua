-- AffixFinder scan, item model, aggregation, and result builders.
-- Loaded through AffixFinder.toc; public APIs live on AF, implementation details on AF._internal.

local AF = _G.AffixFinder
local I = AF._internal

local chat = I.chat
local safeCall = I.safeCall
local safeFirst = I.safeFirst
local isCustomReady = I.isCustomReady
local OBJTYPE_CREATURE = I.OBJTYPE_CREATURE
local NON_KILL_SRC_TYPES = I.NON_KILL_SRC_TYPES

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

local function uint32(value)
    value = tonumber(value) or 0
    if value < 0 then
        value = value + 4294967296
    end
    return value
end

local function maskUnion(a, b)
    a = uint32(a)
    b = uint32(b)
    return a + b - uint32(bitAnd(a, b))
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

-- INVARIANT: every per-item affix gate must exclude melee weapons (see above).
-- This is the id-level chokepoint so a gate only needs the one call -- it makes
-- the GetItemInfoCustom lookup and the isIgnoredMeleeWeapon check once, rather
-- than each gate re-deriving the type/subtype/equipLoc by hand (the divergence
-- that once let melee weapons through the tooltip). Returns false when the
-- custom API is unavailable, so a missing API never wrongly drops an item.
local function isIgnoredMeleeWeaponId(itemId)
    if type(GetItemInfoCustom) ~= "function" then
        return false
    end
    local ok, _, _, _, _, _, itemType, itemSubType, _, itemEquipLoc = safeCall(GetItemInfoCustom, itemId)
    return ok and isIgnoredMeleeWeapon(itemType, itemSubType, itemEquipLoc)
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

-- GetItemAffixMask bits are ItemAttuneAffix.index values, while
-- GetItemAttuneProgress expects the corresponding positive `ex` affix id.
-- Prefer the prop=true entry because that is the attunable suffix for the bit.
local affixMetaByIndex
local function buildAffixMetaIndex()
    local map = {}
    local iaa = _G.ItemAttuneAffix
    if type(iaa) ~= "table" then
        return map
    end
    for _, entry in pairs(iaa) do
        if type(entry) == "table" and type(entry.index) == "number" then
            local idx = entry.index
            local current = map[idx]
            local affixId = tonumber(entry.ex)
            if not affixId or affixId <= 0 then
                affixId = nil
            end
            if not current
                or (entry.prop and not current.prop)
                or (entry.prop == current.prop and current.affixId == nil and affixId ~= nil) then
                map[idx] = {
                    affixId = affixId,
                    name = (type(entry.name) == "string" and entry.name ~= "") and entry.name or nil,
                    prop = entry.prop and true or false,
                }
            end
        end
    end
    return map
end

local function getAffixMetaIndex()
    if not affixMetaByIndex or next(affixMetaByIndex) == nil then
        affixMetaByIndex = buildAffixMetaIndex()
    end
    return affixMetaByIndex
end

local function getAffixMasks(itemId, forgeLevel)
    forgeLevel = tonumber(forgeLevel) or 0
    if forgeLevel == 0 then
        -- The original documented form omits the argument for non-forged items.
        return safeCall(GetItemAffixMask, itemId)
    end
    return safeCall(GetItemAffixMask, itemId, forgeLevel)
end

-- The live client accepts a forge level in GetItemAffixMask, but its returned
-- attuned masks are not reliably level-specific. For forged slices, resolve each
-- possible mask bit to its real affix id and ask the forge-aware progress API.
-- If metadata/progress is unavailable for a bit, retain the mask result as a
-- compatibility fallback.
local function getRemainingAffixMasks(itemId, forgeLevel)
    forgeLevel = tonumber(forgeLevel) or 0
    local ok, possible1, possible2, attuned1, attuned2 =
        getAffixMasks(itemId, forgeLevel)
    if not ok then
        return false
    end

    if forgeLevel == 0 or type(GetItemAttuneProgress) ~= "function" then
        return true, possible1, possible2,
            maskRemaining(possible1, attuned1), maskRemaining(possible2, attuned2)
    end

    local metaByIndex = getAffixMetaIndex()
    local function remainingWord(possibleMask, attunedMask, baseIndex)
        local possible = possibleMask or 0
        local attuned = attunedMask or 0
        if possible < 0 then possible = possible + 4294967296 end
        if attuned < 0 then attuned = attuned + 4294967296 end

        local remaining = 0
        local place = 1
        local bitPos = 0
        while possible > 0 do
            if possible % 2 == 1 then
                local fallbackLeft = math.floor(attuned / place) % 2 == 0
                local meta = metaByIndex[baseIndex + bitPos]
                local progress = meta and meta.affixId
                    and safeFirst(GetItemAttuneProgress, itemId, meta.affixId, forgeLevel) or nil
                local isLeft = fallbackLeft
                if type(progress) == "number" then
                    isLeft = progress < 100
                end
                if isLeft then
                    remaining = remaining + place
                end
            end
            possible = math.floor(possible / 2)
            place = place * 2
            bitPos = bitPos + 1
        end
        return remaining
    end

    return true, possible1, possible2,
        remainingWord(possible1, attuned1, 0),
        remainingWord(possible2, attuned2, 32)
end

local function forgeLevelRange(forgeFilter)
    local minLevel = tonumber(forgeFilter and (forgeFilter.minLevel or forgeFilter.level)) or 0
    if minLevel <= 0 then
        return 0, 0
    end
    local maxLevel = tonumber(forgeFilter and forgeFilter.maxLevel) or 3
    return minLevel, math.max(minLevel, math.min(maxLevel, 3))
end

-- Forge filters are one-way thresholds: TF includes TF/WF/LF, WF includes
-- WF/LF, and LF includes only LF. Combine the included levels as mask unions,
-- not arithmetic sums, so one suffix family still counts only once.
local function getFilteredAffixMasks(itemId, forgeFilter)
    local minLevel, maxLevel = forgeLevelRange(forgeFilter)
    local possible1, possible2, remaining1, remaining2 = 0, 0, 0, 0
    for level = minLevel, maxLevel do
        local ok, levelPossible1, levelPossible2, levelRemaining1, levelRemaining2 =
            getRemainingAffixMasks(itemId, level)
        if not ok then
            return false
        end
        possible1 = maskUnion(possible1, levelPossible1)
        possible2 = maskUnion(possible2, levelPossible2)
        remaining1 = maskUnion(remaining1, levelRemaining1)
        remaining2 = maskUnion(remaining2, levelRemaining2)
    end
    return true, possible1, possible2, remaining1, remaining2
end

local function getAffixCounts(itemId, forgeFilter)
    local ok, possible1, possible2, remaining1, remaining2 =
        getFilteredAffixMasks(itemId, forgeFilter)
    if not ok then
        return 0, 0
    end
    local possible = countBits32(possible1) + countBits32(possible2)
    local left = countBits32(remaining1) + countBits32(remaining2)
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
    local minLevel, maxLevel = forgeLevelRange(forgeFilter)

    -- A threshold remains useful while any included concrete tier is unfinished.
    -- Higher forged attunes include all lower tiers, so LF progress also belongs
    -- to the WF+ and TF+ filters.
    local progressLevels = 0
    for level = minLevel, maxLevel do
        local progress = safeFirst(GetItemAttuneProgress, itemId, nil, level)
        if type(progress) == "number" then
            progressLevels = progressLevels + 1
            if progress < 100 then
                return true
            end
        end
    end
    if progressLevels == (maxLevel - minLevel + 1) then
        return false
    end

    if minLevel == 0 and type(HasAttunedAnyVariantOfItem) == "function" then
        local attuned = safeFirst(HasAttunedAnyVariantOfItem, itemId)
        if attuned ~= nil then
            return not (attuned == true or attuned == 1)
        end
    end

    if type(GetItemAttuneForge) == "function" then
        local forge = safeFirst(GetItemAttuneForge, itemId)
        if type(forge) == "number" then
            return forge < maxLevel
        end
    end
    if type(HasAttunedAnyVariantEx) == "function" then
        local attuned = safeFirst(HasAttunedAnyVariantEx, itemId, maxLevel)
        if attuned ~= nil then
            return not (attuned == true or attuned == 1)
        end
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
-- Per-item snapshots (tooltip + Items panel)
-- ---------------------------------------------------------------------------
-- These reuse the same gates the scan does, but for ONE item and ON DEMAND, so
-- they store no state and respect the memory model: hovering an item or building
-- the Items list never persists anything.

-- Synastria/standard display name for an item id (custom API first), or nil.
function AF.ItemName(itemId)
    local name = safeFirst(GetItemInfoCustom, itemId)
    if (not name or name == "") and type(GetItemInfo) == "function" then
        name = (GetItemInfo(itemId))
    end
    return (name and name ~= "") and name or nil
end

-- The suffix names still left to attune on an item (possible bits minus attuned
-- bits, resolved through ItemAttuneAffix). Returns an array; when `limit` is set
-- and exceeded, it is truncated and `.more` holds the count dropped. nil if the
-- mask API is unavailable.
function AF.GetRemainingAffixNames(itemId, limit, forgeFilter)
    if type(GetItemAffixMask) ~= "function" then
        return nil
    end
    local ok, p1, p2, remaining1, remaining2 = getFilteredAffixMasks(itemId, forgeFilter)
    if not ok then
        return nil
    end
    local metaByIndex = getAffixMetaIndex()
    local names = {}
    local function collect(mask, base)
        mask = mask or 0
        if mask < 0 then
            mask = mask + 4294967296
        end
        local bitPos = 0
        while mask > 0 do
            if mask % 2 == 1 then
                local meta = metaByIndex[base + bitPos]
                names[#names + 1] = (meta and meta.name) or ("affix #" .. (base + bitPos))
            end
            mask = math.floor(mask / 2)
            bitPos = bitPos + 1
        end
    end
    collect(remaining1, 0)
    collect(remaining2, 32)
    if limit and #names > limit then
        local out = {}
        for i = 1, limit do
            out[i] = names[i]
        end
        out.more = #names - limit
        return out
    end
    return names
end

-- On-demand affix snapshot for a single item (no stored state) -- the primitive
-- the item tooltip reuses. Returns nil when the item has no random affix or the
-- custom APIs are not ready yet. `bestSource` is the densest killable source
-- (max drop chance, then spawn count) AMONG sources meeting the spawn threshold
-- (minSpawns, default = the configured minimum), so a 1-spawn mob is not offered
-- as a farming target when the player's minimum is higher; `sources` is the full
-- deduped killable-mob list regardless of threshold.
function AF.GetItemAffixInfo(itemId, minSpawns)
    itemId = tonumber(itemId)
    if not itemId or type(GetItemAffixMask) ~= "function" then
        return nil
    end
    if not itemHasRandomAffix(itemId) then
        return nil
    end
    -- Mirror the scan gates: melee weapons attune a fixed weapon-stat amount, so
    -- their random affixes never count -- the tooltip must drop them too, or it
    -- shows a phantom affix line for an item the window correctly ignores.
    if isIgnoredMeleeWeaponId(itemId) then
        return nil
    end
    local possible, left = getAffixCounts(itemId, nil)
    if possible <= 0 then
        return nil
    end
    minSpawns = tonumber(minSpawns) or tonumber(AF.GetConfig("minSpawns")) or 0
    local sources = getCreatureSources(itemId)
    local best
    for _, s in ipairs(sources) do
        if (s.spawnedCount or 0) >= minSpawns then
            if not best or s.dropProbability > best.dropProbability
                or (s.dropProbability == best.dropProbability and s.spawnedCount > best.spawnedCount) then
                best = s
            end
        end
    end
    return {
        itemId = itemId,
        possible = possible,
        left = left,
        unattuned = itemIsUnattuned(itemId),
        canCharacter = (safeFirst(CanAttuneItemHelper, itemId) or 0) > 0,
        canAccount = (safeFirst(IsAttunableBySomeone, itemId) or 0) ~= 0,
        sources = sources,
        bestSource = best,
    }
end

-- ---------------------------------------------------------------------------

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
        .. ":" .. tostring(forgeFilter and forgeFilter.level or 0)
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
        -- Central per-item record (in-memory aggregate, like mobsByKey -- never
        -- persisted). One entry per affixed item that still has affixes left and
        -- a killable source; the Items panel and per-item views read it without a
        -- rescan. Holds only small scalars + the shared category/class set (no
        -- source rows, no strings beyond category); mobs carry the id lists.
        local itemsById = {}
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

            -- Record the item once (only when it still has affixes left, since
            -- only those reach the mob lists below and the Items panel).
            if affixesLeft > 0 and not itemsById[itemId] then
                itemsById[itemId] = {
                    itemId = itemId,
                    category = category,
                    possible = value.possible,
                    affixesLeft = affixesLeft,
                    unattuned = unattuned,
                    classes = classes,
                }
            end

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
                            -- itemIds this mob drops that still have affixes left
                            -- (refs into itemsById; the Items panel reads these).
                            items = {},
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
                itemsById = itemsById,
                affixedItemsScanned = affixedItemsScanned,
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

-- "scope, Titanforged, BoE" -- the scope/forge/bind portion every caption opens
-- with. The callers wrap this with view-specific context (zone name, counts).
local function filterCaption(scope, forgeFilter, bindFilter)
    return scope
        .. ", " .. tostring((forgeFilter and forgeFilter.label) or "None")
        .. bindLabelText(bindFilter)
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

-- Returns the individual affixed ITEMS (one row per item id) that still have
-- affixes left and drop from a killable mob passing the spawn / zone-substring /
-- class filters. Pure display-time over the slice's itemsById + per-mob item
-- lists, so it never rescans. Each row carries the densest known source mob
-- (bestMob*) so a click can pin it like the Mobs panel.
--   minSpawns  : drop mobs below this reported spawn count (like BuildMobList)
--   classToken : account scope -- keep only items usable by this class (nil = all)
--   zoneNeedle : case-insensitive substring on the source mob's zone (nil = all)
function AF.BuildItemList(data, minSpawns, classToken, zoneNeedle)
    minSpawns = tonumber(minSpawns) or 1
    if minSpawns < 0 then
        minSpawns = 0
    end
    local needle = (type(zoneNeedle) == "string" and zoneNeedle ~= "") and string.lower(zoneNeedle) or nil
    local itemsById = data.itemsById or {}
    local seen = {}
    local rows = {}
    for _, mob in pairs(data.mobsByKey) do
        if mob.items and mob.spawnedCount >= minSpawns
            and (not needle or (mob.zoneName and string.find(string.lower(mob.zoneName), needle, 1, true))) then
            for _, itemId in ipairs(mob.items) do
                local rec = itemsById[itemId]
                if rec and rec.affixesLeft > 0
                    and ((not classToken) or (rec.classes and rec.classes[classToken])) then
                    local r = seen[itemId]
                    if not r then
                        r = {
                            itemId = itemId,
                            category = rec.category,
                            possible = rec.possible,
                            affixesLeft = rec.affixesLeft,
                            unattuned = rec.unattuned,
                            sourceMobs = 0,
                            bestMobName = mob.npcName,
                            bestMobNpcId = mob.npcId,
                            bestMobZone = mob.zoneName,
                            bestMobSpawns = mob.spawnedCount,
                        }
                        seen[itemId] = r
                        rows[#rows + 1] = r
                    end
                    r.sourceMobs = r.sourceMobs + 1
                    if mob.spawnedCount > (r.bestMobSpawns or 0) then
                        r.bestMobName = mob.npcName
                        r.bestMobNpcId = mob.npcId
                        r.bestMobZone = mob.zoneName
                        r.bestMobSpawns = mob.spawnedCount
                    end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.affixesLeft ~= b.affixesLeft then
            return a.affixesLeft > b.affixesLeft
        end
        return (a.itemId or 0) < (b.itemId or 0)
    end)
    return rows
end

-- Sums the slice's remaining affix value by expansion (classic/tbc/wotlk/other),
-- for the Progress dashboard. Honours the same display-time zone filter the other
-- panels use (zonePassFn) and an optional class slice. Sorted by affixes left.
function AF.BuildExpansionBreakdown(data, zonePassFn, classToken)
    local order = { "classic", "tbc", "wotlk", "unknown" }
    local labels = { classic = "Classic", tbc = "TBC", wotlk = "WotLK", unknown = "Other/unknown" }
    local acc = {}
    for _, exp in ipairs(order) do
        acc[exp] = {
            expansion = exp, label = labels[exp],
            totalAffixesLeft = 0, affixedItemsWithAffixesLeft = 0,
            unattunedAffixedItems = 0, zones = 0,
        }
    end
    for _, row in ipairs(data.rows) do
        if (not zonePassFn) or zonePassFn(row.zoneName) then
            local src = row
            if classToken then
                src = row.byClass and row.byClass[classToken]
            end
            if src and src.totalAffixesLeft > 0 then
                local _, exp = AF.ClassifyZone(row.zoneName)
                local a = acc[exp] or acc.unknown
                a.totalAffixesLeft = a.totalAffixesLeft + src.totalAffixesLeft
                a.affixedItemsWithAffixesLeft = a.affixedItemsWithAffixesLeft + src.affixedItemsWithAffixesLeft
                a.unattunedAffixedItems = a.unattunedAffixedItems + src.unattunedAffixedItems
                a.zones = a.zones + 1
            end
        end
    end
    local rows = {}
    for _, exp in ipairs(order) do
        -- Skip the "Other/unknown" bucket: zones we can't place (it still
        -- accumulates above so they aren't misfiled into a real expansion).
        if exp ~= "unknown" and acc[exp].totalAffixesLeft > 0 then
            rows[#rows + 1] = acc[exp]
        end
    end
    table.sort(rows, function(a, b) return a.totalAffixesLeft > b.totalAffixesLeft end)
    return rows
end

-- Account-wide attunement totals from the Synastria count APIs (independent of
-- the killable-mob slice), for the Progress dashboard headline. Every field is
-- optional -- the panel degrades gracefully when an API is missing.
function AF.GetAttuneProgressSummary()
    local s = {}
    if type(CalculateAttunedAffixCount) == "function" then
        s.attunedAffixes = tonumber(safeFirst(CalculateAttunedAffixCount))
    end
    if type(CalculateAttunableAffixCount) == "function" then
        s.attunableAffixes = tonumber(safeFirst(CalculateAttunableAffixCount))
    end
    if type(CalculateAttunedCount) == "function" then
        s.attunedItems = tonumber(safeFirst(CalculateAttunedCount))
    end
    if s.attunedAffixes and s.attunableAffixes and s.attunableAffixes > 0 then
        s.affixPercent = 100 * s.attunedAffixes / s.attunableAffixes
    end
    return s
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


I.Scan = {
    addBreakdownCount = addBreakdownCount,
    affixedItemValue = affixedItemValue,
    beginTask = beginTask,
    bitAnd = bitAnd,
    computeWithCache = computeWithCache,
    countBits32 = countBits32,
    endTask = endTask,
    ensureAffixedIds = ensureAffixedIds,
    EV_MODE_LABELS = EV_MODE_LABELS,
    filterCaption = filterCaption,
    findZoneRow = findZoneRow,
    getAffixCounts = getAffixCounts,
    getAffixMasks = getAffixMasks,
    getCreatureSources = getCreatureSources,
    getDropProbability = getDropProbability,
    getItemCategory = getItemCategory,
    getItemClasses = getItemClasses,
    getZoneId = getZoneId,
    getZoneName = getZoneName,
    isCreatureSource = isCreatureSource,
    isIgnoredMeleeWeapon = isIgnoredMeleeWeapon,
    isIgnoredMeleeWeaponId = isIgnoredMeleeWeaponId,
    itemHasRandomAffix = itemHasRandomAffix,
    itemIsMythic = itemIsMythic,
    itemIsUnattuned = itemIsUnattuned,
    itemMatchesBind = itemMatchesBind,
    itemMatchesScope = itemMatchesScope,
    makeProgress = makeProgress,
    newZoneRow = newZoneRow,
    printBreakdown = printBreakdown,
    reportScanError = reportScanError,
    runChunked = runChunked,
    sortedBreakdown = sortedBreakdown,
}
