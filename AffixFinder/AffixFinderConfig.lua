-- AffixFinder options panel
-- ---------------------------------------------------------------------------
-- Adds an entry under Interface -> AddOns (the same place qtRunner / Questie /
-- ScootsCraft put their options) for the addon's settings, and persists them in
-- the AffixFinderDB SavedVariable.
--
-- Only a few scalars are stored -- never the item graph or source data -- so
-- this does not affect the addon's memory budget or its instant-logout design.
-- The defaults live in the core (AF.configDefaults); this file just loads the
-- saved overrides into AF.config, writes changes back, and notifies the UI.
-- ---------------------------------------------------------------------------

local ADDON_NAME = "AffixFinder"
local DB_NAME = "AffixFinderDB"

local AF = _G.AffixFinder
if not AF then
    return
end

-- ---------------------------------------------------------------------------
-- SavedVariables <-> AF.config
-- ---------------------------------------------------------------------------

local function DB()
    local db = _G[DB_NAME]
    if type(db) ~= "table" then
        db = {}
        _G[DB_NAME] = db
    end
    return db
end

-- Copy persisted values over the in-memory defaults (only for known keys, so a
-- stale/garbage saved key can never leak in).
local function LoadConfig()
    local db = DB()
    for key, default in pairs(AF.configDefaults) do
        local v = db[key]
        if v == nil then
            AF.config[key] = default
        else
            AF.config[key] = v
        end
    end
end

-- Persist one setting and let the open window react to it.
local function SaveConfig(key, value)
    DB()[key] = value
    AF.config[key] = value
    if AF.UI and AF.UI.ApplyConfig then
        AF.UI.ApplyConfig()
    end
end

-- ---------------------------------------------------------------------------
-- Panel + widgets
-- ---------------------------------------------------------------------------

local panel = CreateFrame("Frame", "AffixFinderOptionsPanel", UIParent)
panel.name = "AffixFinder"

-- Register the category and expose the opener FIRST, before building any of the
-- widgets below. If a particular client trips over an options template while
-- decorating a widget, the category is already listed and /af config still
-- works -- the panel just shows fewer controls instead of the whole file
-- aborting (which would leave AF.OpenOptions undefined).
if type(InterfaceOptions_AddCategory) == "function" then
    InterfaceOptions_AddCategory(panel)
end

-- Slash shortcut: /af config opens straight to the panel.
function AF.OpenOptions()
    if type(InterfaceOptionsFrame_OpenToCategory) == "function" then
        -- Call twice: a known 3.3.5 quirk where the first call only expands the
        -- AddOns list and the second actually selects the panel.
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

-- Sets the text of a template sub-region (e.g. "$parentText") if it exists.
local function SetRegionText(frameName, suffix, text)
    local region = _G[frameName .. suffix]
    if region and region.SetText then
        region:SetText(text)
    end
    return region
end

-- The settings outgrew the Interface Options canvas (which never scrolls), so
-- every widget lives on a scroll child instead of the panel itself. The
-- template provides scrollbar + mouse-wheel handling; the child's width
-- tracks the visible area (set on size change) and its height is fixed to
-- the content's extent after the last widget below.
local scroll = CreateFrame("ScrollFrame", "AffixFinderOptionsScroll", panel,
    "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 0, -4)
scroll:SetPoint("BOTTOMRIGHT", -28, 4)  -- leave room for the scrollbar

local content = CreateFrame("Frame", "AffixFinderOptionsContent", scroll)
content:SetSize(600, 620)  -- height = content extent; width corrected below
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function(self, width)
    if width and width > 0 then
        content:SetWidth(width)
    end
end)

local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("AffixFinder")

local subtitle = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetPoint("RIGHT", content, "RIGHT", -32, 0)
subtitle:SetHeight(34)
subtitle:SetJustifyH("LEFT")
subtitle:SetJustifyV("TOP")
subtitle:SetText("Settings for affix-attunement scanning. These persist across sessions; "
    .. "everything else the addon keeps stays in memory only.")

-- --- Include mythics (checkbox) --------------------------------------------
local mythic = CreateFrame("CheckButton", "AffixFinderMythicCheck", content,
    "InterfaceOptionsCheckButtonTemplate")
mythic:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -16)
SetRegionText(mythic:GetName(), "Text", "Include mythic items in calculations")
mythic.tooltipText = "Mythic items are very hard to farm, so by default the rankings ignore "
    .. "them -- the assumption is most players will not chase mythics just for affixes. "
    .. "Enable to count mythic drops too."
mythic:SetScript("OnClick", function(self)
    SaveConfig("includeMythics", self:GetChecked() and true or false)
end)

-- --- Automatic warp (checkbox) --------------------------------------------
local autoWarp = CreateFrame("CheckButton", "AffixFinderAutoWarpCheck", content,
    "InterfaceOptionsCheckButtonTemplate")
autoWarp:SetPoint("TOPLEFT", mythic, "BOTTOMLEFT", 0, -10)
SetRegionText(autoWarp:GetName(), "Text", "T3 map-warp assist from the Mobs view")
autoWarp.tooltipText = "Mob rows always mark the latest clicked target on the map. "
    .. "When enabled, AffixFinder also opens that zone's map so you can click the target to warp -- "
    .. "but only when a warp is usable: it skips dungeons/raids and opens only for zones you actually "
    .. "have the t3 warp for. Safe to leave on with a partial set of warps. Enabled by default."
autoWarp:SetScript("OnClick", function(self)
    SaveConfig("automaticWarp", self:GetChecked() and true or false)
end)

-- --- Item tooltips (checkbox) ----------------------------------------------
local tooltips = CreateFrame("CheckButton", "AffixFinderTooltipsCheck", content,
    "InterfaceOptionsCheckButtonTemplate")
tooltips:SetPoint("TOPLEFT", autoWarp, "BOTTOMLEFT", 0, -10)
SetRegionText(tooltips:GetName(), "Text", "Add affix info to item tooltips")
tooltips.tooltipText = "Adds an AffixFinder line to item tooltips everywhere (bags, bank, auction "
    .. "house, loot, links): affixes left to attune, and the best mob to farm the item from when any "
    .. "remain. Enabled by default; turn off if you find it intrusive."
tooltips:SetScript("OnClick", function(self)
    SaveConfig("tooltips", self:GetChecked() and true or false)
end)

-- --- Slider helper ----------------------------------------------------------
-- OptionsSliderTemplate gives us $parentLow / $parentHigh / $parentText regions.
-- We fold the live value into $parentText so the current setting is always shown
-- above the slider, and commit on change (rounded to the step).
local function BuildSlider(name, labelText, minV, maxV, step, formatValue, configKey, anchor, yGap)
    local s = CreateFrame("Slider", name, content, "OptionsSliderTemplate")
    s:SetWidth(300)
    s:SetHeight(16)
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, yGap)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    SetRegionText(name, "Low", tostring(minV))
    SetRegionText(name, "High", tostring(maxV))

    local function setLabel(v)
        SetRegionText(name, "Text", labelText .. ": " .. formatValue(v))
    end
    s.setLabel = setLabel
    s.step = step

    s:SetScript("OnValueChanged", function(self, value)
        local snapped = math.floor((value / step) + 0.5) * step
        setLabel(snapped)
        if self._loading then
            return
        end
        if self._lastSaved ~= snapped then
            self._lastSaved = snapped
            SaveConfig(configKey, snapped)
        end
    end)

    return s
end

local rescanSlider = BuildSlider(
    "AffixFinderRescanSlider",
    "Auto-rescan interval",
    0, 180, 5,
    function(v)
        if v <= 0 then
            return "every change"
        end
        return v .. " min"
    end,
    "rescanInterval",
    tooltips, -48)
rescanSlider.tooltipText = "How often an automatic rescan may run for a given filter after the "
    .. "addon detects a change (e.g. you attune something). 0 = rescan on every detected change. "
    .. "The Rescan button and changing filters always rescan immediately."

local spawnSlider = BuildSlider(
    "AffixFinderSpawnSlider",
    "Default minimum mob spawns",
    0, 50, 1,
    function(v) return tostring(v) end,
    "minSpawns",
    rescanSlider, -48)
spawnSlider.tooltipText = "Default minimum reported spawn count for a mob to appear in the Mobs "
    .. "view. Higher hides rare/sparse spawns; 0 includes everything. You can still override this "
    .. "per session in the window."

local DENSITY_SLIDER_LABELS = { [0] = "any", [1] = "fair or better", [2] = "good or better", [3] = "excellent only" }
local densitySlider = BuildSlider(
    "AffixFinderDensitySlider",
    "Default minimum pack density",
    0, 3, 1,
    function(v) return DENSITY_SLIDER_LABELS[v] or tostring(v) end,
    "minDensity",
    spawnSlider, -48)
densitySlider.tooltipText = "Default pack-density threshold for the Mobs view: how tightly a mob's "
    .. "best camp of Min-spawns spawn points is packed (walk distance per kill, computed from "
    .. "Questie's spawn data). Mobs whose density is unknown (Questie not loaded, or no data for "
    .. "that NPC) always show. You can still override this per session in the window."

local speedSlider = BuildSlider(
    "AffixFinderSpeedSlider",
    "Scan speed",
    2, 16, 1,
    function(v) return v .. " ms per frame" end,
    "scanBudget",
    densitySlider, -48)
speedSlider.tooltipText = "How much of each frame the background scans (discovery, zone/resist/"
    .. "new-item scans, pack density) may use. Higher finishes scans sooner at the cost of frame "
    .. "rate while they run; lower is smoother but slower. 10 is the default; drop to 3-6 for "
    .. "maximum smoothness."

-- ---------------------------------------------------------------------------
-- Reflect AF.config in the widgets
-- ---------------------------------------------------------------------------

local function RefreshWidgets()
    mythic:SetChecked(AF.GetConfig("includeMythics") and true or false)
    autoWarp:SetChecked(AF.GetConfig("automaticWarp") and true or false)
    tooltips:SetChecked(AF.GetConfig("tooltips") ~= false)

    -- Guard against the OnValueChanged handler writing back while we load.
    local sliders = {
        { rescanSlider, "rescanInterval" },
        { spawnSlider, "minSpawns" },
        { densitySlider, "minDensity" },
        { speedSlider, "scanBudget" },
    }
    for _, s in ipairs(sliders) do s[1]._loading = true end
    for _, s in ipairs(sliders) do s[1]:SetValue(AF.GetConfig(s[2])) end
    for _, s in ipairs(sliders) do s[1]._loading = false end

    -- SetValue does not fire OnValueChanged when the value is unchanged, so set
    -- the labels explicitly to keep them correct.
    for _, s in ipairs(sliders) do
        s[1].setLabel(AF.GetConfig(s[2]))
        s[1]._lastSaved = AF.GetConfig(s[2])
    end
end

panel:SetScript("OnShow", RefreshWidgets)

-- "Defaults" button in the panel resets every setting.
panel.default = function()
    for key, default in pairs(AF.configDefaults) do
        SaveConfig(key, default)
    end
    RefreshWidgets()
end

-- ---------------------------------------------------------------------------
-- Load saved values once the SavedVariable is available.
-- ---------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON_NAME then
        return
    end
    self:UnregisterEvent("ADDON_LOADED")
    LoadConfig()
    RefreshWidgets()
    if AF.UI and AF.UI.ApplyConfig then
        AF.UI.ApplyConfig()  -- seed the Mobs default from the saved value
    end
end)
