-- AffixFinder UI
-- ---------------------------------------------------------------------------
-- A single filterable browser window over the data the core already computes.
--
-- UX model:
--   * Shared filter bar (scope + forge) sits at the top because those filters
--     are cross-cutting: every panel shows the same scope/forge slice, and the
--     core caches results per scope+forge, so re-selecting one is instant.
--   * Panels are tabs (Zones / Mobs / Current Zone). They are alternative views
--     of the *same* filtered dataset, so switching tabs never rescans.
--   * The list is virtualized (a fixed pool of row frames over a FauxScrollFrame)
--     so ~200 zones / thousands of mobs cost a handful of frames, not thousands
--     -- this keeps the addon inside its memory budget.
--   * Panel-specific controls (EV mode, min spawns) live next to the list they
--     affect and only re-sort/re-render -- they never trigger a scan, matching
--     the core's "options never rescan" design.
--
-- Extensibility: a panel is just an entry in the PANELS registry below. Add a
-- table with columns + getRows + (optional) summary/controls/tooltip and a tab
-- appears automatically. New item-level filters follow the bind segmented
-- control: a control in the filter bar plus a field threaded through UI.filters
-- into core's ComputeZoneData cache key.
--
-- No SavedVariables for SCAN DATA: the scanned item graph and aggregates reset
-- each session by design, to preserve the addon's "stores nothing heavy /
-- instant logout" guarantee. The only persisted state is a handful of config
-- scalars plus a tiny bit of window/minimap layout (AffixFinderDB.ui: window
-- point + minimap angle) -- a few bytes, not the item graph. Layout persistence
-- is opt-in cheap: it has none of the logout cost the item graph would.
-- ---------------------------------------------------------------------------

local AF = _G.AffixFinder
if not AF then
    return
end

local ADDON_NAME = "AffixFinder"

local UI = {}
AF.UI = UI

-- Tiny persisted layout (window position + minimap angle) in AffixFinderDB.ui.
-- Read-guarded because the SavedVariable may not exist until ADDON_LOADED.
local function SavedLayout()
    local db = _G.AffixFinderDB
    if type(db) ~= "table" then return nil end
    return db.ui
end

local function LayoutTable()
    local db = _G.AffixFinderDB
    if type(db) ~= "table" then
        db = {}
        _G.AffixFinderDB = db
    end
    if type(db.ui) ~= "table" then
        db.ui = {}
    end
    return db.ui
end

-- ---------------------------------------------------------------------------
-- Layout constants
-- ---------------------------------------------------------------------------
local FRAME_W = 600
local FRAME_H = 588
local PAD = 14
local INNER_W = FRAME_W - PAD * 2
local SCROLLBAR_W = 26          -- room reserved on the right for the scrollbar
local LIST_W = INNER_W - SCROLLBAR_W
local NUM_ROWS = 15
local ROW_H = 22
local MAX_COLS = 5

local TITLE_COLOR = { 0.49, 1.0, 0.83 }  -- the "|cff7fffd4" aquamarine of the addon

-- ---------------------------------------------------------------------------
-- Small widget helpers
-- ---------------------------------------------------------------------------

local function MakeText(parent, layer, font, justify)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlightSmall")
    if justify then
        fs:SetJustifyH(justify)
    end
    return fs
end

-- A row of mutually-exclusive buttons (segmented control). `options` is a list
-- of { value, text, width }. onSelect(value) fires when the selection changes.
-- The selected button is shown locked in its pushed state.
local function CreateSegmented(parent, options, onSelect)
    -- Buttons are created here but positioned by the caller (each group is
    -- anchored to its row label in UI.Build), so this helper doesn't lay them out.
    local seg = { buttons = {}, value = nil }
    for _, opt in ipairs(options) do
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetWidth(opt.width or 64)
        b:SetHeight(20)
        b:SetText(opt.text)
        b.value = opt.value
        b:SetScript("OnClick", function()
            seg:SetValue(b.value, true)
        end)
        seg.buttons[#seg.buttons + 1] = b
    end

    function seg:SetValue(value, fireCallback)
        self.value = value
        for _, b in ipairs(self.buttons) do
            if b.value == value then
                b:SetButtonState("PUSHED", true)
                b:LockHighlight()
            else
                b:SetButtonState("NORMAL")
                b:UnlockHighlight()
            end
        end
        if fireCallback and onSelect then
            onSelect(value)
        end
    end

    -- Enable/disable the whole group (used to grey out filters a panel ignores).
    -- Re-applies the current selection so the pushed/locked look is restored.
    function seg:SetEnabled(enabled)
        for _, b in ipairs(self.buttons) do
            if enabled then b:Enable() else b:Disable() end
        end
        if enabled then
            self:SetValue(self.value, false)
        end
    end

    return seg
end

-- A row of independently-toggleable buttons (multi-select). `options` is a list
-- of { value, text, width }. `selectedSet` is the value->true table the control
-- reads and mutates *in place* (so it can be a UI.filters field shared by the
-- filter helpers). onChange(seg) fires after any toggle. At least one button
-- must stay selected (toggling off the last is ignored), so a filter never
-- collapses to "show nothing".
local function CreateMultiSegmented(parent, options, selectedSet, onChange)
    -- As with CreateSegmented, buttons are positioned by the caller (anchored to
    -- the row label in UI.Build); this helper only creates them.
    local seg = { buttons = {}, selected = selectedSet }
    for _, opt in ipairs(options) do
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetWidth(opt.width or 60)
        b:SetHeight(20)
        b:SetText(opt.text)
        b.value = opt.value
        b:SetScript("OnClick", function() seg:Toggle(b.value) end)
        seg.buttons[#seg.buttons + 1] = b
    end

    function seg:Apply()
        for _, b in ipairs(self.buttons) do
            if self.selected[b.value] then
                b:SetButtonState("PUSHED", true)
                b:LockHighlight()
            else
                b:SetButtonState("NORMAL")
                b:UnlockHighlight()
            end
        end
    end

    function seg:Count()
        local n = 0
        for _, on in pairs(self.selected) do
            if on then n = n + 1 end
        end
        return n
    end

    function seg:Toggle(value)
        if self.selected[value] then
            if self:Count() <= 1 then
                return  -- keep at least one selected
            end
            self.selected[value] = nil
        else
            self.selected[value] = true
        end
        self:Apply()
        if onChange then onChange(self) end
    end

    -- Enable/disable the whole group (see CreateSegmented:SetEnabled).
    function seg:SetEnabled(enabled)
        for _, b in ipairs(self.buttons) do
            if enabled then b:Enable() else b:Disable() end
        end
        if enabled then self:Apply() end
    end

    seg:Apply()
    return seg
end

-- ---------------------------------------------------------------------------
-- Filters (data-driven; shared across every panel)
-- ---------------------------------------------------------------------------
-- scope/forge are single-select; bind/category/expansion are multi-select sets
-- (value -> true). Defaults: character, non-forged, and everything else on.
--
-- scope/forge/bind are item-level: they change which items count, so they are
-- part of the core's scan/cache key (changing one re-scans-or-hits-cache).
-- category/expansion are zone-level properties (see AF.ClassifyZone), so they
-- are applied to the row list at display time and never trigger a scan.

local CATEGORY_ORDER = { "dungeon", "raid", "world" }
local EXPANSION_ORDER = { "classic", "tbc", "wotlk" }
local CATEGORY_LABELS = { dungeon = "Dungeon", raid = "Raid", world = "World" }
local EXPANSION_LABELS = { classic = "Classic", tbc = "TBC", wotlk = "WotLK" }

UI.filters = {
    scope = "character",
    forge = "none",
    bind = { bop = true, boe = true },
    category = { dungeon = true, raid = true, world = true },
    expansion = { classic = true, tbc = true, wotlk = true },
    -- class: nil = all classes (account totals). A class token (e.g. "WARRIOR")
    -- re-slices the Zones/Mobs/Current panels to that class. Account scope only;
    -- zone-level (display-time) like category/expansion -- it never rescans,
    -- because the account scan already computed every class's sub-tallies.
    class = nil,
    -- zone: nil = all zones. A substring (set by typing in the Mobs panel's Zone
    -- box, or the full zone name when a Zones row is clicked) drills the Mobs
    -- panel down to matching zones. Display-time, MOBS-ONLY -- it never rescans
    -- and never narrows the Zones list itself. Matched case-insensitively.
    zone = nil,
    -- item: nil = all items. The Items panel's search substring, matched against
    -- the item NAME or its best-mob zone (an item view should search by item, not
    -- only zone). Display-time, ITEMS-ONLY; kept separate from `zone` so the two
    -- panels' search boxes never contaminate each other.
    item = nil,
}

local function CurrentForgeFilter()
    local key = UI.filters.forge or "none"
    return AF.FORGE_FLAGS and (AF.FORGE_FLAGS[key] or AF.FORGE_FLAGS.none) or nil
end

-- Reduce the bind set to core's single bindFilter: nil (both), "bop", or "boe".
local function CurrentBindFilter()
    local b = UI.filters.bind
    local bop, boe = b.bop and true or false, b.boe and true or false
    if bop and boe then return nil end
    if bop then return "bop" end
    if boe then return "boe" end
    return nil
end

local function allSelected(set, order)
    for _, k in ipairs(order) do
        if not set[k] then return false end
    end
    return true
end

-- Whether a zone passes the (display-time) category + expansion filters.
-- Unknown classification passes either dimension, so unclassifiable zones are
-- never silently hidden.
local function ZonePasses(zoneName)
    local catSet, expSet = UI.filters.category, UI.filters.expansion
    local catAll = allSelected(catSet, CATEGORY_ORDER)
    local expAll = allSelected(expSet, EXPANSION_ORDER)
    if catAll and expAll then
        return true
    end
    local cat, exp = AF.ClassifyZone(zoneName)
    local catOk = catAll or cat == "unknown" or catSet[cat]
    local expOk = expAll or exp == "unknown" or expSet[exp]
    return catOk and expOk
end

-- Short "; a+b" style note for a multi-select set when it isn't fully selected.
local function setNote(set, order, labels)
    if allSelected(set, order) then
        return ""
    end
    local parts = {}
    for _, k in ipairs(order) do
        if set[k] then parts[#parts + 1] = labels[k] end
    end
    return "; " .. table.concat(parts, "+")
end

local function FilterCaption()
    local scope = UI.filters.scope
    local ff = CurrentForgeFilter()
    local bindLabel = AF.BindLabel and AF.BindLabel(CurrentBindFilter())
    local classNote = ""
    if UI.filters.class then
        classNote = ", " .. AF.ClassDisplayName(UI.filters.class)
    end
    return scope
        .. ", " .. tostring((ff and ff.label) or "None")
        .. (bindLabel and (", " .. bindLabel) or "")
        .. classNote
        .. setNote(UI.filters.category, CATEGORY_ORDER, CATEGORY_LABELS)
        .. setNote(UI.filters.expansion, EXPANSION_ORDER, EXPANSION_LABELS)
end

-- ---------------------------------------------------------------------------
-- Panels registry
-- ---------------------------------------------------------------------------
-- Each panel:
--   id, title
--   columns      : list of { title, width, justify, numeric, value(e), text(e) }
--   defaultSort  : column index to sort by initially (numeric cols sort desc)
--   getRows(data): -> array of entry objects
--   summary(data, n) (optional): caption shown above the list
--   tooltip(entry)   (optional): array of {left, right?} lines for hover
--   buildControls(strip) (optional): create panel-specific controls once

local function num(v) return v or 0 end

-- Give an EditBox a flat dark field with a 1px solid border. Used instead of
-- InputBoxTemplate, whose middle/corner border textures tile and show seams at
-- our widths (a bright vertical "cut" mid-field). A solid edge has no pieces to
-- seam, so it renders cleanly at any size.
local function ApplyFlatEditBoxStyle(eb)
    eb:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    eb:SetBackdropColor(0, 0, 0, 0.6)
    eb:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
end

-- Shared panel control strip: a search substring box (with Clear, and an
-- optional "Curr" current-zone shortcut) and a Min-spawns box. `filterKey` is
-- the UI.filters field the box drives ("zone" for Mobs, "item" for Items),
-- `label` / `placeholderText` label it. `withCurr` adds the current-zone button
-- (only meaningful for a zone search). Used by the Mobs and Items panels; sets
-- panel._edit / panel._searchEdit / panel._searchKey / panel._updatePlaceholder.
local function BuildSearchSpawnControls(panel, strip, label, filterKey, placeholderText, withCurr)
    panel.minSpawns = AF.GetConfig("minSpawns")  -- seed from the saved default
    panel._searchKey = filterKey

    local zoneLabel = MakeText(strip, "OVERLAY", "GameFontNormalSmall")
    zoneLabel:SetPoint("LEFT", 0, 0)
    zoneLabel:SetText(label)

    -- A plain backdrop EditBox rather than InputBoxTemplate: the template's
    -- middle border texture TILES, so at this width a tile seam lands mid-box and
    -- shows as a bright vertical "cut". A stretched backdrop renders continuously
    -- at any width.
    local zoneEdit = CreateFrame("EditBox", nil, strip)
    zoneEdit:SetAutoFocus(false)
    zoneEdit:SetMaxLetters(40)
    zoneEdit:SetWidth(150)
    zoneEdit:SetHeight(18)
    zoneEdit:SetPoint("LEFT", zoneLabel, "RIGHT", 8, 0)
    zoneEdit:SetFontObject(GameFontHighlightSmall)
    zoneEdit:SetTextInsets(6, 6, 0, 0)
    ApplyFlatEditBoxStyle(zoneEdit)

    local placeholder = MakeText(zoneEdit, "OVERLAY", "GameFontDisableSmall", "LEFT")
    placeholder:SetPoint("LEFT", 6, 0)
    placeholder:SetText(placeholderText or "all")
    local function updatePlaceholder()
        if zoneEdit:GetText() == "" and not zoneEdit:HasFocus() then
            placeholder:Show()
        else
            placeholder:Hide()
        end
    end

    local function commitZone()
        local txt = zoneEdit:GetText() or ""
        txt = string.gsub(txt, "^%s+", "")
        txt = string.gsub(txt, "%s+$", "")
        UI.filters[filterKey] = (txt ~= "") and txt or nil
        zoneEdit:ClearFocus()
        updatePlaceholder()
        UI.RefreshActivePanel()
    end
    zoneEdit:SetScript("OnEnterPressed", commitZone)
    zoneEdit:SetScript("OnEditFocusLost", commitZone)
    zoneEdit:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    zoneEdit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)

    local clearBtn = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    clearBtn:SetSize(46, 18)
    clearBtn:SetPoint("LEFT", zoneEdit, "RIGHT", 4, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        zoneEdit:SetText("")
        UI.filters[filterKey] = nil
        zoneEdit:ClearFocus()
        updatePlaceholder()
        UI.RefreshActivePanel()
    end)

    local lastAnchor = clearBtn
    if withCurr then
        local currBtn = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
        currBtn:SetSize(46, 18)
        currBtn:SetPoint("LEFT", clearBtn, "RIGHT", 4, 0)
        currBtn:SetText("Curr")
        currBtn:SetScript("OnClick", function()
            local zone = AF.GetCurrentZoneName()
            zoneEdit:SetText(zone or "")
            UI.filters[filterKey] = (zone and zone ~= "") and zone or nil
            zoneEdit:ClearFocus()
            updatePlaceholder()
            UI.RefreshActivePanel()
        end)
        currBtn:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_TOP")
            GameTooltip:AddLine("Filter to your current zone", 1, 1, 1)
            GameTooltip:AddLine(AF.GetCurrentZoneName() or "?", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        currBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        lastAnchor = currBtn
    end

    local spawnLabel = MakeText(strip, "OVERLAY", "GameFontNormalSmall")
    spawnLabel:SetPoint("LEFT", lastAnchor, "RIGHT", 18, 0)
    spawnLabel:SetText("Min spawns:")

    local edit = CreateFrame("EditBox", nil, strip)
    edit:SetAutoFocus(false)
    edit:SetNumeric(true)
    edit:SetMaxLetters(4)
    edit:SetWidth(40)
    edit:SetHeight(18)
    edit:SetPoint("LEFT", spawnLabel, "RIGHT", 8, 0)
    edit:SetFontObject(GameFontHighlightSmall)
    edit:SetTextInsets(5, 5, 0, 0)
    edit:SetJustifyH("CENTER")
    ApplyFlatEditBoxStyle(edit)
    edit:SetText(tostring(panel.minSpawns))
    local function commit()
        local n = tonumber(edit:GetText())
        if not n or n < 0 then n = 0 end
        panel.minSpawns = n
        panel._userSetSpawns = true  -- stop following the saved default this session
        edit:SetText(tostring(n))
        edit:ClearFocus()
        UI.RefreshActivePanel()
    end
    edit:SetScript("OnEnterPressed", commit)
    edit:SetScript("OnEditFocusLost", commit)

    local hint = MakeText(strip, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", edit, "RIGHT", 8, 0)
    hint:SetText("(0 = include sparse mobs)")

    panel._edit = edit
    panel._searchEdit = zoneEdit
    panel._updatePlaceholder = updatePlaceholder
end

local function SyncSearchSpawnControls(panel)
    if panel._edit then panel._edit:SetText(tostring(panel.minSpawns)) end
    if panel._searchEdit then
        panel._searchEdit:SetText(UI.filters[panel._searchKey] or "")
        if panel._updatePlaceholder then panel._updatePlaceholder() end
    end
end

local PANELS = {}

-- --- Panel: Zones (ranked by remaining affix value) -----------------------
PANELS[#PANELS + 1] = {
    id = "zones",
    title = "Zones",
    defaultSort = 2,
    zoneField = "zoneName",  -- honour the display-time category/expansion filters
    columns = {
        { title = "Zone", width = 230, justify = "LEFT",
          value = function(e) return e.zoneName or "" end },
        { title = "Affixes left", width = 92, justify = "RIGHT", numeric = true,
          headerTooltip = "Total affixes still left to attune across every affixed item killable mobs drop in this zone.",
          value = function(e) return num(e.totalAffixesLeft) end },
        { title = "Items w/ left", width = 110, justify = "RIGHT", numeric = true,
          headerTooltip = "Affixed items dropped here that still have at least one affix left to attune.",
          value = function(e) return num(e.affixedItemsWithAffixesLeft) end },
        { title = "Unattuned", width = 110, justify = "RIGHT", numeric = true,
          headerTooltip = "Affixed items dropped here that you have not attuned at all yet.",
          value = function(e) return num(e.unattunedAffixedItems) end },
    },
    getRows = function(data)
        return AF.BuildZoneRankings(data, UI.filters.class)
    end,
    -- Clicking a zone drills the Mobs panel down to that zone (display-time).
    onRowClick = function(entry)
        if not entry.zoneName then return end
        UI.filters.zone = entry.zoneName
        local mi = UI.PanelIndexById("mobs")
        if mi then UI.SelectPanel(mi) end  -- shows + syncs Mobs controls, refreshes
    end,
    summary = function(data, n)
        return string.format(
            "%d zones with remaining affix value (%s, mob sources) -- click a zone to see its mobs",
            n, FilterCaption())
    end,
    tooltip = function(e)
        local lines = { { left = e.zoneName, right = string.format("%d affixes left", num(e.totalAffixesLeft)) } }
        local bd = e.breakdown and e.breakdown.totalAffixesLeft
        for _, r in ipairs(AF.SortedBreakdown(bd)) do
            lines[#lines + 1] = { left = "  " .. r.key, right = tostring(r.value) }
        end
        if #lines == 1 then
            lines[#lines + 1] = { left = "  (no category breakdown)" }
        end
        return lines
    end,
}

-- --- Panel: Mobs (individual mobs ranked by expected useful drops/1000) ----
-- One row per NPC. Every column is a per-mob value (nothing is summed across
-- mobs), so "Affixes left" is the remaining affixes across the items THIS mob
-- drops, not a cross-mob zone total.
PANELS[#PANELS + 1] = {
    id = "mobs",
    title = "Mobs",
    defaultSort = 3,
    zoneField = "zoneName",  -- honour the display-time category/expansion filters
    -- Default minimum spawn count comes from the saved setting (see
    -- AF.GetConfig); buildControls seeds it and UI.ApplyConfig keeps it in sync
    -- until the user overrides it via the in-window box this session.
    minSpawns = 5,           -- hide the long tail of rare/sparse spawns by default
    columns = {
        { title = "Mob", width = 168, justify = "LEFT",
          value = function(e) return e.npcName or "?" end },
        { title = "Zone", width = 150, justify = "LEFT",
          value = function(e) return e.zoneName or "" end },
        { title = "Drops/1k", width = 76, justify = "RIGHT", numeric = true,
          headerTooltip = "Expected useful affix drops per 1000 kills of this mob: drop chance x (affixes left / possible affixes), summed over the items it drops.",
          value = function(e) return num(e.evPerKill) * 1000 end,
          text = function(e) return string.format("%.2f", num(e.evPerKill) * 1000) end },
        { title = "Spawns", width = 64, justify = "RIGHT", numeric = true,
          headerTooltip = "Reported spawn count for this mob -- higher means a denser pack to farm. The Min spawns box hides mobs below its value.",
          value = function(e) return num(e.spawnedCount) end },
        { title = "Items", width = 56, justify = "RIGHT", numeric = true,
          headerTooltip = "Affixed items this mob drops that still have affixes left (a per-mob count -- nothing is summed across mobs).",
          value = function(e) return num(e.itemsDropped) end },
    },
    getRows = function(data, panel)
        local rows = AF.BuildMobList(data, panel.minSpawns, UI.filters.class)
        -- Mobs-only zone filter (case-insensitive substring on zoneName). The
        -- shared category/expansion pass in RefreshActivePanel still applies on
        -- top of this; the Zones list itself is never narrowed.
        local zf = UI.filters.zone
        if zf and zf ~= "" then
            local needle = string.lower(zf)
            local filtered = {}
            for _, e in ipairs(rows) do
                if e.zoneName and string.find(string.lower(e.zoneName), needle, 1, true) then
                    filtered[#filtered + 1] = e
                end
            end
            rows = filtered
        end
        return rows
    end,
    summary = function(data, n, panel)
        local zf = UI.filters.zone
        local zonePart = (zf and zf ~= "") and string.format(" in zones matching \"%s\"", zf) or ""
        local warpPart = AF.GetConfig("automaticWarp") and " -- click a mob to pin/open map" or " -- click a mob to pin it"
        return string.format("%d mobs%s (%s; min spawns %d) -- expected useful affix drops per 1000 kills%s",
            n, zonePart, FilterCaption(), panel.minSpawns, warpPart)
    end,
    onRowClick = function(entry)
        if AF.TryWarpToMob then
            AF.TryWarpToMob(entry)
        end
    end,
    tooltip = function(e)
        local lines = {
            { left = e.npcName or "?", right = e.zoneName },
            { left = "  Useful affix drops / 1000 kills", right = string.format("%.2f", num(e.evPerKill) * 1000) },
            { left = "  Reported spawn count", right = tostring(num(e.spawnedCount)) },
            { left = "  Affixed items it drops (with affixes left)", right = tostring(num(e.itemsDropped)) },
            { left = "  Remaining affixes across those items", right = tostring(num(e.affixesLeft)) },
        }
        if AF.GetConfig("automaticWarp") then
            lines[#lines + 1] = { left = "  Click", right = "pin latest target and open t3 map" }
        else
            lines[#lines + 1] = { left = "  Click", right = "pin latest target on the map" }
        end
        return lines
    end,
    buildControls = function(panel, strip)
        BuildSearchSpawnControls(panel, strip, "Zone:", "zone", "all zones", true)
    end,
    syncControls = SyncSearchSpawnControls,
}

-- --- Panel: Items (the actual affixed items still worth farming) ----------
-- One row per affixed item that still has affixes left and drops from a killable
-- mob passing the filters. The drill-down target of Zones -> Mobs -> Items: it
-- shares the Mobs panel's Zone box + Min-spawns control (and the click-to-pin
-- best mob), so a Zones-row click flows straight through to "what do I farm here
-- and which suffix do I still need". Names resolve lazily at render.
PANELS[#PANELS + 1] = {
    id = "items",
    title = "Items",
    defaultSort = 3,
    zoneField = "bestMobZone",  -- honour the display-time category/expansion filters
    minSpawns = 5,
    columns = {
        { title = "Item", width = 214, justify = "LEFT",
          value = function(e) return e._name or ("item " .. tostring(e.itemId)) end },
        { title = "Category", width = 92, justify = "LEFT",
          value = function(e) return e.category or "" end },
        { title = "Affixes left", width = 86, justify = "RIGHT", numeric = true,
          headerTooltip = "Suffixes still left to attune on this item (possible suffixes minus the ones you've attuned).",
          value = function(e) return num(e.affixesLeft) end },
        { title = "Possible", width = 66, justify = "RIGHT", numeric = true,
          headerTooltip = "Total suffixes this item can roll.",
          value = function(e) return num(e.possible) end },
        { title = "Best mob", width = 128, justify = "LEFT",
          headerTooltip = "Densest mob (by spawn count) that drops this item among the zones passing your filters. Click the row to pin it on the map.",
          value = function(e) return e.bestMobName or "" end },
    },
    getRows = function(data, panel)
        -- No zone needle into BuildItemList: this panel searches by item name (or
        -- zone) below, so all items pass the spawn/class gate first.
        local rows = AF.BuildItemList(data, panel.minSpawns, UI.filters.class, nil)
        -- Resolve display names once per build (the comparator tiebreaks on them
        -- and the cells show them); the list itself is virtualized.
        for _, e in ipairs(rows) do
            if e._name == nil then
                e._name = (AF.ItemName and AF.ItemName(e.itemId)) or ("item " .. tostring(e.itemId))
            end
        end
        -- Search box (UI.filters.item): match the item NAME only. This is an
        -- item view -- the player is looking for an item and will go wherever the
        -- addon sends them, so matching the zone too (e.g. "pen" hitting Hellfire
        -- Peninsula drops) would only add confusing, irrelevant rows.
        local needle = UI.filters.item
        if needle and needle ~= "" then
            needle = string.lower(needle)
            local filtered = {}
            for _, e in ipairs(rows) do
                if string.find(string.lower(e._name or ""), needle, 1, true) then
                    filtered[#filtered + 1] = e
                end
            end
            rows = filtered
        end
        return rows
    end,
    onRowClick = function(entry)
        if AF.TryWarpToMob and entry.bestMobNpcId then
            AF.TryWarpToMob({
                npcId = entry.bestMobNpcId,
                npcName = entry.bestMobName,
                zoneName = entry.bestMobZone,
            })
        end
    end,
    summary = function(data, n, panel)
        local sf = UI.filters.item
        local searchPart = (sf and sf ~= "") and string.format(" matching \"%s\"", sf) or ""
        local warpPart = AF.GetConfig("automaticWarp") and " -- click an item to pin its best mob/open map" or " -- click an item to pin its best mob"
        return string.format("%d items with affixes left%s (%s; min spawns %d)%s",
            n, searchPart, FilterCaption(), panel.minSpawns, warpPart)
    end,
    tooltip = function(e)
        local lines = {
            { left = e._name or ("item " .. tostring(e.itemId)),
              right = string.format("%d/%d affixes left", num(e.affixesLeft), num(e.possible)) },
            { left = "  Category", right = e.category or "?" },
            { left = "  Best mob", right = string.format("%s (%s, %d spawns)",
                tostring(e.bestMobName or "?"), tostring(e.bestMobZone or "?"), num(e.bestMobSpawns)) },
            { left = "  Mobs that drop it (this filter)", right = tostring(num(e.sourceMobs)) },
        }
        local names = AF.GetRemainingAffixNames
            and AF.GetRemainingAffixNames(e.itemId, 10, CurrentForgeFilter())
        if names and #names > 0 then
            lines[#lines + 1] = { left = "  Suffixes still needed:" }
            for _, nm in ipairs(names) do
                lines[#lines + 1] = { left = "    " .. nm }
            end
            if names.more then
                lines[#lines + 1] = { left = string.format("    +%d more", names.more) }
            end
        end
        return lines
    end,
    buildControls = function(panel, strip)
        BuildSearchSpawnControls(panel, strip, "Search:", "item", "item name")
    end,
    syncControls = SyncSearchSpawnControls,
}

-- --- Panel: Current Zone (per-category breakdown for the player's zone) -----
PANELS[#PANELS + 1] = {
    id = "current",
    title = "Current Zone",
    defaultSort = 4,
    columns = {
        { title = "Category", width = 226, justify = "LEFT",
          value = function(e) return e.category or "" end },
        { title = "Unattuned", width = 108, justify = "RIGHT", numeric = true,
          headerTooltip = "Affixed items in this category, here, you have not attuned at all yet.",
          value = function(e) return num(e.unattuned) end },
        { title = "Items w/ left", width = 108, justify = "RIGHT", numeric = true,
          headerTooltip = "Affixed items in this category that still have affixes left to attune.",
          value = function(e) return num(e.withLeft) end },
        { title = "Affixes left", width = 96, justify = "RIGHT", numeric = true,
          headerTooltip = "Total affixes left to attune across this category in the current zone.",
          value = function(e) return num(e.affixesLeft) end },
    },
    getRows = function(data, panel)
        local zoneName = AF.GetCurrentZoneName()
        panel._zoneName = zoneName
        local row = AF.FindZoneRow(data, zoneName)
        -- When a class is selected, show that class's slice of this zone; the
        -- per-class tally mirrors the zone row shape, so the rest is identical.
        local src = row
        if row and UI.filters.class then
            src = row.byClass and row.byClass[UI.filters.class]
        end
        panel._row = src
        if not src then
            return {}
        end
        -- Merge the three per-category breakdowns into one row per category.
        local byCat = {}
        local order = {}
        local function bucket(cat)
            if not byCat[cat] then
                byCat[cat] = { category = cat, unattuned = 0, withLeft = 0, affixesLeft = 0 }
                order[#order + 1] = byCat[cat]
            end
            return byCat[cat]
        end
        for _, r in ipairs(AF.SortedBreakdown(src.breakdown.unattunedAffixedItems)) do
            bucket(r.key).unattuned = r.value
        end
        for _, r in ipairs(AF.SortedBreakdown(src.breakdown.affixedItemsWithAffixesLeft)) do
            bucket(r.key).withLeft = r.value
        end
        for _, r in ipairs(AF.SortedBreakdown(src.breakdown.totalAffixesLeft)) do
            bucket(r.key).affixesLeft = r.value
        end
        return order
    end,
    summary = function(data, n, panel)
        local row = panel._row
        if not row then
            return string.format("%s: no affixes obtainable from killable mobs here (%s)",
                panel._zoneName or "?", FilterCaption())
        end
        return string.format("%s (%s): %d unattuned, %d items w/ affixes left, %d affixes left",
            panel._zoneName or "?", FilterCaption(),
            num(row.unattunedAffixedItems), num(row.affixedItemsWithAffixesLeft), num(row.totalAffixesLeft))
    end,
}

-- --- Panel: Classes (which class has the most affixes left to attune) ------
-- Account scope only. Sums each class's remaining affix value over the zones
-- that pass the active category/expansion filters, so it answers both "which
-- class should I main for affixes" and (with those filters narrowed) "best
-- class for this content". No zoneField: it filters zones internally via
-- ZonePasses, since its rows are classes rather than zones.
PANELS[#PANELS + 1] = {
    id = "classes",
    title = "Classes",
    defaultSort = 2,
    columns = {
        { title = "Class", width = 150, justify = "LEFT",
          value = function(e) return e.className or "" end,
          text = function(e)
              return (AF.ClassColorCode(e.classToken) or "") .. (e.className or "") .. "|r"
          end },
        { title = "Affixes left", width = 100, justify = "RIGHT", numeric = true,
          headerTooltip = "Total affixes the account can still attune on this class, summed over the zones passing the Source/Expansion filters.",
          value = function(e) return num(e.totalAffixesLeft) end },
        { title = "Items w/ left", width = 110, justify = "RIGHT", numeric = true,
          headerTooltip = "Affixed items with affixes left that this class can use (classes overlap, so these don't partition the account total).",
          value = function(e) return num(e.affixedItemsWithAffixesLeft) end },
        { title = "Unattuned", width = 110, justify = "RIGHT", numeric = true,
          headerTooltip = "Affixed items this class can use that are not yet attuned at all.",
          value = function(e) return num(e.unattunedAffixedItems) end },
    },
    getRows = function(data)
        if UI.filters.scope ~= "account" then
            return {}
        end
        return AF.BuildClassRankings(data, ZonePasses)
    end,
    summary = function(data, n)
        if UI.filters.scope ~= "account" then
            return "Per-class breakdown is available in Account scope -- switch Scope to Account."
        end
        return string.format("%d classes with remaining affix value (%s, mob sources)", n, FilterCaption())
    end,
    tooltip = function(e)
        return {
            { left = e.className, right = string.format("%d affixes left", num(e.totalAffixesLeft)) },
            { left = "  Items with affixes left", right = tostring(num(e.affixedItemsWithAffixesLeft)) },
            { left = "  Items not yet attuned at all", right = tostring(num(e.unattunedAffixedItems)) },
            { left = "  Select this class above to re-slice the other panels." },
        }
    end,
}

-- --- Panel: Resist (farm one chosen resistance) ---------------------------
-- A different data source from the other panels: it scans ComputeResistData for
-- the selected element (not ComputeZoneData), so it declares its own fetch +
-- dataSig (see UI.RequestData / UI.SelectPanel). The shared Scope filter and the
-- display-time Source/Expansion filters apply; Forge/Bind/Class do not (resist
-- attunement is flat per forge, so it cannot change the ranking).
PANELS[#PANELS + 1] = {
    id = "resist",
    title = "Resist",
    defaultSort = 2,
    zoneField = "zoneName",  -- honour the display-time category/expansion filters
    element = "fire",        -- selected resist; the panel's control strip changes it
    minSpawns = 5,           -- display-time spawn threshold (like the Mobs panel)
    -- Resist attunement is flat per forge and class-agnostic, so Forge/Bind/Class
    -- can't change the ranking. The filter bar greys them out on this tab.
    ignoresItemFilters = true,
    columns = {
        { title = "Zone", width = 206, justify = "LEFT",
          value = function(e) return e.zoneName or "" end },
        { title = "Resist/1k", width = 84, justify = "RIGHT", numeric = true,
          headerTooltip = "Estimated resistance gained per 1000 kills of the zone's best mob. \"~\" because the amount is estimated from item level (base-forge attune).",
          value = function(e) return num(e.score) end,
          text = function(e) return string.format("~%.2f", num(e.score)) end },
        { title = "Best mob", width = 148, justify = "LEFT",
          headerTooltip = "The single best mob to farm in this zone for the chosen resist (what the Resist/1k score is based on).",
          value = function(e) return e.bestMobName or "" end },
        { title = "Spawns", width = 60, justify = "RIGHT", numeric = true,
          headerTooltip = "Reported spawn count of the best mob.",
          value = function(e) return num(e.bestMobSpawns) end },
        -- Items the BEST mob drops that still roll this resist unattuned (already
        -- resist-specific via the per-item gate). Can run opposite to the resist
        -- ranking: many low-resist items vs few high-resist ones.
        { title = "Items", width = 48, justify = "RIGHT", numeric = true,
          headerTooltip = "Items the best mob drops that still roll this resist unattuned. Can run opposite to the score (many small-resist items vs few large ones).",
          value = function(e) return num(e.bestMobItems) end },
    },
    -- Custom data source + signature (consumed by UI.RequestData/SelectPanel).
    fetch = function(panel, onComplete)
        AF.ComputeResistData(UI.filters.scope, panel.element, onComplete)
    end,
    dataSig = function(panel)
        return "resist:" .. UI.filters.scope .. ":" .. tostring(panel.element)
            .. ":" .. (AF.GetConfig("includeMythics") and "m" or "n")
    end,
    scanLabel = function(panel)
        local info = AF.RESIST_ELEMENTS and AF.RESIST_ELEMENTS[panel.element]
        return (info and info.label or panel.element) .. " resist (" .. UI.filters.scope .. ")"
    end,
    getRows = function(data, panel)
        -- "best" mode: rank each zone by its single best farming mob, which is
        -- what targeted resist farming actually does.
        return (AF.BuildZoneEV(data, "best", panel.minSpawns))
    end,
    -- Each row is a zone, but it names the single best mob to farm there, so
    -- clicking pins that mob exactly like the Mobs panel (BuildZoneEV carries its
    -- npcId). Reuses AF.TryWarpToMob, so the t3 warp-assist setting applies too.
    onRowClick = function(entry)
        if not (AF.TryWarpToMob and entry.bestMobNpcId) then return end
        AF.TryWarpToMob({
            npcId = entry.bestMobNpcId,
            npcName = entry.bestMobName,
            zoneName = entry.zoneName,
        })
    end,
    summary = function(data, n, panel)
        local info = AF.RESIST_ELEMENTS and AF.RESIST_ELEMENTS[panel.element]
        local label = info and info.label or panel.element
        local warpPart = AF.GetConfig("automaticWarp") and " -- click a zone to pin its best mob/open map" or " -- click a zone to pin its best mob"
        return string.format(
            "%s resist: %d zones by ~%s resistance/1000 kills (%s; best mob; min spawns %d) -- estimated from item level; Forge/Bind don't apply%s",
            label, n, label, UI.filters.scope, panel.minSpawns, warpPart)
    end,
    tooltip = function(e)
        local lines = {
            { left = e.zoneName, right = string.format("~%.2f resist / 1000 kills", num(e.score)) },
            { left = "  Best mob", right = tostring(e.bestMobName or "?") },
            { left = "  Reported spawn count", right = tostring(num(e.bestMobSpawns)) },
            { left = "  Items it drops with this resist (unattuned)", right = tostring(num(e.bestMobItems)) },
            { left = "  Estimate: 20% of base resist (base forge), from item level." },
        }
        if AF.GetConfig("automaticWarp") then
            lines[#lines + 1] = { left = "  Click", right = "pin the best mob and open t3 map" }
        else
            lines[#lines + 1] = { left = "  Click", right = "pin the best mob on the map" }
        end
        return lines
    end,
    buildControls = function(panel, strip)
        panel.minSpawns = AF.GetConfig("minSpawns")

        local elemLabel = MakeText(strip, "OVERLAY", "GameFontNormalSmall")
        elemLabel:SetPoint("LEFT", 0, 0)
        elemLabel:SetText("Resist:")

        local elemSeg = CreateSegmented(strip, {
            { value = "fire", text = "Fire", width = 46 },
            { value = "nature", text = "Nature", width = 56 },
            { value = "frost", text = "Frost", width = 48 },
            { value = "shadow", text = "Shadow", width = 58 },
            { value = "arcane", text = "Arcane", width = 56 },
        }, function(value)
            panel.element = value
            UI.RequestData()  -- changing the resist is a different scan
        end)
        local prev, gx = elemLabel, 6
        for _, b in ipairs(elemSeg.buttons) do
            b:ClearAllPoints()
            b:SetPoint("LEFT", prev, "RIGHT", gx, 0)
            prev = b; gx = 2
        end

        local spawnLabel = MakeText(strip, "OVERLAY", "GameFontNormalSmall")
        spawnLabel:SetPoint("LEFT", prev, "RIGHT", 16, 0)
        spawnLabel:SetText("Min spawns:")

        local edit = CreateFrame("EditBox", nil, strip)
        edit:SetAutoFocus(false)
        edit:SetNumeric(true)
        edit:SetMaxLetters(4)
        edit:SetWidth(40)
        edit:SetHeight(18)
        edit:SetPoint("LEFT", spawnLabel, "RIGHT", 8, 0)
        edit:SetFontObject(GameFontHighlightSmall)
        edit:SetTextInsets(5, 5, 0, 0)
        edit:SetJustifyH("CENTER")
        ApplyFlatEditBoxStyle(edit)
        edit:SetText(tostring(panel.minSpawns))
        local function commit()
            local n = tonumber(edit:GetText())
            if not n or n < 0 then n = 0 end
            panel.minSpawns = n
            panel._userSetSpawns = true
            edit:SetText(tostring(n))
            edit:ClearFocus()
            UI.RefreshActivePanel()  -- display-time threshold; no rescan
        end
        edit:SetScript("OnEnterPressed", commit)
        edit:SetScript("OnEditFocusLost", commit)

        panel._elemSeg = elemSeg
        panel._edit = edit
        elemSeg:SetValue(panel.element, false)
    end,
    syncControls = function(panel)
        if panel._elemSeg then panel._elemSeg:SetValue(panel.element, false) end
        if panel._edit then panel._edit:SetText(tostring(panel.minSpawns)) end
    end,
}

-- --- Panel: Progress (completion dashboard) -------------------------------
-- Two layers: a headline summary of account-wide attunement from the Synastria
-- count APIs (independent of the killable-mob slice; degrades if an API is
-- missing), and per-expansion rows of the FARMABLE affixes still left in the
-- current filter. Uses the shared ComputeZoneData slice; rows are expansions, so
-- (like Classes) it filters zones internally via ZonePasses instead of zoneField.
PANELS[#PANELS + 1] = {
    id = "progress",
    title = "Progress",
    defaultSort = 2,
    columns = {
        { title = "Expansion", width = 150, justify = "LEFT",
          value = function(e) return e.label or "" end },
        { title = "Affixes left", width = 100, justify = "RIGHT", numeric = true,
          headerTooltip = "Farmable affixes still left in this expansion (this filter, killable mob sources).",
          value = function(e) return num(e.totalAffixesLeft) end },
        { title = "Zones", width = 84, justify = "RIGHT", numeric = true,
          headerTooltip = "Zones in this expansion that still have remaining affix value.",
          value = function(e) return num(e.zones) end },
        { title = "Items w/ left", width = 110, justify = "RIGHT", numeric = true,
          headerTooltip = "Affixed items in this expansion with at least one affix left to attune.",
          value = function(e) return num(e.affixedItemsWithAffixesLeft) end },
    },
    getRows = function(data)
        return AF.BuildExpansionBreakdown(data, ZonePasses, UI.filters.class)
    end,
    summary = function(data, n)
        local s = (AF.GetAttuneProgressSummary and AF.GetAttuneProgressSummary()) or {}
        local parts = {}
        if s.attunedAffixes and s.attunableAffixes then
            local pct = s.affixPercent and string.format(" (%.1f%%)", s.affixPercent) or ""
            parts[#parts + 1] = string.format("Account affixes attuned: %d / %d%s",
                s.attunedAffixes, s.attunableAffixes, pct)
        end
        if s.attunedItems then
            parts[#parts + 1] = string.format("items attuned: %d", s.attunedItems)
        end
        local head = (#parts > 0) and (table.concat(parts, "  |  ") .. "  --  ") or ""
        return head .. string.format("farmable remaining by expansion (%s)", FilterCaption())
    end,
    tooltip = function(e)
        return {
            { left = e.label, right = string.format("%d affixes left", num(e.totalAffixesLeft)) },
            { left = "  Zones with remaining value", right = tostring(num(e.zones)) },
            { left = "  Items with affixes left", right = tostring(num(e.affixedItemsWithAffixesLeft)) },
            { left = "  Not yet attuned at all", right = tostring(num(e.unattunedAffixedItems)) },
        }
    end,
}

UI.panels = PANELS
UI.activePanelIndex = 1

local function ActivePanel()
    return PANELS[UI.activePanelIndex]
end

function UI.PanelIndexById(id)
    for i, p in ipairs(PANELS) do
        if p.id == id then return i end
    end
end

-- A string identifying what dataset a panel needs, so tab-switching only rescans
-- when the dataset actually differs. The shared Zones/Mobs/Current/Classes panels
-- all read the same ComputeZoneData slice, so they share one signature; the
-- Resist panel declares its own (per element + scope) via panel.dataSig.
local function PanelSig(panel)
    if panel.dataSig then
        return panel.dataSig(panel)
    end
    return "zone:" .. UI.filters.scope
        .. ":" .. (UI.filters.forge or "none")
        .. ":" .. (CurrentBindFilter() or "any")
end

-- ---------------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------------

local function LayoutColumns(widgets, columns, anchorParent)
    -- Position a row of column-aligned widgets (cells or header buttons).
    local x = 0
    for i = 1, MAX_COLS do
        local w = widgets[i]
        local col = columns[i]
        if col then
            w:ClearAllPoints()
            w:SetPoint("LEFT", anchorParent, "LEFT", x, 0)
            w:SetWidth(col.width)
            w:Show()
            x = x + col.width
        else
            w:Hide()
        end
    end
end

function UI.Build()
    if UI.frame then
        return UI.frame
    end

    local f = CreateFrame("Frame", "AffixFinderUIFrame", UIParent)
    f:SetSize(FRAME_W, FRAME_H)
    -- Restore the saved window position if we have one, else open centered.
    local lay = SavedLayout()
    if lay and lay.point then
        f:SetPoint(lay.point, UIParent, lay.relPoint or lay.point, lay.x or 0, lay.y or 0)
    else
        f:SetPoint("CENTER")
    end
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) s:StartMoving() end)
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        -- Persist the new position (a few scalars; no logout cost).
        local point, _, relPoint, x, y = s:GetPoint()
        local ui = LayoutTable()
        ui.point, ui.relPoint, ui.x, ui.y = point, relPoint, x, y
    end)
    f:Hide()
    UI.frame = f

    -- Close with Escape.
    tinsert(UISpecialFrames, "AffixFinderUIFrame")

    -- Title
    local title = MakeText(f, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD, -14)
    title:SetText("AffixFinder")
    title:SetTextColor(TITLE_COLOR[1], TITLE_COLOR[2], TITLE_COLOR[3])

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- Filter bar: Scope + Forge
    local scopeLabel = MakeText(f, "OVERLAY", "GameFontNormalSmall")
    scopeLabel:SetPoint("TOPLEFT", PAD, -44)
    scopeLabel:SetText("Scope:")

    local scopeSeg = CreateSegmented(f, {
        { value = "character", text = "Character", width = 80 },
        { value = "account", text = "Account", width = 76 },
    }, function(value)
        UI.filters.scope = value
        UI.UpdateClassControl()
        UI.RequestData()
    end)
    local prev = scopeLabel
    local gx = 6
    for _, b in ipairs(scopeSeg.buttons) do
        b:ClearAllPoints()
        b:SetPoint("LEFT", prev, "RIGHT", gx, 0)
        prev = b; gx = 2
    end

    local forgeLabel = MakeText(f, "OVERLAY", "GameFontNormalSmall")
    forgeLabel:SetPoint("LEFT", prev, "RIGHT", 18, 0)
    forgeLabel:SetText("Forge:")

    local forgeSeg = CreateSegmented(f, {
        { value = "none", text = "None", width = 50 },
        { value = "tf", text = "TF", width = 44 },
        { value = "wf", text = "WF", width = 44 },
        { value = "lf", text = "LF", width = 40 },
    }, function(value)
        UI.filters.forge = value
        UI.RequestData()
    end)
    prev = forgeLabel; gx = 6
    for _, b in ipairs(forgeSeg.buttons) do
        b:ClearAllPoints()
        b:SetPoint("LEFT", prev, "RIGHT", gx, 0)
        prev = b; gx = 2
    end

    -- Filter bar row 2: Bind (multi, item-level -> rescan) + Source (multi,
    -- zone-level -> display-time)
    local bindLabel = MakeText(f, "OVERLAY", "GameFontNormalSmall")
    bindLabel:SetPoint("TOPLEFT", PAD, -70)
    bindLabel:SetText("Bind:")

    local bindSeg = CreateMultiSegmented(f, {
        { value = "bop", text = "BoP", width = 44 },
        { value = "boe", text = "BoE", width = 44 },
    }, UI.filters.bind, function()
        UI.RequestData()
    end)
    prev = bindLabel; gx = 6
    for _, b in ipairs(bindSeg.buttons) do
        b:ClearAllPoints()
        b:SetPoint("LEFT", prev, "RIGHT", gx, 0)
        prev = b; gx = 2
    end

    local sourceLabel = MakeText(f, "OVERLAY", "GameFontNormalSmall")
    sourceLabel:SetPoint("LEFT", prev, "RIGHT", 18, 0)
    sourceLabel:SetText("Source:")

    local sourceSeg = CreateMultiSegmented(f, {
        { value = "dungeon", text = "Dungeon", width = 68 },
        { value = "raid", text = "Raid", width = 48 },
        { value = "world", text = "World", width = 56 },
    }, UI.filters.category, function()
        UI.RefreshActivePanel()
    end)
    prev = sourceLabel; gx = 6
    for _, b in ipairs(sourceSeg.buttons) do
        b:ClearAllPoints()
        b:SetPoint("LEFT", prev, "RIGHT", gx, 0)
        prev = b; gx = 2
    end

    -- Filter bar row 3: Expansion (multi, zone-level -> display-time)
    local expLabel = MakeText(f, "OVERLAY", "GameFontNormalSmall")
    expLabel:SetPoint("TOPLEFT", PAD, -96)
    expLabel:SetText("Expansion:")

    local expSeg = CreateMultiSegmented(f, {
        { value = "wotlk", text = "WotLK", width = 60 },
        { value = "tbc", text = "TBC", width = 48 },
        { value = "classic", text = "Classic", width = 64 },
    }, UI.filters.expansion, function()
        UI.RefreshActivePanel()
    end)
    prev = expLabel; gx = 6
    for _, b in ipairs(expSeg.buttons) do
        b:ClearAllPoints()
        b:SetPoint("LEFT", prev, "RIGHT", gx, 0)
        prev = b; gx = 2
    end

    -- Class selector (account scope only). Display-time re-slice -> no rescan.
    -- A dropdown (not segmented buttons) because there are 11 options.
    local classLabel = MakeText(f, "OVERLAY", "GameFontNormalSmall")
    classLabel:SetPoint("LEFT", prev, "RIGHT", 18, 0)
    classLabel:SetText("Class:")

    local classDD = CreateFrame("Frame", "AffixFinderClassDropDown", f, "UIDropDownMenuTemplate")
    -- The template carries built-in padding; nudge so it lines up with the row.
    classDD:SetPoint("LEFT", classLabel, "RIGHT", -10, -2)
    UIDropDownMenu_SetWidth(classDD, 96)

    local ALL_CLASSES_LABEL = "All classes"
    local CLASS_MENU = { { token = nil, text = ALL_CLASSES_LABEL } }
    for _, token in ipairs(AF.CLASS_ORDER) do
        CLASS_MENU[#CLASS_MENU + 1] = { token = token, text = AF.ClassDisplayName(token) }
    end

    UIDropDownMenu_Initialize(classDD, function(_, level)
        for _, opt in ipairs(CLASS_MENU) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.text
            info.colorCode = opt.token and AF.ClassColorCode(opt.token) or nil
            info.checked = (UI.filters.class == opt.token)
            info.func = function()
                UI.filters.class = opt.token
                UIDropDownMenu_SetText(classDD, opt.text)
                CloseDropDownMenus()
                UI.RefreshActivePanel()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetText(classDD, ALL_CLASSES_LABEL)

    UI.classLabel = classLabel
    UI.classDD = classDD
    UI.classAllLabel = ALL_CLASSES_LABEL

    UI.scopeSeg = scopeSeg
    UI.forgeSeg = forgeSeg
    UI.bindSeg = bindSeg
    UI.sourceSeg = sourceSeg
    UI.expSeg = expSeg
    UI.forgeLabel = forgeLabel
    UI.bindLabel = bindLabel

    -- Tab buttons (one per panel)
    UI.tabButtons = {}
    local tx = PAD
    for i, panel in ipairs(PANELS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetHeight(22)
        b:SetWidth(math.max(70, panel.title:len() * 8 + 16))
        b:SetText(panel.title)
        b:SetPoint("TOPLEFT", tx, -124)
        b.panelIndex = i
        b:SetScript("OnClick", function() UI.SelectPanel(i) end)
        UI.tabButtons[i] = b
        tx = tx + b:GetWidth() + 4
    end

    -- Control strip (panel-specific controls live here)
    local strip = CreateFrame("Frame", nil, f)
    strip:SetPoint("TOPLEFT", PAD, -152)
    strip:SetSize(INNER_W, 22)
    UI.controlStrip = strip

    -- Summary caption
    local summary = MakeText(f, "OVERLAY", "GameFontNormalSmall", "LEFT")
    summary:SetPoint("TOPLEFT", PAD, -178)
    summary:SetWidth(INNER_W)
    summary:SetText("")
    UI.summaryText = summary

    -- Column header buttons (sortable)
    local headerHost = CreateFrame("Frame", nil, f)
    headerHost:SetPoint("TOPLEFT", PAD, -198)
    headerHost:SetSize(LIST_W, 18)
    UI.headerHost = headerHost
    UI.headerButtons = {}
    for i = 1, MAX_COLS do
        local hb = CreateFrame("Button", nil, headerHost)
        hb:SetHeight(18)
        hb.colIndex = i
        -- The label is given a single anchor (in SelectPanel) so it shrinks to
        -- its text and sits at the justified side of the column; the arrow then
        -- anchors directly to the label so it always hugs the column name rather
        -- than floating at the far edge of the (full-width) header button.
        local label = MakeText(hb, "OVERLAY", "GameFontNormalSmall")
        hb.label = label
        local arrow = hb:CreateTexture(nil, "OVERLAY")
        arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
        arrow:SetWidth(13)
        arrow:SetHeight(13)
        arrow:Hide()
        hb.arrow = arrow
        hb:SetScript("OnClick", function() UI.ToggleSort(i) end)
        hb:SetScript("OnEnter", function(s)
            s.label:SetTextColor(1, 1, 1)
            local col = ActivePanel().columns[s.colIndex]
            if col and col.headerTooltip then
                GameTooltip:SetOwner(s, "ANCHOR_TOP")
                GameTooltip:AddLine(col.title, 1, 1, 1)
                GameTooltip:AddLine(col.headerTooltip, 0.85, 0.85, 0.85, true)
                GameTooltip:AddLine("Click to sort.", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end
        end)
        hb:SetScript("OnLeave", function(s)
            local c = NORMAL_FONT_COLOR
            s.label:SetTextColor(c.r, c.g, c.b)
            GameTooltip:Hide()
        end)
        UI.headerButtons[i] = hb
    end

    -- Scroll list
    local listTop = -218
    local scroll = CreateFrame("ScrollFrame", "AffixFinderUIScroll", f, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, listTop)
    scroll:SetSize(LIST_W, NUM_ROWS * ROW_H)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, UI.RefreshList)
    end)
    UI.scroll = scroll

    -- Row pool
    UI.rows = {}
    for r = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(LIST_W, ROW_H)
        if r == 1 then
            row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", UI.rows[r - 1], "BOTTOMLEFT", 0, 0)
        end

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.4)

        row.cells = {}
        for c = 1, MAX_COLS do
            local cell = MakeText(row, "OVERLAY", "GameFontHighlightSmall")
            cell:SetHeight(ROW_H)
            if cell.SetWordWrap then cell:SetWordWrap(false) end
            row.cells[c] = cell
        end

        row:SetScript("OnEnter", function(s)
            if not s.entry then return end
            local panel = ActivePanel()
            if not panel.tooltip then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            for _, line in ipairs(panel.tooltip(s.entry)) do
                if line.right then
                    GameTooltip:AddDoubleLine(line.left, line.right, 1, 1, 1, 1, 1, 1)
                else
                    GameTooltip:AddLine(line.left, 1, 1, 1)
                end
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Row click dispatches to the active panel's optional onRowClick (only
        -- the Zones panel defines one -> drills the Mobs panel to that zone).
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(s)
            if not s.entry then return end
            local panel = ActivePanel()
            if panel.onRowClick then panel.onRowClick(s.entry) end
        end)

        UI.rows[r] = row
    end

    -- Centered overlay message (scanning / empty / error states)
    local overlay = MakeText(f, "OVERLAY", "GameFontNormal", "CENTER")
    overlay:SetPoint("CENTER", scroll, "CENTER", 0, 0)
    overlay:SetWidth(LIST_W - 20)
    overlay:Hide()
    UI.overlay = overlay

    -- Footer: status + rescan
    local status = MakeText(f, "OVERLAY", "GameFontDisableSmall", "LEFT")
    status:SetPoint("BOTTOMLEFT", PAD, 16)
    status:SetWidth(INNER_W - 90)
    UI.statusText = status

    local rescan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rescan:SetSize(80, 20)
    rescan:SetPoint("BOTTOMRIGHT", -PAD, 14)
    rescan:SetText("Rescan")
    rescan:SetScript("OnClick", function() UI.Rescan() end)
    rescan:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:AddLine("Clear caches and rescan from scratch.", 1, 1, 1)
        GameTooltip:AddLine("Use after a server data reload.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    rescan:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI.rescanButton = rescan

    -- Build per-panel controls once.
    for _, panel in ipairs(PANELS) do
        if panel.buildControls then
            panel._controlFrame = CreateFrame("Frame", nil, strip)
            panel._controlFrame:SetAllPoints(strip)
            panel.buildControls(panel, panel._controlFrame)
            panel._controlFrame:Hide()
        end
    end

    -- Refresh while shown so attune/cache changes propagate.
    f:RegisterEvent("CHAT_MSG_SYSTEM")
    -- Keep the Current Zone panel pointed at where the player actually is.
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "CHAT_MSG_SYSTEM" and type(arg1) == "string"
            and string.find(arg1, "You have attuned with", 1, true) then
            -- Core drops cached aggregates on this; our copy is now stale.
            UI.data = nil
            if f:IsShown() then
                UI.RequestData()
            end
        elseif event == "ZONE_CHANGED_NEW_AREA" then
            -- The Current Zone panel reads the live zone each render; the data
            -- already covers every zone, so just re-render it (no rescan).
            if f:IsShown() and UI.data and ActivePanel().id == "current" then
                UI.RefreshActivePanel()
            end
        end
    end)

    -- Initialise selection state (multi-selects applied themselves on build).
    scopeSeg:SetValue(UI.filters.scope, false)
    forgeSeg:SetValue(UI.filters.forge, false)
    UI.UpdateClassControl()
    UI.SelectPanel(UI.activePanelIndex, true)

    return f
end

-- Shows the Class selector only in Account scope (per-class is meaningless for a
-- single character). Leaving Account scope resets the selection to "all" so the
-- other panels return to account totals and never show a stale class slice.
function UI.UpdateClassControl()
    if not UI.classDD then return end
    if UI.filters.scope == "account" then
        UI.classLabel:Show()
        UI.classDD:Show()
    else
        UI.filters.class = nil
        UIDropDownMenu_SetText(UI.classDD, UI.classAllLabel)
        UI.classLabel:Hide()
        UI.classDD:Hide()
    end
    UI.UpdateFilterControlState()
end

local LABEL_ENABLED_COLOR = NORMAL_FONT_COLOR or { r = 1, g = 0.82, b = 0 }
local LABEL_DISABLED_COLOR = GRAY_FONT_COLOR or { r = 0.5, g = 0.5, b = 0.5 }

local function setLabelEnabled(label, enabled)
    if not label then return end
    local c = enabled and LABEL_ENABLED_COLOR or LABEL_DISABLED_COLOR
    label:SetTextColor(c.r, c.g, c.b)
end

-- Grey out the filters the active panel ignores (Forge/Bind/Class on the Resist
-- tab) so the bar tells the truth about what applies. Class is only ever shown
-- in Account scope, so it is left to UI.UpdateClassControl to show/hide; here we
-- just enable/disable whatever is currently shown.
function UI.UpdateFilterControlState()
    if not UI.forgeSeg then return end
    local panel = PANELS[UI.activePanelIndex]
    local itemFiltersApply = not (panel and panel.ignoresItemFilters)

    UI.forgeSeg:SetEnabled(itemFiltersApply)
    UI.bindSeg:SetEnabled(itemFiltersApply)
    setLabelEnabled(UI.forgeLabel, itemFiltersApply)
    setLabelEnabled(UI.bindLabel, itemFiltersApply)

    if UI.classDD then
        if itemFiltersApply then
            UIDropDownMenu_EnableDropDown(UI.classDD)
        else
            UIDropDownMenu_DisableDropDown(UI.classDD)
        end
        setLabelEnabled(UI.classLabel, itemFiltersApply)
    end
end

-- ---------------------------------------------------------------------------
-- Panel selection / column layout
-- ---------------------------------------------------------------------------

function UI.SelectPanel(index, skipRequest)
    UI.activePanelIndex = index
    local panel = PANELS[index]

    for i, b in ipairs(UI.tabButtons) do
        if i == index then
            b:SetButtonState("PUSHED", true)
            b:LockHighlight()
        else
            b:SetButtonState("NORMAL")
            b:UnlockHighlight()
        end
    end

    -- Show only this panel's controls.
    for _, p in ipairs(PANELS) do
        if p._controlFrame then
            p._controlFrame:Hide()
        end
    end
    if panel._controlFrame then
        panel._controlFrame:Show()
        if panel.syncControls then panel.syncControls(panel) end
    end

    -- Grey out filters this panel ignores (e.g. Forge/Bind/Class on Resist).
    UI.UpdateFilterControlState()

    -- Lay out column headers for this panel.
    for i, hb in ipairs(UI.headerButtons) do
        local col = panel.columns[i]
        if col then
            hb.label:ClearAllPoints()
            hb.arrow:ClearAllPoints()
            hb.label:SetText(col.title)
            hb.label:SetJustifyH(col.justify or "LEFT")
            if col.justify == "RIGHT" then
                -- Name hugs the column's right edge (over the right-aligned
                -- numbers); arrow sits just to its left.
                hb.label:SetPoint("RIGHT", hb, "RIGHT", 0, 0)
                hb.arrow:SetPoint("RIGHT", hb.label, "LEFT", -3, 0)
            else
                -- Name hugs the column's left edge; arrow sits just to its right.
                hb.label:SetPoint("LEFT", hb, "LEFT", 1, 0)
                hb.arrow:SetPoint("LEFT", hb.label, "RIGHT", 3, 0)
            end
        end
    end
    LayoutColumns(UI.headerButtons, panel.columns, UI.headerHost)

    -- Lay out the cells in every row for this panel.
    for _, row in ipairs(UI.rows) do
        for i, cell in ipairs(row.cells) do
            local col = panel.columns[i]
            if col then
                cell:SetJustifyH(col.justify or "LEFT")
            end
        end
        LayoutColumns(row.cells, panel.columns, row)
    end

    -- Default sort for the panel (numeric -> desc, text -> asc).
    local sc = panel.sortCol or panel.defaultSort or 1
    if panel.sortCol == nil then
        panel.sortCol = sc
        panel.sortAsc = not panel.columns[sc].numeric
    end

    if not skipRequest then
        -- Re-scan only if this panel needs a different dataset than the one we
        -- hold (e.g. switching to/from Resist); otherwise just re-render.
        if UI.data and UI.dataSig == PanelSig(panel) then
            UI.RefreshActivePanel()
        else
            UI.RequestData()
        end
    end
end

function UI.ToggleSort(colIndex)
    local panel = ActivePanel()
    if not panel.columns[colIndex] then return end
    if panel.sortCol == colIndex then
        panel.sortAsc = not panel.sortAsc
    else
        panel.sortCol = colIndex
        panel.sortAsc = not panel.columns[colIndex].numeric
    end
    UI.RefreshActivePanel()
end

-- ---------------------------------------------------------------------------
-- Data request / state
-- ---------------------------------------------------------------------------

local retryFrame = CreateFrame("Frame")
retryFrame:Hide()
retryFrame.elapsed = 0
retryFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed >= 0.4 then
        self.elapsed = 0
        if not AF.busy then
            self:Hide()
            UI.RequestData()
        end
    end
end)

function UI.SetOverlay(msg)
    if msg then
        UI.overlay:SetText(msg)
        UI.overlay:Show()
        for _, row in ipairs(UI.rows) do
            row:Hide()
            row.entry = nil
        end
    else
        UI.overlay:Hide()
    end
end

function UI.RequestData()
    if not UI.frame then return end
    local panel = ActivePanel()

    UI.requestSeq = (UI.requestSeq or 0) + 1
    local seq = UI.requestSeq

    -- The Resist panel scans a different source and ignores Forge/Bind, so its
    -- scan label differs from the shared filter caption.
    local label = (panel.scanLabel and panel.scanLabel(panel)) or FilterCaption()
    UI.statusText:SetText("Scanning " .. label .. "... (progress in chat)")
    UI.SetOverlay("Scanning " .. label .. "...\nThe first scan of a filter combination takes a few seconds.")

    local function handle(data, err)
        if seq ~= UI.requestSeq then
            return  -- filters changed again; ignore this stale result
        end
        if not data then
            if err == "busy" then
                UI.statusText:SetText("Waiting for a running scan to finish...")
                retryFrame.elapsed = 0
                retryFrame:Show()
            else
                UI.SetOverlay("Cannot scan yet:\n" .. tostring(err) .. "\nTry again after entering the world.")
                UI.statusText:SetText("Not ready: " .. tostring(err))
            end
            return
        end
        UI.data = data
        UI.dataSig = PanelSig(panel)
        UI.dataItemsScanned = data.affixedItemsScanned
        UI.RefreshActivePanel()
    end

    -- A panel may declare its own data source (Resist -> ComputeResistData);
    -- otherwise use the shared scope/forge/bind ComputeZoneData slice.
    if panel.fetch then
        panel.fetch(panel, handle)
    else
        AF.ComputeZoneData(UI.filters.scope, CurrentForgeFilter(), CurrentBindFilter(), handle)
    end
end

function UI.Rescan()
    if AF.busy then
        UI.statusText:SetText("Busy: a scan is already running.")
        return
    end
    AF.ClearAll()
    if AF.ResetZoneClassification then
        AF.ResetZoneClassification()  -- pick up any newly-loaded LFG/map data
    end
    UI.data = nil
    UI.RequestData()
end

-- Re-read the saved settings after the options panel changes them. The min-spawn
-- default flows into the Mobs panel (unless the user overrode it in-window this
-- session); the mythic setting changes which items count, so re-requesting picks
-- the matching cache slice (or scans once for the new combination). Safe to call
-- before the window has ever been built.
function UI.ApplyConfig()
    for _, p in ipairs(PANELS) do
        if (p.id == "mobs" or p.id == "resist" or p.id == "items") and not p._userSetSpawns then
            p.minSpawns = AF.GetConfig("minSpawns")
            if p._edit then p._edit:SetText(tostring(p.minSpawns)) end
        end
    end
    if UI.frame and UI.frame:IsShown() then
        UI.data = nil
        UI.RequestData()
    end
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function UI.RefreshActivePanel()
    if not UI.frame or not UI.data then return end
    local panel = ActivePanel()

    local entries = panel.getRows(UI.data, panel) or {}

    -- Apply the display-time zone filters (category + expansion). Cheap when
    -- everything is selected: ZonePasses short-circuits before classifying.
    if panel.zoneField then
        local filtered = {}
        for _, e in ipairs(entries) do
            if ZonePasses(e[panel.zoneField]) then
                filtered[#filtered + 1] = e
            end
        end
        entries = filtered
    end

    -- Apply the active column sort.
    local sc = panel.sortCol
    if sc and panel.columns[sc] then
        local col = panel.columns[sc]
        local asc = panel.sortAsc
        table.sort(entries, function(a, b)
            local va, vb = col.value(a), col.value(b)
            if va == vb then
                -- stable-ish tiebreak on zone/category name
                local na = tostring(a.zoneName or a.category or "")
                local nb = tostring(b.zoneName or b.category or "")
                return na < nb
            end
            if asc then return va < vb else return va > vb end
        end)
    end
    UI.currentEntries = entries

    -- Header arrows.
    for i, hb in ipairs(UI.headerButtons) do
        if panel.columns[i] and i == sc then
            hb.arrow:Show()
            -- UI-SortArrow points up; flip vertically for descending.
            if panel.sortAsc then
                hb.arrow:SetTexCoord(0, 1, 0, 1)
            else
                hb.arrow:SetTexCoord(0, 1, 1, 0)
            end
        else
            hb.arrow:Hide()
        end
    end

    -- Summary caption.
    if panel.summary then
        UI.summaryText:SetText(panel.summary(UI.data, #entries, panel))
    else
        UI.summaryText:SetText("")
    end

    -- Footer status. A slice goes "dirty" when you attune something; the core
    -- keeps serving it (rate-limited by the rescan interval) rather than
    -- rescanning on every attune, so surface that instead of a flat "cached".
    local scanned = UI.dataItemsScanned or 0
    local cacheState = "cached"
    if UI.data.dirty then
        local interval = (tonumber(AF.GetConfig("rescanInterval")) or 0) * 60
        local remaining = interval - (time() - (UI.data.computedAt or 0))
        if interval > 0 and remaining > 0 then
            cacheState = string.format("stale -- auto-refresh in ~%dm (or Rescan)",
                math.max(1, math.ceil(remaining / 60)))
        else
            cacheState = "stale -- Rescan to refresh"
        end
    end
    UI.statusText:SetText(string.format("%d rows  |  %d affixed items with mob sources  |  %s",
        #entries, scanned, cacheState))

    if #entries == 0 then
        UI.SetOverlay("Nothing to show for these filters.")
    else
        UI.SetOverlay(nil)
    end

    UI.RefreshList()
end

function UI.RefreshList()
    local entries = UI.currentEntries or {}
    local panel = ActivePanel()
    local n = #entries

    FauxScrollFrame_Update(UI.scroll, n, NUM_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(UI.scroll)

    for r = 1, NUM_ROWS do
        local row = UI.rows[r]
        local idx = r + offset
        local entry = entries[idx]
        if entry and idx <= n then
            row.entry = entry
            for c = 1, MAX_COLS do
                local col = panel.columns[c]
                local cell = row.cells[c]
                if col then
                    local text = col.text and col.text(entry) or tostring(col.value(entry))
                    cell:SetText(text)
                else
                    cell:SetText("")
                end
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public toggle
-- ---------------------------------------------------------------------------

function AF.ShowUI()
    UI.Build()
    UI.frame:Show()
    UI.scopeSeg:SetValue(UI.filters.scope, false)
    UI.forgeSeg:SetValue(UI.filters.forge, false)
    if UI.data then
        UI.RefreshActivePanel()
    else
        UI.RequestData()
    end
end

function AF.HideUI()
    if UI.frame then
        UI.frame:Hide()
    end
end

function AF.ToggleUI()
    UI.Build()
    if UI.frame:IsShown() then
        AF.HideUI()
    else
        AF.ShowUI()
    end
end

-- ---------------------------------------------------------------------------
-- Minimap toggle button
-- ---------------------------------------------------------------------------
-- Hand-rolled minimap button (no LibDBIcon), matching the look used by
-- WeakAuras/Questie/ScootsCraft: an icon framed by the standard tracking-border
-- ring. It is draggable around the minimap edge; its angle persists in
-- AffixFinderDB.ui.minimapAngle (a single scalar). It defaults to the north-west
-- of the ring, clear of the zone text at the top and the calendar/clock at the
-- top-right. The icon is a spyglass -- a "finder" -- and is a one-line swap below.

local MINIMAP_ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"

local function CreateMinimapButton()
    if UI.minimapButton or not Minimap then
        return
    end

    -- north-west default (0 = east, 90 = north); overridden by a saved angle if
    -- the SavedVariable is already loaded, else the ADDON_LOADED loader applies it.
    local saved = SavedLayout()
    UI.minimapAngle = (saved and saved.minimapAngle) or 135

    local btn = CreateFrame("Button", "AffixFinderMinimapButton", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetWidth(31)
    btn:SetHeight(31)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(MINIMAP_ICON)
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)  -- trim the icon's baked-in border

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT", 0, 0)

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local function updatePosition()
        local angle = math.rad(UI.minimapAngle or 45)
        local radius = (Minimap:GetWidth() / 2) + 5
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER",
            math.cos(angle) * radius, math.sin(angle) * radius)
    end
    UI.UpdateMinimapPosition = updatePosition

    local function onDragUpdate()
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local px, py = GetCursorPosition()
        px, py = px / scale, py / scale
        UI.minimapAngle = math.deg(math.atan2(py - my, px - mx))
        updatePosition()
    end

    btn:SetScript("OnDragStart", function(s) s:SetScript("OnUpdate", onDragUpdate) end)
    btn:SetScript("OnDragStop", function(s)
        s:SetScript("OnUpdate", nil)
        LayoutTable().minimapAngle = UI.minimapAngle  -- persist the new angle
    end)
    btn:SetScript("OnClick", function() AF.ToggleUI() end)
    btn:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_LEFT")
        GameTooltip:AddLine("AffixFinder")
        GameTooltip:AddLine("Click to open the window.", 1, 1, 1)
        GameTooltip:AddLine("Drag to move around the minimap.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UI.minimapButton = btn
    updatePosition()
end

CreateMinimapButton()

-- The SavedVariable may not be loaded when this file runs, so re-apply the saved
-- minimap angle once it is available (the button was placed at the default).
local layoutLoader = CreateFrame("Frame")
layoutLoader:RegisterEvent("ADDON_LOADED")
layoutLoader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON_NAME then
        return
    end
    self:UnregisterEvent("ADDON_LOADED")
    local lay = SavedLayout()
    if lay and lay.minimapAngle and UI.minimapButton then
        UI.minimapAngle = lay.minimapAngle
        if UI.UpdateMinimapPosition then
            UI.UpdateMinimapPosition()
        end
    end
end)
