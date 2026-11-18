local _, ns = ...
local L = ns.L
local NativeCraft = {}
ns.NativeCraft = NativeCraft

-- Forever: ProfessionsCraftingPageMixin creates CreateButton/CreateAllButton;
-- Create reads CreateMultipleInputBox:GetValue(), a NumericInputSpinnerTemplate.
-- Separate sibling controls leave native scripts and crafting APIs untouched.
local state, refreshing

-- Block native clicks too, including recipes CAB does not replace. Never
-- rewrite native OnClick handlers or their readiness/enablement state.
local function transferClickGuards()
    local blocked = ns.BankTransfer and ns.BankTransfer.IsBusy and ns.BankTransfer.IsBusy()
    if blocked and not state.transferGuards then
        state.transferGuards = {}
        for index=1,2 do
            local original = state.originals[index]
            local guard = CreateFrame("Frame", nil, original)
            guard:SetAllPoints(original)
            guard:SetFrameLevel(original:GetFrameLevel()+5)
            if guard.EnableMouse then guard:EnableMouse(true) end
            guard:SetScript("OnMouseDown",function() end)
            guard:SetScript("OnMouseUp",function() end)
            guard:SetScript("OnEnter",function(self)
                if GameTooltip then
                    GameTooltip:SetOwner(self,"ANCHOR_TOP")
                    GameTooltip:SetText(L.BANK_TRANSFER_BUSY)
                    GameTooltip:Show()
                end
            end)
            guard:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
            state.transferGuards[index]=guard
        end
    end
    for _, guard in ipairs(state.transferGuards or {}) do guard:SetShown(blocked and true or false) end
end

local function clamp(value, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or (issecretvalue and issecretvalue(value)) then value = 1 end
    return math.max(1, math.min(maximum or 1000, math.floor(value)))
end

local function shown(frame)
    return frame and (not frame.IsShown or frame:IsShown())
end

local function setText(button, value)
    if button.SetTextToFit then button:SetTextToFit(value) else button:SetText(value) end
end

local function captureVisibility()
    for index, original in ipairs(state.originals) do state.visible[index] = shown(original) end
end

local function restore()
    if not state then return end
    for _, control in ipairs(state.controls) do control:Hide() end
    if state.active then
        state.active = false
        for index, original in ipairs(state.originals) do
            if state.visible[index] then original:Show() else original:Hide() end
        end
    end
    state.recipeID, state.createQuote, state.allQuote = nil, nil, nil
end

local function current()
    -- Combat lockdown only starts after PLAYER_REGEN_DISABLED: also follow the event.
    local inCombat = ns.InCombat and ns.InCombat() or (InCombatLockdown and InCombatLockdown())
    if not state or ns.catalogueActive or inCombat then return nil end
    if ns.Sidebar and ns.Sidebar.IsGamepadMode and ns.Sidebar.IsGamepadMode() then return nil end
    local page = state.page
    if not shown(page) or (page.IsVisible and not page:IsVisible()) then return nil end
    if not ns.API.IsOwnProfession() or ns.API.GetProfessionKey() ~= ns.professionKey then return nil end
    local id = ns.API.SelectedRecipeID()
    if not id then return nil end
    local recipe = id and ns.recipes and ns.recipes[id]
    return id, recipe
end

local function quotePlan(plan)
    if not plan or not plan.craftable then return false, L.PLAN_UNAVAILABLE, nil, nil, nil, plan end
    local bankMessage = ns.Bank and ns.Bank.Message(plan)
        or (ns.BankPurchaseWarning and ns.BankPurchaseWarning(ns.recipes, plan))
    if bankMessage then
        local alternativePlan, alternativeQuote, allowed, reason = ns.Bank.Alternative(ns.recipes, plan)
        return allowed, allowed and L.BANK_OVERRIDE_NOTICE or reason,
            ns.Merchant.Quote(plan.purchases), bankMessage, alternativeQuote, alternativePlan
    end
    if not next(plan.purchases or {}) then return true, nil, nil, nil, nil, plan end
    local quote = ns.Merchant.Quote(plan.purchases)
    if not CraftAutoBuyDB or CraftAutoBuyDB.autoBuy ~= true then
        return false, L.CATALOG_AUTO_BUY_DISABLED, quote, nil, nil, plan
    end
    -- A timed-out order blocks every merchant: say so even with the vendor closed.
    if quote.unconfirmed and ns.Merchant.HasUnconfirmedOrder and ns.Merchant.HasUnconfirmedOrder() then
        return false, L.PURCHASE_STILL_UNCONFIRMED, quote, nil, nil, plan
    end
    if not ns.Merchant.IsOpen() then return false, L.OPEN_MERCHANT_NEEDED, quote, nil, nil, plan end
    return quote.canBuy == true, ns.Merchant.QuoteReason(quote), quote, nil, nil, plan
end

local function craftReadiness(id, plan)
    if ns.CraftReadiness then return ns.CraftReadiness(id, plan) end
    return ns.API.RecipeReady(id)
end

local function purchaseOnly(ready, kind, plan)
    return not ready and kind == "requirements" and plan and next(plan.purchases or {}) ~= nil or false
end

local function busy()
    return ns.pendingStart ~= nil or ns.bankConfirmation ~= nil or ns.Merchant.IsBusy()
        or (ns.job and (ns.job.running or ns.job.pending or ns.job.awaitingPurchase))
end

local function showTooltip(button)
    if not GameTooltip then return end
    local reason = button.reason
    local quote = button.alternativeQuote or state.createQuote
    GameTooltip:SetOwner(button, "ANCHOR_TOP")
    if button == state.cancelButton then
        local pending = ns.job and ns.job.pending
        GameTooltip:SetText(pending and L.STOP_BATCH or L.CANCEL)
        GameTooltip:AddLine(pending and L.STOP_BATCH_HELP or L.CANCEL_OPERATION_HELP, 1, 1, 1, true)
        GameTooltip:Show()
        return
    end
    if button == state.all then
        GameTooltip:SetText(L.MAX_QUANTITY)
        GameTooltip:AddLine(L.MAX_QUANTITY_HELP, 1, 1, 1, true)
        GameTooltip:Show()
        return
    end
    local buying = button.actionIntent == "buy"
    GameTooltip:SetText(buying and L.ACTION_BUY or ns.ActionButtons.CraftText(button.craftQuantity))
    GameTooltip:AddLine(buying and L.ACTION_BUY_HELP or L.ACTION_CRAFT_HELP, 1, 1, 1, true)
    -- Reagent rows already identify bank stock. Keep the detailed warning in
    -- the action tooltip, where it cannot overlap reagent names, prices or tracking.
    if button.bankMessage then GameTooltip:AddLine(button.bankMessage, 1, .82, 0, true) end
    if button.requirementReason then GameTooltip:AddLine(button.requirementReason, 1, .4, .4, true) end
    if reason and reason ~= button.bankMessage and reason ~= button.requirementReason then
        GameTooltip:AddLine(reason, 1, .4, .4, true)
    end
    if quote and ns.UI and ns.UI.CostSummary then
        GameTooltip:AddLine(ns.UI.CostSummary(quote, reason, button.plan), 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function click()
    local intendedPurchaseOnly = state.create.buyOnly == true
    local intendedAction = state.create.actionIntent
    NativeCraft.Refresh() -- Revalidate current form/stock/price before any action.
    if not state.active then return end
    if not state.create:IsEnabled() then return end
    -- A delivery or a removed reagent must not turn the label clicked into
    -- the opposite action. Core checks again after its own live recipe scan.
    if intendedAction ~= state.create.actionIntent then
        if ns.Print then ns.Print(L.ACTION_CHANGED) end
        return
    end
    local id = ns.API.SelectedRecipeID()
    if id ~= state.recipeID then return end
    local quantity = state.quantity:GetValue()
    if ns.job then quantity = ns.job.remaining end
    state.quantity:ClearFocus()
    ns.StartNative(id, clamp(quantity), intendedPurchaseOnly, intendedAction)
end

local function selectMaximum()
    NativeCraft.Refresh()
    if not state.active or not state.all:IsEnabled() then return end
    state.quantity:ClearFocus()
    state.quantity:SetValue(state.maximum)
    NativeCraft.Refresh()
end

function NativeCraft.GetQuantity(recipeID)
    if not state or not state.active or state.recipeID ~= recipeID or ns.catalogueActive
        or ns.API.SelectedRecipeID() ~= recipeID then return nil end
    return clamp(state.quantity:GetValue())
end

function NativeCraft.GetQuote(recipeID)
    if NativeCraft.GetQuantity(recipeID) ~= nil then return state.createQuote end
end

function NativeCraft.Install()
    if state then return true end
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    if not page or not page.CreateButton or not page.CreateAllButton or not page.CreateMultipleInputBox
        or not hooksecurefunc or not ns.API then return false end
    state = {page = page, active = false, visible = {},
        originals = {page.CreateButton, page.CreateAllButton, page.CreateMultipleInputBox}}
    local template = page.GetButtonTemplate and page:GetButtonTemplate() or "UIPanelButtonTemplate"
    local create = CreateFrame("Button", "CraftAutoBuyNativeCreateButton", page, template)
    local all = CreateFrame("Button", "CraftAutoBuyNativeCreateAllButton", page, template)
    local quantity = CreateFrame("EditBox", "CraftAutoBuyNativeQuantityInput", page, "NumericInputSpinnerTemplate")
    local cancel = CreateFrame("Button", "CraftAutoBuyNativeCancelButton", page, template .. ",InsecureActionButtonTemplate")
    state.create, state.all, state.quantity = create, all, quantity
    state.cancelButton = cancel
    state.controls = {create, all, quantity, cancel}
    NativeCraft.CreateButton, NativeCraft.CreateAllButton, NativeCraft.QuantityInput = create, all, quantity
    NativeCraft.MaxButton, NativeCraft.CancelButton = all, cancel
    for index, control in ipairs({create, all, quantity}) do
        local original = state.originals[index]
        control:SetAllPoints(original)
        control:SetFrameLevel(original:GetFrameLevel() + 1)
        control:Hide()
    end
    -- Quantity first, Max next, then an action fitted to the localized label.
    quantity:ClearAllPoints()
    quantity:SetPoint("LEFT", state.originals[2], "LEFT", 24, 0)
    quantity:SetSize(40, 24)
    all:ClearAllPoints()
    all:SetPoint("LEFT", state.originals[2], "LEFT", 98, 0)
    all:SetSize(44, 24)
    create:ClearAllPoints()
    create:SetPoint("LEFT", all, "RIGHT", 12, 0)
    create:SetHeight(24)
    cancel:SetPoint("LEFT", all, "RIGHT", 12, 0)
    cancel:SetHeight(24)
    cancel:SetFrameLevel(create:GetFrameLevel() + 1)
    cancel:Hide()
    quantity:SetAutoFocus(false)
    quantity:SetMaxLetters(4)
    quantity.clampIfInputExceedsRange = true
    quantity.highlightIfInputExceedsRange = true
    quantity:SetMinMaxValues(1, 1000)
    quantity:SetValue(1)
    quantity:SetOnValueChangedCallback(function()
        -- Forever's NumericInputSpinner invokes this after updating currentValue
        -- for both keyboard input and arrow SetValue calls. Avoid observing the
        -- nested OnTextChanged events generated by SetNumber.
        if not refreshing then
            local job = ns.job
            if job and state.active and job.recipeID == current()
                and job.professionKey == ns.professionKey and not busy()
                and ns.CanEditQuantity and ns.CanEditQuantity() and ns.SetQuantity then
                -- Once a job exists, its remaining quantity is authoritative.
                -- Forward an allowed edit before refreshing from that value.
                ns.SetQuantity(clamp(quantity:GetValue()))
            end
            NativeCraft.Refresh()
            if ns.NativeUI and ns.NativeUI.Refresh then ns.NativeUI.Refresh() end
        end
    end)
    quantity:HookScript("OnEnterPressed", function(self) self:ClearFocus(); NativeCraft.Refresh() end)
    quantity:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)
    create:SetScript("OnClick", click)
    all:SetScript("OnClick", selectMaximum)
    ns.ActionButtons.BindCancel(cancel)
    for _, button in ipairs({create, all, cancel}) do
        if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
        button:SetScript("OnEnter", showTooltip)
        button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    if type(page.ValidateControls) == "function" then
        hooksecurefunc(page, "ValidateControls", function()
            -- Native validation has just recomputed all three visibility flags.
            if state.active then captureVisibility() end
            NativeCraft.Refresh()
        end)
    end
    local form = page.SchematicForm
    if form and type(form.Init) == "function" then hooksecurefunc(form, "Init", NativeCraft.Refresh) end
    page:HookScript("OnShow", NativeCraft.Refresh)
    page:HookScript("OnHide", restore)
    return true
end

function NativeCraft.Refresh()
    if refreshing or not NativeCraft.Install() then return end
    transferClickGuards()
    refreshing = true
    local id, recipe = current()
    if not id then restore(); refreshing = false; return end
    if ns.job and not busy() and (ns.job.recipeID ~= id or ns.job.professionKey ~= ns.professionKey) then
        -- A different native selection abandons a resting project. No cast or
        -- purchase is in flight here, so this never invokes a stop action.
        ns.Cancel()
        id, recipe = current()
        if not id then restore(); refreshing = false; return end
    end
    if not recipe or recipe.supported == false then restore(); refreshing = false; return end
    local matchingJob = ns.job and ns.job.recipeID == id and ns.job.professionKey == ns.professionKey
    local matchingStart = ns.pendingStart and ns.pendingStart.recipeID == id
        and ns.pendingStart.professionKey == ns.professionKey
    local ignoreBank = (matchingJob and ns.job.ignoreBank) or (matchingStart and ns.pendingStart.ignoreBank)
    local catalogueBankOff = (matchingJob and ns.job.catalogueIncludeBank == false)
        or (matchingStart and ns.pendingStart.catalogueIncludeBank == false)
    local inventory, bank
    if catalogueBankOff and ns.PlanningStock then inventory, bank = ns.PlanningStock(ns.recipes)
    elseif ns.Bank and not ignoreBank and not catalogueBankOff then inventory, bank = ns.Bank.Snapshot(ns.recipes)
    else inventory, bank = ns.API.Inventory(ns.recipes), {} end
    local maximum, maximumPlan = ns.Planner.MaxCrafts(ns.recipes, inventory, ns.vendorItems, id, 1000, bank)
    if maximum == 0 and not matchingJob then restore(); refreshing = false; return end

    local changed = not state.active or state.recipeID ~= id
    if not state.active then captureVisibility() end
    local multiple = recipe.canCreateMultiple ~= false
    local quantity = changed and state.originals[3]:GetValue() or state.quantity:GetValue()
    if matchingJob then quantity = ns.job.remaining end
    quantity = multiple and clamp(quantity, math.max(maximum, 1)) or 1
    if matchingJob then quantity = clamp(ns.job.remaining) end
    state.quantity:SetMinMaxValues(1, math.max(maximum, quantity, 1))
    if not state.quantity:HasFocus() or changed then state.quantity:SetValue(quantity) end
    state.active, state.recipeID, state.maximum = true, id, maximum
    for _, original in ipairs(state.originals) do original:Hide() end

    local plan = quantity == maximum and maximumPlan
        or ns.Planner.Plan(ns.recipes, inventory, ns.vendorItems, id, quantity, bank)
    local canCreate, createReason, createQuote, createBank, createAlternative, createPlan = quotePlan(plan)
    local ready, reason, kind = craftReadiness(id, createPlan)
    local buyOnly = purchaseOnly(ready, kind, createPlan)
    local idle = not busy() and (not ns.job or matchingJob)
    local canEdit = idle and (not ns.CanEditQuantity or ns.CanEditQuantity())
    state.createQuote, state.allQuote = createQuote, nil
    -- The tooltip prices the bags-only alternative only when it has a quote;
    -- otherwise it shows the bank-aware quote, which belongs to the bank plan.
    state.create.plan = createAlternative and createPlan or plan
    state.create.buyOnly = buyOnly
    state.create.actionIntent = createPlan and next(createPlan.purchases or {}) and "buy" or "craft"
    state.create.requirementReason = buyOnly and reason or nil
    state.create.reason = buyOnly and not canCreate and createReason or (not ready and reason or createReason)
    -- An unacknowledged purchase disables the action: explain why in its tooltip.
    if ns.Merchant.IsBusy() and (not ns.job or matchingJob) then state.create.reason = L.WAIT_PURCHASES_RESUME end
    state.create.bankMessage, state.create.alternativeQuote = createBank, createAlternative
    state.cancel = busy() and true or false
    state.create.craftQuantity = quantity
    local actionText = state.create.actionIntent == "buy" and L.ACTION_BUY or ns.ActionButtons.CraftText(quantity)
    local cancelText = ns.job and ns.job.pending and L.STOP_BATCH or L.CANCEL
    if ns.UI and ns.UI.FitActionButton then
        ns.UI.FitActionButton(state.all, L.MAX_QUANTITY, 64, 40)
        local available = 188
        if state.originals[1].GetRight and state.all.GetRight then
            local right, afterMax = state.originals[1]:GetRight(), state.all:GetRight()
            if type(right) == "number" and type(afterMax) == "number" and right > afterMax + 12 then
                available = right - afterMax - 12
            end
        end
        ns.UI.FitActionButton(state.create, actionText, available)
        ns.UI.FitActionButton(state.cancelButton, cancelText, available)
    else
        setText(state.create, actionText); setText(state.all, L.MAX_QUANTITY); setText(state.cancelButton, cancelText)
    end
    state.create:SetEnabled((ready or buyOnly) and canCreate and idle or false)
    state.all:SetEnabled(canEdit and multiple and maximum > 0 or false)
    state.cancelButton:SetEnabled(state.cancel)
    state.quantity:SetEnabled(canEdit and multiple or false)
    state.create:SetShown(not state.cancel)
    state.all:SetShown(multiple)
    state.cancelButton:SetShown(state.cancel)
    state.quantity:SetShown(multiple and state.visible[3])
    refreshing = false
end
