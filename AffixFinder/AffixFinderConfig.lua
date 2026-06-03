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

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("AffixFinder")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetPoint("RIGHT", panel, "RIGHT", -32, 0)
subtitle:SetHeight(34)
subtitle:SetJustifyH("LEFT")
subtitle:SetJustifyV("TOP")
subtitle:SetText("Settings for affix-attunement scanning. These persist across sessions; "
    .. "everything else the addon keeps stays in memory only.")

-- --- Include mythics (checkbox) --------------------------------------------
local mythic = CreateFrame("CheckButton", "AffixFinderMythicCheck", panel,
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
local autoWarp = CreateFrame("CheckButton", "AffixFinderAutoWarpCheck", panel,
    "InterfaceOptionsCheckButtonTemplate")
autoWarp:SetPoint("TOPLEFT", mythic, "BOTTOMLEFT", 0, -10)
SetRegionText(autoWarp:GetName(), "Text", "T3 map-warp assist from the Mobs view")
autoWarp.tooltipText = "Mob rows always mark the latest clicked target on the map. "
    .. "When enabled, AffixFinder also checks your t3 warp attunement and opens the zone map "
    .. "so you can click the target location. Disabled by default."
autoWarp:SetScript("OnClick", function(self)
    SaveConfig("automaticWarp", self:GetChecked() and true or false)
end)

-- --- Slider helper ----------------------------------------------------------
-- OptionsSliderTemplate gives us $parentLow / $parentHigh / $parentText regions.
-- We fold the live value into $parentText so the current setting is always shown
-- above the slider, and commit on change (rounded to the step).
local function BuildSlider(name, labelText, minV, maxV, step, formatValue, configKey, anchor, yGap)
    local s = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
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
    autoWarp, -48)
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

-- ---------------------------------------------------------------------------
-- Reflect AF.config in the widgets
-- ---------------------------------------------------------------------------

local function RefreshWidgets()
    mythic:SetChecked(AF.GetConfig("includeMythics") and true or false)
    autoWarp:SetChecked(AF.GetConfig("automaticWarp") and true or false)

    -- Guard against the OnValueChanged handler writing back while we load.
    rescanSlider._loading, spawnSlider._loading = true, true
    rescanSlider:SetValue(AF.GetConfig("rescanInterval"))
    spawnSlider:SetValue(AF.GetConfig("minSpawns"))
    rescanSlider._loading, spawnSlider._loading = false, false

    -- SetValue does not fire OnValueChanged when the value is unchanged, so set
    -- the labels explicitly to keep them correct.
    rescanSlider.setLabel(AF.GetConfig("rescanInterval"))
    spawnSlider.setLabel(AF.GetConfig("minSpawns"))
    rescanSlider._lastSaved = AF.GetConfig("rescanInterval")
    spawnSlider._lastSaved = AF.GetConfig("minSpawns")
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
