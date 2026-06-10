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

local FORGE_NONE = { level = 0, label = "None" }
local FORGE_FLAGS = {
    none = FORGE_NONE,
    base = FORGE_NONE,
    tf = { level = 1, label = "Titanforged" },
    wf = { level = 2, label = "Warforged" },
    lf = { level = 3, label = "Lightforged" },
}

-- Exposed so the UI can present the same exact forge-level filters the slash
-- command accepts without duplicating the table. `base` remains an alias for
-- `none` for backwards-compatible slash usage.
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
    if type(_G.AffixFinderDB) == "table" then
        _G.AffixFinderDB.affixCache = nil
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
