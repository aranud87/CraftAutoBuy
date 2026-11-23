local _, ns = ...
local L = ns.L
local Options = {}
ns.Settings = Options

local merchantButton, canvas, category, dialog, merchantMenu, contextMenu, languageMenu
local checks, openChecks, languageChecks = {}, {}, {}
local languageButtons = {}
local showLanguageMenu
local lastMenuValue, lastMenuOpen
local languageInitialized = false
local languageNotices = {}
local transmutationChecks, opacityControls = {}, {}
local MIN_OPACITY, MAX_OPACITY = 25, 100

function Options.GetTransmutationOptions()
    CraftAutoBuyDB = CraftAutoBuyDB or {}
    local prefs = CraftAutoBuyDB.transmutations
    if type(prefs) ~= "table" then
        prefs = {}
        CraftAutoBuyDB.transmutations = prefs
    end
    if prefs.alert == nil then prefs.alert = true end
    if prefs.sound == nil then prefs.sound = true end
    if prefs.popup == nil then prefs.popup = true end
    if type(prefs.locked) ~= "boolean" then prefs.locked = false end
    local opacity = prefs.opacity
    if type(opacity) ~= "number" or opacity ~= opacity or opacity < MIN_OPACITY or opacity > MAX_OPACITY then
        prefs.opacity = 90
    end
    return prefs
end

local function setTransmutationOption(key, value)
    Options.GetTransmutationOptions()[key] = value
    Options.Sync()
    if ns.Transmutations then ns.Transmutations.Update() end
end

local function enabled()
    return not CraftAutoBuyDB or CraftAutoBuyDB.autoBuy ~= false
end

local function openAtMerchant()
    return CraftAutoBuyDB and CraftAutoBuyDB.openAtMerchant == true or false
end

local function language()
    local code = CraftAutoBuyDB and CraftAutoBuyDB.language
    return ns.Locale.HasLocale(code) and code or "auto"
end

local function applyLanguage()
    if languageInitialized then return end
    local code = language()
    if code == "auto" then code = ns.Locale.GetClientLocale() end
    if ns.Locale then ns.Locale.SetLocale(code) end
    languageInitialized = true
end

local function autoLanguageLabel()
    local code, detected = ns.Locale.GetClientLocale()
    if detected and ns.Locale.HasLocale(code) then
        for _, entry in ipairs(ns.Locale.GetAvailableLocales()) do
            if entry.code == code then return string.format(L.LANGUAGE_AUTO_DETECTED, entry.name) end
        end
    end
    return L.LANGUAGE_AUTO_FALLBACK
end

local function languageLabel()
    local selected = language()
    if selected == "auto" then return autoLanguageLabel() end
    for _, entry in ipairs(ns.Locale.GetAvailableLocales()) do
        if entry.code == selected then return entry.name end
    end
    return autoLanguageLabel()
end

function Options.Sync()
    local value = enabled()
    local openValue = openAtMerchant()
    for _, check in ipairs(checks) do check:SetChecked(value) end
    for _, check in ipairs(openChecks) do check:SetChecked(openValue) end
    for _, check in ipairs(languageChecks) do check:SetChecked(check.localeCode == language()) end
    for _, control in ipairs(languageButtons) do control:SetText(languageLabel()) end
    local requested = language()
    if requested == "auto" then requested = ns.Locale.GetClientLocale() end
    local pending = ns.Locale.ResolveLocale(requested) ~= ns.Locale.GetLocale()
    for _, notice in ipairs(languageNotices) do notice:SetText(pending and L.LANGUAGE_RELOAD_REQUIRED or "") end
    local prefs = Options.GetTransmutationOptions()
    for _, check in ipairs(transmutationChecks) do
        check:SetChecked(prefs[check.optionKey] == true)
        if check.optionKey == "sound" then check:SetEnabled(prefs.alert == true) end
    end
    for _, control in ipairs(opacityControls) do
        control.value:SetText(("%d%%"):format(prefs.opacity))
        control.minus:SetEnabled(prefs.opacity > MIN_OPACITY)
        control.plus:SetEnabled(prefs.opacity < MAX_OPACITY)
    end
    if contextMenu and (lastMenuValue ~= value or lastMenuOpen ~= openValue) then
        lastMenuValue, lastMenuOpen = value, openValue
        if contextMenu.ReinitializeAll then contextMenu:ReinitializeAll() end
    end
end

function Options.SetOpenAtMerchant(value)
    value = value and true or false
    local changed = openAtMerchant() ~= value
    CraftAutoBuyDB = CraftAutoBuyDB or {}
    CraftAutoBuyDB.openAtMerchant = value
    -- Preference only: opening is handled on the next MERCHANT_SHOW event.
    Options.Sync()
    return changed
end

function Options.SetAutoBuy(value)
    value = value and true or false
    local changed = enabled() ~= value
    CraftAutoBuyDB = CraftAutoBuyDB or {}
    CraftAutoBuyDB.autoBuy = value
    if not changed then Options.Sync(); return false end
    -- Changing a preference never purchases. Only the crafting action may buy.
    -- Turning it off also disarms a pending purchase-to-craft continuation.
    if not value then
        if ns.PausePurchaseContinuation then ns.PausePurchaseContinuation() end
        if ns.Merchant and ns.Merchant.Stop then ns.Merchant.Stop() end
    end
    Options.Sync()
    if ns.Refresh then ns.Refresh() end
    return true
end

function Options.SetLanguage(code)
    if code ~= "auto" and not ns.Locale.HasLocale(code) then return false end
    CraftAutoBuyDB = CraftAutoBuyDB or {}
    local changed = language() ~= code
    CraftAutoBuyDB.language = code
    -- Keep current labels and pending status messages in one language for this
    -- session. The saved choice is applied once after /reload, before UI creation.
    Options.Sync()
    return changed
end

local function label(parent, text, font, x, y, width)
    local region = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    region:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    region:SetWidth(width)
    region:SetJustifyH("LEFT")
    region:SetJustifyV("TOP")
    region:SetText(text)
    return region
end

local function checkbox(parent, x, y, width)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(26, 26)
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    check.optionKey = "autoBuy"
    label(parent, L.AUTO_BUY, "GameFontHighlight", x + 29, y - 6, width or 400)
    check:SetScript("OnClick", function(self) Options.SetAutoBuy(self:GetChecked()) end)
    checks[#checks + 1] = check
    check:SetChecked(enabled())
    return check
end

local function openCheckbox(parent, x, y, width)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(26, 26)
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    check.optionKey = "openAtMerchant"
    label(parent, L.OPEN_AT_MERCHANT, "GameFontHighlight", x + 29, y - 6, width or 400)
    check:SetScript("OnClick", function(self) Options.SetOpenAtMerchant(self:GetChecked()) end)
    openChecks[#openChecks + 1] = check
    check:SetChecked(openAtMerchant())
    return check
end

local function languageChoice(parent, code, text, x, y)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(26, 26)
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    check.localeCode = code
    label(parent, text, "GameFontHighlight", x + 29, y - 6, 380)
    check:SetScript("OnClick", function()
        Options.SetLanguage(code)
        if languageMenu then languageMenu:Hide() end
    end)
    languageChecks[#languageChecks + 1] = check
    return check
end

local function button(parent, text, x, y, width, handler)
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetSize(width, 24)
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    control:SetText(text)
    control:SetScript("OnClick", handler)
    return control
end

local function configureGeneral(parent)
    label(parent, L.SETTINGS_HELP, "GameFontHighlight", 20, -86, 450)
    checkbox(parent, 16, -132)
    label(parent, L.AUTO_BUY_HELP, "GameFontHighlightSmall", 20, -162, 450)
    openCheckbox(parent, 16, -222)
    label(parent, L.OPEN_AT_MERCHANT_HELP, "GameFontHighlightSmall", 20, -258, 450)
    label(parent, L.LANGUAGE, "GameFontNormal", 20, -326, 450)
    local selector = button(parent, languageLabel(), 20, -348, 450, function(self) showLanguageMenu(self) end)
    selector.optionKey = "language"
    selector:HookScript("OnHide", function()
        if languageMenu and languageMenu.owner == selector then languageMenu:Hide() end
    end)
    languageButtons[#languageButtons + 1] = selector
    label(parent, L.LANGUAGE_HELP, "GameFontHighlightSmall", 20, -387, 450)
    languageNotices[#languageNotices + 1] = label(parent, "", "GameFontNormal", 20, -466, 450)
end

local function transmutationCheckbox(parent, key, text, x, y)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(26, 26)
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    check.optionKey = key
    label(parent, text, "GameFontHighlight", x + 29, y - 6, 360)
    check:SetScript("OnClick", function(self) setTransmutationOption(key, self:GetChecked() and true or false) end)
    transmutationChecks[#transmutationChecks + 1] = check
end

local function opacityAdjustment(parent, y)
    label(parent, L.TRANSMUTATION_OPACITY, "GameFontHighlight", 45, y - 6, 285)
    local function adjust(step)
        local opacity = Options.GetTransmutationOptions().opacity + step
        setTransmutationOption("opacity", math.max(MIN_OPACITY, math.min(MAX_OPACITY, opacity)))
    end
    local minus = button(parent, "-", 337, y, 26, function() adjust(-5) end)
    local plus = button(parent, "+", 426, y, 26, function() adjust(5) end)
    local value = label(parent, "", "GameFontHighlight", 366, y - 6, 57)
    value:SetJustifyH("CENTER")
    opacityControls[#opacityControls + 1] = {minus = minus, plus = plus, value = value}
end

local function configure(parent)
    parent:SetHeight(500)
    label(parent, "CraftAutoBuy", "GameFontNormalLarge", 20, -18, 450)
    local general = CreateFrame("Frame", nil, parent)
    local transmutations = CreateFrame("Frame", nil, parent)
    general:SetAllPoints(parent)
    transmutations:SetAllPoints(parent)
    configureGeneral(general)
    transmutationCheckbox(transmutations, "alert", L.TRANSMUTATION_ALERT, 16, -91)
    transmutationCheckbox(transmutations, "sound", L.TRANSMUTATION_SOUND, 43, -123)
    transmutationCheckbox(transmutations, "popup", L.TRANSMUTATION_POPUP, 16, -180)
    label(transmutations, L.TRANSMUTATION_POPUP_HELP, "GameFontHighlightSmall", 45, -215, 400)
    transmutationCheckbox(transmutations, "locked", L.TRANSMUTATION_LOCK, 16, -267)
    opacityAdjustment(transmutations, -305)

    local generalTab, transmutationTab
    local function showTransmutations(show)
        general:SetShown(not show)
        transmutations:SetShown(show)
        generalTab:SetEnabled(show)
        transmutationTab:SetEnabled(not show)
    end
    generalTab = button(parent, L.SETTINGS_GENERAL, 20, -47, 220, function() showTransmutations(false) end)
    transmutationTab = button(parent, L.TRANSMUTATIONS, 250, -47, 220, function() showTransmutations(true) end)
    showTransmutations(false)
    parent:SetScript("OnShow", Options.Sync)
end

local function floatingFrame(name, width, height)
    local frame = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 7, right = 7, top = 7, bottom = 7 },
    })
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() frame:Hide() end)
    if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = name end
    frame:Hide()
    return frame
end

local function showFallbackLanguageMenu(owner)
    if languageMenu and languageMenu.owner == owner and languageMenu:IsShown() then
        languageMenu:Hide()
        return
    end
    if not languageMenu then
        languageMenu = floatingFrame("CraftAutoBuyLanguageMenu", 474, 260)
        label(languageMenu, L.LANGUAGE, "GameFontNormalLarge", 18, -18, 400)
        local scroll = CreateFrame("ScrollFrame", nil, languageMenu, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", languageMenu, "TOPLEFT", 18, -48)
        scroll:SetSize(410, 190)
        local content = CreateFrame("Frame", nil, scroll)
        local locales = ns.Locale.GetAvailableLocales()
        content:SetSize(410, (#locales + 1) * 32)
        scroll:SetScrollChild(content)
        languageChoice(content, "auto", autoLanguageLabel(), 0, 0)
        for index, entry in ipairs(locales) do
            languageChoice(content, entry.code, entry.name, 0, -index * 32)
        end
        languageMenu.scroll, languageMenu.locales = scroll, locales
    end
    languageMenu.owner = owner
    languageMenu:ClearAllPoints()
    languageMenu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", -12, -3)
    Options.Sync()
    languageMenu:Show()
    local selected, index = language(), 0
    for i, entry in ipairs(languageMenu.locales) do
        if entry.code == selected then index = i; break end
    end
    local maximum = math.max(0, (#languageMenu.locales + 1) * 32 - 190)
    languageMenu.scroll:SetVerticalScroll(math.min(maximum, index * 32))
end

showLanguageMenu = function(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then showFallbackLanguageMenu(owner); return end
    -- Forever's menu API supports radios and a bounded scrolling root menu.
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.LANGUAGE)
        root:SetScrollMode(240)
        local function selected(code) return language() == code end
        local function choose(code) Options.SetLanguage(code) end
        root:CreateRadio(autoLanguageLabel(), selected, choose, "auto")
        for _, entry in ipairs(ns.Locale.GetAvailableLocales()) do
            root:CreateRadio(entry.name, selected, choose, entry.code)
        end
    end)
end

local function showFallbackSettings()
    if not dialog then
        dialog = floatingFrame("CraftAutoBuySettingsDialog", 500, 500)
        configure(dialog)
        dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    Options.Sync()
    dialog:Show()
end

local function showFallbackMerchantMenu(owner)
    if not merchantMenu then
        merchantMenu = floatingFrame("CraftAutoBuyMerchantMenu", 326, 205)
        label(merchantMenu, "CraftAutoBuy", "GameFontNormalLarge", 18, -18, 270)
        checkbox(merchantMenu, 14, -50, 270)
        openCheckbox(merchantMenu, 14, -88, 270)
        button(merchantMenu, L.ADDON_SETTINGS, 18, -153, 290, Options.Open)
        merchantMenu:SetScript("OnShow", Options.Sync)
    end
    if merchantMenu:IsShown() then merchantMenu:Hide(); return end
    merchantMenu:ClearAllPoints()
    merchantMenu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -3)
    Options.Sync()
    merchantMenu:Show()
end

local function showMerchantMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then showFallbackMerchantMenu(owner); return end
    contextMenu = MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("CraftAutoBuy")
        root:CreateCheckbox(L.AUTO_BUY, enabled, function() Options.SetAutoBuy(not enabled()) end)
        root:CreateCheckbox(L.OPEN_AT_MERCHANT, openAtMerchant, function()
            Options.SetOpenAtMerchant(not openAtMerchant())
        end)
        root:CreateDivider()
        root:CreateButton(L.ADDON_SETTINGS, Options.Open)
    end)
    lastMenuValue, lastMenuOpen = enabled(), openAtMerchant()
    if contextMenu and contextMenu.SetClosedCallback then
        contextMenu:SetClosedCallback(function(closed)
            if contextMenu == closed then contextMenu = nil end
        end)
    end
end

function Options.Install()
    CraftAutoBuyDB = CraftAutoBuyDB or {}
    if CraftAutoBuyDB.autoBuy == nil then CraftAutoBuyDB.autoBuy = true end
    if CraftAutoBuyDB.openAtMerchant == nil then CraftAutoBuyDB.openAtMerchant = false end
    if not ns.Locale.HasLocale(CraftAutoBuyDB.language) then CraftAutoBuyDB.language = "auto" end
    applyLanguage()
    if not merchantButton and MerchantFrame then
        merchantButton = CreateFrame("Button", "CraftAutoBuyMerchantButton", MerchantFrame, "UIPanelButtonTemplate")
        merchantButton:SetSize(132, 24)
        merchantButton:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -5, -3)
        merchantButton:SetText("CraftAutoBuy")
        merchantButton:SetScript("OnClick", showMerchantMenu)
        merchantButton:SetScript("OnShow", Options.Sync)
        if MerchantFrame.HookScript then
            MerchantFrame:HookScript("OnHide", function()
                if merchantMenu then merchantMenu:Hide() end
                contextMenu = nil
            end)
        end
    end
    if not category and Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        if not canvas then
            canvas = CreateFrame("Frame", "CraftAutoBuySettingsPanel", UIParent)
            canvas.name = "CraftAutoBuy"
            configure(canvas)
            canvas:Hide()
        end
        category = Settings.RegisterCanvasLayoutCategory(canvas, "CraftAutoBuy")
        Settings.RegisterAddOnCategory(category)
    end
    Options.Sync()
end

function Options.Open()
    Options.Install()
    if category and Settings and Settings.OpenToCategory then
        local id = category.GetID and category:GetID() or category.ID
        if id then
            local ok = pcall(Settings.OpenToCategory, id)
            if ok then return end
        end
    end
    showFallbackSettings()
end
