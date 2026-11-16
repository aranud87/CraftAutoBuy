local _, ns = ...
local L = ns.L
local BootstrapUI = {}
ns.BootstrapUI = BootstrapUI

local NAME, WIDTH, INTERVAL = "CraftAutoBuyInitializationFrame", 400, 0.10
local initialized, dismissed, automaticHide = false, false, false
local frame, title, help, status, bar, percentage, hideButton
local lastUpdate

local function finite(value)
    return type(value) == "number" and not (issecretvalue and issecretvalue(value))
        and value == value and value > -math.huge and value < math.huge
end

local function loggedIn()
    if type(IsLoggedIn) ~= "function" then return false end
    local ok, value = pcall(IsLoggedIn)
    return ok and not (issecretvalue and issecretvalue(value)) and value == true
end

local function hideAutomatically()
    if not frame or not frame:IsShown() then return end
    automaticHide = true
    frame:Hide()
    automaticHide = false
end

local function region(parent, font, width)
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    text:SetWidth(width)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetWordWrap(true)
    return text
end

local function height(text, minimum)
    local value = text:GetStringHeight()
    return finite(value) and math.max(minimum, value) or minimum
end

local function create()
    frame = CreateFrame("Frame", NAME, UIParent, "BackdropTemplate")
    frame:Hide()
    frame:SetSize(WIDTH, 192)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    -- Only the close controls receive input. Scanning does not block the game.
    frame:EnableMouse(false)
    frame:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 24,
        insets = {left = 7, right = 7, top = 7, bottom = 7}})
    frame:SetBackdropColor(0.04, 0.04, 0.04, 1)
    frame:SetScript("OnHide", function()
        if not automaticHide then dismissed = true end
    end)
    if type(UISpecialFrames) == "table" then UISpecialFrames[#UISpecialFrames + 1] = NAME end

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() frame:Hide() end)

    title = region(frame, "GameFontNormalLarge", WIDTH - 66)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -16)
    title:SetText(L.INITIALIZATION_TITLE)
    help = region(frame, "GameFontHighlightSmall", WIDTH - 32)
    help:SetText(L.INITIALIZATION_BACKGROUND_HELP)
    status = region(frame, "GameFontHighlight", WIDTH - 32)

    bar = CreateFrame("StatusBar", nil, frame)
    bar:SetSize(WIDTH - 32, 18)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.15, 0.65, 0.85)
    bar:SetMinMaxValues(0, 100)
    local background = bar:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(bar)
    background:SetColorTexture(0.08, 0.08, 0.08, 0.9)
    percentage = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    percentage:SetPoint("CENTER", bar, "CENTER", 0, 0)

    hideButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    hideButton:SetText(L.INITIALIZATION_HIDE_BUTTON)
    local label = hideButton:GetFontString()
    local width = label and label:GetStringWidth()
    width = finite(width) and width + 24 or 180
    hideButton:SetSize(math.min(WIDTH - 32, math.max(96, math.ceil(width))), 24)
    hideButton:SetPoint("BOTTOM", frame, "BOTTOM", 0, 14)
    hideButton:SetScript("OnClick", function() frame:Hide() end)
end

local function progress(state)
    local total = finite(state.total) and math.max(0, state.total) or 0
    local done = finite(state.done) and math.max(0, state.done) or 0
    local workTotal = finite(state.workTotal) and math.max(0, state.workTotal) or 0
    local workDone = finite(state.workDone) and math.max(0, state.workDone) or 0
    if total == 0 then return 0 end
    local partial = workTotal > 0 and math.min(1, workDone / workTotal) or 0
    local value = (math.min(done, total) + (done < total and partial or 0)) / total
    -- A pending/waiting scan must never appear complete.
    return math.min(99, math.max(0, math.floor(value * 100)))
end

function BootstrapUI.Update(time)
    if not initialized or dismissed then return end
    if not loggedIn() then hideAutomatically(); return end
    if not finite(time) then time = type(GetTime) == "function" and GetTime() or 0 end
    if not finite(time) then return end
    if lastUpdate and time >= lastUpdate and time - lastUpdate < INTERVAL then return end
    lastUpdate = time
    if not ns.Bootstrap or type(ns.Bootstrap.GetState) ~= "function" then return end
    local state = ns.Bootstrap.GetState()
    if type(state) ~= "table" then return end
    if state.complete == true then hideAutomatically(); return end
    if not frame then create() end
    local message = ns.Bootstrap.StatusText()
    if type(message) ~= "string" or message == "" then
        message = L.INITIALIZING_RECIPES:format(state.done or 0, state.total or 0)
    end
    status:SetText(message)
    local helpTop = 16 + height(title, 18) + 10
    help:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -helpTop)
    local statusTop = helpTop + height(help, 24) + 10
    status:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -statusTop)
    local barTop = statusTop + height(status, 16) + 12
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -barTop)
    frame:SetHeight(barTop + 18 + 12 + 24 + 14)
    local value = progress(state)
    bar:SetValue(value)
    percentage:SetText(("%d%%"):format(value))
    frame:Show()
end

function BootstrapUI.Init()
    initialized = true
    BootstrapUI.Update()
end
