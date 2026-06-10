-- AffixFinder tooltip integration
-- ---------------------------------------------------------------------------
-- Adds an AffixFinder line to item tooltips anywhere in the game (bags, bank,
-- auction house, loot, quest rewards, chat links, LootDB): how many affixes are still
-- left to attune on the item, and -- when any remain -- the best killable source
-- and the suffixes still needed. This is what makes the addon ambient: you no
-- longer have to open the window to know whether an item in front of you is
-- worth attuning and where it drops.
--
-- Everything is computed ON DEMAND via AF.GetItemAffixInfo / GetRemainingAffixNames
-- (the same gates the scan uses, but for one item), so the tooltip stores no
-- state and respects the addon's memory model. A 1-entry memo absorbs the
-- multiple OnTooltipSetItem fires a single hover produces.
-- ---------------------------------------------------------------------------

local AF = _G.AffixFinder
if not AF then
    return
end

local PREFIX_COLOR = "|cff7fffd4"   -- the addon's aquamarine
local LEFT_COLOR   = "|cff40ff40"   -- green: affixes still to gain
local DONE_COLOR   = "|cff999999"   -- grey: nothing left

-- Resolve the base item id from a concrete link (custom API first, then parse).
local function extractItemId(link)
    if type(link) ~= "string" then
        return nil
    end
    if type(CustomExtractItemId) == "function" then
        local ok, id = pcall(CustomExtractItemId, link)
        if ok and tonumber(id) then
            return tonumber(id)
        end
    end
    return tonumber(string.match(link, "Hitem:(%d+)"))
end

-- 1-entry memo: OnTooltipSetItem can fire several times for one hover, and a
-- bag full of items is hovered in quick succession, so cache the last lookup.
local lastId, lastInfo
function AF.InvalidateTooltipMemo()
    lastId = nil
    lastInfo = nil
end

local function affixInfoFor(itemId)
    if itemId == lastId then
        return lastInfo
    end
    lastId = itemId
    lastInfo = AF.GetItemAffixInfo and AF.GetItemAffixInfo(itemId) or nil
    return lastInfo
end

local function addAffixLines(tooltip, link)
    if type(AF.GetItemAffixInfo) ~= "function" then
        return
    end
    -- Honour the toggle (Interface -> AddOns -> AffixFinder). Hooks stay
    -- installed, but no line is added when the player has turned it off.
    if AF.GetConfig and AF.GetConfig("tooltips") == false then
        return
    end
    local itemId = extractItemId(link)
    if not itemId then
        return
    end
    local info = affixInfoFor(itemId)
    if not info then
        return  -- not an affixed item, or the custom APIs are not ready yet
    end

    local left = info.left or 0
    local possible = info.possible or 0
    local valueColor = (left > 0) and LEFT_COLOR or DONE_COLOR
    tooltip:AddLine(string.format("%sAffixFinder|r: %s%d|r/%d affixes left to attune",
        PREFIX_COLOR, valueColor, left, possible))

    -- The player is already inspecting the item, so the suffixes it can roll are
    -- on the tooltip in front of them -- we only add what they can't see: the
    -- best place to farm it. bestSource already respects the spawn threshold.
    if left > 0 and info.bestSource then
        local s = info.bestSource
        tooltip:AddLine(string.format("  Best source: %s -- %s (%d spawns)",
            tostring(s.zoneName or "?"), tostring(s.npcName or "?"),
            tonumber(s.spawnedCount) or 0), 0.8, 0.8, 0.8)
    end

    tooltip:Show()  -- re-fit the tooltip after adding the AffixFinder lines
end

local function hookTooltip(tooltip)
    if type(tooltip) ~= "table" or type(tooltip.HookScript) ~= "function" then
        return
    end
    tooltip:HookScript("OnTooltipSetItem", function(self)
        local _, link = self:GetItem()
        addAffixLines(self, link)
    end)
end

hookTooltip(GameTooltip)
hookTooltip(ItemRefTooltip)        -- chat-link / shift-clicked item links
hookTooltip(ShoppingTooltip1)      -- AH / equipped-comparison tooltips
hookTooltip(ShoppingTooltip2)
