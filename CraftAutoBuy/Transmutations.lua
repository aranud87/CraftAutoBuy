local _, ns = ...
local L = ns.L
local Transmutations = {}
ns.Transmutations = Transmutations

-- A cell holds the recipe icon, its state and the reagent bag. The cells form
-- one grid inside a single frame: the player picks the number of columns with
-- the grip and the height follows the rows.
local CELL_HEIGHT, CELL_GAP, PADDING = 23, 4, 5
local ICON_SIZE, BAG_WIDTH, BAG_HEIGHT = 22, 14, 16
local STATUS_LEFT, STATUS_RIGHT, MIN_STATUS_WIDTH, STATUS_SLACK = 4, 3, 44, 2
local ROW_STEP = CELL_HEIGHT + CELL_GAP
-- The grip sits in a strip below the last row, clear of its reagent bag.
local GRIP_SIZE, GRIP_INSET = 14, 4
local GRIP_MARGIN = GRIP_SIZE + GRIP_INSET + 2
local SCROLL_WIDTH, SCROLL_GAP, MIN_THUMB = 6, 3, 8
local DEFAULT_COLUMNS, DEFAULT_RIGHT = 2, 80
-- A pointer this close to the right screen edge asks for one more column:
-- the grip cannot travel further there.
local EDGE_SLOP = 2
-- Earlier versions saved a free width and height. The column count is read
-- from that width with their 87 px cells, and a resize writes it back in the
-- same form, so that an earlier version shows the same grid.
local LEGACY_CELL, LEGACY_GRIP, LEGACY_MIN_HEIGHT = 87, 12, CELL_HEIGHT + 2 * PADDING
local LEGACY_MIN_WIDTH = LEGACY_CELL + 2 * PADDING
local BORDER_IDLE, BORDER_HOVER = {0.65, 0.55, 0.34, 0.5}, {0.86, 0.72, 0.43, 1}
local GRIP_IDLE_ALPHA = 0.45
local QUESTION_MARK = 134400
local NOTICE_SECONDS = 10
local window, viewport, content, grip, emptyText, measure, scrollBar, thumb
local lines, visibleLines, outputIcons = {}, {}, {}
local cellWidth = ICON_SIZE + STATUS_LEFT + MIN_STATUS_WIDTH + STATUS_RIGHT + BAG_WIDTH
local noticeFrame, noticeLabel
local noticeBatches = {}
local layout
local started
local knowsAlchemy

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function legacyColumns(width)
    return math.max(1, math.floor((width - 2 * PADDING + CELL_GAP) / (LEGACY_CELL + CELL_GAP)))
end

local function legacyWidth(columns)
    return 2 * PADDING + columns * (LEGACY_CELL + CELL_GAP) - CELL_GAP
end

local function cursor()
    if not GetCursorPosition then return end
    local x, y = GetCursorPosition()
    local scale = window:GetEffectiveScale()
    if finite(x) and finite(y) and finite(scale) and scale > 0 then return x / scale, y / scale end
end

-- The client can lose a button release, for instance when another window
-- takes the focus during a gesture.
local function buttonReleased()
    return IsMouseButtonDown ~= nil and not IsMouseButtonDown("LeftButton")
end

local function hideTooltip(owner)
    if GameTooltip and GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
end

-- An unlocked window shows a stronger border and grip while the pointer is
-- over it or the player moves or resizes it.
local function refreshHover()
    if not window then return end
    local hovered = not window.locked and window:IsShown()
        and (window.sizing ~= nil or window.dragging == true or window:IsMouseOver())
    hovered = hovered and true or false
    if window.hovered == hovered then return end
    window.hovered = hovered
    local color = hovered and BORDER_HOVER or BORDER_IDLE
    window:SetBackdropBorderColor(color[1], color[2], color[3], color[4])
    grip:SetAlpha(hovered and 1 or GRIP_IDLE_ALPHA)
end

local function hoverAware(handler)
    return function(self, ...)
        if handler then handler(self, ...) end
        refreshHover()
    end
end

-- Earlier versions read the centre (x, y). The values written here are kept
-- in writtenX/writtenY, so that a later move made by such a version is seen.
local function saveCentre(prefs)
    if not (finite(prefs.left) and finite(prefs.top)) then return end
    prefs.x, prefs.y = prefs.left + window:GetWidth() / 2, prefs.top - window:GetHeight() / 2
    prefs.writtenX, prefs.writtenY = prefs.x, prefs.y
end

-- Only the player's own placement is saved, on a drop or a grip release.
-- Keeping the frame on screen is left to layout and changes nothing saved.
local function stopDragging()
    if not window.dragging then return end
    window.dragging = nil
    window:SetScript("OnUpdate", nil)
    window:StopMovingOrSizing()
    local prefs = ns.Settings.GetTransmutationOptions()
    local left, top = window:GetLeft(), window:GetTop()
    if finite(left) and finite(top) then
        prefs.left, prefs.top = left - UIParent:GetWidth() / 2, top - UIParent:GetHeight() / 2
        -- The drop replaces a centre an earlier version saved.
        prefs.writtenX, prefs.writtenY = prefs.x, prefs.y
    end
    window.anchor = nil
    layout()
    saveCentre(prefs)
    refreshHover()
end

-- Releasing the grip fits the width to the columns. The choice is saved only
-- when the pointer changed the number of columns and the number of recipes
-- did not change at any time during the gesture. The gesture never moves a saved
-- corner. A window at its default place gets the corner it showed when its
-- columns are saved, so that the new width does not move it; a click alone
-- leaves it at its automatic place.
local function stopSizing()
    local sizing = window.sizing
    if not sizing then return end
    window.sizing = nil
    grip:SetScript("OnUpdate", nil)
    local prefs = ns.Settings.GetTransmutationOptions()
    if sizing.columns ~= sizing.startColumns and sizing.count > 0 and not sizing.countChanged then
        prefs.width = legacyWidth(sizing.columns)
        if not (finite(prefs.left) and finite(prefs.top)) then
            prefs.left, prefs.top = sizing.left - UIParent:GetWidth() / 2, sizing.top - UIParent:GetHeight() / 2
        end
    end
    layout()
    saveCentre(prefs)
    refreshHover()
end

local function stopMovingOrSizing()
    stopDragging()
    stopSizing()
end

local function watchDrag()
    if buttonReleased() then stopDragging() end
end

local function setDragHandlers(frame, recordDrag)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if recordDrag then self.wasDragged = true end
        if window.locked or window.sizing or window.dragging then return end
        hideTooltip(self)
        window:StartMoving()
        window.dragging = true
        window:SetScript("OnUpdate", watchDrag)
        refreshHover()
    end)
    frame:SetScript("OnDragStop", stopDragging)
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

local function scrollRange()
    return math.max(0, (window.rows or 0) - (window.visibleRows or 0)) * ROW_STEP
end

local function placeThumb()
    local maximum = scrollRange()
    if maximum == 0 then return end
    local track = scrollBar:GetHeight()
    local size = math.min(track, math.max(MIN_THUMB, math.floor(track * window.visibleRows / window.rows + 0.5)))
    local position = (track - size) * viewport:GetVerticalScroll() / maximum
    thumb:SetHeight(size)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOPLEFT", scrollBar, "TOPLEFT", 0, -position)
    thumb:SetPoint("TOPRIGHT", scrollBar, "TOPRIGHT", 0, -position)
    scrollBar.thumbTop, scrollBar.thumbSize = position, size
end

-- The view always starts on a row, so that no row is cut at the top or the
-- bottom of the visible part.
local function scrollTo(offset)
    local maximum = scrollRange()
    offset = math.floor(offset / ROW_STEP + 0.5) * ROW_STEP
    offset = math.max(0, math.min(offset, maximum))
    if viewport:GetVerticalScroll() ~= offset then viewport:SetVerticalScroll(offset) end
    placeThumb()
end

local function wheel(_, delta)
    scrollTo(viewport:GetVerticalScroll() - delta * ROW_STEP)
end

local function stopThumb()
    scrollBar.drag = nil
    thumb:SetScript("OnUpdate", nil)
end

local function followThumb()
    local drag = scrollBar.drag
    local _, y = cursor()
    if not drag or not y then return end
    local travel = scrollBar:GetHeight() - (scrollBar.thumbSize or 0)
    if travel > 0 then scrollTo(drag.offset + (drag.y - y) * scrollRange() / travel) end
end

-- A release that never reached the thumb keeps the last position read.
local function dragThumb()
    if not scrollBar.drag then return end
    if buttonReleased() then
        stopThumb()
        return
    end
    followThumb()
end

local function releaseThumb(_, button)
    if button ~= "LeftButton" or not scrollBar.drag then return end
    followThumb()
    stopThumb()
end

-- A click on the track moves the view by one page towards the click.
local function pageTrack(self, button)
    if button ~= "LeftButton" then return end
    local _, y = cursor()
    local top = self:GetTop()
    if not y or not finite(top) then return end
    local depth, offset = top - y, viewport:GetVerticalScroll()
    local page = math.max(1, window.visibleRows or 1) * ROW_STEP
    if depth < (self.thumbTop or 0) then scrollTo(offset - page)
    elseif depth > (self.thumbTop or 0) + (self.thumbSize or 0) then scrollTo(offset + page) end
end

local function followPointer()
    local sizing = window.sizing
    local x = sizing and cursor()
    if not x then return end
    local width = sizing.startWidth + x - sizing.startX
    local atEdge = x >= UIParent:GetWidth() - EDGE_SLOP
    if width == sizing.width and atEdge == sizing.atEdge then return end
    sizing.width, sizing.atEdge = width, atEdge
    layout()
end

-- A release that never reached the grip keeps the last position read.
local function resizeStep()
    if not window.sizing then return end
    if buttonReleased() then
        stopSizing()
        return
    end
    followPointer()
end

-- The release can come with a last move that no frame update has read yet.
local function releaseGrip(_, button)
    if button ~= "LeftButton" or not window.sizing then return end
    followPointer()
    stopSizing()
end

local function startSizing(_, button)
    if button ~= "LeftButton" or window.locked or window.dragging or window.sizing
        or #visibleLines == 0 or not window.corner then return end
    local x = cursor()
    if not x then return end
    local width = window:GetWidth()
    window.sizing = {
        startX = x, startWidth = width, width = width, left = window.corner[1], top = window.corner[2],
        columns = window.columns, startColumns = window.columns, count = #visibleLines, atEdge = false,
    }
    grip:SetScript("OnUpdate", resizeStep)
    refreshHover()
end

local function createWindow()
    window = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    window:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    window:SetBackdropColor(0.07, 0.07, 0.09, 1)
    window:SetSize(LEGACY_MIN_WIDTH, LEGACY_MIN_HEIGHT)
    window:SetFrameStrata("MEDIUM")
    window:SetClampedToScreen(true)
    setDragHandlers(window)
    window:SetScript("OnHide", function()
        stopMovingOrSizing()
        refreshHover()
    end)
    window:SetScript("OnEnter", refreshHover)
    window:SetScript("OnLeave", refreshHover)
    -- The margins scroll too while the rows do not all fit.
    window:SetScript("OnMouseWheel", wheel)

    viewport = CreateFrame("ScrollFrame", nil, window)
    viewport:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING, -PADDING)
    viewport:EnableMouseWheel(true)
    viewport:SetScript("OnMouseWheel", wheel)
    content = CreateFrame("Frame", nil, viewport)
    content:SetSize(cellWidth, CELL_HEIGHT)
    viewport:SetScrollChild(content)

    scrollBar = CreateFrame("Frame", nil, window)
    scrollBar:SetPoint("TOPLEFT", viewport, "TOPRIGHT", SCROLL_GAP, 0)
    scrollBar:SetSize(SCROLL_WIDTH, CELL_HEIGHT)
    scrollBar:EnableMouse(true)
    scrollBar:EnableMouseWheel(true)
    scrollBar:SetScript("OnMouseWheel", wheel)
    scrollBar:SetScript("OnMouseDown", pageTrack)
    scrollBar:SetScript("OnEnter", refreshHover)
    scrollBar:SetScript("OnLeave", refreshHover)
    local track = scrollBar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(scrollBar)
    track:SetColorTexture(0, 0, 0, 0.45)
    thumb = CreateFrame("Frame", nil, scrollBar)
    thumb:SetSize(SCROLL_WIDTH, MIN_THUMB)
    thumb:EnableMouse(true)
    local thumbTexture = thumb:CreateTexture(nil, "ARTWORK")
    thumbTexture:SetAllPoints(thumb)
    thumbTexture:SetColorTexture(0.86, 0.72, 0.43, 0.9)
    thumb:SetScript("OnMouseDown", function(_, button)
        local _, y = cursor()
        if button ~= "LeftButton" or not y then return end
        scrollBar.drag = {y = y, offset = viewport:GetVerticalScroll()}
        thumb:SetScript("OnUpdate", dragThumb)
    end)
    thumb:SetScript("OnMouseUp", releaseThumb)
    thumb:SetScript("OnHide", stopThumb)
    thumb:SetScript("OnEnter", refreshHover)
    thumb:SetScript("OnLeave", refreshHover)
    scrollBar:Hide()

    grip = CreateFrame("Button", nil, window)
    grip:SetSize(GRIP_SIZE, GRIP_SIZE)
    grip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -GRIP_INSET, GRIP_INSET)
    grip:SetFrameLevel(window:GetFrameLevel() + 8)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", startSizing)
    grip:SetScript("OnMouseUp", releaseGrip)
    grip:SetScript("OnEnter", refreshHover)
    grip:SetScript("OnLeave", refreshHover)

    emptyText = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    emptyText:SetPoint("TOPLEFT", window, "TOPLEFT", PADDING, -PADDING)
    emptyText:SetJustifyH("LEFT")
    measure = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    measure:SetPoint("TOPLEFT", window, "TOPLEFT")
    measure:SetAlpha(0)
    refreshHover()
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

local function createLine(id, professionKey)
    local line = CreateFrame("Frame", nil, content)
    line:SetSize(cellWidth, CELL_HEIGHT)
    line:EnableMouse(true)
    setDragHandlers(line)
    local function showRecipeTooltip(self)
        if not GameTooltip or window.dragging or window.sizing then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local ok = GameTooltip.SetSpellByID and pcall(GameTooltip.SetSpellByID, GameTooltip, id)
        if not ok or GameTooltip:NumLines() == 0 then GameTooltip:SetText(line.recipeName) end
        GameTooltip:Show()
    end
    line:SetScript("OnEnter", hoverAware(showRecipeTooltip))
    line:SetScript("OnLeave", hoverAware(hideTooltip))
    line:SetScript("OnHide", hideTooltip)

    local openButton = CreateFrame("Button", nil, line)
    line.openButton = openButton
    openButton:SetSize(ICON_SIZE, ICON_SIZE)
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
    openButton:SetScript("OnEnter", hoverAware(showRecipeTooltip))
    openButton:SetScript("OnLeave", hoverAware(hideTooltip))
    openButton:SetScript("OnHide", hideTooltip)
    line.icon = openButton:CreateTexture(nil, "ARTWORK")
    line.icon:SetAllPoints(openButton)
    line.icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)

    local bag = CreateFrame("Frame", nil, line)
    line.bag = bag
    bag.recipeID = id
    bag:SetSize(BAG_WIDTH, BAG_HEIGHT)
    bag:SetPoint("RIGHT", line, "RIGHT")
    bag:EnableMouse(true)
    setDragHandlers(bag)
    local bagIcon = bag:CreateTexture(nil, "ARTWORK")
    bagIcon:SetAllPoints(bag)
    bagIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
    bag:SetScript("OnEnter", hoverAware(showStockTooltip))
    bag:SetScript("OnLeave", hoverAware(hideTooltip))
    bag:SetScript("OnHide", hideTooltip)

    line.status = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.status:SetPoint("LEFT", line.icon, "RIGHT", STATUS_LEFT, 0)
    line.status:SetPoint("RIGHT", bag, "LEFT", -STATUS_RIGHT, 0)
    line.status:SetJustifyH("LEFT")
    line.status:SetWordWrap(false)
    return line
end

local function timeLabel(remaining)
    if not remaining then return L.TRANSMUTATION_UNKNOWN, 1, 0.76, 0.38 end
    if remaining == 0 then return L.TRANSMUTATION_READY, 0.48, 0.92, 0.55 end
    local seconds = math.ceil(remaining)
    return ("%d:%02d:%02d"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60), 1, 1, 1
end

local function sortRows(a, b)
    local aKey, bKey = a.professionKey or 0, b.professionKey or 0
    if aKey ~= bKey then return aKey < bKey end
    local aRunning, bRunning = (a.remaining or 0) > 0, (b.remaining or 0) > 0
    if aRunning ~= bRunning then return aRunning end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
end

-- Every state label of the player's language, and the longest countdown,
-- fits on one line of a cell, with a little room for pixel rounding.
local function measureCellWidth()
    local function textWidth(text)
        measure:SetText(text)
        local method = measure.GetUnboundedStringWidth or measure.GetStringWidth
        local ok, width = pcall(method, measure)
        if ok and type(width) == "number" and not (issecretvalue and issecretvalue(width))
            and finite(width) and width >= 0 and width < 1000 then return width end
        return 0
    end
    local widest = math.max(textWidth(L.TRANSMUTATION_READY), textWidth(L.TRANSMUTATION_UNKNOWN))
    -- A countdown reaches 47:59:59. Digits can differ in width, so the
    -- widest one is assumed in each of the six places.
    local digit = 0
    for value = 0, 9 do digit = math.max(digit, textWidth(tostring(value))) end
    widest = math.max(widest, textWidth("47:59:59"), 6 * digit + 2 * textWidth(":"))
    measure:SetText("")
    local status = math.max(MIN_STATUS_WIDTH, math.ceil(widest + STATUS_SLACK))
    return ICON_SIZE + STATUS_LEFT + status + STATUS_RIGHT + BAG_WIDTH
end

-- Earlier versions saved the centre of a window sized by `width` and `height`,
-- or by their 97 px default and automatic height. The first display with
-- recipes keeps that window's top-left corner, reads the columns from its
-- width and lets the height follow the rows again. The same happens when an
-- earlier version moved or resized the window since this one saved it.
local function movedElsewhere(prefs)
    return finite(prefs.x) and finite(prefs.y) and (prefs.x ~= prefs.writtenX or prefs.y ~= prefs.writtenY)
end

-- Size of the earlier window. Without a saved height and without recipes,
-- `fallback` stands in for its automatic height.
local function legacySize(prefs, count, fallback)
    local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight()
    local chrome = prefs.locked == true and 0 or LEGACY_GRIP
    local width = LEGACY_MIN_WIDTH
    if finite(prefs.width) then
        width = math.max(LEGACY_MIN_WIDTH, math.min(prefs.width, math.max(LEGACY_MIN_WIDTH, screenWidth - 24)))
    end
    local height = fallback
    if finite(prefs.height) then
        height = math.max(LEGACY_MIN_HEIGHT + chrome, prefs.height)
    elseif count > 0 then
        local columns = math.min(count, legacyColumns(width))
        height = 2 * PADDING + math.ceil(count / columns) * ROW_STEP - CELL_GAP + chrome
    end
    return width, math.min(height, math.max(LEGACY_MIN_HEIGHT + LEGACY_GRIP, screenHeight - 24))
end

local function adopt(prefs, count)
    local current = prefs.layout == ns.Settings.TRANSMUTATION_LAYOUT
    local moved = movedElsewhere(prefs)
    if current and prefs.height == nil and not moved then return end
    -- The earlier window's automatic height depends on the recipes.
    if count == 0 then return end
    if moved then
        local width, height = legacySize(prefs, count)
        prefs.left, prefs.top = prefs.x - width / 2, prefs.y + height / 2
        prefs.writtenX, prefs.writtenY = prefs.x, prefs.y
    end
    if not current and not finite(prefs.width) then prefs.width = legacyWidth(1) end
    prefs.height = nil
    prefs.layout = ns.Settings.TRANSMUTATION_LAYOUT
end

-- Frame size for a number of columns and rows. Rows taller than `available`
-- scroll, and the view keeps whole rows.
local function frameSize(columns, rows, available)
    local bottom = window.locked and PADDING or GRIP_MARGIN
    local width = 2 * PADDING + columns * cellWidth + (columns - 1) * CELL_GAP
    if rows == 0 then
        emptyText:SetWidth(width - 2 * PADDING)
        return width, PADDING + emptyText:GetStringHeight() + bottom, 0
    end
    local fit = math.floor((available - PADDING - bottom + CELL_GAP) / ROW_STEP)
    local visible = math.max(1, math.min(rows, fit))
    if visible < rows then width = width + SCROLL_GAP + SCROLL_WIDTH end
    return width, PADDING + visible * ROW_STEP - CELL_GAP + bottom, visible
end

layout = function()
    if window.dragging then return end
    local prefs = ns.Settings.GetTransmutationOptions()
    local count = #visibleLines
    local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight()
    adopt(prefs, count)
    local sizing = window.sizing
    local available = screenHeight
    local function shape(columns)
        local rows = count > 0 and math.ceil(count / columns) or 0
        local width, height, visible = frameSize(columns, rows, available)
        return width, height, rows, visible
    end

    local screenColumns = math.max(1, math.floor((screenWidth - 2 * PADDING + CELL_GAP) / (cellWidth + CELL_GAP)))
    local columns, width, height, rows, visible, frameWidth
    if sizing then
        -- Follow the pointer between one column and one column per recipe,
        -- within the screen width. A column appears or goes when the pointer
        -- passes half of it, so that one fits next to the default place too.
        local widest, widestWidth = 1, (shape(1))
        for candidate = 2, math.min(count, screenColumns) do
            local candidateWidth = shape(candidate)
            if candidateWidth > screenWidth then break end
            widest, widestWidth = candidate, candidateWidth
        end
        local wanted = sizing.width
        -- At the right screen edge the pointer cannot pass half a column:
        -- reaching the edge asks for one more column than at the start.
        if sizing.atEdge and widest > sizing.startColumns then
            local nextColumns = sizing.startColumns + 1
            wanted = math.max(wanted, ((shape(nextColumns - 1)) + (shape(nextColumns))) / 2)
        end
        columns = 1
        local previous = (shape(1))
        for candidate = 2, widest do
            local candidateWidth = shape(candidate)
            if wanted < (previous + candidateWidth) / 2 then break end
            columns, previous = candidate, candidateWidth
        end
        sizing.columns = columns
        width, height, rows, visible = shape(columns)
        frameWidth = math.max(width, math.min(wanted, widestWidth))
    else
        local chosen
        if finite(prefs.width) then chosen = legacyColumns(prefs.width)
        elseif prefs.layout == ns.Settings.TRANSMUTATION_LAYOUT then chosen = DEFAULT_COLUMNS
        else chosen = 1 end
        -- An empty frame only shows a sentence: no wider than the default grid.
        columns = math.min(chosen, screenColumns, count > 0 and count or DEFAULT_COLUMNS)
        width, height, rows, visible = shape(columns)
        while width > screenWidth and columns > 1 do
            columns = columns - 1
            width, height, rows, visible = shape(columns)
        end
        frameWidth = width
    end

    local left, top
    if sizing then
        left, top = sizing.left, sizing.top
    elseif movedElsewhere(prefs) then
        -- Centre saved by an earlier version, until a display with recipes
        -- converts it: same corner as that version's window.
        local legacyWidthNow, legacyHeight = legacySize(prefs, count, height)
        left = screenWidth / 2 + prefs.x - legacyWidthNow / 2
        top = screenHeight / 2 + prefs.y + legacyHeight / 2
    elseif finite(prefs.left) and finite(prefs.top) then
        left, top = screenWidth / 2 + prefs.left, screenHeight / 2 + prefs.top
    else
        left, top = screenWidth - DEFAULT_RIGHT - frameWidth, (screenHeight + height) / 2
    end
    -- The frame stays on screen, during a gesture too: the corner moves only
    -- as far as the screen edge requires. The saved corner does not change,
    -- so the frame returns to it once there is room again.
    left = math.max(0, math.min(left, screenWidth - frameWidth))
    top = math.max(height, math.min(top, screenHeight))

    local anchorX, anchorY = left - screenWidth / 2, top - screenHeight / 2
    if not window.anchor or window.anchor[1] ~= anchorX or window.anchor[2] ~= anchorY then
        window.anchor = {anchorX, anchorY}
        window:ClearAllPoints()
        window:SetPoint("TOPLEFT", UIParent, "CENTER", anchorX, anchorY)
    end
    window.corner = {left, top}
    if window:GetWidth() ~= frameWidth or window:GetHeight() ~= height then window:SetSize(frameWidth, height) end

    window.columns, window.rows, window.visibleRows = columns, rows, visible
    local gridWidth = columns * cellWidth + (columns - 1) * CELL_GAP
    viewport:SetShown(count > 0)
    if count > 0 then
        viewport:SetSize(gridWidth, visible * ROW_STEP - CELL_GAP)
        content:SetSize(gridWidth, rows * ROW_STEP - CELL_GAP)
        for index, line in ipairs(visibleLines) do
            local x = (index - 1) % columns * (cellWidth + CELL_GAP)
            local y = math.floor((index - 1) / columns) * ROW_STEP
            if line.left ~= x or line.top ~= y then
                line.left, line.top = x, y
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
            end
            if line:GetWidth() ~= cellWidth then line:SetWidth(cellWidth) end
        end
    end
    local scrolling = visible < rows
    scrollBar:SetShown(scrolling)
    if scrolling then scrollBar:SetHeight(visible * ROW_STEP - CELL_GAP) end
    if window.wheel ~= scrolling then
        window.wheel = scrolling
        window:EnableMouseWheel(scrolling)
    end
    scrollTo(viewport:GetVerticalScroll())
end

local function render(rows, prefs)
    if not window then createWindow() end
    local locked = prefs.locked == true
    if window.locked ~= locked then
        if locked then stopMovingOrSizing() end
        window.locked = locked
        window:SetMovable(not locked)
        window:EnableMouse(not locked)
        grip:SetShown(not locked)
    end
    window:SetAlpha(prefs.opacity / 100)

    table.sort(rows, sortRows)
    emptyText:SetShown(#rows == 0)
    if #rows == 0 then
        local state = ns.Bootstrap and ns.Bootstrap.GetState()
        local loading = state and not state.complete and not state.manual and not state.waiting
        emptyText:SetText(loading and L.LOADING_PROFESSION or L.TRANSMUTATION_EMPTY)
    end
    for _, line in ipairs(visibleLines) do line.inUse = false end
    visibleLines = {}
    for _, row in ipairs(rows) do
        local key = row.professionKey or 0
        lines[key] = lines[key] or {}
        local line = lines[key][row.id]
        if not line then
            line = createLine(row.id, row.professionKey)
            lines[key][row.id] = line
        end
        visibleLines[#visibleLines + 1] = line
        line.inUse = true
        line.recipeName = row.name
        line.icon:SetTexture(recipeIcon(row.id))
        local text, r, g, b = timeLabel(row.remaining)
        line.status:SetText(text)
        line.status:SetTextColor(r, g, b)
        line:Show()
    end
    for _, byID in pairs(lines) do
        for _, line in pairs(byID) do
            if not line.inUse then line:Hide() end
        end
    end
    cellWidth = measureCellWidth()
    layout()
    window:Show()
    refreshHover()
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
    -- While the grip is held, the recipes are read as during the gesture, even
    -- if the window is being hidden: both counts then come from the same sources.
    local rows = ns.API.ReadTransmutationCooldowns(alert or popup or (window ~= nil and window.sizing ~= nil))
    -- Any change in the number of recipes during a gesture cancels its column
    -- choice. It is noted here, before a lock or a hide below can end it.
    if window and window.sizing and #rows ~= window.sizing.count then window.sizing.countChanged = true end
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
