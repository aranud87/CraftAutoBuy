local _, ns = ...
local Sidebar = {}
ns.Sidebar = Sidebar

-- Forever uses LargeSideTabButtonTemplate and its Camelot atlas sizing.
-- Source: Gethe/wow-ui-source, forever branch, SharedUIPanelTemplates.xml/.lua
-- and Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.xml/.lua.
-- Do not insert the addon into rightProfessionTabs: Blizzard rewrites that array
-- to represent learned skills and calls RightTabSelected during passive updates.
local ICON = "Interface\\AddOns\\CraftAutoBuy\\Icon.tga"
local STOCK_ICON = "Interface\\Icons\\INV_Misc_Bag_10"
local book, tab, stockTab
local inputRegistered, restoringInput, inputUpdateHooked
local inputWaiting, inputQueued, inputFailed, timerBroken
local restoreCatalogue, restoreStock
local hookedMethods = setmetatable({}, {__mode = "k"})
local hookedFrames = setmetatable({}, {__mode = "k"})

function Sidebar.IsGamepadMode()
    return InputUtil and type(InputUtil.IsGamepadUIEnabled) == "function"
        and InputUtil.IsGamepadUIEnabled() == true or false
end

local function inCombat()
    return (ns.InCombat and ns.InCombat()) or (InCombatLockdown and InCombatLockdown())
end

local function restoreInput()
    inputQueued = nil
    if not inputWaiting or restoringInput or inCombat() then return end
    inputWaiting, restoringInput = false, true
    -- InputUtil subscribers run in hash-table order. This work runs on the
    -- following frame, after Blizzard's own setup, and never during combat.
    -- Retain each restoration until it succeeds, even if Hide released the
    -- active flag before a native page method failed.
    -- Report a failure once to the game's error handler, from the failing call
    -- so its stack is kept: otherwise the player sees a page without gamepad
    -- prompts and nothing to report. A handler error cannot escape.
    local function report(err)
        local handler = geterrorhandler and geterrorhandler()
        if type(handler) == "function" then pcall(handler, err) end
        return err
    end
    local ok = xpcall(function()
        if Sidebar.IsGamepadMode() then
            if ns.catalogueActive and ns.UI then restoreCatalogue = ns.UI.Hide end
            if ns.stockActive and ns.StockUI then restoreStock = ns.StockUI.Hide end
        end
        if restoreCatalogue then restoreCatalogue(); restoreCatalogue = nil end
        if restoreStock then restoreStock(); restoreStock = nil end
        if ns.NativeCraft then ns.NativeCraft.Refresh() end
        if ns.NativeUI then ns.NativeUI.Refresh() end
        -- Gamepad focus stays with Blizzard's own secure transition code:
        -- SmartNavigation refuses a selection placed from addon code and shows
        -- "Interface action failed because of an AddOn".
    end, report)
    restoringInput = false
    if not ok then
        -- Do not retry a failing native method every frame. A new explicit
        -- interface transition rearms it; this failure cannot latch our guard.
        inputWaiting, inputFailed = true, true
        return
    end
    Sidebar.Refresh()
end

function Sidebar.RequestNativeRestore(retry)
    if retry then inputFailed = nil end
    inputWaiting = true
    if restoringInput or inputQueued or inputFailed or inCombat() then return end
    if not timerBroken and C_Timer and type(C_Timer.After) == "function" then
        local request = {}
        inputQueued = request
        local ok = pcall(C_Timer.After, 0, function()
            if inputQueued == request then restoreInput() end
        end)
        -- A failing timer must not be retried every frame: fall back to the
        -- book's next OnUpdate, which provides the same one-frame deferral.
        if not ok then inputQueued, timerBroken = nil, true end
    end
    -- Without timers, the book's next OnUpdate provides the same deferral.
end

local function postHook(object, method, callback)
    if not object or type(object[method]) ~= "function" then return end
    local methods = hookedMethods[object]
    if not methods then methods = {}; hookedMethods[object] = methods end
    if methods[method] then return end
    hooksecurefunc(object, method, callback)
    methods[method] = true
end

local function hookVisibility(frame)
    if not frame or not frame.HookScript or hookedFrames[frame] then return end
    hookedFrames[frame] = true
    frame:HookScript("OnShow", function() Sidebar.Refresh() end)
    frame:HookScript("OnHide", function() Sidebar.Refresh() end)
end

local function attachNativeTab(nativeTab)
    if not nativeTab then return end
    hookVisibility(nativeTab)
    -- These native tabs are Frames: OnClick is a Lua method invoked by their
    -- mouse-up handler, not a Button OnClick script. This observes user choices
    -- without mistaking RefreshRightTabs for a request to leave the catalogue.
    postHook(nativeTab, "OnClick", function()
        restoreCatalogue, restoreStock, inputFailed = nil, nil, nil
        local wasCustom = ns.catalogueActive or ns.stockActive
        if ns.UI and ns.UI.NativeTabSelected then ns.UI.NativeTabSelected() end
        if ns.StockUI and ns.StockUI.NativeTabSelected then ns.StockUI.NativeTabSelected() end
        if wasCustom then
            -- A native OnClick may have shown its page while our passive-show
            -- guard still owned the book. Reveal the explicit user's choice
            -- once both custom pages and their title/portrait overlays are gone.
            local page = nativeTab == book.ProfessionsOverviewTab and book.BookPage or book.CraftingPage
            local other = page == book.BookPage and book.CraftingPage or book.BookPage
            if other then other:Hide() end
            if page then page:Show() end
        end
        Sidebar.Refresh()
    end)
end

function Sidebar.Refresh()
    if not book or not tab then return false end
    if Sidebar.IsGamepadMode() then
        tab:Hide(); stockTab:Hide()
        -- Forever's gamepad footer invokes native buttons even when hidden.
        -- Use the native pages/controls in this mode instead of mixing routes.
        if not restoringInput and (ns.catalogueActive or ns.stockActive) then Sidebar.RequestNativeRestore() end
    else
        tab:Show(); stockTab:Show()
    end
    attachNativeTab(book.ProfessionsOverviewTab)
    local anchor = book.ProfessionsOverviewTab
    if anchor and not anchor:IsShown() then anchor = nil end
    for _, nativeTab in ipairs(book.rightProfessionTabs or {}) do
        attachNativeTab(nativeTab)
        if nativeTab:IsShown() then anchor = nativeTab end
    end
    tab:ClearAllPoints()
    if anchor then
        tab:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    else
        tab:SetPoint("TOPLEFT", book, "TOPRIGHT", 0, -60)
    end
    local selected = ns.catalogueActive == true
    local stockSelected = ns.stockActive == true
    tab:SetChecked(selected)
    stockTab:ClearAllPoints()
    stockTab:SetPoint("TOPLEFT", tab, "BOTTOMLEFT", 0, -2)
    stockTab:SetChecked(stockSelected)
    if selected or stockSelected then
        if book.ProfessionsOverviewTab then book.ProfessionsOverviewTab:SetChecked(false) end
        for _, nativeTab in ipairs(book.rightProfessionTabs or {}) do nativeTab:SetChecked(false) end
    end
    return true
end

function Sidebar.Install()
    if not ProfessionsFrame or type(CreateFrame) ~= "function" or type(hooksecurefunc) ~= "function" then return false end
    if not tab then
        book = ProfessionsFrame
        tab = CreateFrame("Frame", "CraftAutoBuySidebarTab", book, "LargeSideTabButtonTemplate")
        tab.tooltipText = "CraftAutoBuy"
        tab.Icon:SetTexture(ICON)
        -- Same fill and crop as ProfessionsFrameRightTabTemplateWrapper. Leave
        -- width/height and the icon anchors to the native Camelot tab art.
        tab:SetFillToInterior(true)
        tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
            if button == "LeftButton" and upInside then
                if ns.UI and ns.UI.Show then ns.UI.Show() end
                Sidebar.Refresh()
            end
        end)
        stockTab = CreateFrame("Frame", "CraftAutoBuyStockSidebarTab", book, "LargeSideTabButtonTemplate")
        stockTab.tooltipText = ns.L.STOCK_TITLE
        stockTab.Icon:SetTexture(STOCK_ICON)
        stockTab:SetFillToInterior(true)
        stockTab:SetCustomOnMouseUpHandler(function(_, button, upInside)
            if button == "LeftButton" and upInside then
                if ns.StockUI and ns.StockUI.Show then ns.StockUI.Show() end
                Sidebar.Refresh()
            end
        end)
        hookVisibility(book)
    end
    postHook(book, "RefreshRightTabs", function() Sidebar.Refresh() end)
    postHook(book, "RefreshRightTab", function() Sidebar.Refresh() end)
    hookVisibility(book.CraftingPage)
    hookVisibility(book.BookPage)
    if not inputUpdateHooked then
        book:HookScript("OnUpdate", function()
            if inputWaiting and not inputQueued and not inputFailed and not restoringInput and not inCombat() then
                if not timerBroken and C_Timer and type(C_Timer.After) == "function" then Sidebar.RequestNativeRestore()
                else restoreInput() end
            end
        end)
        inputUpdateHooked = true
    end
    if not inputRegistered and InputUtil and type(InputUtil.RegisterForInterfaceTransitions) == "function" then
        -- InputUtil dispatches INPUT_DEVICE_INTERFACE_TRANSITION, including a
        -- switch while the book is already open. No gameplay action is started.
        InputUtil.RegisterForInterfaceTransitions(Sidebar, function()
            -- Native Create can own a confirmation while neither CAB page is
            -- active. Cancel it immediately so its saved acceptance is inert.
            if ns.CancelBankConfirmation then ns.CancelBankConfirmation() end
            Sidebar.RequestNativeRestore(true)
            Sidebar.Refresh()
        end)
        inputRegistered = true
    end
    Sidebar.Refresh()
    return true
end
