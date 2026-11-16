local _, ns = ...
local L = ns.L
local UI = {}
ns.UI = UI

-- A profession-style page selected by the final side tab. Its catalogue does
-- not depend on Blizzard's current profession or native ingredient filters.
local book, panel, returnPage
local switching, rendering, installed = false, false, false
local widgets, rows, categories, reagents, collapsed = {}, {}, {}, {}, {}
local fallbackView = {includeBank = true, progressionOnly = false, collapsed = collapsed, scroll = 0}
local restoringScroll, selectionRestored, groupKeys, searchScroll = false, false, {}, 0
local ICON = "Interface\\AddOns\\CraftAutoBuy\\Icon.tga"
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local function view()
    return ns.CatalogueView and ns.CatalogueView.Get() or fallbackView
end

function UI.IncludesBank()
    return view().includeBank ~= false
end

local function saveSelection(id, key)
    if ns.CatalogueView then ns.CatalogueView.SetSelection(id, key) end
end

local function restoreSelection()
    if selectionRestored or not ns.CatalogueView or ns.job or ns.pendingStart or ns.bankConfirmation
        or ns.Merchant.IsBusy() then return end
    local state = view()
    if not state.selectedID then selectionRestored = true; return end
    local recipes = ns.Catalogue and ns.Catalogue.GetRecipes(state.selectedProfessionKey)
    local recipe = recipes and recipes[state.selectedID]
    if recipe then
        -- A background catalogue may use the parent profession ID. Adopt the
        -- actual cached recipe source when a complete native scan replaced it.
        selectionRestored = true
        if ns.SelectCatalogRecipe(state.selectedID, recipe.professionKey or state.selectedProfessionKey) == false then
            selectionRestored = false
        end
    end
end

local function setCollapsed(key, value)
    if ns.CatalogueView then ns.CatalogueView.SetCollapsed(key, value)
    else collapsed[key] = value or nil end
end

-- Size in the same UI units as the button, using its actual font rather than
-- string length (CJK and Latin labels have different glyph widths).
function UI.FitActionButton(control, text, maximum, minimum)
    control:SetText(text)
    local font = control.GetFontString and control:GetFontString()
    local measure = font and (font.GetUnboundedStringWidth or font.GetStringWidth)
    local width
    if measure then
        local ok, value = pcall(measure, font)
        if ok and not (issecretvalue and issecretvalue(value)) and type(value) == "number"
            and value >= 0 and value < math.huge then width = value end
    elseif control.GetTextWidth then
        local ok, value = pcall(control.GetTextWidth, control)
        if ok and not (issecretvalue and issecretvalue(value)) and type(value) == "number"
            and value >= 0 and value < math.huge then width = value end
    end
    maximum, minimum = maximum or 188, minimum or 64
    minimum = math.min(minimum, maximum)
    local target = math.max(minimum, math.min(maximum, math.ceil(width or 0) + 24))
    control:SetWidth(target)
    -- Blizzard's SetTextToFit enlarges the frame; it must not undo this bound.
    return target
end

local function label(parent, font, x, y, width, height, text)
    local value = parent:CreateFontString(nil, "OVERLAY", font)
    value:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    value:SetSize(width, height)
    value:SetJustifyH("LEFT")
    value:SetJustifyV("TOP")
    if text then value:SetText(text) end
    return value
end

local function texture(parent, atlas, layer)
    local value = parent:CreateTexture(nil, layer or "BACKGROUND")
    value:SetAllPoints(parent)
    if atlas then value:SetAtlas(atlas) end
    return value
end

local function button(name, parent, text, width, x, y, handler, template)
    local value = CreateFrame("Button", name, parent, template or "UIPanelButtonTemplate")
    value:SetSize(width, 24)
    value:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    value:SetText(text)
    if handler then value:SetScript("OnClick", handler) end
    return value
end

local function tooltip(owner, title, text)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title)
    GameTooltip:AddLine(text, 1, 1, 1, true)
    GameTooltip:Show()
end

local function tooltipHide()
    if GameTooltip then GameTooltip:Hide() end
end

local function itemTooltip(self)
    if not GameTooltip or not self.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
    if self.isReagent then
        GameTooltip:AddLine("CraftAutoBuy", 1, .82, 0)
        GameTooltip:AddLine(L.NATIVE_QUANTITY_HELP, 1, 1, 1, true)
        local source = ns.NativeUI.FormatSources(self.bankCount, self.vendorSource)
        if source ~= "" then
            GameTooltip:AddLine(source, 1, .82, 0, true)
            GameTooltip:AddLine(L.REAGENT_SOURCE_HELP, 1, 1, 1, true)
            local vendorHint = ns.NativeUI.VendorHint and ns.NativeUI.VendorHint(self.itemID)
            if vendorHint then GameTooltip:AddLine(vendorHint, 1, 1, 1, true) end
        end
    end
    GameTooltip:Show()
end

local function itemIcon(itemID)
    return itemID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID) or QUESTION_MARK
end

local function moneyText(value)
    local copper = math.max(0, math.floor(value or 0))
    return L.MONEY_AMOUNT:format(math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function shortMoney(value)
    if GetMoneyString then return GetMoneyString(math.max(0, math.floor(value or 0)), true) end
    return moneyText(value)
end

local function blockingQuoteReason(quote)
    if not quote or quote.canBuy then return nil end
    -- A timed-out order blocks purchases at every merchant, open or closed.
    if quote.unconfirmed and ns.Merchant.HasUnconfirmedOrder and ns.Merchant.HasUnconfirmedOrder() then
        return L.PURCHASE_STILL_UNCONFIRMED
    end
    if not ns.Merchant.IsOpen() then return nil end
    if quote.invalid or quote.unconfirmed or next(quote.unavailable or {})
        or next(quote.insufficientStock or {}) then
        return ns.Merchant.QuoteReason(quote) or L.MERCHANT_REAGENTS_UNAVAILABLE
    end
end

local function shortfallText(amount, crafts)
    local message = (tonumber(crafts) or 1) > 1 and L.COST_SHORTFALL or L.COST_SHORTFALL_SINGLE
    return message:format(amount)
end

-- plan (optional): the plan priced by quote; reducing the quantity cannot help
-- an infeasible plan or a single craft.
function UI.CostSummary(quote, displayedReason, plan)
    if not quote then return L.COST_SELECT_RECIPE end
    local lines = {}
    if quote.complete then
        lines[#lines + 1] = (quote.live and L.COST_VENDOR_TOTAL or L.COST_VENDOR_ESTIMATE):format(moneyText(quote.totalCost))
    else
        lines[#lines + 1] = L.COST_VENDOR_INCOMPLETE:format(moneyText(quote.totalCost))
    end
    lines[#lines + 1] = L.COST_AVAILABLE_MONEY:format(moneyText(quote.money))
    local bundledItems = {}
    for itemID, surplus in pairs(quote.surplus or {}) do
        if surplus > 0 then bundledItems[#bundledItems + 1] = itemID end
    end
    table.sort(bundledItems)
    for _, itemID in ipairs(bundledItems) do
        local purchased = quote.purchaseQuantities[itemID]
        local surplus = quote.surplus[itemID]
        lines[#lines + 1] = L.PURCHASE_BUNDLE_DETAIL:format(ns.ItemName(itemID), purchased - surplus, purchased, surplus)
    end
    local blockingReason = blockingQuoteReason(quote)
    if blockingReason then
        if blockingReason ~= displayedReason then lines[#lines + 1] = blockingReason end
    elseif (quote.shortfall or 0) > 0 then
        if not plan or plan.craftable then
            lines[#lines + 1] = shortfallText(moneyText(quote.shortfall), plan and plan.crafts or ns.quantity)
        end
    elseif not quote.complete then
        lines[#lines + 1] = L.COST_DISCOVER_PRICES
    elseif ns.Merchant.IsOpen() and not quote.canBuy and (plan or ns.plan)
        and next((plan or ns.plan).purchases or {}) then
        local reason = ns.Merchant.QuoteReason(quote) or L.PURCHASES_CANNOT_START
        if reason ~= displayedReason then lines[#lines + 1] = reason end
    end
    return table.concat(lines, "\n")
end

local function bankAlternative(recipes, plan)
    local message = ns.Bank and ns.Bank.Message(plan)
    if not message then return nil, false end
    if type(ns.Bank.Alternative) ~= "function" then return message, false end
    local alternative, quote, allowed, reason = ns.Bank.Alternative(recipes, plan)
    return message, allowed == true, alternative, quote, reason
end

-- A bag-only material plan may still require a missing station or tool. Only
-- advertise confirmation when the displayed action can use that alternative.
local function bankActionMessage(message, allowed, quote, reason, craftReady, plan)
    if not message then return nil end
    local displayedReason
    if allowed and craftReady then
        message = message .. "\n\n" .. L.BANK_OVERRIDE_NOTICE
    elseif reason and reason ~= message then
        message = message .. "\n\n" .. reason
        displayedReason = reason
    end
    -- The cost summary must not repeat the blocker already shown just above.
    if quote then message = message .. "\n" .. UI.CostSummary(quote, displayedReason, plan) end
    return message
end

local function recipeAvailability(id, key, plan)
    -- A cached profession supplies recipe data, never a current station/tool
    -- check. Its source must be opened before an actual create action is shown.
    if (ns.IsProfessionClosed and ns.IsProfessionClosed())
        or not ns.API.IsOwnProfession or not ns.API.IsOwnProfession()
        or not ns.API.GetProfessionKey or ns.API.GetProfessionKey() ~= key then return nil end
    local check = ns.CraftReadiness or ns.API.RecipeReady
    if check then return check(id, plan) end
end

local function craftAction(id, key, plan)
    local ready, reason, kind = recipeAvailability(id, key, plan)
    if ready == nil then return false, nil, false, "unverified" end
    local purchaseOnly = not ready and kind == "requirements" and plan and next(plan.purchases or {}) ~= nil or false
    return ready or purchaseOnly, reason, purchaseOnly, kind
end

local function requirementText(reason, kind)
    if reason and kind == "requirements" then return "|cffff7777" .. reason .. "|r" end
    return reason
end

-- Operation messages are kept while work is in flight. At rest, a few of them
-- describe a cause that may have ended since: derive those from live state.
local function restingJobStatus(job, needsBuy)
    local current = ns.status or ""
    -- A timed-out order was never acknowledged, even when equivalent supplies
    -- reached the bags from another source: every resume offer recalls it.
    local unconfirmed = ns.Merchant.HasUnconfirmedOrder and ns.Merchant.HasUnconfirmedOrder()
    if current == L.LAST_PURCHASE_PENDING or current == L.PURCHASE_READY_CLICK then
        if needsBuy then return L.PURCHASE_CRAFT_PAUSED end
        return unconfirmed and L.PURCHASE_UNCONFIRMED_READY_CLICK or L.PURCHASE_READY_CLICK
    end
    -- A stop that asked to confirm a changed quote, or that found purchases
    -- incomplete, is obsolete once nothing remains to buy (the bank supplies
    -- were withdrawn, for example).
    if (current == L.BANK_OVERRIDE_CHANGED or current == L.PURCHASE_CRAFT_INCOMPLETE) and not needsBuy then
        return unconfirmed and L.PURCHASE_UNCONFIRMED_READY_CLICK or L.PROJECT_RESUME_CLICK
    end
    local combatPause = current == L.PROJECT_PAUSED_COMBAT or current == L.CRAFT_PAUSED_COMBAT
        or current == L.PURCHASES_PAUSED_COMBAT
    if not combatPause and current ~= L.PROJECT_PAUSED_REOPEN then return current end
    -- Each cause must have ended: combat (tracked by its events) and the closed
    -- profession window. Combat lockdown only starts after PLAYER_REGEN_DISABLED.
    local inCombat = ns.InCombat and ns.InCombat() or (InCombatLockdown and InCombatLockdown())
    local professionOpen = not (ns.IsProfessionClosed and ns.IsProfessionClosed())
        and ns.API.IsOwnProfession and ns.API.IsOwnProfession()
        and ns.API.GetProfessionKey and ns.API.GetProfessionKey() == job.professionKey
    if inCombat then return combatPause and current or L.PROJECT_PAUSED_COMBAT end
    if not professionOpen then return L.PROJECT_PAUSED_REOPEN end
    if not needsBuy and unconfirmed then return L.PURCHASE_UNCONFIRMED_READY_CLICK end
    return L.PROJECT_RESUME_CLICK
end

local function actionTooltip(button, defaultHelp)
    local function addCost(lines)
        if not button.costQuote then return end
        if button.costReason then lines[#lines + 1] = button.costReason end
        lines[#lines + 1] = UI.CostSummary(button.costQuote, button.costReason, button.costPlan)
    end
    if button.needsVerification then
        -- A resting project cannot be verified: its own profession must be reopened.
        local lines = {ns.job and L.PROJECT_PAUSED_REOPEN or L.CATALOG_VERIFY_HELP}
        addCost(lines)
        tooltip(button, L.CATALOG_VERIFY, table.concat(lines, "\n\n"))
        return
    end
    local lines = {button.actionIntent == "buy" and L.ACTION_BUY_HELP
        or button.actionIntent == "craft" and L.ACTION_CRAFT_HELP or defaultHelp}
    if button.requirementReason then
        lines[#lines + 1] = requirementText(button.requirementReason, button.requirementKind)
    end
    if button.bankMessage then lines[#lines + 1] = button.bankMessage end
    addCost(lines)
    tooltip(button, button.actionIntent == "buy" and L.ACTION_BUY or L.ACTION_CRAFT, table.concat(lines, "\n\n"))
end

local function updateSidebar()
    if ns.Sidebar then ns.Sidebar.Refresh() end
end

function UI.IsActive()
    return ns.catalogueActive == true
end

local function setBookArt()
    if ns.BookArt then ns.BookArt.Acquire(book, "catalogue", "CraftAutoBuy", ICON) end
end

local function restoreBookArt()
    if ns.BookArt then ns.BookArt.Release(book, "catalogue") end
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

local function deactivate(restore, cancelPending)
    if cancelPending and ns.CancelPendingStart then ns.CancelPendingStart() end
    ns.catalogueActive = false
    if not panel then return end
    panel:Hide()
    restoreBookArt()
    updateSidebar()
    if not restore or not book:IsShown() then return end
    switching = true
    local ok, err = pcall(function()
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
    if not ok then error(err, 0) end
end

function UI.Hide()
    deactivate(true, true)
end

-- A pending profession switch can temporarily hide the book without giving up
-- CAB. Once that switch ends, a still-hidden book must release the custom page
-- so a later native profession opening does not get hidden behind stale state.
function UI.DeactivateIfHidden()
    if UI.IsActive() and not switching and book and not book:IsShown() then
        deactivate(false, false)
        return true
    end
    return false
end

-- Explicit native tab clicks cancel a pending switch; passive refreshes don't.
function UI.NativeTabSelected()
    deactivate(false, true)
    return returnPage
end

local function displayPage()
    switching = true
    if book.CraftingPage then book.CraftingPage:Hide() end
    if book.BookPage then book.BookPage:Hide() end
    panel:Show()
    setBookArt()
    updateSidebar()
    switching = false
end

local function makeReagent(index)
    local value = CreateFrame("Button", nil, widgets.reagentContent)
    value:SetSize(296, 36)
    value.Icon = value:CreateTexture(nil, "ARTWORK")
    value.Icon:SetPoint("TOPLEFT", value, "TOPLEFT", 2, -2)
    value.Icon:SetSize(32, 32)
    value.Border = value:CreateTexture(nil, "OVERLAY")
    value.Border:SetPoint("TOPLEFT", value, "TOPLEFT", 0, 0)
    value.Border:SetSize(36, 36)
    value.Border:SetAtlas("Professions-Slot-Frame")
    value.Name = label(value, "GameFontHighlight", 43, -2, 242, 14)
    value.Name:SetWordWrap(true)
    value.SourceLine = label(value, "GameFontNormal", 43, -18, 242, 14)
    value.SourceLine:SetWordWrap(true)
    value.isReagent = true
    value:SetScript("OnEnter", itemTooltip)
    value:SetScript("OnLeave", tooltipHide)
    reagents[index] = value
    return value
end

function UI.Install()
    if panel then
        if installed and ns.Sidebar then ns.Sidebar.Install() end
        -- A frame allocated before an installation error is not a complete
        -- page. Do not render missing widgets after that first client error.
        return installed
    end
    if not ProfessionsFrame then return false end
    book = ProfessionsFrame
    panel = CreateFrame("Frame", "CraftAutoBuyPage", book)
    panel:SetSize(650, 510)
    panel:SetPoint("TOPLEFT", book, "TOPLEFT", 12, -74)
    panel:SetFrameLevel(book:GetFrameLevel() + 5)
    panel.Background = texture(panel, "Profession-Background-Template2")
    panel:Hide()
    panel.RecipeRows, panel.CategoryRows, panel.ReagentButtons = rows, categories, reagents

    -- Use the book's free header strip for search and filters. The section
    -- controls stay above the list, leaving the recipe detail unobstructed.
    widgets.toolbar = CreateFrame("Frame", nil, panel)
    widgets.toolbar:SetSize(632, 24)
    widgets.toolbar:SetPoint("TOPLEFT", panel, "TOPLEFT", 9, 28)
    widgets.search = CreateFrame("EditBox", "CraftAutoBuySearchBox", widgets.toolbar, "SearchBoxTemplate")
    widgets.search:SetSize(267, 20)
    widgets.search:SetPoint("TOPLEFT", widgets.toolbar, "TOPLEFT", 0, 0)
    widgets.search:SetAutoFocus(false)
    widgets.search:SetMaxLetters(80)
    widgets.search:SetScript("OnTextChanged", function(self)
        if SearchBoxTemplate_OnTextChanged then SearchBoxTemplate_OnTextChanged(self) end
        -- The native clear-search button calls SetText programmatically.
        if widgets.listScroll then
            searchScroll = 0
            restoringScroll = true
            widgets.listScroll:SetVerticalScroll(0)
            restoringScroll = false
            UI.Render()
        end
    end)
    widgets.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.SearchBox = widgets.search
    panel.Toolbar = widgets.toolbar

    widgets.filterRow = CreateFrame("Frame", nil, widgets.toolbar)
    widgets.filterRow:SetSize(327, 24)
    widgets.filterRow:SetPoint("TOPLEFT", widgets.toolbar, "TOPLEFT", 305, 2)

    local function filter(name, text, help, x)
        local control = CreateFrame("CheckButton", nil, widgets.filterRow, "UICheckButtonTemplate")
        control:SetSize(22, 22)
        control:SetPoint("LEFT", widgets.filterRow, "LEFT", x, 0)
        local caption = control.Text or control.text or control:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        caption:ClearAllPoints()
        caption:SetPoint("LEFT", control, "RIGHT", 3, 0)
        caption:SetSize(130, 18)
        caption:SetFontObject("GameFontHighlightSmall")
        caption:SetJustifyH("LEFT")
        caption:SetJustifyV("MIDDLE")
        caption:SetWordWrap(false)
        caption:SetText(text)
        control.Label = caption
        control:SetHitRectInsets(0, -131, 0, 0)
        control:SetScript("OnClick", function(self)
            if self.enabled == false then return end
            if name == "includeBank" and (ns.job or ns.pendingStart or ns.bankConfirmation or ns.Merchant.IsBusy()) then
                UI.Render(); return
            end
            local enabled = self:GetChecked() == true
            if ns.CatalogueView then ns.CatalogueView.SetFilter(name, enabled)
            else fallbackView[name] = enabled end
            if ns.Refresh then ns.Refresh() else UI.Render() end
        end)
        control:SetScript("OnEnter", function(self) tooltip(self, text, help) end)
        control:SetScript("OnLeave", tooltipHide)
        return control
    end
    widgets.bankFilter = filter("includeBank", L.CATALOG_FILTER_BANK, L.CATALOG_FILTER_BANK_HELP, 0)
    widgets.progressionFilter = filter("progressionOnly", L.CATALOG_FILTER_PROGRESSION, L.CATALOG_FILTER_PROGRESSION_HELP, 160)
    widgets.collapseAll = button(nil, panel, L.CATALOG_COLLAPSE_ALL, 129, 9, -8, function()
        local keys = ns.Catalogue and ns.Catalogue.SectionKeys and ns.Catalogue.SectionKeys() or groupKeys
        for key in pairs(keys) do
            if key == "favorites" or key:match("^profession:") then setCollapsed(key, true) end
        end
        UI.Render()
    end)
    widgets.expandAll = button(nil, panel, L.CATALOG_EXPAND_ALL, 129, 147, -8, function()
        -- Also expand remembered sections currently hidden by a search/filter.
        local keys = {}
        for key in pairs(view().collapsed) do keys[#keys + 1] = key end
        for _, key in ipairs(keys) do setCollapsed(key, false) end
        UI.Render()
    end)
    for _, control in ipairs({widgets.collapseAll, widgets.expandAll}) do
        control:SetNormalFontObject("GameFontNormalSmall")
        control:SetHighlightFontObject("GameFontHighlightSmall")
        control:SetDisabledFontObject("GameFontDisableSmall")
        control:SetScript("OnEnter", function(self) tooltip(self, self:GetText(), "") end)
        control:SetScript("OnLeave", tooltipHide)
    end
    panel.BankFilter, panel.ProgressionFilter = widgets.bankFilter, widgets.progressionFilter
    panel.CollapseAllButton, panel.ExpandAllButton = widgets.collapseAll, widgets.expandAll

    local listBackground = panel:CreateTexture(nil, "ARTWORK")
    listBackground:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -34)
    listBackground:SetSize(288, 476)
    listBackground:SetAtlas("Professions-background-summarylist")
    widgets.listScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    widgets.listScroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 3, -39)
    widgets.listScroll:SetSize(267, 464)
    widgets.listContent = CreateFrame("Frame", nil, widgets.listScroll)
    widgets.listContent:SetSize(267, 464)
    widgets.listScroll:SetScrollChild(widgets.listContent)
    widgets.listScroll:HookScript("OnVerticalScroll", function(_, offset)
        -- Clamping a temporary filtered list must not overwrite the last
        -- disposition of the full list; only user scrolls publish a new offset.
        if not restoringScroll and not rendering then
            if widgets.search:GetText() ~= "" then searchScroll = math.max(0, tonumber(offset) or 0)
            elseif ns.CatalogueView then ns.CatalogueView.SetScroll(offset) end
        end
    end)
    panel.RecipeScroll = widgets.listScroll
    widgets.empty = label(widgets.listContent, "GameFontNormal", 8, -16, 245, 140)
    panel.EmptyText = widgets.empty

    local detail = CreateFrame("Frame", "CraftAutoBuyRecipeDetails", panel)
    detail:SetPoint("TOPLEFT", panel, "TOPLEFT", 305, 0)
    detail:SetSize(342, 474)
    detail.Background = texture(detail, "Professions-Recipe-Background")
    panel.DetailFrame = detail
    widgets.detail = detail
    widgets.output = CreateFrame("Button", "CraftAutoBuyOutputButton", detail, "ProfessionsOutputButtonTemplate")
    widgets.output:SetSize(47, 47)
    widgets.output:SetPoint("TOPLEFT", detail, "TOPLEFT", 18, -17)
    widgets.output.Icon = widgets.output.Icon or widgets.output.icon
    if not widgets.output.Icon then widgets.output.Icon = texture(widgets.output, nil, "ARTWORK") end
    if widgets.output.Count then widgets.output.Count:Hide() end
    if widgets.output.CountShadow then widgets.output.CountShadow:Hide() end
    widgets.output:SetScript("OnEnter", itemTooltip)
    widgets.output:SetScript("OnLeave", tooltipHide)
    widgets.output:SetScript("OnClick", function() end)
    widgets.recipeName = label(detail, "GameFontHighlight", 80, -18, 246, 46)
    widgets.profession = label(detail, "GameFontDisable", 80, -67, 246, 18)
    widgets.reagentTitle = label(detail, "GameFontNormal", 20, -102, 298, 18, L.CATALOG_COMPONENTS)
    widgets.reagentScroll = CreateFrame("ScrollFrame", nil, detail, "UIPanelScrollFrameTemplate")
    widgets.reagentScroll:SetPoint("TOPLEFT", detail, "TOPLEFT", 20, -124)
    widgets.reagentScroll:SetSize(296, 238)
    widgets.reagentContent = CreateFrame("Frame", nil, widgets.reagentScroll)
    widgets.reagentContent:SetSize(296, 238)
    widgets.reagentScroll:SetScrollChild(widgets.reagentContent)
    widgets.cost = label(detail, "GameFontNormal", 20, -374, 302, 44)
    widgets.costHit = CreateFrame("Frame", nil, detail)
    widgets.costHit:SetPoint("TOPLEFT", detail, "TOPLEFT", 20, -374)
    widgets.costHit:SetSize(302, 44)
    widgets.costHit:EnableMouse(true)
    widgets.costHit:SetScript("OnEnter", function(self) tooltip(self, "CraftAutoBuy", UI.CostSummary(ns.quote, nil, ns.plan)) end)
    widgets.costHit:SetScript("OnLeave", tooltipHide)
    widgets.status = label(detail, "GameFontHighlight", 20, -420, 302, 48)
    widgets.statusHit = CreateFrame("Frame", nil, detail)
    widgets.statusHit:SetAllPoints(widgets.status)
    widgets.statusHit:EnableMouse(true)
    widgets.statusHit:SetScript("OnEnter", function(self)
        -- Details of the status actually displayed, never another message.
        tooltip(self, "CraftAutoBuy", widgets.statusDetail or widgets.status:GetText())
    end)
    widgets.statusHit:SetScript("OnLeave", tooltipHide)
    detail.OutputButton, detail.RecipeName, detail.ProfessionName = widgets.output, widgets.recipeName, widgets.profession
    detail.ReagentsLabel, detail.CostText, detail.StatusText = widgets.reagentTitle, widgets.cost, widgets.status

    -- Max only selects a quantity. Buying and crafting share one explicit
    -- action, whose rendered intent is revalidated by Core at the click.
    widgets.createAll = button("CraftAutoBuyCreateAllButton", panel, L.MAX_QUANTITY, 44, 403, -482, function()
        widgets.quantity:ClearFocus()
        ns.Refresh()
        if ns.CanEditQuantity() and (ns.maxCrafts or 0) > 0 then ns.SetQuantity(ns.maxCrafts) end
    end)
    widgets.createAll:SetScript("OnEnter", function(self)
        tooltip(self, L.MAX_QUANTITY, L.MAX_QUANTITY_HELP)
    end)
    widgets.createAll:SetScript("OnLeave", tooltipHide)
    widgets.decrease = button(nil, panel, "-", 18, 305, -482, function() ns.SetQuantity((ns.quantity or 1) - 1) end)
    widgets.quantity = CreateFrame("EditBox", "CraftAutoBuyQuantityInput", panel, "InputBoxTemplate")
    widgets.quantity:SetSize(40, 22)
    widgets.quantity:SetPoint("TOPLEFT", panel, "TOPLEFT", 329, -483)
    widgets.quantity:SetAutoFocus(false)
    widgets.quantity:SetNumeric(true)
    widgets.quantity:SetMaxLetters(4)
    widgets.quantity:SetJustifyH("CENTER")
    widgets.quantity:SetScript("OnEnterPressed", function(self) ns.SetQuantity(self:GetText()); self:ClearFocus() end)
    widgets.quantity:SetScript("OnEscapePressed", function(self) self:ClearFocus(); UI.Render() end)
    widgets.quantity:SetScript("OnEditFocusLost", function(self) ns.SetQuantity(self:GetText()) end)
    widgets.quantity:SetScript("OnTextChanged", function(self, userInput) if userInput then ns.SetQuantity(self:GetText()) end end)
    widgets.increase = button(nil, panel, "+", 18, 375, -482, function() ns.SetQuantity((ns.quantity or 1) + 1) end)
    widgets.craft = button("CraftAutoBuyCreateButton", panel, L.ACTION_CRAFT, 188, 459, -482, function(self)
        local purchaseOnly, needsVerification, intent = self.purchaseOnly, self.needsVerification, self.actionIntent
        widgets.quantity:ClearFocus()
        if needsVerification then
            if ns.VerifySelectedRecipe then ns.VerifySelectedRecipe() end
            return
        end
        ns.Start(purchaseOnly == true, intent ~= "buy", intent)
    end)
    widgets.craft:SetScript("OnEnter", function(self)
        actionTooltip(self, L.CATALOG_BUY_HELP)
    end)
    widgets.craft:SetScript("OnLeave", tooltipHide)
    if widgets.craft.SetMotionScriptsWhileDisabled then
        widgets.craft:SetMotionScriptsWhileDisabled(true)
        widgets.createAll:SetMotionScriptsWhileDisabled(true)
    end
    widgets.cancel = button("CraftAutoBuyCancelButton", panel, L.CANCEL, 188, 459, -482, nil,
        "UIPanelButtonTemplate,InsecureActionButtonTemplate")
    ns.ActionButtons.BindCancel(widgets.cancel)
    widgets.cancel:SetScript("OnEnter", function(self)
        local casting = ns.job and ns.job.pending
        tooltip(self, casting and L.STOP_BATCH or L.CANCEL,
            casting and L.STOP_BATCH_HELP or L.CANCEL_OPERATION_HELP)
    end)
    widgets.cancel:SetScript("OnLeave", tooltipHide)
    widgets.cancel:Hide()
    widgets.openProfession = button("CraftAutoBuyOpenProfessionButton", panel, L.CATALOG_VERIFY,
        188, 459, -482, nil, "UIPanelButtonTemplate,InsecureActionButtonTemplate")
    ns.ActionButtons.BindProfession(widgets.openProfession)
    widgets.openProfession:SetScript("OnEnter", function(self)
        tooltip(self, L.CATALOG_VERIFY, ns.job and L.PROJECT_PAUSED_REOPEN or L.CATALOG_VERIFY_HELP)
    end)
    widgets.openProfession:SetScript("OnLeave", tooltipHide)
    if widgets.openProfession.SetMotionScriptsWhileDisabled then widgets.openProfession:SetMotionScriptsWhileDisabled(true) end
    widgets.openProfession:Hide()
    panel.QuantityInput, panel.CreateButton = widgets.quantity, widgets.craft
    panel.CreateAllButton, panel.CancelButton = widgets.createAll, widgets.cancel
    panel.MaxButton = widgets.createAll
    panel.OpenProfessionButton = widgets.openProfession

    for _, nativePage in pairs({book.CraftingPage, book.BookPage}) do
        nativePage:HookScript("OnShow", function(self)
            returnPage = self
            -- Native data events also show this page. Only an explicit native
            -- tab click (Sidebar) or closing the book relinquishes our page.
            local pending = ns.pendingStart
            local currentKey = ns.API.GetProfessionKey and ns.API.GetProfessionKey()
            if UI.IsActive() and not switching and pending and not panel:IsShown() and book:IsShown()
                and currentKey and pending.professionKey and ns.API.GetProfessionParentKey
                and ns.API.GetProfessionParentKey(currentKey) ~= ns.API.GetProfessionParentKey(pending.professionKey) then
                -- A different profession was explicitly reopened while the
                -- pending switch was hidden. Do not cover it with stale CAB.
                deactivate(false, true)
                return
            end
            -- Gamepad mode uses the native pages. While CAB waits to give the
            -- book back (one frame, or until combat ends), a page Blizzard shows
            -- wins: release CAB without calling any native method.
            if UI.IsActive() and not switching and ns.Sidebar and ns.Sidebar.IsGamepadMode
                and ns.Sidebar.IsGamepadMode() then
                deactivate(false, true)
                return
            end
            if UI.IsActive() and not switching then self:Hide() end
        end)
    end
    book:HookScript("OnHide", function()
        if ns.pendingStart and UI.IsActive() then panel:Hide() else deactivate(false, false) end
    end)
    installed = true
    if ns.Sidebar then ns.Sidebar.Install() end
    return true
end

-- Forever's native recipe list uses these three atlases for skill progression.
-- Craftable quantities and skill-up chances are independent indicators.
local SKILL_STYLES = {
    [0] = {atlas = "Professions-Icon-Skill-High", text = "SKILL_UP_OPTIMAL"},
    [1] = {atlas = "Professions-Icon-Skill-Medium", text = "SKILL_UP_MEDIUM"},
    [2] = {atlas = "Professions-Icon-Skill-Low", text = "SKILL_UP_EASY"},
}

local function renderSkillUps(row, recipe, selectable)
    local style = recipe and recipe.canSkillUp == true and SKILL_STYLES[recipe.relativeDifficulty]
    local points = recipe and recipe.numSkillUps
    row.skillUpText = nil
    row.SkillUps.Text:SetText("")
    row.SkillUps.Text:Hide()
    row.SkillUps:SetEnabled(selectable)
    row.SkillUps:SetShown(style ~= nil and style ~= false)
    if not style then return end
    row.SkillUps.Icon:SetAtlas(style.atlas, true)
    if type(points) == "number" and points > 0 then
        row.skillUpText = L[style.text]:format(points)
        if recipe.relativeDifficulty == 0 and points > 1 then
            row.SkillUps.Text:SetText(tostring(points))
            row.SkillUps.Text:Show()
        end
    end
end

local function makeRow(index)
    local row = CreateFrame("Button", nil, widgets.listContent)
    row:SetSize(265, 20)
    row.Label = label(row, "GameFontHighlight", 30, -3, 184, 16)
    row.Profession = label(row, "GameFontDisableSmall", 30, -19, 220, 14)
    row.Profession:Hide()
    row.Count = label(row, "GameFontHighlight", 214, -3, 48, 16)
    row.Count:SetJustifyH("RIGHT")
    row.Selection = texture(row, "Professions_Recipe_Active", "BACKGROUND")
    row.Highlight = texture(row, "Professions_Recipe_Hover", "HIGHLIGHT")
    row.SkillUps = CreateFrame("Button", nil, row)
    row.SkillUps:SetSize(26, 15)
    row.SkillUps:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.SkillUps.Icon = row.SkillUps:CreateTexture(nil, "ARTWORK")
    row.SkillUps.Icon:SetPoint("RIGHT", row.SkillUps, "RIGHT", 0, -1)
    row.SkillUps.Text = row.SkillUps:CreateFontString(nil, "OVERLAY", "GameFontHighlight_NoShadow")
    row.SkillUps.Text:SetHeight(13)
    row.SkillUps.Text:SetPoint("RIGHT", row.SkillUps.Icon, "LEFT", 0, 1)
    row.SkillUps.Text:SetTextColor(1, .5, .25)
    row.SkillUps:SetScript("OnClick", function() row:Click() end)
    row.SkillUps:SetScript("OnEnter", function(self)
        if row.entry and row.skillUpText then tooltip(self, row.entry.name, row.skillUpText) end
    end)
    row.SkillUps:SetScript("OnLeave", tooltipHide)
    row:SetScript("OnClick", function(self)
        if self.entry then
            widgets.reagentScroll:SetVerticalScroll(0)
            selectionRestored = true
            saveSelection(self.entry.recipeID, self.entry.professionKey)
            ns.SelectCatalogRecipe(self.entry.recipeID, self.entry.professionKey)
        end
    end)
    row:SetScript("OnEnter", function(self)
        if self.entry then
            tooltip(self, self.entry.name, self.entry.bankMessage or self.entry.professionName or "")
            if self.skillUpText and GameTooltip then
                GameTooltip:AddLine(self.skillUpText, 1, .82, 0, true)
                GameTooltip:Show()
            end
        end
    end)
    row:SetScript("OnLeave", tooltipHide)
    rows[index] = row
    return row
end

local function makeCategory(index)
    local category = CreateFrame("Button", nil, widgets.listContent, "ListHeaderVisualTemplate")
    category:SetSize(265, 22)
    category.Label = category.ButtonText or label(category, "GameFontNormal", 8, -3, 230, 16)
    local function toggle()
        setCollapsed(category.groupKey, not view().collapsed[category.groupKey])
        UI.Render()
    end
    category:SetScript("OnClick", toggle)
    -- CollapseButtonTemplate propagates mouse input to this header (Both).
    -- A second OnClick handler on the icon would toggle twice and undo itself.
    categories[index] = category
    return category
end

local function renderList()
    local state = view()
    widgets.bankFilter:SetChecked(state.includeBank ~= false)
    widgets.progressionFilter:SetChecked(state.progressionOnly == true)
    widgets.bankFilter:SetEnabled(not ns.job and not ns.pendingStart and not ns.bankConfirmation and not ns.Merchant.IsBusy())
    local search = widgets.search:GetText()
    local entries = ns.Catalogue and ns.Catalogue.Rows(search, state) or {}
    local favorites = ns.Catalogue and ns.Catalogue.Favorites and ns.Catalogue.Favorites(search, state) or {}
    local selectable
    if ns.CanSelectRecipe then selectable = ns.CanSelectRecipe()
    else selectable = not ns.job and not ns.pendingStart and not ns.bankConfirmation and not ns.Merchant.IsBusy() end
    local y, rowCount, categoryCount = 0, 0, 0
    local visible, roots, professions = {}, {}, {}
    groupKeys = {favorites = true}
    if #favorites > 0 then
        roots[#roots + 1] = {key = "favorites", name = L.CATALOG_FAVORITES, entries = favorites, favorite = true}
    end
    for _, entry in ipairs(entries) do
        local key = entry.groupProfessionKey or entry.professionKey
        local node = professions[key]
        if not node then
            node = {key = "profession:" .. key, name = entry.professionName, professionKey = key, entries = {}}
            professions[key] = node
            roots[#roots + 1] = node
        end
        -- The profession is the only header. Native category metadata must
        -- never add another Cuisine heading or nested sections to this view.
        node.entries[#node.entries + 1] = entry
    end
    local function collect(node)
        groupKeys[node.key] = true
        for _, entry in ipairs(node.entries) do visible[entry.professionKey .. ":" .. entry.recipeID] = true end
        table.sort(node.entries, function(a, b)
            if node.favorite and a.professionName ~= b.professionName then return a.professionName < b.professionName end
            if a.name ~= b.name then return a.name < b.name end
            if a.recipeID ~= b.recipeID then return a.recipeID < b.recipeID end
            return a.professionKey < b.professionKey
        end)
    end
    for _, node in ipairs(roots) do collect(node) end
    local function renderGroup(node)
        categoryCount = categoryCount + 1
        local category = categories[categoryCount] or makeCategory(categoryCount)
        category.professionKey, category.groupKey = node.professionKey, node.key
        category:ClearAllPoints()
        category:SetPoint("TOPLEFT", widgets.listContent, "TOPLEFT", 0, -y)
        category:SetWidth(265)
        category.Label:SetWidth(230)
        category.Label:SetText(node.name or L.CATALOG_UNCATEGORIZED)
        category.Label:SetTextColor(1, .82, 0)
        if category.CollapseButton and category.CollapseButton.UpdateCollapsedState then
            category.CollapseButton:UpdateCollapsedState(state.collapsed[node.key] == true)
        end
        category:Show()
        y = y + 25
        if state.collapsed[node.key] then return end
        for _, entry in ipairs(node.entries) do
            rowCount = rowCount + 1
            local row = rows[rowCount] or makeRow(rowCount)
            row.entry = entry
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", widgets.listContent, "TOPLEFT", 0, -y)
            row.Label:SetText(entry.name)
            row.Profession:SetText(node.favorite and entry.professionName or "")
            row.Profession:SetShown(node.favorite == true)
            row:SetHeight(node.favorite and 36 or 20)
            renderSkillUps(row, entry.recipe, selectable)
            row.Count:SetText("[" .. tostring(entry.count) .. (entry.count >= 1000 and "+" or "") .. "]")
            local r, g, b = .5, 1, .5
            if entry.count == 0 then r, g, b = .6, .6, .6
            elseif entry.needsBank then r, g, b = .35, .7, 1 end
            row.Label:SetTextColor(r, g, b)
            row.Count:SetTextColor(r, g, b)
            row.Selection:SetShown(entry.recipeID == ns.selectedID and entry.professionKey == ns.selectedProfessionKey)
            row:SetEnabled(selectable)
            row:Show()
            y = y + (node.favorite and 36 or 20)
        end
    end
    for _, node in ipairs(roots) do renderGroup(node) end
    for index = rowCount + 1, #rows do rows[index].entry = nil; rows[index]:Hide() end
    for index = categoryCount + 1, #categories do categories[index]:Hide() end
    widgets.listContent:SetHeight(math.max(464, y))
    restoringScroll = true
    local offset = search ~= "" and searchScroll or state.scroll or 0
    widgets.listScroll:SetVerticalScroll(math.min(offset, math.max(0, y - 464)))
    restoringScroll = false
    widgets.empty:SetShown(#entries == 0 and #favorites == 0)
    if #entries == 0 and #favorites == 0 then
        local missing = ns.Catalogue and ns.Catalogue.MissingProfessions() or {}
        local initializing = ns.Bootstrap and ns.Bootstrap.StatusText()
        local known = ns.Catalogue and ns.Catalogue.HasRecipes and ns.Catalogue.HasRecipes()
        widgets.empty:SetText(known and L.CATALOG_NO_RESULTS
            or (initializing and (initializing .. "\n\n" .. L.STOCK_INITIALIZING)
            or (L.CATALOG_EMPTY .. (#missing > 0 and ("\n\n" .. L.CATALOG_OPEN_PROFESSIONS) or ""))))
    end
    return visible
end

local function renderReagents(recipe, recipes, id, crafts)
    local count, y = 0, 0
    if recipe then
        local inventory, bank
        local knownBank
        if ns.Bank and not (ns.job and ns.job.ignoreBank) then _, knownBank = ns.Bank.Snapshot(recipes) end
        if ns.PlanningStock then inventory, bank = ns.PlanningStock(recipes)
        elseif (ns.job and ns.job.ignoreBank) or not UI.IncludesBank() then inventory, bank = ns.API.Inventory(recipes), {}
        elseif ns.Bank then inventory, bank = ns.Bank.Snapshot(recipes)
        else inventory = ns.API.Inventory(recipes) end
        local projection = ns.NativeUI and ns.NativeUI.Project(id, recipes, inventory, ns.vendorItems, crafts,
            ns.quote and ns.quote.purchaseQuantities, bank)
        for index, reagent in ipairs(recipe.reagents or {}) do
            local value = reagents[index] or makeReagent(index)
            local projected = projection and projection.reagents[reagent.itemID]
            local owned = inventory[reagent.itemID] or 0
            local potential = projected and projected.potential or owned
            local amounts = ns.NativeUI and ns.NativeUI.FormatQuantity(owned, potential, reagent.quantity, true)
                or (tostring(owned) .. " / " .. tostring(reagent.quantity))
            value.itemID = reagent.itemID
            value.bankCount = knownBank and knownBank[reagent.itemID] or (bank and bank[reagent.itemID]) or 0
            value.vendorSource = projected and projected.vendorSource
            if value.vendorSource == nil and ns.vendorItems and ns.vendorItems[reagent.itemID] then
                if ns.Merchant.GetReagentSourceStock then value.vendorSource = ns.Merchant.GetReagentSourceStock(reagent.itemID)
                else value.vendorSource = true end
            end
            value.Icon:SetTexture(itemIcon(reagent.itemID))
            value.Name:SetText(amounts .. " " .. ns.ItemName(reagent.itemID))
            local sourceText = ns.NativeUI.FormatSources(value.bankCount, value.vendorSource, true)
            if not UI.IncludesBank() and value.bankCount > 0 then sourceText = sourceText .. "\n" .. L.CATALOG_BANK_EXCLUDED end
            value.SourceLine:SetText(sourceText)
            value.SourceLine:SetShown(sourceText ~= "")
            -- Measure the actual text, rather than reserving two name lines
            -- for every reagent. The source sits directly below the name.
            value.Name:SetHeight(0)
            local nameHeight = math.max(14, math.ceil(value.Name:GetStringHeight()))
            value.Name:SetHeight(nameHeight)
            value.SourceLine:ClearAllPoints()
            value.SourceLine:SetPoint("TOPLEFT", value.Name, "BOTTOMLEFT", 0, -2)
            value.SourceLine:SetHeight(0)
            local sourceHeight = sourceText ~= "" and math.max(14, math.ceil(value.SourceLine:GetStringHeight())) or 0
            value.SourceLine:SetHeight(sourceHeight)
            local height = math.max(36, 2 + nameHeight + (sourceHeight > 0 and sourceHeight + 2 or 0))
            value:SetHeight(height)
            value:ClearAllPoints()
            value:SetPoint("TOPLEFT", widgets.reagentContent, "TOPLEFT", 0, -y)
            y = y + height + 8
            value:Show()
            count = index
        end
    end
    for index = count + 1, #reagents do
        reagents[index].itemID, reagents[index].bankCount, reagents[index].vendorSource = nil, nil, nil
        reagents[index].SourceLine:Hide()
        reagents[index]:Hide()
    end
    widgets.reagentContent:SetHeight(math.max(1, y))
    widgets.reagentScroll:SetHeight(math.max(1, math.min(y, 238)))
    if widgets.reagentScroll.ScrollBar then widgets.reagentScroll.ScrollBar:SetShown(y > 238) end
    widgets.reagentTitle:SetShown(recipe ~= nil)
    widgets.reagentScroll:SetShown(recipe ~= nil)
    local costY = 124 + math.min(y, 238) + 10
    widgets.cost:ClearAllPoints()
    widgets.cost:SetPoint("TOPLEFT", widgets.detail, "TOPLEFT", 20, -costY)
    widgets.costHit:ClearAllPoints()
    widgets.costHit:SetPoint("TOPLEFT", widgets.detail, "TOPLEFT", 20, -costY)
end

local function detailBackground(key)
    local atlas = "Professions-Recipe-Background"
    if key and Professions and Professions.GetProfessionBackgroundAtlas
        and C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, key)
        if ok and info then
            local atlasOK, professionAtlas = pcall(Professions.GetProfessionBackgroundAtlas, info)
            if atlasOK and type(professionAtlas) == "string" then atlas = professionAtlas end
        end
    end
    widgets.detail.Background:SetAtlas(atlas)
end

function UI.Render()
    if rendering or not UI.Install() or not UI.IsActive() then return end
    if ns.Sidebar and ns.Sidebar.IsGamepadMode and ns.Sidebar.IsGamepadMode() then
        if ns.Sidebar.RequestNativeRestore then ns.Sidebar.RequestNativeRestore() end
        return
    end
    rendering = true
    restoreSelection()
    if book:IsShown() and not panel:IsShown() then displayPage() end
    local visible = renderList()
    local job = ns.job
    local id = job and job.recipeID or ns.selectedID
    local recipes = ns.ActiveRecipes and ns.ActiveRecipes() or (job and job.recipes or ns.recipes or {})
    local recipe = id and recipes[id]
    local key = job and job.professionKey or ns.selectedProfessionKey or ns.professionKey
    -- Preserve the selection for filter reversal, but expose no stale action
    -- for a recipe outside the current catalogue. Active work stays visible.
    if not job and not ns.pendingStart and not ns.bankConfirmation and not ns.Merchant.IsBusy()
        and (not id or not key or not visible[key .. ":" .. id]) then recipe = nil end
    local professionName = ns.Catalogue and ns.Catalogue.GetProfessionName(key) or ""
    widgets.recipeName:SetText(recipe and recipe.name or L.CATALOG_SELECT)
    if selectionRestored and not job and recipe then saveSelection(id, key) end
    widgets.profession:SetText(recipe and professionName or "")
    widgets.output:SetShown(recipe ~= nil)
    widgets.output.itemID = recipe and recipe.outputItemID
    widgets.output.Icon:SetTexture(itemIcon(widgets.output.itemID))
    detailBackground(key)
    local count, crafts = ns.maxCrafts or 0, job and job.remaining or ns.quantity or 1
    if not widgets.quantity:HasFocus() then widgets.quantity:SetText(tostring(crafts)) end
    local canEdit = recipe ~= nil and ns.CanEditQuantity() and not ns.pendingStart and not ns.bankConfirmation
    widgets.quantity:SetEnabled(canEdit)
    widgets.decrease:SetEnabled(canEdit and crafts > 1)
    widgets.increase:SetEnabled(canEdit and crafts < 1000)
    local needsBuy = recipe and ns.plan and next(ns.plan.purchases or {}) ~= nil
    local bankMessage, bankAllowed, alternativePlan, bankQuote, bankReason
    if recipe then bankMessage, bankAllowed, alternativePlan, bankQuote, bankReason = bankAlternative(recipes, ns.plan) end
    local autoBuy = CraftAutoBuyDB and CraftAutoBuyDB.autoBuy == true
    local purchaseReady = not needsBuy or (autoBuy and ns.Merchant.IsOpen() and ns.quote and ns.quote.canBuy)
    local idle = not ns.pendingStart and not ns.bankConfirmation and not (job and (job.running or job.pending or job.awaitingPurchase))
        and not ns.Merchant.IsBusy()
    local ready = (not bankMessage and purchaseReady) or (bankMessage and bankAllowed)
    ns.readinessPlan = alternativePlan or ns.plan
    local craftReady, requirementReason, purchaseOnly, requirementKind = false, nil, false, nil
    if recipe then craftReady, requirementReason, purchaseOnly, requirementKind = craftAction(id, key, ns.readinessPlan) end
    widgets.craft.bankMessage = bankActionMessage(bankMessage, bankAllowed, bankQuote, bankReason, craftReady, alternativePlan)
    widgets.craft.requirementReason, widgets.craft.purchaseOnly = requirementReason, purchaseOnly
    widgets.craft.requirementKind = requirementKind
    local actionPlan = alternativePlan or ns.plan
    widgets.craft.actionIntent = actionPlan and next(actionPlan.purchases or {}) and "buy" or "craft"
    widgets.craft.costQuote = not bankMessage and ns.quote or nil
    widgets.craft.costPlan = ns.plan
    widgets.craft.costReason = nil
    if not bankMessage and needsBuy then
        if not autoBuy then widgets.craft.costReason = L.CATALOG_AUTO_BUY_DISABLED
        elseif ns.quote and ns.quote.unconfirmed and ns.Merchant.HasUnconfirmedOrder
            and ns.Merchant.HasUnconfirmedOrder() then
            widgets.craft.costReason = L.PURCHASE_STILL_UNCONFIRMED
        elseif not ns.Merchant.IsOpen() and not blockingQuoteReason(ns.quote) then
            widgets.craft.costReason = L.OPEN_MERCHANT_NEEDED
        end
    end
    local needsVerification = requirementKind == "unverified"
    if needsVerification then widgets.craft.costQuote, widgets.craft.costReason = nil, nil end
    widgets.craft.needsVerification = needsVerification
    UI.FitActionButton(widgets.createAll, L.MAX_QUANTITY, 64, 40)
    local actionLeft = 403 + widgets.createAll:GetWidth() + 12
    local actionWidth = 647 - actionLeft
    for _, control in ipairs({widgets.craft, widgets.cancel, widgets.openProfession}) do
        control:ClearAllPoints()
        control:SetPoint("TOPLEFT", panel, "TOPLEFT", actionLeft, -482)
    end
    UI.FitActionButton(widgets.craft,
        widgets.craft.actionIntent == "buy" and L.ACTION_BUY or L.ACTION_CRAFT, actionWidth)
    UI.FitActionButton(widgets.openProfession, L.CATALOG_VERIFY, actionWidth)
    local canCraft = recipe ~= nil and ns.plan and ns.plan.craftable and ready and craftReady and idle or false
    if needsVerification then
        canCraft = false
    end
    widgets.craft:SetEnabled(canCraft)
    -- Selecting the maximum is never an authorization to spend. Its resulting
    -- quote and enablement belong to the primary action after the quantity edit.
    ns.readinessAllPlan = nil
    widgets.createAll:SetEnabled(canEdit and count > 0 or false)
    local canCancel = not idle
    widgets.createAll:Show()
    widgets.craft:SetShown(not canCancel and not needsVerification)
    local openingSpell = needsVerification and ns.API.GetProfessionOpenSpell
        and ns.API.GetProfessionOpenSpell(key)
    widgets.openProfession:SetShown(needsVerification and not canCancel)
    widgets.openProfession:SetEnabled(openingSpell ~= nil and openingSpell ~= false and idle and not job)
    UI.FitActionButton(widgets.cancel, job and job.pending and L.STOP_BATCH or L.CANCEL, actionWidth)
    widgets.cancel:SetShown(canCancel)
    widgets.cancel:SetEnabled(canCancel)
    renderReagents(recipe, recipes, id, crafts)
    local quote = recipe and ns.quote
    local cost = ""
    if quote then
        if quote.complete then
            cost = (quote.live and L.CATALOG_COST or L.CATALOG_ESTIMATE):format(shortMoney(quote.totalCost))
        elseif quote.totalCost > 0 then
            cost = L.CATALOG_COST_PARTIAL:format(shortMoney(quote.totalCost))
        else cost = L.CATALOG_COST_UNKNOWN end
        local surplus = 0
        for _, quantity in pairs(quote.surplus or {}) do surplus = surplus + quantity end
        if surplus > 0 then cost = cost .. "\n" .. L.PURCHASE_SURPLUS_SUMMARY:format(surplus) end
    end
    widgets.cost:SetText(cost)
    widgets.costHit:SetShown(quote ~= nil)
    local status, statusDetail = "", nil
    if recipe then
        -- Keep operation messages while work is in flight. Once idle, derive
        -- instructions from the same live conditions that enable the button.
        if not idle then status = ns.status or ""
        elseif ns.plan and not ns.plan.craftable then status = L.PLAN_UNAVAILABLE
        -- "Vérifier" is disabled while a project exists: ask to reopen its profession.
        elseif needsVerification then status = job and L.PROJECT_PAUSED_REOPEN or L.CATALOG_VERIFY_HELP
        elseif bankMessage then
            status = bankAllowed and craftReady and L.BANK_OVERRIDE_NOTICE or L.BANK_NOTICE
            if ns.Stock and ns.Stock.IsBankUnverified and ns.Stock.IsBankUnverified() then
                -- The compact status has room for three lines. The unverified
                -- notice already explains both choices; keep details on hover.
                -- At an open bank the reading is simply still in progress.
                local open = ns.Stock.IsBankOpen and ns.Stock.IsBankOpen()
                status = open and L.STOCK_BANK_LOADING or L.BANK_UNVERIFIED_NOTICE
            end
            -- The hover details this compact notice, and keeps its requirement.
            statusDetail = widgets.craft.bankMessage
            -- A purchase-only route (button "Buy") still lacks its station or tool.
            if requirementReason and (not craftReady or purchaseOnly) then
                local requirement = requirementText(requirementReason, requirementKind)
                status = status .. "\n" .. requirement
                statusDetail = statusDetail .. "\n\n" .. requirement
            end
        elseif not needsBuy and requirementKind == "requirements"
            and (ns.status == L.BUY_ONLY_COMPLETE or ns.status == L.BUY_ONLY_READY) then status = ns.status
        elseif not craftReady and requirementReason then status = requirementText(requirementReason, requirementKind)
        elseif needsBuy and not autoBuy then status = L.CATALOG_AUTO_BUY_DISABLED
        elseif needsBuy and quote and quote.unconfirmed and ns.Merchant.HasUnconfirmedOrder
            and ns.Merchant.HasUnconfirmedOrder() then status = L.PURCHASE_STILL_UNCONFIRMED
        elseif needsBuy and not ns.Merchant.IsOpen() then
            -- Without a live quote, a shortfall estimated from remembered prices
            -- still warns the player before the trip to a merchant.
            if craftReady and quote and quote.complete and (quote.shortfall or 0) > 0 then
                status = L.OPEN_MERCHANT_SHORTFALL:format(shortMoney(quote.shortfall))
            else status = L.OPEN_MERCHANT_NEEDED end
        elseif needsBuy and quote and not quote.canBuy then status = ns.Merchant.QuoteReason(quote) or ""
        elseif not needsBuy and craftReady and (ns.status == L.BUY_ONLY_COMPLETE or ns.status == L.BUY_ONLY_READY) then
            -- The station or tool is now available: the instruction to reach it
            -- is obsolete. Offer the craft, recalling an order never confirmed.
            status = ns.Merchant.HasUnconfirmedOrder and ns.Merchant.HasUnconfirmedOrder()
                and L.PURCHASE_UNCONFIRMED_READY_CLICK
                or (ns.status == L.BUY_ONLY_COMPLETE and L.PURCHASE_READY_CLICK or "")
        elseif job then status = restingJobStatus(job, needsBuy)
        elseif requirementReason then status = requirementText(requirementReason, requirementKind) end
        if not bankMessage and idle and craftReady and needsBuy and autoBuy and ns.Merchant.IsOpen() and quote
            and ns.plan and ns.plan.craftable
            and not blockingQuoteReason(quote) and (quote.shortfall or 0) > 0 then
            status = shortfallText(shortMoney(quote.shortfall), crafts)
        end
        if requirementReason and status == requirementReason then status = requirementText(status, requirementKind) end
    end
    widgets.status:SetText(status)
    widgets.statusDetail = statusDetail
    -- Station proximity has no event: Core polls it against what is displayed.
    if ns.NoteRenderedReadiness then ns.NoteRenderedReadiness() end
    rendering = false
end

-- The status currently displayed by an active CAB page, or nil when none is shown.
function UI.StatusText()
    if not UI.IsActive() or not widgets or not widgets.status or not widgets.status.GetText then return nil end
    return widgets.status:GetText()
end

function UI.Show()
    if ns.Sidebar and ns.Sidebar.IsGamepadMode and ns.Sidebar.IsGamepadMode() then return false end
    if not UI.Install() then return false end
    if ns.Bootstrap then ns.Bootstrap.Wake() end
    local previousPage
    if ns.StockUI and ns.StockUI.IsActive() then previousPage = ns.StockUI.NativeTabSelected() end
    if not UI.IsActive() then
        selectionRestored = false
        returnPage = previousPage or (book.BookPage and book.BookPage:IsShown() and book.BookPage or book.CraftingPage)
    end
    ns.catalogueActive = true
    switching = true
    if not book:IsShown() then
        if ShowUIPanel then ShowUIPanel(book) else book:Show() end
    end
    switching = false
    displayPage()
    if ns.Refresh then ns.Refresh() else UI.Render() end
    return true
end
