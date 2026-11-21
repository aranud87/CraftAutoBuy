local _, ns = ...
local L = ns.L
local StockUI = {}
ns.StockUI = StockUI

local ICON = "Interface\\Icons\\INV_Misc_Bag_10"
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local book, panel, returnPage
local switching, rendering = false, false
local widgets = {}

local function label(parent, font, x, y, width, height)
    local value = parent:CreateFontString(nil, "OVERLAY", font)
    value:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    value:SetSize(width, height)
    value:SetJustifyH("LEFT")
    value:SetJustifyV("TOP")
    return value
end

local function refreshSidebar()
    if ns.Sidebar then ns.Sidebar.Refresh() end
end

function StockUI.IsActive()
    return ns.stockActive == true
end

local function setBookArt()
    if ns.BookArt then ns.BookArt.Acquire(book, "stock", L.STOCK_TITLE, ICON) end
end

local function restoreBookArt()
    if ns.BookArt then ns.BookArt.Release(book, "stock") end
end

-- CAB unchecked every native tab while it was selected. Back on the crafting
-- page, check the tab of the profession Blizzard last selected (read only:
-- writing Blizzard's fields from addon code would taint its later reads).
local function checkProfessionTab()
    local skillLine = book and book.selectedSkillLine
    if skillLine == nil then return end
    if book.ProfessionsOverviewTab then book.ProfessionsOverviewTab:SetChecked(false) end
    for _, nativeTab in ipairs(book.rightProfessionTabs or {}) do
        if nativeTab.skillLine ~= nil then nativeTab:SetChecked(nativeTab.skillLine == skillLine) end
    end
end

local function deactivate(restore)
    if not StockUI.IsActive() and not restore then return end
    ns.stockActive = false
    if panel then panel:Hide(); restoreBookArt() end
    refreshSidebar()
    if not restore or not book or not book:IsShown() then return end
    switching = true
    local ok, reason = pcall(function()
        if returnPage == book.CraftingPage and book.CraftingPage.professionInfo then
            if book.BookPage then book.BookPage:Hide() end
            book.CraftingPage:Show()
            checkProfessionTab()
        elseif book.SelectBookPage and not (ns.Sidebar and ns.Sidebar.IsGamepadMode
            and ns.Sidebar.IsGamepadMode()) then
            book:SelectBookPage()
        elseif book.BookPage then
            -- In gamepad mode SelectBookPage would select a SmartNavigation
            -- button from addon code, which Forever refuses on the overview.
            -- Show the page only and leave the focus to Blizzard.
            if book.CraftingPage then book.CraftingPage:Hide() end
            book.BookPage:Show()
            -- The art SelectBookPage would set; a profession refresh may have
            -- renamed the hidden book meanwhile.
            if book.SetPortraitToAsset then book:SetPortraitToAsset("Interface/ICONS/INV_SideTab_Professions_c60") end
            if book.SetTitleFormatted and TRADE_SKILL_TITLE and TRADE_SKILLS then
                book:SetTitleFormatted(TRADE_SKILL_TITLE, TRADE_SKILLS)
            end
            if book.ProfessionsOverviewTab then book.ProfessionsOverviewTab:SetChecked(true) end
            for _, nativeTab in ipairs(book.rightProfessionTabs or {}) do nativeTab:SetChecked(false) end
        end
    end)
    switching = false
    if not ok then error(reason) end
end

function StockUI.Hide()
    deactivate(true)
end

function StockUI.NativeTabSelected()
    deactivate(false)
    return returnPage
end

local function displayPage()
    switching = true
    if book.CraftingPage then book.CraftingPage:Hide() end
    if book.BookPage then book.BookPage:Hide() end
    panel:Show()
    setBookArt()
    refreshSidebar()
    switching = false
end

local installed, restoringScroll = false, false
local searchScroll = {bags = 0, bank = 0, inventory = 0}
local fallbackView = {content = "components", inventory = false, extensionsExpanded = false,
    comparisonSize = 20, scroll = {bags = 0, bank = 0, inventory = 0}}
local lastData
local LIST_TOP, LIST_HEIGHT, COMPACT_LIST_HEIGHT = 94, 315, 171

local function searchQuery()
    return ns.Locale.TrimSearch(widgets.search:GetText())
end

local function view()
    return ns.StockView and ns.StockView.Get() or fallbackView
end

local function preference(method, field, value)
    if ns.StockView and ns.StockView[method] then return ns.StockView[method](value) end
    fallbackView[field] = value
    return true
end

local function tooltip(owner, text)
    if not GameTooltip then return end
    -- A cleared native FontString returns nil, not an empty string.
    if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) or text == "" then
        GameTooltip:Hide()
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    -- Use the native tooltip width for localized help instead of one long line.
    GameTooltip:SetText(text, 1, .82, 0, 1, true)
    GameTooltip:Show()
end

local function hideTooltip() if GameTooltip then GameTooltip:Hide() end end

local function help(control, text)
    control:SetScript("OnEnter", function(self) tooltip(self, text()) end)
    control:SetScript("OnLeave", hideTooltip)
end

local function button(parent, text, x, y, width, handler)
    local value = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    value:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    value:SetSize(width, 22)
    value:SetText(text)
    value:SetNormalFontObject("GameFontNormalSmall")
    value:SetHighlightFontObject("GameFontHighlightSmall")
    value:SetDisabledFontObject("GameFontDisableSmall")
    if value.Text then value.Text:SetWordWrap(false); value.Text:SetMaxLines(1) end
    value:SetScript("OnClick", handler)
    return value
end

local function selector(parent, x, y, width, handler)
    local value = CreateFrame("Button", nil, parent, "BackdropTemplate")
    value:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    value:SetSize(width, 24)
    value:SetBackdrop({bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16,
        edgeSize = 10, insets = {left = 3, right = 3, top = 3, bottom = 3}})
    value:SetBackdropColor(.08, .07, .05, 1)
    value:SetBackdropBorderColor(.58, .47, .30, 1)
    local caption = value:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("LEFT", value, "LEFT", 8, 0)
    caption:SetSize(width - 31, 18)
    caption:SetJustifyH("LEFT"); caption:SetJustifyV("MIDDLE"); caption:SetWordWrap(false); caption:SetMaxLines(1)
    value:SetFontString(caption)
    value:SetNormalFontObject("GameFontNormalSmall")
    value:SetHighlightFontObject("GameFontHighlightSmall")
    value:SetDisabledFontObject("GameFontDisableSmall")
    local arrow = value:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetPoint("RIGHT", value, "RIGHT", -4, 0)
    arrow:SetSize(16, 16)
    value.Caption, value.Arrow = caption, arrow
    value:SetScript("OnClick", handler)
    return value
end

local function nativeTextWidth(fontString, fallback)
    local method = fontString.GetUnboundedStringWidth or fontString.GetStringWidth
    if type(method) == "function" then
        local ok, width = pcall(method, fontString)
        if ok and type(width) == "number" and not (issecretvalue and issecretvalue(width))
            and width == width and width >= 0 and width < 10000 then return math.ceil(width) end
    end
    -- Compatibility only; the native font measurement is used in Forever.
    return #fallback * 7
end

local function measureText(text)
    widgets.measure:SetText(text)
    return nativeTextWidth(widgets.measure, text)
end

local function layoutToolbar(professionName)
    local gap, available = 8, 626 -- Inside the 650px page, x=14..640.
    local contentWidth = math.min(150, math.max(110,
        math.max(measureText(L.STOCK_COMPONENTS), measureText(L.STOCK_ALL)) + 31))
    local professionWidth = math.min(185, math.max(145,
        math.max(measureText(L.STOCK_ALL_PROFESSIONS), measureText(professionName)) + 31))
    local checkWidth = math.min(125, math.max(80,
        nativeTextWidth(widgets.inventoryFilter.Label, L.STOCK_INVENTORY_MODE) + 25))
    local searchWidth = math.min(200, available - contentWidth - professionWidth - checkWidth - gap * 3)
    local extra = available - searchWidth - contentWidth - professionWidth - checkWidth - gap * 3
    local grow = math.min(extra, 185 - professionWidth)
    professionWidth, extra = professionWidth + grow, extra - grow
    contentWidth = contentWidth + math.min(extra, 150 - contentWidth)

    widgets.search:ClearAllPoints(); widgets.search:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -12)
    widgets.search:SetSize(searchWidth, 20)
    local x = 14 + searchWidth + gap
    for _, entry in ipairs({{widgets.contentFilter, contentWidth}, {widgets.professionFilter, professionWidth}}) do
        local control, width = entry[1], entry[2]
        control:ClearAllPoints(); control:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -10)
        control:SetSize(width, 24); control.Caption:SetSize(width - 31, 18)
        x = x + width + gap
    end
    widgets.inventoryFilter:ClearAllPoints()
    widgets.inventoryFilter:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -11)
    widgets.inventoryFilter.Label:SetSize(checkWidth - 25, 18)
    widgets.inventoryFilter:SetHitRectInsets(0, -(checkWidth - 22), 0, 0)
end

local function showMenu(owner, title, choices, selected, choose)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle(title)
            root:SetScrollMode(220)
            for _, choice in ipairs(choices) do
                root:CreateRadio(choice.text, selected, choose, choice.value)
            end
        end)
        return
    end
    -- Native frame/button fallback for clients without the shared menu API.
    local menu = widgets.menu
    if not menu then
        menu = CreateFrame("Frame", nil, panel)
        menu:SetFrameStrata("TOOLTIP")
        menu:SetFrameLevel(panel:GetFrameLevel() + 20)
        local background = menu:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(menu)
        background:SetColorTexture(.08, .07, .05, 1)
        menu.rows = {}
        menu:Hide()
        widgets.menu = menu
    end
    if menu:IsShown() and menu.owner == owner then menu:Hide(); return end
    menu.owner = owner
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    menu:SetSize(220, 8 + #choices * 24)
    for index, choice in ipairs(choices) do
        local row = menu.rows[index]
        if not row then row = button(menu, "", 4, -4 - (index - 1) * 24, 212); menu.rows[index] = row end
        row:SetText((selected(choice.value) and "|cffffd100" or "") .. choice.text)
        row:SetScript("OnClick", function() menu:Hide(); choose(choice.value) end)
        row:Show()
    end
    for index = #choices + 1, #menu.rows do menu.rows[index]:Hide() end
    menu:Show()
end

local function rememberScroll(column, offset)
    if rendering or restoringScroll then return end
    if offset == nil and column.scroll.GetVerticalScroll then offset = column.scroll:GetVerticalScroll() end
    if offset == nil and column.scroll.ScrollBar and column.scroll.ScrollBar.GetValue then
        offset = column.scroll.ScrollBar:GetValue()
    end
    if type(offset) ~= "number" or (issecretvalue and issecretvalue(offset)) or offset ~= offset
        or offset < 0 or offset == math.huge then return end
    if searchQuery() ~= "" then searchScroll[column.key] = offset
    elseif ns.StockView then ns.StockView.SetScroll(column.key, offset)
    else fallbackView.scroll[column.key] = offset end
end

local function makeRow(column, inventory)
    -- Informational item frames never purchase, craft, or move an item.
    local row = CreateFrame("Frame", nil, column.content)
    row:SetSize(inventory and 614 or 284, 40)
    row:EnableMouse(true)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -4)
    row.Icon:SetSize(32, 32)
    row.Name = label(row, "GameFontHighlight", 40, -4, inventory and 280 or 190, 32)
    row.Name:SetWordWrap(true)
    row.Name:SetMaxLines(2)
    if inventory then
        row.BagCount = label(row, "GameFontHighlight", 330, -4, 76, 32)
        row.BankCount = label(row, "GameFontHighlight", 414, -4, 76, 32)
        row.Total = label(row, "GameFontNormal", 498, -4, 76, 32)
        row.BagCount:SetJustifyH("RIGHT"); row.BankCount:SetJustifyH("RIGHT"); row.Total:SetJustifyH("RIGHT")
    else
        row.Count = label(row, "GameFontHighlight", 237, -4, 45, 32)
        row.Count:SetJustifyH("RIGHT")
    end
    row:SetScript("OnEnter", function(self)
        if not GameTooltip or not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID)
        else GameTooltip:SetText(self.Name:GetText()) end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", hideTooltip)
    return row
end

local function makeColumn(name, key, x, inventory)
    local frame = CreateFrame("Frame", name, panel)
    frame:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -LIST_TOP)
    frame:SetSize(inventory and 642 or 312, LIST_HEIGHT + 24)
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetAtlas("Professions-background-summarylist")
    local heading = label(frame, "GameFontHighlightSmall", 10, -2, 280, 18)
    local headers = {}
    if inventory then
        for index, left in ipairs({340, 424, 508}) do
            headers[index] = label(frame, "GameFontHighlightSmall", left, -2, 76, 18)
            headers[index]:SetJustifyH("RIGHT")
        end
    else
        headers[1] = label(frame, "GameFontHighlightSmall", 247, -2, 45, 18)
        headers[1]:SetJustifyH("RIGHT")
    end
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 9, -24)
    scroll:SetSize(inventory and 614 or 284, LIST_HEIGHT)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(inventory and 614 or 284, LIST_HEIGHT)
    scroll:SetScrollChild(content)
    local empty = label(frame, "GameFontHighlight", 12, -38, inventory and 590 or 276, 72)
    empty:SetWordWrap(true)
    local column = {key = key, frame = frame, scroll = scroll, content = content,
        empty = empty, rows = {}, title = heading, headers = headers, inventory = inventory}
    frame.Rows, frame.Scroll, frame.EmptyText = column.rows, scroll, empty
    frame.ObjectHeading, frame.Headers = heading, headers
    -- A generic OnVerticalScroll also runs after deferred native clamping.
    -- Persist only explicit user input, never those programmatic events.
    scroll:HookScript("OnMouseWheel", function() rememberScroll(column) end)
    local scrollbar = scroll.ScrollBar
    if scrollbar then
        scrollbar:HookScript("OnValueChanged", function(_, offset, userInput)
            if userInput == true then rememberScroll(column, offset) end
        end)
        for _, arrow in pairs({scrollbar.ScrollUpButton, scrollbar.ScrollDownButton}) do
            arrow:HookScript("OnClick", function() rememberScroll(column) end)
        end
    end
    return column
end

local function capacitySummary(x)
    local value = {heading = label(panel, "GameFontNormalLarge", x, -50, 150, 20),
        used = label(panel, "GameFontHighlightSmall", x + 150, -53, 140, 18),
        free = label(panel, "GameFontHighlightSmall", x, -73, 145, 16),
        total = label(panel, "GameFontHighlightSmall", x + 145, -73, 145, 16)}
    value.used:SetJustifyH("RIGHT"); value.total:SetJustifyH("RIGHT")
    local hit = CreateFrame("Frame", nil, panel)
    hit:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -48)
    hit:SetSize(292, 42); hit:EnableMouse(true)
    help(hit, function()
        local descriptor = value.data or {}
        local text = L.STOCK_CAPACITY_HELP
        if descriptor.generalFree ~= nil then text = text .. "\n" .. L.STOCK_SLOTS_GENERAL:format(descriptor.generalFree) end
        if descriptor.specializedFree and descriptor.specializedFree > 0 then
            text = text .. "\n" .. L.STOCK_CAPACITY_SPECIALIZED:format(descriptor.specializedFree)
        end
        return text
    end)
    return value
end

function StockUI.Install()
    if panel then return installed end
    if not ProfessionsFrame then return false end
    book = ProfessionsFrame
    panel = CreateFrame("Frame", "CraftAutoBuyStockPage", book)
    panel:SetSize(650, 510)
    panel:SetPoint("TOPLEFT", book, "TOPLEFT", 12, -74)
    panel:SetFrameLevel(book:GetFrameLevel() + 5)
    panel.Background = panel:CreateTexture(nil, "BACKGROUND")
    panel.Background:SetAllPoints(panel)
    panel.Background:SetAtlas("Profession-Background-Template2")
    panel:Hide()
    widgets.measure = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    widgets.measure:Hide()

    widgets.search = CreateFrame("EditBox", "CraftAutoBuyStockSearchBox", panel, "SearchBoxTemplate")
    widgets.search:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -12)
    widgets.search:SetSize(200, 20)
    widgets.search:SetAutoFocus(false); widgets.search:SetMaxLetters(80)
    widgets.search:SetScript("OnTextChanged", function(self)
        if SearchBoxTemplate_OnTextChanged then SearchBoxTemplate_OnTextChanged(self) end
        if installed then
            searchScroll = {bags = 0, bank = 0, inventory = 0}
            StockUI.Render(true)
        end
    end)
    widgets.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    widgets.contentFilter = selector(panel, 222, -10, 130, function(self)
        showMenu(self, L.STOCK_SHOW, {{text = L.STOCK_COMPONENTS, value = "components"}, {text = L.STOCK_ALL, value = "all"}},
            function(value) return view().content == value end,
            function(value) preference("SetContent", "content", value); StockUI.Render() end)
    end)
    help(widgets.contentFilter, function() return L.STOCK_SHOW .. ": " .. (widgets.contentFilter:GetText() or "") end)
    widgets.professionFilter = selector(panel, 360, -10, 170, function(self)
        if view().content == "all" then return end
        local choices = {{text = L.STOCK_ALL_PROFESSIONS, value = false}}
        for _, profession in ipairs(lastData and lastData.professions or {}) do
            choices[#choices + 1] = {text = profession.name, value = profession.key}
        end
        showMenu(self, L.STOCK_PROFESSION, choices,
            function(value) return (view().professionKey or false) == value end,
            function(value) preference("SetProfession", "professionKey", value or nil); StockUI.Render() end)
    end)
    help(widgets.professionFilter, function()
        return (widgets.professionFilter:GetText() or L.STOCK_PROFESSION) .. "\n" .. L.STOCK_PROFESSION_HELP
    end)
    widgets.inventoryFilter = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    widgets.inventoryFilter:SetPoint("TOPLEFT", panel, "TOPLEFT", 538, -11)
    widgets.inventoryFilter:SetSize(22, 22)
    local checkText = widgets.inventoryFilter.Text or widgets.inventoryFilter:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    checkText:ClearAllPoints(); checkText:SetPoint("LEFT", widgets.inventoryFilter, "RIGHT", 3, 0)
    checkText:SetSize(77, 18); checkText:SetJustifyH("LEFT"); checkText:SetJustifyV("MIDDLE")
    checkText:SetWordWrap(false); checkText:SetMaxLines(1)
    widgets.inventoryFilter.Label = checkText
    widgets.inventoryFilter:SetHitRectInsets(0, -80, 0, 0)
    widgets.inventoryFilter:SetScript("OnClick", function(self)
        preference("SetInventory", "inventory", self:GetChecked() == true); StockUI.Render()
    end)
    help(widgets.inventoryFilter, function() return L.STOCK_INVENTORY_HELP end)
    widgets.bagCapacity, widgets.bankCapacity = capacitySummary(14), capacitySummary(344)
    widgets.bags = makeColumn("CraftAutoBuyStockBags", "bags", 4)
    widgets.bank = makeColumn("CraftAutoBuyStockBank", "bank", 334)
    widgets.inventory = makeColumn("CraftAutoBuyStockInventory", "inventory", 4, true)
    widgets.bags.heading, widgets.bank.heading = widgets.bagCapacity.heading, widgets.bankCapacity.heading
    widgets.bags.frame.Heading, widgets.bank.frame.Heading = widgets.bags.heading, widgets.bank.heading
    widgets.source = label(panel, "GameFontHighlightSmall", 14, -439, 300, 18)
    widgets.scope = label(panel, "GameFontHighlightSmall", 326, -439, 310, 18)
    widgets.scope:SetJustifyH("RIGHT")
    widgets.capacityToggle = button(panel, "", 9, -461, 631, function()
        preference("SetExtensions", "extensionsExpanded", not view().extensionsExpanded); StockUI.Render()
    end)
    widgets.extensions = CreateFrame("Frame", nil, panel)
    widgets.extensions:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -346)
    widgets.extensions:SetSize(620, 140)
    widgets.equipped = label(widgets.extensions, "GameFontNormalSmall", 0, 0, 300, 18)
    widgets.sizes = label(widgets.extensions, "GameFontHighlightSmall", 0, -21, 300, 26)
    widgets.sizes:SetWordWrap(true)
    widgets.compareLabel = label(widgets.extensions, "GameFontHighlightSmall", 0, -49, 246, 18)
    widgets.comparison = CreateFrame("EditBox", nil, widgets.extensions, "InputBoxTemplate")
    widgets.comparison:SetPoint("TOPLEFT", widgets.extensions, "TOPLEFT", 251, -47)
    widgets.comparison:SetSize(42, 20); widgets.comparison:SetAutoFocus(false)
    widgets.comparison:SetNumeric(true); widgets.comparison:SetMaxLetters(3)
    local function commitSize(self)
        local size = tonumber(self:GetText())
        if size and size == math.floor(size) and size >= 1 and size <= 100 then
            preference("SetComparisonSize", "comparisonSize", size)
        end
        self:ClearFocus(); StockUI.Render()
    end
    widgets.comparison:SetScript("OnEnterPressed", commitSize)
    widgets.comparison:SetScript("OnEditFocusLost", commitSize)
    widgets.comparison:SetScript("OnEscapePressed", function(self) self:ClearFocus(); StockUI.Render() end)
    widgets.gain = label(widgets.extensions, "GameFontHighlightSmall", 0, -77, 300, 36)
    widgets.gain:SetWordWrap(true)
    widgets.bankEquipped = label(widgets.extensions, "GameFontNormalSmall", 330, 0, 286, 18)
    widgets.bankSizes = label(widgets.extensions, "GameFontHighlightSmall", 330, -21, 286, 26)
    widgets.bankSizes:SetWordWrap(true)
    widgets.bankExtension = label(widgets.extensions, "GameFontNormalSmall", 330, -49, 286, 28)
    widgets.bankExtension:SetWordWrap(true)
    widgets.bankGain = label(widgets.extensions, "GameFontHighlightSmall", 330, -80, 286, 32)
    widgets.bankGain:SetWordWrap(true)
    widgets.bankCost = label(widgets.extensions, "GameFontHighlightSmall", 330, -114, 286, 22)
    widgets.bankCost:SetWordWrap(true)
    widgets.missing = label(panel, "GameFontHighlightSmall", 14, -490, 620, 18)
    widgets.missing:SetWordWrap(false)
    widgets.missingHit = CreateFrame("Frame", nil, panel)
    widgets.missingHit:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -490)
    widgets.missingHit:SetSize(620, 18); widgets.missingHit:EnableMouse(true)
    widgets.missingHit:SetScript("OnEnter", function(self)
        tooltip(self, widgets.missing:GetText())
    end)
    widgets.missingHit:SetScript("OnLeave", hideTooltip)
    panel.SearchBox, panel.Bags, panel.Bank = widgets.search, widgets.bags.frame, widgets.bank.frame
    panel.MissingProfessions = widgets.missing
    panel.ContentFilter, panel.ProfessionFilter = widgets.contentFilter, widgets.professionFilter
    panel.InventoryFilter, panel.Inventory = widgets.inventoryFilter, widgets.inventory.frame
    panel.CapacityToggle, panel.ComparisonSize = widgets.capacityToggle, widgets.comparison
    panel.BagCapacity, panel.BankCapacity = widgets.bagCapacity, widgets.bankCapacity
    panel.Extensions, panel.ExtensionGain, panel.BankExtension = widgets.extensions, widgets.gain, widgets.bankExtension
    panel.BankBagsEquipped, panel.BankBagSizes = widgets.bankEquipped, widgets.bankSizes
    panel.BankUpgradeGain, panel.BankCost = widgets.bankGain, widgets.bankCost
    panel.SourceText, panel.ScopeText = widgets.source, widgets.scope
    for _, nativePage in pairs({book.CraftingPage, book.BookPage}) do
        nativePage:HookScript("OnShow", function(self)
            returnPage = self
            if StockUI.IsActive() and not switching and ns.Sidebar and ns.Sidebar.IsGamepadMode
                and ns.Sidebar.IsGamepadMode() then deactivate(false); return end
            if StockUI.IsActive() and not switching then self:Hide() end
        end)
    end
    panel:SetScript("OnHide", function() if widgets.menu then widgets.menu:Hide() end end)
    book:HookScript("OnHide", function() if not switching then deactivate(false) end end)
    installed = true
    if ns.Sidebar then ns.Sidebar.Install() end
    return true
end

local function countText(value) return value == nil and "?" or tostring(value) end

local function renderColumn(column, entries, emptyText, height)
    for index, entry in ipairs(entries) do
        local row = column.rows[index]
        if not row then row = makeRow(column, column.inventory); column.rows[index] = row end
        row.itemID = entry.itemID
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", column.content, "TOPLEFT", 0, -(index - 1) * 40)
        row.Icon:SetTexture(entry.icon or QUESTION_MARK); row.Name:SetText(entry.name)
        if column.inventory then
            row.BagCount:SetText(countText(entry.bagCount)); row.BankCount:SetText(countText(entry.bankCount))
            row.Total:SetText(countText(entry.total))
        else row.Count:SetText(countText(entry.count)) end
        row:Show()
    end
    for index = #entries + 1, #column.rows do column.rows[index].itemID = nil; column.rows[index]:Hide() end
    column.frame:SetHeight(height + 24); column.scroll:SetHeight(height)
    column.content:SetHeight(math.max(height, #entries * 40))
    column.empty:SetText(emptyText); column.empty:SetShown(#entries == 0)
    local desired = searchQuery() ~= "" and searchScroll[column.key] or view().scroll[column.key] or 0
    restoringScroll = true
    column.scroll:SetVerticalScroll(math.min(desired, math.max(0, #entries * 40 - height)))
    restoringScroll = false
end

local function dataFor(search, state, searchOnly)
    if ns.Stock and ns.Stock.View then return ns.Stock.View(search, state, searchOnly) end
    local bags, bank, known, missing = {}, {}, false, {}
    if ns.Stock and ns.Stock.Rows then bags, bank, known, missing = ns.Stock.Rows(search) end
    return {bags = bags, bank = bank, bankKnown = known, bagsKnown = true,
        missing = missing, professions = {}, inventory = {}, capacity = {}, extensions = {}}
end

local function renderCapacity(widget, descriptor)
    descriptor = descriptor or {}
    widget.data = descriptor
    if descriptor.known and descriptor.total ~= nil and descriptor.used ~= nil and descriptor.free ~= nil then
        widget.used:SetText(L.STOCK_CAPACITY_USED:format(descriptor.used))
        widget.free:SetText(L.STOCK_CAPACITY_FREE:format(descriptor.free))
        widget.total:SetText(L.STOCK_CAPACITY_TOTAL:format(descriptor.total))
    else
        widget.used:SetText("?"); widget.free:SetText(L.STOCK_CAPACITY_UNKNOWN); widget.total:SetText("")
    end
end

local function bagDetails(capacity, size)
    capacity = capacity or {}
    local equipped, sizes, replacements, gain, uncertain = 0, {}, 0, 0, false
    if capacity.known then
        for _, container in ipairs(capacity.containers or {}) do
            if type(container.id) == "number" and container.id > 0 and type(container.size) == "number" and container.size > 0 then
                equipped = equipped + 1
                sizes[#sizes + 1] = L.STOCK_BAG_SLOTS:format(container.size)
                if container.size < size then
                    if container.family == 0 then
                        replacements = replacements + 1
                        gain = gain + size - container.size
                    elseif type(container.family) ~= "number" then
                        -- An unread bag type could change the total gain.
                        uncertain = true
                    end
                end
            end
        end
    end
    local result = L.STOCK_UPGRADE_UNKNOWN
    if capacity.known and not uncertain then
        result = replacements > 0 and L.STOCK_UPGRADE_GAIN:format(gain, replacements)
            or L.STOCK_UPGRADE_NONE:format(size)
    end
    return capacity.known and equipped or nil, table.concat(sizes, " / "), result
end

local function renderExtensions(data, state)
    local equipped, sizes, gain = bagDetails(data.capacity and data.capacity.bags, state.comparisonSize)
    widgets.equipped:SetText(equipped and L.STOCK_BAGS_EQUIPPED:format(equipped) or L.STOCK_UPGRADE_UNKNOWN)
    widgets.sizes:SetText(sizes)
    widgets.gain:SetText(gain)
    local bankEquipped, bankSizes, bankGain = bagDetails(data.bankBags, state.comparisonSize)
    widgets.bankEquipped:SetText(bankEquipped and L.STOCK_BANK_BAGS_EQUIPPED:format(bankEquipped) or L.STOCK_UPGRADE_UNKNOWN)
    widgets.bankSizes:SetText(bankSizes); widgets.bankGain:SetText(bankGain)
    widgets.compareLabel:SetText(L.STOCK_UPGRADE_TARGET)
    if not widgets.comparison:HasFocus() then widgets.comparison:SetText(tostring(state.comparisonSize)) end
    local bank = data.extensions and data.extensions.bank or {}
    if bank.known and bank.remaining ~= nil then
        if bank.purchased == 0 and bank.remaining > 0 then
            -- The first purchase is fixed storage, not an optional bag slot.
            widgets.bankExtension:SetText(L.STOCK_UPGRADE_UNKNOWN)
        else
            widgets.bankExtension:SetText(bank.remaining > 0 and L.STOCK_BANK_UNLOCKABLE:format(bank.remaining,
                state.comparisonSize, bank.remaining * state.comparisonSize) or L.STOCK_BANK_FULLY_UNLOCKED)
        end
        if bank.nextCost ~= nil then
            local money = GetCoinTextureString and GetCoinTextureString(bank.nextCost)
                or GetMoneyString and GetMoneyString(bank.nextCost) or tostring(bank.nextCost)
            widgets.bankCost:SetText(L.STOCK_BANK_NEXT_COST:format(money))
        else widgets.bankCost:SetText("") end
    else widgets.bankExtension:SetText(L.STOCK_BANK_EXTENSION_UNKNOWN); widgets.bankCost:SetText("") end
end

local function renderNow(searchOnly)
    if book:IsShown() and not panel:IsShown() then displayPage() end
    setBookArt()
    local state, search = view(), searchQuery()
    local data = dataFor(search, state, searchOnly)
    if data.professionsComplete and state.professionKey then
        local found = false
        for _, profession in ipairs(data.professions or {}) do if profession.key == state.professionKey then found = true; break end end
        if not found then preference("SetProfession", "professionKey", nil); state = view(); data = dataFor(search, state) end
    end
    lastData = data
    widgets.contentFilter:SetText(state.content == "all" and L.STOCK_ALL or L.STOCK_COMPONENTS)
    local professionName = L.STOCK_ALL_PROFESSIONS
    if state.professionKey then
        professionName = tostring(state.professionKey)
        for _, profession in ipairs(data.professions or {}) do if profession.key == state.professionKey then professionName = profession.name; break end end
    end
    widgets.professionFilter:SetText(professionName)
    widgets.professionFilter:SetEnabled(state.content ~= "all")
    widgets.professionFilter.Arrow:SetAlpha(state.content == "all" and .4 or 1)
    widgets.inventoryFilter.Label:SetText(L.STOCK_INVENTORY_MODE); widgets.inventoryFilter:SetChecked(state.inventory)
    layoutToolbar(professionName)
    widgets.bags.heading:SetText(L.STOCK_BAGS); widgets.bank.heading:SetText(L.STOCK_BANK)
    widgets.bags.title:SetText(L.STOCK_OBJECT); widgets.bank.title:SetText(L.STOCK_OBJECT)
    widgets.bags.headers[1]:SetText(L.STOCK_QUANTITY); widgets.bank.headers[1]:SetText(L.STOCK_QUANTITY)
    widgets.inventory.title:SetText(L.STOCK_OBJECT)
    for index, text in ipairs({L.STOCK_BAGS, L.STOCK_BANK, L.STOCK_TOTAL}) do widgets.inventory.headers[index]:SetText(text) end
    widgets.bags.frame:SetShown(not state.inventory); widgets.bank.frame:SetShown(not state.inventory)
    widgets.inventory.frame:SetShown(state.inventory)
    local bankOpen = ns.Stock and ns.Stock.IsBankOpen and ns.Stock.IsBankOpen()
    local initializing = state.content ~= "all" and ns.Bootstrap and ns.Bootstrap.StatusText() or nil
    local empty = initializing and L.STOCK_INITIALIZING or nil
    local bagEmpty = data.bagsKnown == false and L.STOCK_BAGS_LOADING or (search ~= "" and L.STOCK_NO_RESULTS
        or empty or (state.content == "all" and L.STOCK_EMPTY_ALL_BAGS or L.STOCK_EMPTY_BAGS))
    local bankEmpty = not data.bankKnown and (bankOpen and L.STOCK_BANK_LOADING or L.STOCK_BANK_UNKNOWN)
        or (search ~= "" and L.STOCK_NO_RESULTS or empty or (state.content == "all" and L.STOCK_EMPTY_ALL_BANK or L.STOCK_EMPTY_BANK))
    local height = state.extensionsExpanded and COMPACT_LIST_HEIGHT or LIST_HEIGHT
    if not state.inventory then
        renderColumn(widgets.bags, data.bags or {}, bagEmpty, height)
        renderColumn(widgets.bank, (data.bankKnown or data.bankPartial) and data.bank or {}, bankEmpty, height)
    end
    local inventoryEmpty = data.bagsKnown == false and L.STOCK_BAGS_LOADING or empty
        or not data.bankKnown and bankEmpty
        or (search ~= "" and L.STOCK_NO_RESULTS or (state.content == "all"
            and (L.STOCK_EMPTY_ALL_BAGS .. " " .. L.STOCK_EMPTY_ALL_BANK)
            or (L.STOCK_EMPTY_BAGS .. " " .. L.STOCK_EMPTY_BANK)))
    if state.inventory then renderColumn(widgets.inventory, data.inventory or {}, inventoryEmpty, height) end
    renderCapacity(widgets.bagCapacity, data.capacity and data.capacity.bags)
    renderCapacity(widgets.bankCapacity, data.capacity and data.capacity.bank)
    local footerY = LIST_TOP + 24 + height + 6
    widgets.source:ClearAllPoints(); widgets.source:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -footerY)
    widgets.scope:ClearAllPoints(); widgets.scope:SetPoint("TOPLEFT", panel, "TOPLEFT", 326, -footerY)
    widgets.source:SetText((bankOpen and L.STOCK_BANK_CURRENT or L.STOCK_BANK_MEMORY) .. ((data.bankPartial or data.bankUnverified) and " (?)" or ""))
    widgets.scope:SetText(state.content == "all" and L.STOCK_ALL_OBJECTS or L.STOCK_COMPONENTS_KNOWN)
    widgets.capacityToggle:ClearAllPoints(); widgets.capacityToggle:SetPoint("TOPLEFT", panel, "TOPLEFT", 9, -(footerY + 22))
    widgets.capacityToggle:SetText((state.extensionsExpanded and "- " or "+ ") .. L.STOCK_CAPACITY_EXTENSIONS)
    widgets.extensions:SetShown(state.extensionsExpanded)
    if state.extensionsExpanded then renderExtensions(data, state) end
    local names = {}
    for _, profession in ipairs(data.missing or {}) do names[#names + 1] = profession.name end
    widgets.missing:SetText(data.bagsKnown == false and L.STOCK_BAGS_LOADING or initializing or (state.content ~= "all" and #names > 0
        and L.STOCK_MISSING_PROFESSIONS:format(table.concat(names, ", ")) or ""))
end

function StockUI.Render(searchOnly)
    if rendering or not StockUI.IsActive() or not StockUI.Install() then return end
    if ns.Sidebar and ns.Sidebar.IsGamepadMode and ns.Sidebar.IsGamepadMode() then ns.Sidebar.RequestNativeRestore(); return end
    rendering = true
    local ok, reason = pcall(renderNow, searchOnly == true)
    rendering = false
    if not ok then error(reason, 0) end
end


function StockUI.Show()
    if ns.Sidebar and ns.Sidebar.IsGamepadMode and ns.Sidebar.IsGamepadMode() then return false end
    if not StockUI.Install() then return false end
    if ns.Bootstrap then ns.Bootstrap.Wake() end
    if ns.CancelPendingStart then ns.CancelPendingStart() end
    local previousPage
    if ns.UI and ns.UI.IsActive() then previousPage = ns.UI.NativeTabSelected() end
    if not StockUI.IsActive() then
        returnPage = previousPage or (book.BookPage and book.BookPage:IsShown() and book.BookPage or book.CraftingPage)
    end
    ns.stockActive = true
    switching = true
    if not book:IsShown() then
        if ShowUIPanel then ShowUIPanel(book) else book:Show() end
    end
    switching = false
    displayPage()
    StockUI.Render()
    return true
end
