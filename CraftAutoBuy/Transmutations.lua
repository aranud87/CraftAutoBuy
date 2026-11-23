local _, ns = ...
local L = ns.L
local Transmutations = {}
ns.Transmutations = Transmutations

local CELL_WIDTH, CELL_HEIGHT, PADDING = 87, 23, 5
local CELL_GAP, GROUP_GAP, GRIP_HEIGHT = 4, 7, 12
local MIN_WIDTH, MIN_HEIGHT = CELL_WIDTH + 2 * PADDING, CELL_HEIGHT + 2 * PADDING
local QUESTION_MARK = 134400
local NOTICE_SECONDS = 10
local window, viewport, content, grip, emptyPanel, emptyText
local groups, visibleGroups, outputIcons = {}, {}, {}
local noticeFrame, noticeLabel
local noticeBatches = {}
local layout
local started
local knowsAlchemy

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function placeWindow(prefs)
    window:ClearAllPoints()
    if finite(prefs.x) and finite(prefs.y) then
        window:SetPoint("CENTER", UIParent, "CENTER", prefs.x, prefs.y)
    else
        window:SetPoint("RIGHT", UIParent, "RIGHT", -80, 0)
    end
end

local function stopMovingOrSizing()
    if not window.dragging and not window.sizing then return end
    local sizing = window.sizing
    window:StopMovingOrSizing()
    window.dragging, window.sizing = nil, nil
    local prefs = ns.Settings.GetTransmutationOptions()
    if sizing then prefs.width, prefs.height = window:GetSize() end
    local x, y = window:GetCenter()
    if finite(x) and finite(y) then
        prefs.x = x - UIParent:GetWidth() / 2
        prefs.y = y - UIParent:GetHeight() / 2
        placeWindow(prefs)
    end
    if sizing then layout() end
end

local function hideTooltip(owner)
    if GameTooltip and GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
end

local function setDragHandlers(frame, recordDrag)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if recordDrag then self.wasDragged = true end
        if window.locked or window.sizing then return end
        hideTooltip(self)
        window:StartMoving()
        window.dragging = true
    end)
    frame:SetScript("OnDragStop", stopMovingOrSizing)
end

local function createPanel(parent, name)
    local panel = CreateFrame("Frame", name, parent, "BackdropTemplate")
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    panel:SetBackdropColor(0.07, 0.07, 0.09, 1)
    panel:SetBackdropBorderColor(0.65, 0.55, 0.34, 1)
    return panel
end

local function scrollTo(offset)
    local visibleHeight = window:GetHeight() - (window.locked and 0 or GRIP_HEIGHT)
    local maximum = math.max(0, content:GetHeight() - visibleHeight)
    offset = math.max(0, math.min(offset, maximum))
    if viewport:GetVerticalScroll() ~= offset then viewport:SetVerticalScroll(offset) end
end

local function createWindow(prefs)
    window = CreateFrame("Frame", nil, UIParent)
    local maxWidth = math.max(MIN_WIDTH, UIParent:GetWidth() - 24)
    local maxHeight = math.max(MIN_HEIGHT + GRIP_HEIGHT, UIParent:GetHeight() - 24)
    window:SetSize(finite(prefs.width) and math.max(MIN_WIDTH, math.min(prefs.width, maxWidth)) or MIN_WIDTH,
        MIN_HEIGHT + GRIP_HEIGHT)
    window:SetFrameStrata("MEDIUM")
    window:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT + GRIP_HEIGHT, maxWidth, maxHeight)
    window.maxHeight = maxHeight
    window:SetClampedToScreen(true)
    setDragHandlers(window)
    window:SetScript("OnHide", stopMovingOrSizing)
    window:SetScript("OnSizeChanged", function()
        if window.sizing then layout() end
    end)

    viewport = CreateFrame("ScrollFrame", nil, window)
    viewport:SetPoint("TOPLEFT", window)
    viewport:EnableMouseWheel(true)
    viewport:SetScript("OnMouseWheel", function(self, delta)
        scrollTo(self:GetVerticalScroll() - delta * (CELL_HEIGHT + CELL_GAP))
    end)
    content = CreateFrame("Frame", nil, viewport)
    content:SetSize(MIN_WIDTH, MIN_HEIGHT)
    viewport:SetScrollChild(content)

    grip = CreateFrame("Button", nil, window)
    grip:SetSize(GRIP_HEIGHT, GRIP_HEIGHT)
    grip:SetPoint("BOTTOMRIGHT", window)
    grip:SetFrameLevel(window:GetFrameLevel() + 8)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" or window.locked or window.dragging then return end
        window.sizing = true
        window:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and window.sizing then stopMovingOrSizing() end
    end)

    emptyPanel = createPanel(content)
    emptyPanel:SetPoint("TOPLEFT", content)
    emptyText = emptyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyText:SetPoint("TOPLEFT", PADDING, -PADDING)
    emptyText:SetJustifyH("LEFT")
    placeWindow(prefs)
end

local function positiveID(value)
    return type(value) == "number" and not (issecretvalue and issecretvalue(value)) and value > 0
end

local function recipeIcon(id)
    if outputIcons[id] then return outputIcons[id] end
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic and C_Item and C_Item.GetItemIconByID then
        local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, id, false)
        if ok and type(schematic) == "table" and not (issecretvalue and issecretvalue(schematic))
            and positiveID(schematic.outputItemID) then
            local iconOK, icon = pcall(C_Item.GetItemIconByID, schematic.outputItemID)
            if iconOK and positiveID(icon) then
                outputIcons[id] = icon
                return icon
            end
        end
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, icon = pcall(C_Spell.GetSpellTexture, id)
        if ok and positiveID(icon) then return icon end
    end
    return QUESTION_MARK
end

local function showStockTooltip(self)
    if not GameTooltip or window.dragging or window.sizing then return end
    local x = self:GetCenter()
    GameTooltip:SetOwner(self, x and x > UIParent:GetWidth() / 2 and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
    GameTooltip:SetText(self:GetParent().recipeName)
    local reagents = ns.API.ReadTransmutationReagentStock(self.recipeID)
    if reagents then
        for _, reagent in ipairs(reagents) do
            GameTooltip:AddLine(L.BANK_COMPONENT:format(reagent.needed, reagent.name), 1, 0.82, 0.35, true)
            local bags = ("%s: %s"):format(L.STOCK_BAGS, reagent.bags or "?")
            local bank = ("%s: %s"):format(L.STOCK_BANK, reagent.bank or "?")
            GameTooltip:AddDoubleLine(bags, bank, 0.9, 0.9, 0.9, 0.55, 0.78, 1)
            local vendor
            if reagent.vendorQuantity ~= nil then vendor = L.MERCHANT_REAGENT_STOCK:format(reagent.vendorQuantity)
            elseif reagent.vendorHere then vendor = L.MERCHANT_REAGENT_HERE
            elseif reagent.vendorKnown then
                if reagent.vendorUnverified then vendor = L.TRANSMUTATION_VENDOR_READING
                elseif reagent.vendor == false then vendor = L.MERCHANT_REAGENT_NOT_HERE
                else vendor = L.MERCHANT_REAGENT_AVAILABLE end
            end
            if vendor then GameTooltip:AddLine(vendor, 0.9, 0.78, 0.42, true) end
        end
    else
        GameTooltip:AddLine(L.LOADING_REAGENTS, 1, 0.82, 0.35, true)
    end
    GameTooltip:Show()
end

local function createLine(id, parent, professionKey)
    local line = CreateFrame("Frame", nil, parent)
    line:SetSize(CELL_WIDTH, CELL_HEIGHT)
    line:EnableMouse(true)
    setDragHandlers(line)
    local function showRecipeTooltip(self)
        if not GameTooltip or window.dragging or window.sizing then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local ok = GameTooltip.SetSpellByID and pcall(GameTooltip.SetSpellByID, GameTooltip, id)
        if not ok or GameTooltip:NumLines() == 0 then GameTooltip:SetText(line.recipeName) end
        GameTooltip:Show()
    end
    line:SetScript("OnEnter", showRecipeTooltip)
    line:SetScript("OnLeave", hideTooltip)
    line:SetScript("OnHide", hideTooltip)

    local openButton = CreateFrame("Button", nil, line)
    line.openButton = openButton
    openButton:SetSize(22, 22)
    openButton:SetPoint("LEFT", line, "LEFT")
    openButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    openButton:RegisterForClicks("LeftButtonUp")
    setDragHandlers(openButton, true)
    openButton:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then self.wasDragged = nil end
    end)
    openButton:SetScript("OnClick", function(self, button)
        if button ~= "LeftButton" or self.wasDragged or window.dragging or window.sizing then return end
        hideTooltip(self)
        local opened, reason = ns.UI.ShowRecipe(id, professionKey)
        if not opened and reason then ns.Print(reason) end
    end)
    openButton:SetScript("OnEnter", showRecipeTooltip)
    openButton:SetScript("OnLeave", hideTooltip)
    openButton:SetScript("OnHide", hideTooltip)
    line.icon = openButton:CreateTexture(nil, "ARTWORK")
    line.icon:SetAllPoints(openButton)
    line.icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)

    local bag = CreateFrame("Frame", nil, line)
    line.bag = bag
    bag.recipeID = id
    bag:SetSize(14, 16)
    bag:SetPoint("RIGHT", line, "RIGHT")
    bag:EnableMouse(true)
    setDragHandlers(bag)
    local bagIcon = bag:CreateTexture(nil, "ARTWORK")
    bagIcon:SetAllPoints(bag)
    bagIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
    bag:SetScript("OnEnter", showStockTooltip)
    bag:SetScript("OnLeave", hideTooltip)
    bag:SetScript("OnHide", hideTooltip)

    line.status = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.status:SetPoint("LEFT", line.icon, "RIGHT", 4, 0)
    line.status:SetPoint("RIGHT", bag, "LEFT", -3, 0)
    line.status:SetJustifyH("LEFT")
    return line
end

local function timeLabel(remaining)
    if not remaining then return L.TRANSMUTATION_UNKNOWN, 1, 0.76, 0.38 end
    if remaining == 0 then return L.TRANSMUTATION_READY, 0.48, 0.92, 0.55 end
    local seconds = math.ceil(remaining)
    return ("%d:%02d:%02d"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60), 1, 1, 1
end

local function sortRows(a, b)
    local aRunning, bRunning = (a.remaining or 0) > 0, (b.remaining or 0) > 0
    if aRunning ~= bRunning then return aRunning end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
end

-- Fit as many recipes per row as the available width permits. Profession
-- blocks share the viewport, and only the blocks themselves have backdrops.
layout = function()
    local width = window:GetWidth()
    local chrome = window.locked and 0 or GRIP_HEIGHT
    local height
    if #visibleGroups == 0 then
        emptyText:SetWidth(width - 2 * PADDING)
        height = math.max(MIN_HEIGHT, emptyText:GetStringHeight() + 2 * PADDING)
        emptyPanel:SetSize(width, height)
    else
        local maxColumns = math.max(1, math.floor((width - 2 * PADDING + CELL_GAP) / (CELL_WIDTH + CELL_GAP)))
        local x, y, shelfHeight = 0, 0, 0
        for _, group in ipairs(visibleGroups) do
            local count = #group.visible
            local columns = math.min(count, maxColumns)
            local blockWidth = 2 * PADDING + columns * (CELL_WIDTH + CELL_GAP) - CELL_GAP
            local blockHeight = 2 * PADDING + math.ceil(count / columns) * (CELL_HEIGHT + CELL_GAP) - CELL_GAP
            if x > 0 and x + blockWidth > width then
                x, y, shelfHeight = 0, y + shelfHeight + GROUP_GAP, 0
            end
            local panel = group.panel
            if panel.left ~= x or panel.top ~= y then
                panel.left, panel.top = x, y
                panel:ClearAllPoints()
                panel:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
            end
            panel:SetSize(blockWidth, blockHeight)
            for index, line in ipairs(group.visible) do
                local left = PADDING + (index - 1) % columns * (CELL_WIDTH + CELL_GAP)
                local top = PADDING + math.floor((index - 1) / columns) * (CELL_HEIGHT + CELL_GAP)
                if line.left ~= left or line.top ~= top then
                    line.left, line.top = left, top
                    line:ClearAllPoints()
                    line:SetPoint("TOPLEFT", panel, "TOPLEFT", left, -top)
                end
            end
            x = x + blockWidth + GROUP_GAP
            shelfHeight = math.max(shelfHeight, blockHeight)
        end
        height = y + shelfHeight
    end

    if not window.sizing then
        local saved = ns.Settings.GetTransmutationOptions().height
        local target = finite(saved) and math.max(MIN_HEIGHT + chrome, saved) or height + chrome
        target = math.min(target, window.maxHeight)
        if window:GetHeight() ~= target then window:SetHeight(target) end
    end
    local currentWidth, currentHeight = content:GetSize()
    if currentWidth ~= width or currentHeight ~= height then content:SetSize(width, height) end
    scrollTo(viewport:GetVerticalScroll())
end

local function render(rows, prefs)
    if not window then createWindow(prefs) end
    local locked = prefs.locked == true
    if window.locked ~= locked then
        if locked then stopMovingOrSizing() end
        window.locked = locked
        window:SetMovable(not locked)
        window:SetResizable(not locked)
        window:EnableMouse(not locked)
        grip:SetShown(not locked)
        viewport:ClearAllPoints()
        viewport:SetPoint("TOPLEFT", window)
        viewport:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, locked and 0 or GRIP_HEIGHT)
    end
    window:SetAlpha(prefs.opacity / 100)

    table.sort(rows, sortRows)
    emptyPanel:SetShown(#rows == 0)
    if #rows == 0 then
        local state = ns.Bootstrap and ns.Bootstrap.GetState()
        local loading = state and not state.complete and not state.manual and not state.waiting
        emptyText:SetText(loading and L.LOADING_PROFESSION or L.TRANSMUTATION_EMPTY)
    end
    visibleGroups = {}
    for _, group in pairs(groups) do
        for _, line in ipairs(group.visible) do line.inUse = false end
        group.visible = {}
    end
    for _, row in ipairs(rows) do
        local key = row.professionKey or 0
        local group = groups[key]
        if not group then
            group = {key = key, panel = createPanel(content), lines = {}, visible = {}}
            groups[key] = group
        end
        if #group.visible == 0 then visibleGroups[#visibleGroups + 1] = group end
        local line = group.lines[row.id]
        if not line then
            line = createLine(row.id, group.panel, row.professionKey)
            group.lines[row.id] = line
        end
        group.visible[#group.visible + 1] = line
        line.inUse = true
        line.recipeName = row.name
        line.icon:SetTexture(recipeIcon(row.id))
        local text, r, g, b = timeLabel(row.remaining)
        line.status:SetText(text)
        line.status:SetTextColor(r, g, b)
        line:Show()
    end
    for _, group in pairs(groups) do
        group.panel:SetShown(#group.visible > 0)
        for _, line in pairs(group.lines) do
            if not line.inUse then line:Hide() end
        end
    end
    table.sort(visibleGroups, function(a, b) return a.key < b.key end)
    layout()
    window:Show()
end

local function redrawNotice()
    if #noticeBatches == 0 then
        noticeFrame:Hide()
        return
    end
    local lines = {}
    for _, batch in ipairs(noticeBatches) do
        for _, message in ipairs(batch) do lines[#lines + 1] = message end
    end
    noticeLabel:SetText(table.concat(lines, "\n"))
    noticeFrame:SetHeight(math.max(44, noticeLabel:GetStringHeight() + 22))
    noticeFrame:Show()
end

local function showNotice(messages)
    if not noticeFrame then
        noticeFrame = createPanel(UIParent, "CraftAutoBuyTransmutationNotice")
        local width = math.min(430, UIParent:GetWidth() - 24)
        noticeFrame:SetSize(width, 44)
        noticeFrame:SetPoint("TOP", UIParent, "TOP", 0, -125)
        noticeFrame:SetFrameStrata("HIGH")
        noticeFrame:SetClampedToScreen(true)
        noticeFrame:EnableMouse(false)
        noticeLabel = noticeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        noticeLabel:SetPoint("TOP", noticeFrame, "TOP", 0, -11)
        noticeLabel:SetWidth(width - 28)
        noticeLabel:SetJustifyH("CENTER")
        noticeLabel:SetTextColor(1, 0.86, 0.45)
    end
    noticeBatches[#noticeBatches + 1] = messages
    redrawNotice()
    C_Timer.After(NOTICE_SECONDS, function()
        for index, batch in ipairs(noticeBatches) do
            if batch == messages then
                table.remove(noticeBatches, index)
                break
            end
        end
        redrawNotice()
    end)
end

-- A complete live roster takes precedence over saved rows after unlearning
-- Alchemy. During login the roster can be partial, so a known recipe still
-- lets a returning alchemist see their timer while the missing slots load.
local function hasAlchemy(rows)
    if knowsAlchemy ~= nil then return knowsAlchemy end
    local professions, complete = ns.API.GetProfessions()
    for _, profession in ipairs(professions) do
        if profession.key == 171 then
            knowsAlchemy = true
            return true
        end
    end
    if complete then
        -- Empty slots can also be returned while entering the world. Retry
        -- them on the next tick without briefly showing a non-alchemist UI.
        if #professions > 0 then knowsAlchemy = false end
        return false
    end
    return #rows > 0 or (ns.Catalogue and next(ns.Catalogue.GetRecipes(171)) ~= nil)
end

function Transmutations.InvalidateProfessions()
    knowsAlchemy = nil
end

function Transmutations.Update()
    if not started then return end
    local prefs = ns.Settings.GetTransmutationOptions()
    local alert, popup = prefs.alert == true, prefs.popup == true
    local rows = ns.API.ReadTransmutationCooldowns(alert or popup)
    if popup and hasAlchemy(rows) then render(rows, prefs)
    elseif window then window:Hide() end

    if not alert then return end
    local messages = {}
    for _, row in ipairs(rows) do
        if row.finished then
            messages[#messages + 1] = L.TRANSMUTATION_NOTICE:format(row.name)
        end
    end
    if #messages == 0 then return end
    showNotice(messages)
    local playSound = C_Sound and C_Sound.PlaySound or PlaySound
    if prefs.sound == true and playSound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
        playSound(SOUNDKIT.RAID_WARNING)
    end
end

function Transmutations.Start()
    if started then return end
    started = true
    Transmutations.Update()
    C_Timer.NewTicker(1, Transmutations.Update)
end
