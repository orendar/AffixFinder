local ADDON_NAME = "AffixFinder"
local PREFIX = "|cff7fffd4AffixFinder|r"

local AF = {}
_G.AffixFinder = AF

-- Cross-file implementation details are grouped here instead of expanding the
-- public AF API. Modules publish only the helpers required by later modules.
AF._internal = {}

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

-- New-attunables mode caches (AffixFinderAttune.lua): farm targets for items
-- the player has not attuned AT ALL yet, regardless of affixes. Same transient
-- model as the others.
--   attunableItemIds : list of item ids attunable by someone on the account --
--                      the candidate superset for both scopes. Persisted in
--                      AffixFinderDB.attunableCache like affixCache, but
--                      fingerprinted by MAX_ITEMID + character level, since
--                      attunability grows as characters level (see
--                      AffixFinderAttune.lua). attunableItemIdsLevel is the
--                      session memo's own level stamp -- the scan re-checks it
--                      so a mid-session level-up forces rediscovery.
--   attuneData       : aggregated results keyed by scope+bind+mythics.
AF.attunableItemIds = nil
AF.attunableItemIdsLevel = nil
AF.attuneData = {}

-- Kill-denominator tallies (killsByZoneNpc + zoneIdsByName), cached per
-- candidate-id list (keys: "affix", "attune") and shared by every slice built
-- from that list. They depend ONLY on static source data -- never on
-- attunement progress or the item-level filters -- so ClearDynamicData leaves
-- them alone and reusing them lets later scans skip the source walk for items
-- the value gate drops (the scan's dominant cost). Each entry is
-- { ids, kills, zoneIds }, validated by the id table's IDENTITY: a
-- rediscovery (level-up, ClearAll) makes a new table and the stale tally
-- simply stops matching. In-memory only, never persisted.
AF.killTallies = {}

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
    -- tooltips : add the AffixFinder line (affixes left + best source) to item
    --            tooltips everywhere. On by default; off for players who find it
    --            intrusive. Read live by AffixFinderTooltip.lua (hooks stay
    --            installed; the line is just skipped when this is false).
    tooltips = true,
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

local FORGE_NONE = { level = 0, minLevel = 0, maxLevel = 0, label = "None" }
local FORGE_FLAGS = {
    none = FORGE_NONE,
    base = FORGE_NONE,
    tf = { level = 1, minLevel = 1, maxLevel = 3, label = "Titanforged+" },
    wf = { level = 2, minLevel = 2, maxLevel = 3, label = "Warforged+" },
    lf = { level = 3, minLevel = 3, maxLevel = 3, label = "Lightforged" },
}

-- Exposed so the UI can present the same forge thresholds the slash command
-- accepts without duplicating the table. `base` remains an alias for `none`.
AF.FORGE_FLAGS = FORGE_FLAGS

-- Chance that one dropped item rolls AT each forge level (Synastria base
-- rates, before forge power): TF 5%, WF 0.7%, LF 0.1%. The remaining ~94.2%
-- of drops are unforged. Forge EV math must weight forged thresholds by these
-- -- a TF+ drop is ~17x rarer than "any drop".
local FORGE_BASE_RATES = { [1] = 0.05, [2] = 0.007, [3] = 0.001 }
AF.FORGE_BASE_RATES = FORGE_BASE_RATES

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
    for _, data in pairs(AF.attuneData or {}) do
        data.dirty = true
    end
    if type(AF.InvalidateTooltipMemo) == "function" then
        AF.InvalidateTooltipMemo()
    end
end

-- Full reset: also re-discover the affixed-item list (use after a data reload).
-- Drops the cross-session persisted id list too, so a server data reload that
-- left MAX_ITEMID unchanged (fingerprint still "matching") is forced to rescan.
function AF.ClearAll()
    AF.affixedItemIds = nil
    AF.zoneData = {}
    AF.resistData = {}
    AF.attunableItemIds = nil
    AF.attunableItemIdsLevel = nil
    AF.attuneData = {}
    AF.killTallies = {}
    if type(_G.AffixFinderDB) == "table" then
        _G.AffixFinderDB.affixCache = nil
        _G.AffixFinderDB.attunableCache = nil
    end
    if type(AF.InvalidateTooltipMemo) == "function" then
        AF.InvalidateTooltipMemo()
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


-- Forge Power (FP): a prestige stat that multiplies every forge proc rate by
-- (1 + FP/100) -- 100% FP doubles them (10% TF / 1.4% WF / 0.2% LF). Only
-- prestiged characters have it: CMCGetMultiClassEnabled() == 2 marks prestige,
-- and GetCustomGameData(29, 1494) returns the active FP percent (the same
-- reads ScootsStats uses for its Forge Power stat line). Returns 0 for
-- non-prestiged characters or when the APIs are unavailable.
function AF.GetForgePower()
    local prestiged = tonumber(safeFirst(_G.CMCGetMultiClassEnabled)) or 1
    if prestiged ~= 2 then
        return 0
    end
    local fp = tonumber(safeFirst(_G.GetCustomGameData, 29, 1494))
    if not fp or fp < 0 then
        return 0
    end
    return fp
end

-- Probability that one dropped copy of an item rolls at or above the filter's
-- forge floor. Forge filters are one-way thresholds (TF+ = levels 1..3), and
-- attuning ANY included level satisfies the threshold, so the qualifying mass
-- is the SUM of the included levels' roll rates, scaled by forge power.
-- The base filter returns 1: every drop, forged or not, attunes base affixes.
-- forgePower (percent) is optional; omitted = read live via AF.GetForgePower().
function AF.GetForgeDropChance(forgeFilter, forgePower)
    local minLevel = tonumber(forgeFilter and (forgeFilter.minLevel or forgeFilter.level)) or 0
    if minLevel <= 0 then
        return 1
    end
    local chance = 0
    for level = minLevel, 3 do
        chance = chance + (FORGE_BASE_RATES[level] or 0)
    end
    local fp = tonumber(forgePower)
    if fp == nil then
        fp = AF.GetForgePower()
    end
    if fp > 0 then
        chance = chance * (1 + fp / 100)
    end
    return math.min(chance, 1)
end


local I = AF._internal
I.ADDON_NAME = ADDON_NAME
I.PREFIX = PREFIX
I.FORGE_NONE = FORGE_NONE
I.FORGE_FLAGS = FORGE_FLAGS
I.OBJTYPE_CREATURE = OBJTYPE_CREATURE
I.NON_KILL_SRC_TYPES = NON_KILL_SRC_TYPES
I.chat = chat
I.safeCall = safeCall
I.safeFirst = safeFirst
I.isCustomReady = isCustomReady
