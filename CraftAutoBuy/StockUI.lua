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

local function makeRow(column)
    -- This is an informational frame, not an item/transfer button.
    local row = CreateFrame("Frame", nil, column.content)
    row:SetSize(284, 40)
    row:EnableMouse(true)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -4)
    row.Icon:SetSize(32, 32)
    row.Name = label(row, "GameFontHighlight", 40, -4, 195, 32)
    row.Name:SetWordWrap(true)
    row.Name:SetMaxLines(2)
    row.Count = label(row, "GameFontHighlight", 237, -4, 45, 32)
    row.Count:SetJustifyH("RIGHT")
    row:SetScript("OnEnter", function(self)
        if not GameTooltip or not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID)
        else GameTooltip:SetText(self.Name:GetText()) end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return row
end

local function makeColumn(name, title, x)
    local frame = CreateFrame("Frame", name, panel)
    frame:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -44)
    frame:SetSize(312, 414)
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetAtlas("Professions-background-summarylist")
    local heading = label(frame, "GameFontNormalLarge", 10, -8, 286, 24)
    heading:SetText(title)
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 9, -37)
    scroll:SetSize(284, 366)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(284, 366)
    scroll:SetScrollChild(content)
    local empty = label(frame, "GameFontHighlight", 12, -49, 276, 72)
    empty:SetWordWrap(true)
    local column = {frame = frame, heading = heading, scroll = scroll, content = content, empty = empty, rows = {}}
    frame.Rows, frame.Scroll, frame.EmptyText, frame.Heading = column.rows, scroll, empty, heading
    return column
end

function StockUI.Install()
    if panel then return true end
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
    widgets.search = CreateFrame("EditBox", "CraftAutoBuyStockSearchBox", panel, "SearchBoxTemplate")
    widgets.search:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -10)
    widgets.search:SetSize(300, 20)
    widgets.search:SetAutoFocus(false)
    widgets.search:SetMaxLetters(80)
    widgets.search:SetScript("OnTextChanged", function(self)
        if SearchBoxTemplate_OnTextChanged then SearchBoxTemplate_OnTextChanged(self) end
        if widgets.bags then
            widgets.bags.scroll:SetVerticalScroll(0)
            widgets.bank.scroll:SetVerticalScroll(0)
            StockUI.Render()
        end
    end)
    widgets.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    widgets.bags = makeColumn("CraftAutoBuyStockBags", L.STOCK_BAGS, 4)
    widgets.bank = makeColumn("CraftAutoBuyStockBank", L.STOCK_BANK, 334)
    widgets.missing = label(panel, "GameFontHighlight", 14, -468, 620, 38)
    widgets.missing:SetWordWrap(true)
    panel.SearchBox, panel.Bags, panel.Bank = widgets.search, widgets.bags.frame, widgets.bank.frame
    panel.MissingProfessions = widgets.missing
    for _, nativePage in pairs({book.CraftingPage, book.BookPage}) do
        nativePage:HookScript("OnShow", function(self)
            returnPage = self
            -- In gamepad mode a page Blizzard shows wins over the waiting Stock page.
            if StockUI.IsActive() and not switching and ns.Sidebar and ns.Sidebar.IsGamepadMode
                and ns.Sidebar.IsGamepadMode() then
                deactivate(false)
                return
            end
            if StockUI.IsActive() and not switching then self:Hide() end
        end)
    end
    book:HookScript("OnHide", function() if not switching then deactivate(false) end end)
    if ns.Sidebar then ns.Sidebar.Install() end
    return true
end

local function renderColumn(column, entries, emptyText)
    for index, entry in ipairs(entries) do
        local row = column.rows[index]
        if not row then row = makeRow(column); column.rows[index] = row end
        row.itemID = entry.itemID
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", column.content, "TOPLEFT", 0, -(index - 1) * 40)
        row.Icon:SetTexture(entry.icon or QUESTION_MARK)
        row.Name:SetText(entry.name)
        row.Count:SetText(tostring(entry.count))
        row:Show()
    end
    for index = #entries + 1, #column.rows do
        local row = column.rows[index]
        row.itemID = nil
        row:Hide()
    end
    column.content:SetHeight(math.max(366, #entries * 40))
    column.empty:SetText(emptyText)
    column.empty:SetShown(#entries == 0)
end

function StockUI.Render()
    if rendering or not StockUI.IsActive() or not StockUI.Install() then return end
    if ns.Sidebar and ns.Sidebar.IsGamepadMode and ns.Sidebar.IsGamepadMode() then
        ns.Sidebar.RequestNativeRestore()
        return
    end
    rendering = true
    if book:IsShown() and not panel:IsShown() then displayPage() end
    setBookArt()
    local search = widgets.search:GetText()
    widgets.bags.heading:SetText(L.STOCK_BAGS)
    widgets.bank.heading:SetText(L.STOCK_BANK)
    local bags, bank, bankKnown, missing = {}, {}, false, {}
    if ns.Stock then bags, bank, bankKnown, missing = ns.Stock.Rows(search) end
    local bankOpen = ns.Stock and ns.Stock.IsBankOpen and ns.Stock.IsBankOpen()
    local initializing = ns.Bootstrap and ns.Bootstrap.StatusText()
    local empty = initializing and L.STOCK_INITIALIZING or nil
    renderColumn(widgets.bags, bags or {}, search ~= "" and L.STOCK_NO_RESULTS or empty or L.STOCK_EMPTY_BAGS)
    renderColumn(widgets.bank, bankKnown and bank or {}, not bankKnown and (bankOpen and L.STOCK_BANK_LOADING or L.STOCK_BANK_UNKNOWN)
        or (search ~= "" and L.STOCK_NO_RESULTS or empty or L.STOCK_EMPTY_BANK))
    local names = {}
    for _, profession in ipairs(missing or {}) do names[#names + 1] = profession.name end
    widgets.missing:SetText(initializing
        or (#names > 0 and L.STOCK_MISSING_PROFESSIONS:format(table.concat(names, ", ")) or ""))
    rendering = false
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
