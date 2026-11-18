local addonName, ns = ...
local L = ns.L
ns.name = addonName
ns.recipes = {}
ns.vendorItems = {}
ns.quantity = 1
ns.maxCrafts = 0
ns.status = L.OPEN_PROFESSION_SELECT_RECIPE

-- Only well-known vendor containers are assumed before visiting a merchant.
-- All recipe quantities and item outputs are read from the live client.
local defaultVendors = ns.VendorData and ns.VendorData.DefaultItems
    or { [3371] = true, [3372] = true, [8925] = true, [18256] = true }
local frame = CreateFrame("Frame")
ns.eventFrame = frame
local rescanAt, lastSelectionCheck = nil, 0
local scanAttempts = 0
local professionClosed = false
local openOnMerchantVisit = false
local bankOverride
local learnVendors
local readinessSnapshot
local initialized = false
local quantityRecipeID, quantityProfessionKey
local allQuantityRequest
-- BAG_UPDATE bookkeeping until the next BAG_UPDATE_DELAYED (see ns.OnEvent).
local bagUpdates, inventoryChanged = false, false

-- Create All borrows the input only while its explicit action is pending. A
-- refusal before its project exists, or a cancelled confirmation, must not turn
-- the next ordinary Create into a maximum batch. A launch of that project
-- (purchase, craft, or one refused by the client) commits the maximum.
local function settleAllQuantity()
    local request = allQuantityRequest
    if not request or request.executing then return end
    if request.committed then allQuantityRequest = nil; return end
    if ns.bankConfirmation or ns.pendingStart then return end
    allQuantityRequest = nil
    if ns.job == request.job and ns.job then
        ns.job.remaining, ns.job.total = request.remaining, request.total
        -- Restore the earlier source choice, never an old spending ceiling.
        -- Refresh immediately revokes it if current bags now require purchases.
        ns.job.ignoreBank, ns.job.bankApproval = request.ignoreBank == true, nil
    elseif not request.job and ns.job and not ns.job.pending and not ns.job.awaitingPurchase then
        ns.job = nil
    end
    if ns.selectedID == request.recipeID and ns.selectedProfessionKey == request.professionKey then
        ns.quantity = request.quantity
        quantityRecipeID, quantityProfessionKey = request.quantityRecipeID, request.quantityProfessionKey
    end
    -- The native page's own input showed the borrowed project: give it back too.
    -- A failure is reported, never allowed to break the settlement.
    if request.onRestore then
        local ok, err = pcall(request.onRestore)
        local handler = not ok and geterrorhandler and geterrorhandler()
        if type(handler) == "function" then pcall(handler, err) end
    end
end

local function commitAllQuantity()
    if allQuantityRequest then allQuantityRequest.committed = true end
end

-- Last messages shown in chat and given to pause(): a Create All that ends
-- without work uses them to explain itself once, without repeating a report.
local lastPrinted, lastPause

function ns.Print(message)
    lastPrinted = message
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc66CraftAutoBuy|r : " .. tostring(message))
    end
end

local function cleanNumber(value)
    if issecretvalue and issecretvalue(value) then return nil end
    return type(value) == "number" and value or nil
end

local function now() return GetTime() end
local function combat() return InCombatLockdown and InCombatLockdown() end

-- The client starts its combat lockdown only after PLAYER_REGEN_DISABLED and
-- ends it before PLAYER_REGEN_ENABLED: follow the events too, for display only.
local combatEvent = false
function ns.InCombat() return combatEvent or combat() == true end

-- TRADE_SKILL_CLOSE marks the profession window closed until the next
-- TRADE_SKILL_SHOW, even if the client still reports the last profession.
function ns.IsProfessionClosed() return professionClosed end

function ns.ItemName(itemID)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    return name or L.ITEM_FALLBACK:format(tostring(itemID))
end

function ns.ActiveRecipes()
    if ns.job then return ns.job.recipes end
    if ns.Catalogue and ns.selectedProfessionKey then
        return ns.Catalogue.GetRecipes(ns.selectedProfessionKey) or {}
    end
    return ns.recipes
end
local activeRecipes = ns.ActiveRecipes

local function invalidateCatalogue()
    if ns.Catalogue then ns.Catalogue.Invalidate() end
end

local function catalogueIncludesBank()
    -- An active project keeps the source choice made at its originating click,
    -- even when CAB is hidden or the player returns to the native profession.
    if ns.job then return ns.job.catalogueIncludeBank ~= false end
    if ns.pendingStart then return ns.pendingStart.catalogueIncludeBank ~= false end
    return not ns.catalogueActive or not ns.CatalogueView or ns.CatalogueView.Get().includeBank ~= false
end

local function planningStock(recipes)
    if not catalogueIncludesBank() or bankOverride or (ns.job and ns.job.ignoreBank)
        or (ns.pendingStart and ns.pendingStart.ignoreBank) then
        return ns.API.Inventory(recipes), {}
    end
    if ns.Bank then return ns.Bank.Snapshot(recipes) end
    return ns.API.Inventory(recipes), {}
end
-- CAB's component projection uses the same source decision as its Max and
-- action plan; a separate physical snapshot may still describe stored stock.
ns.PlanningStock = planningStock

local function bankPurchaseOverlap(recipes, plan, quote)
    if catalogueIncludesBank() or not ns.Bank or not ns.Bank.Snapshot or not ns.Bank.Message
        or not plan or not plan.craftable or not next(plan.purchases or {}) then return nil end
    local _, bank = ns.Bank.Snapshot(recipes)
    quote = quote or ns.Merchant.Quote(plan.purchases)
    local overlaps, retrievals = {}, {}
    for itemID, needed in pairs(plan.purchases) do
        local purchased = quote and quote.purchaseQuantities and quote.purchaseQuantities[itemID] or needed
        local stored = bank and bank[itemID] or 0
        if type(purchased) == "number" and purchased > 0 and stored > 0 then
            overlaps[itemID] = math.min(stored, purchased)
            -- The confirmation prices the rounded merchant bundle, but only
            -- the missing recipe units need withdrawing to avoid that purchase.
            retrievals[itemID] = math.min(stored, needed)
        end
    end
    if not next(overlaps) then return nil end
    return ns.Bank.Message({bankWithdrawals = retrievals}), overlaps
end

local function bankPurchasesApproved(overlaps, approval)
    if not overlaps then return true end
    local allowed = approval and approval.bankRepurchases
    for itemID, quantity in pairs(overlaps) do
        if not allowed or quantity > (allowed[itemID] or 0) then return false end
    end
    return true
end

-- Filtering out the bank changes the calculation, never the permission to buy
-- supplies the character already owns there. This read-only warning also lets
-- CAB/native controls describe the same confirmation as the execution guard.
function ns.BankPurchaseWarning(recipes, plan, quote)
    local message, overlaps = bankPurchaseOverlap(recipes, plan, quote)
    if message and not bankPurchasesApproved(overlaps, bankOverride or (ns.job and ns.job.bankApproval)) then
        return message, overlaps
    end
end

local function bankMessage()
    return ns.Bank and ns.Bank.Message(ns.plan)
end

local function clearBankApproval()
    bankOverride = nil
    if ns.job then ns.job.ignoreBank, ns.job.bankApproval = false, nil end
end

-- The monetary ceiling belongs to one purchase phase. The decision to use
-- bag materials instead of a bank intermediate lasts for this job, so the next
-- explicit click can actually craft that intermediate after approval expires.
local function clearSpendingApproval()
    bankOverride = nil
    if ns.job then ns.job.bankApproval = nil end
end

-- Readiness shown by the open CAB page, polled like Blizzard's required-tools
-- display: the selected recipe, or a project at rest awaiting its next click
-- (CAB hides the native page, whose own periodic validation then stops). Nil
-- while work is in flight, during a confirmation or for another profession.
local function readinessState()
    local job = ns.job
    local id = job and job.recipeID or ns.selectedID
    local key = job and job.professionKey or ns.selectedProfessionKey
    if not ns.catalogueActive or not id or ns.pendingStart or ns.bankConfirmation or ns.Merchant.IsBusy() then
        return nil
    end
    if job and (job.running or job.pending or job.awaitingPurchase or professionClosed) then return nil end
    if not ns.API.IsOwnProfession() or ns.API.GetProfessionKey() ~= key then return nil end
    local plan = ns.readinessPlan or ns.plan
    local state = {recipeID = id, professionKey = key}
    state.ready, state.reason, state.kind = ns.CraftReadiness(id, plan)
    if ns.readinessAllPlan and ns.readinessAllPlan ~= plan then
        state.allReady, state.allReason, state.allKind = ns.CraftReadiness(id, ns.readinessAllPlan)
    end
    return state
end

local READINESS_FIELDS = {"recipeID", "professionKey", "ready", "reason", "kind", "allReady", "allReason", "allKind"}
local function sameReadiness(a, b)
    if not a or not b then return false end
    for _, field in ipairs(READINESS_FIELDS) do
        if a[field] ~= b[field] then return false end
    end
    return true
end

-- Called at the end of every complete CAB render, including direct renders
-- (search, category toggle): the poll compares the live readiness with what
-- the page actually displays.
local renderedReadiness = 0
function ns.NoteRenderedReadiness()
    readinessSnapshot = readinessState()
    renderedReadiness = renderedReadiness + 1
end

function ns.Refresh()
    settleAllQuantity()
    if not ns.job and ns.selectedID and (quantityRecipeID ~= ns.selectedID
        or quantityProfessionKey ~= ns.selectedProfessionKey) then
        ns.quantity = 1
        quantityRecipeID, quantityProfessionKey = ns.selectedID, ns.selectedProfessionKey
    end
    -- Banking follows the displayed CAB request. Cancel the previous recipe
    -- before another transfer can run after any selection/quantity change.
    if ns.BankTransferUI and ns.BankTransferUI.OnContextChanged then ns.BankTransferUI.OnContextChanged() end
    if not ns.pendingStart and ns.UI and ns.UI.DeactivateIfHidden then ns.UI.DeactivateIfHidden() end
    local recipes = activeRecipes()
    local recipeID = ns.job and ns.job.recipeID or ns.selectedID
    local quantity = ns.job and ns.job.remaining or ns.quantity
    if recipeID and recipes[recipeID] then
        local inventory, bank = planningStock(recipes)
        ns.maxCrafts = ns.Planner.MaxCrafts(recipes, inventory, ns.vendorItems, recipeID, 1000, bank)
        ns.plan = ns.Planner.Plan(recipes, inventory, ns.vendorItems, recipeID, quantity, bank)
        local job = ns.job
        if job and job.ignoreBank and not job.bankApproval and not bankOverride
            and not job.running and not job.pending and not job.awaitingPurchase
            and not ns.pendingStart and not ns.bankConfirmation and not ns.Merchant.IsBusy()
            and (not ns.plan.craftable or next(ns.plan.purchases or {})) then
            -- A bag-only choice cannot hide bank supplies behind a disabled
            -- button after the bags change. Replan once without spending or
            -- prompting; a later explicit click may request a new approval.
            clearBankApproval()
            inventory, bank = planningStock(recipes)
            ns.maxCrafts = ns.Planner.MaxCrafts(recipes, inventory, ns.vendorItems, recipeID, 1000, bank)
            ns.plan = ns.Planner.Plan(recipes, inventory, ns.vendorItems, recipeID, quantity, bank)
        end
        ns.quote = ns.Merchant.Quote(ns.plan.purchases)
    else
        ns.plan, ns.maxCrafts, ns.quote = nil, 0, nil
    end
    local renders = renderedReadiness
    if ns.UI then ns.UI.Render() end
    -- A complete render recorded what it displayed. Otherwise (CAB hidden or
    -- already rendering) remember the current state, so the poll does not
    -- refresh in vain. A failed render records nothing: the poll retries.
    if renderedReadiness == renders then readinessSnapshot = readinessState() end
    if ns.StockUI then ns.StockUI.Render() end
    if ns.NativeCraft then ns.NativeCraft.Refresh() end
    if ns.NativeUI then ns.NativeUI.Refresh() end
    if ns.Settings then ns.Settings.Sync() end
end

local function selectRecipe(recipeID, key)
    key = key or ns.professionKey
    if recipeID == ns.selectedID and key == ns.selectedProfessionKey then return end
    if ns.CancelBankConfirmation then ns.CancelBankConfirmation() end
    ns.selectedID, ns.selectedProfessionKey = recipeID, key
    local recipes = activeRecipes()
    if not ns.job and recipeID and recipes[recipeID] then
        ns.quantity = 1
        quantityRecipeID, quantityProfessionKey = recipeID, key
        ns.status = L.CHOOSE_QUANTITY
    end
    ns.Refresh()
end

function ns.CancelBankConfirmation()
    ns.bankConfirmation = nil
    if ns.Bank and ns.Bank.CancelConfirmation then ns.Bank.CancelConfirmation() end
    settleAllQuantity()
end

function ns.CancelPendingStart()
    -- A dropped switch must not keep announcing that a profession is opening:
    -- a resting project then derives its usual reopen/resume instruction.
    if ns.pendingStart and ns.status == L.CATALOGUE_SWITCHING then
        ns.status = ns.job and L.PROJECT_PAUSED_REOPEN or nil
    end
    ns.pendingStart = nil
    ns.CancelBankConfirmation()
end

function ns.CanSelectRecipe()
    if ns.pendingStart or ns.bankConfirmation or ns.Merchant.IsBusy() then return false end
    local job = ns.job
    return not job or (not job.pending and not job.running and not job.awaitingPurchase)
end

function ns.SelectCatalogRecipe(recipeID, key)
    if not ns.CanSelectRecipe() then return false end
    local recipes = ns.Catalogue and ns.Catalogue.GetRecipes(key)
    if not recipes or not recipes[recipeID] then return false end
    if ns.job and (recipeID ~= ns.job.recipeID or key ~= ns.job.professionKey) then ns.Cancel() end
    selectRecipe(recipeID, key)
    return true
end

local function sameProfession(left, right)
    if not left or not right then return false end
    if left == right then return true end
    if not ns.API.GetProfessionParentKey then return false end
    local parent = ns.API.GetProfessionParentKey(left)
    return parent ~= nil and parent == ns.API.GetProfessionParentKey(right)
end

function ns.Scan(preserveSelection)
    -- A rejected linked/new profession must not reuse an unprepared old recipe.
    -- A normal close keeps the previous selection for the visit to a merchant.
    local key = ns.API.GetProfessionKey()
    local own = ns.API.IsOwnProfession()
    if not ns.job and not ns.catalogueActive and not ns.pendingStart and not preserveSelection
        and key and (not own or (ns.professionKey and key ~= ns.professionKey)) then
        ns.selectedID = nil
    end
    local recipes, err = ns.API.ScanRecipes()
    if recipes then
        ns.recipes = recipes
        ns.professionKey = ns.API.GetProfessionKey()
        if ns.Catalogue then ns.Catalogue.Record(ns.professionKey, recipes) end
        if ns.Bootstrap then ns.Bootstrap.Wake() end
        -- A known catalogue may use the base profession while the freshly
        -- opened source identifies its child skill line. Adopt only a verified
        -- recipe of that same profession, preserving the user's chosen lot.
        local selected = ns.selectedID and recipes[ns.selectedID]
        if ns.catalogueActive and not ns.job and not ns.pendingStart and not ns.bankConfirmation
            and own and ns.API.IsOwnProfession() and selected and selected.supported ~= false
            and ns.selectedProfessionKey ~= ns.professionKey
            and sameProfession(ns.professionKey, ns.selectedProfessionKey) then
            ns.selectedProfessionKey = ns.professionKey
            quantityRecipeID, quantityProfessionKey = ns.selectedID, ns.professionKey
        end
        if ns.Merchant.IsOpen() and learnVendors then learnVendors() end
        ns.scanError = nil
        scanAttempts = 0
        if not ns.catalogueActive and not ns.pendingStart and not preserveSelection then
            selectRecipe(ns.API.SelectedRecipeID())
        end
    else
        ns.scanError = err
        ns.status = err or L.RECIPES_LOADING_STATUS
        scanAttempts = scanAttempts + 1
        if scanAttempts < 8 and ns.API.IsOwnProfession() then rescanAt = now() + 0.6 end
    end
    ns.Refresh()
    return recipes, err
end

function ns.CanEditQuantity()
    if ns.pendingStart or ns.bankConfirmation or ns.Merchant.IsBusy() then return false end
    local job = ns.job
    return not job or (not job.pending and not job.running and not job.awaitingPurchase and job.remaining == job.total)
end

function ns.SetQuantity(value)
    if not ns.CanEditQuantity() then return end
    local quantity = math.max(1, math.min(1000, math.floor(tonumber(value) or 1)))
    if ns.job and quantity ~= ns.job.remaining then clearBankApproval() end
    ns.quantity = quantity
    quantityRecipeID = ns.job and ns.job.recipeID or ns.selectedID
    quantityProfessionKey = ns.job and ns.job.professionKey or ns.selectedProfessionKey
    if ns.job then ns.job.remaining, ns.job.total = ns.quantity, ns.quantity end
    ns.Refresh()
end

local function prepareJob()
    if ns.job then return true end
    ns.Refresh()
    if not ns.plan or not ns.plan.craftable then
        ns.status = L.PLAN_UNAVAILABLE
        ns.Refresh()
        return false
    end
    local includeBank = catalogueIncludesBank()
    ns.job = {
        recipeID = ns.selectedID, remaining = ns.quantity, total = ns.quantity,
        recipes = activeRecipes(), professionKey = ns.selectedProfessionKey or ns.professionKey, running = false,
        ignoreBank = bankOverride ~= nil, bankApproval = bankOverride,
        catalogueIncludeBank = includeBank,
    }
    ns.Refresh()
    return true
end

function ns.Cancel(stopRequested)
    -- All callers are explicit user actions (Cancel buttons or /cab stop).
    -- Detach first: the client can synchronously emit interruption events.
    local pending = ns.job and ns.job.pending
    clearBankApproval()
    ns.job = nil
    ns.pendingStart = nil
    ns.CancelBankConfirmation()
    ns.Merchant.Stop()
    local stopStatus
    -- A real InsecureActionButtonTemplate click may already have requested the
    -- stop through /stopcasting. Never call the protected global from Lua.
    if stopRequested == true then stopStatus = L.CRAFT_STOP_REQUESTED
    elseif pending then stopStatus = L.CRAFT_STOP_UNCONFIRMED end
    ns.status = stopStatus or L.PROJECT_CANCELLED
    ns.Refresh()
    -- Once detached, no status line shows the stop result (e.g. press Escape).
    if stopStatus then ns.Print(stopStatus) end
end

learnVendors = function()
    local sold = ns.Merchant.Scan()
    local function learn(recipes)
        for _, recipe in pairs(recipes or {}) do
            for _, reagent in ipairs(recipe.reagents or {}) do
                if sold[reagent.itemID] and CraftAutoBuyDB.vendorItems[reagent.itemID] ~= false then
                    ns.vendorItems[reagent.itemID] = true
                    CraftAutoBuyDB.vendorItems[reagent.itemID] = true
                end
            end
        end
    end
    learn(activeRecipes())
    learn(ns.recipes)
    if ns.Catalogue and ns.API.GetProfessions then
        for _, profession in ipairs(ns.API.GetProfessions()) do
            learn(ns.Catalogue.GetRecipes(profession.key))
        end
    end
    invalidateCatalogue()
    return sold
end

local function openAtSupplier(sold)
    if not openOnMerchantVisit or not ns.Merchant.IsOpen() then return end
    if not CraftAutoBuyDB.openAtMerchant or combat() or ns.job or ns.pendingStart or ns.bankConfirmation or ns.Merchant.IsBusy() then
        openOnMerchantVisit = false
        return
    end
    local supplier = false
    for itemID in pairs(sold or {}) do
        if ns.vendorItems[itemID] then supplier = true; break end
    end
    if not supplier then return end -- Merchant inventory can arrive in MERCHANT_UPDATE.
    openOnMerchantVisit = false -- At most once, even when the user closes the book.
    if not ProfessionsFrame and ProfessionsFrame_LoadUI then
        local ok, loaded = pcall(ProfessionsFrame_LoadUI)
        if not ok or not loaded then return end
    end
    if ns.UI and ns.UI.Show then ns.UI.Show() end
end

-- The bank was checked at the click, but its contents can become known later
-- (a late transfer reply, a reading that becomes unverified). Merchant calls
-- this before each new order: a withdrawal that this job has not explicitly
-- bypassed stops the queue, and only a new click may show the confirmation.
-- It never buys, crafts, prompts or approves anything.
local function purchaseGuard(job)
    return function(remainingBasket, remainingQuote)
        if ns.job ~= job or not job.awaitingPurchase then return false end
        local inventory, bank = planningStock(job.recipes)
        local plan = ns.Planner.Plan(job.recipes, inventory, ns.vendorItems, job.recipeID, job.remaining, bank)
        if not plan.craftable then return false, L.PLAN_UNAVAILABLE end
        -- The merchant queue retains its original item targets. A newly gained
        -- intermediate can remove purchases from the project replan while that
        -- queue still has orders to send; consent must cover the actual cart.
        local purchasePlan = remainingBasket and {craftable = true, purchases = remainingBasket} or plan
        if ns.BankPurchaseWarning(job.recipes, purchasePlan, remainingQuote) then
            return false, L.BANK_OVERRIDE_CHANGED
        end
        return not (ns.Bank and ns.Bank.Message(plan)), L.BANK_OVERRIDE_CHANGED
    end
end

local function buyForCraft()
    if combat() then
        ns.status = L.PURCHASES_PAUSED_COMBAT
        ns.Refresh()
        return false
    end
    if ns.Merchant.IsBusy() or not ns.Merchant.IsOpen() then return false end
    learnVendors()
    if not ns.job then return false end
    if ns.job.pending then return false end
    ns.Refresh()
    if ns.plan and ns.plan.craftable then
        if bankMessage() then ns.status = bankMessage(); ns.Refresh(); return false end
        if ns.BankPurchaseWarning(ns.job.recipes, ns.plan, ns.quote) then
            clearBankApproval(); ns.status = L.BANK_OVERRIDE_CHANGED; ns.Refresh(); return false
        end
        local ok, reason = ns.Merchant.Start(ns.plan.purchases, ns.job.bankApproval, purchaseGuard(ns.job))
        if ok then commitAllQuantity() end
        if not ok then
            ns.status = reason or L.PURCHASES_CANNOT_START
            if reason == L.BANK_OVERRIDE_CHANGED then clearBankApproval(); ns.Print(reason) end
        end
        ns.Refresh()
        return ok
    end
    ns.Refresh()
    return false
end

function ns.PausePurchaseContinuation()
    if ns.job and ns.job.awaitingPurchase then
        local job = ns.job
        local purchaseOnly = job.purchaseOnly
        -- Inventory events can confirm the last delivery before OnUpdate has
        -- retired the purchase phase. Use fresh bags, not the cached plan, to
        -- keep the accepted source choice in that small interruption window.
        local bagsPlan = not purchaseOnly and ns.Planner.Plan(job.recipes, ns.API.Inventory(job.recipes),
            ns.vendorItems, job.recipeID, job.remaining)
        local complete = bagsPlan and bagsPlan.craftable and not next(bagsPlan.purchases)
        -- Supplies from another source can complete the bags while one order is
        -- still unacknowledged: never announce a receipt that was not observed.
        local inFlight = ns.Merchant.HasPending and ns.Merchant.HasPending()
        ns.job.awaitingPurchase = nil
        ns.job.running = false
        -- An approval covers one purchase phase, including money already sent.
        -- Restarting Merchant.Start would otherwise reset its spent ledger and
        -- reuse the original ceiling after a partial/interrupted basket.
        if complete then clearSpendingApproval() else clearBankApproval() end
        if purchaseOnly then
            ns.job = nil
            ns.Merchant.Stop()
        end
        ns.status = inFlight and L.LAST_PURCHASE_PENDING
            or (complete and L.PURCHASE_READY_CLICK or L.PURCHASE_CRAFT_PAUSED)
        if purchaseOnly then ns.Refresh() end
    end
end

local function pause(message, alreadyReported)
    lastPause = message
    if ns.job then ns.job.running = false end
    if ns.job and ns.job.purchaseOnly then
        clearBankApproval()
        ns.job = nil
        ns.Merchant.Stop()
    end
    ns.status = message
    if message == L.BANK_OVERRIDE_CHANGED and not alreadyReported then ns.Print(message) end
    ns.Refresh()
end

-- The resting status line derives its text from live state, so it may not show
-- why an explicit click was refused: report it once in chat when it does not.
local function refuseClick(message)
    pause(message)
    if not message or message == L.BANK_OVERRIDE_CHANGED then return end
    local shown = ns.UI and ns.UI.StatusText and ns.UI.StatusText()
    if shown ~= message then ns.Print(message) end
end

-- True when the visible CAB status line already carries the message (the
-- native and Stock pages have none: UI.StatusText is nil there).
local function statusShows(message)
    local shown = ns.UI and ns.UI.StatusText and ns.UI.StatusText()
    return type(shown) == "string" and shown:find(message, 1, true) ~= nil
end

-- A refused launch or purchase start keeps or drops the project without any
-- other explanation outside the CAB page: say it once in chat. A changed quote
-- is printed by its own path.
local function explainRefusal(message)
    if type(message) ~= "string" or message == "" or message == L.BANK_OVERRIDE_CHANGED then return end
    if not statusShows(message) then ns.Print(message) end
end

-- A Create All that ends without starting any work drops the project it
-- created, and the resting status line no longer explains why (refused purchase,
-- recipe unavailable after a confirmation...): report the reason once in chat.
local function reportUnstartedAll(request)
    if request.committed or request.job or ns.bankConfirmation or ns.pendingStart then return end
    if type(lastPause) ~= "string" or lastPause == "" then return end
    if not statusShows(lastPause) and lastPause ~= lastPrinted then ns.Print(lastPause) end
end

-- Missing tools or stations allow a separate purchase-only action. Check every
-- dependency first: a cooldown or unavailable recipe must still prevent buying.
function ns.CraftReadiness(recipeID, plan)
    if ns.BankTransfer and ns.BankTransfer.IsBusy and ns.BankTransfer.IsBusy() then
        return false, L.BANK_TRANSFER_BUSY
    end
    if not recipeID then return false, L.SELECT_RECIPE end
    local seen, requirement = {}, nil
    local function check(id)
        if seen[id] then return true end
        seen[id] = true
        local ready, reason, kind = ns.API.RecipeReady(id)
        if ready then return true end
        if kind ~= "requirements" then
            return false, reason or L.RECIPE_TEMPORARILY_UNAVAILABLE, kind
        end
        requirement = requirement or reason or L.RECIPE_TEMPORARILY_UNAVAILABLE
        return true
    end
    local ready, reason, kind = check(recipeID)
    if not ready then return false, reason, kind end
    for _, step in ipairs(plan and plan.steps or {}) do
        ready, reason, kind = check(step.recipeID)
        if not ready then return false, reason, kind end
    end
    if requirement then return false, requirement, "requirements" end
    return true
end

local function approvedBasket(plan, quote, approval)
    if not approval then return true end
    if not quote or not quote.complete or quote.totalCost > approval.totalCost then return false end
    for itemID, quantity in pairs(quote.purchaseQuantities or plan.purchases or {}) do
        if quantity > (approval.purchaseQuantities[itemID] or 0) then return false end
    end
    return true
end

-- The smart action names what the user authorized, independently of whether
-- the recipe itself permits buying without its missing station or tool.
local function matchesActionIntent(actionIntent)
    if actionIntent == nil then return true end
    local plan = ns.plan
    if bankMessage() and ns.Bank then plan = ns.Bank.Alternative(activeRecipes(), plan) end
    local needsPurchase = plan and next(plan.purchases or {}) ~= nil
    return actionIntent == (needsPurchase and "buy" or "craft")
end

local function runWithoutBank(approval, purchaseOnly, actionIntent)
    local previous = bankOverride
    bankOverride = approval
    if ns.job then ns.job.ignoreBank, ns.job.bankApproval = true, approval end
    local ok, err = pcall(ns.Start, purchaseOnly, false, actionIntent)
    bankOverride = previous
    if not ok then error(err) end
    ns.Refresh()
end

local function requestBankConfirmation(purchaseOnly, actionIntent)
    local recipes = activeRecipes()
    local message = bankMessage() or ns.BankPurchaseWarning(recipes, ns.plan, ns.quote)
    if not message then return false end
    local alternative, quote, allowed, reason = ns.Bank.Alternative(recipes, ns.plan)
    if not allowed then pause(reason or message); return true end
    local approval = {totalCost = quote.totalCost, purchaseQuantities = {}}
    for id, quantity in pairs(quote.purchaseQuantities or alternative.purchases or {}) do
        approval.purchaseQuantities[id] = quantity
    end
    local _, overlaps = bankPurchaseOverlap(recipes, alternative, quote)
    approval.bankRepurchases = overlaps
    local context = {
        recipeID = ns.job and ns.job.recipeID or ns.selectedID,
        professionKey = ns.job and ns.job.professionKey or ns.selectedProfessionKey,
        quantity = ns.job and ns.job.remaining or ns.quantity,
        job = ns.job, quote = quote, approval = approval,
        native = not ns.catalogueActive,
        purchaseOnly = purchaseOnly == true,
        actionIntent = actionIntent,
        catalogueIncludeBank = catalogueIncludesBank(),
    }
    ns.bankConfirmation = context
    ns.status = message
    local function cancel()
        if ns.bankConfirmation == context then ns.bankConfirmation = nil; ns.Refresh() end
    end
    local function acceptAction()
        if ns.bankConfirmation ~= context then return end
        ns.CancelBankConfirmation()
        local id = ns.job and ns.job.recipeID or ns.selectedID
        local key = ns.job and ns.job.professionKey or ns.selectedProfessionKey
        local quantity = ns.job and ns.job.remaining or ns.quantity
        if id ~= context.recipeID or key ~= context.professionKey or quantity ~= context.quantity
            or ns.job ~= context.job or combat() or ns.pendingStart or ns.Merchant.IsBusy()
            or catalogueIncludesBank() ~= context.catalogueIncludeBank
            or (context.native and ns.API.SelectedRecipeID() ~= id) then
            pause(L.BANK_OVERRIDE_CHANGED); return
        end
        if ns.API.IsOwnProfession() and ns.API.GetProfessionKey() == key then
            local fresh, err = ns.Scan(true)
            if not fresh or not fresh[id] then pause(err or L.CATALOGUE_RECIPE_CHANGED); return end
            if ns.job then ns.job.recipes = fresh end
        end
        ns.Refresh()
        local freshPlan, freshQuote, canProceed, why = ns.Bank.Alternative(activeRecipes(), ns.plan)
        if not canProceed then pause(why or L.PLAN_UNAVAILABLE); return end
        if not approvedBasket(freshPlan, freshQuote, approval) then pause(L.BANK_OVERRIDE_CHANGED); return end
        local _, freshOverlaps = bankPurchaseOverlap(activeRecipes(), freshPlan, freshQuote)
        if not bankPurchasesApproved(freshOverlaps, approval) then pause(L.BANK_OVERRIDE_CHANGED); return end
        runWithoutBank(approval, context.purchaseOnly, context.actionIntent)
    end
    local function accept()
        if ns.bankConfirmation ~= context then return end
        local request = allQuantityRequest
        if request then request.executing = true; lastPause, lastPrinted = nil, nil end
        local ok, err = pcall(acceptAction)
        if request then request.executing = false end
        settleAllQuantity()
        ns.Refresh()
        if not ok then error(err) end
        if request then reportUnstartedAll(request) end
    end
    local shown = ns.Bank.RequestConfirmation(message, quote, accept, cancel)
    if not shown then ns.bankConfirmation = nil; ns.status = message end
    ns.Refresh()
    return true
end

local function castBatch()
    local job = ns.job
    if not job or job.pending then return end
    if combat() then pause(L.CRAFT_PAUSED_COMBAT) return end
    if not ns.API.IsOwnProfession() or ns.API.GetProfessionKey() ~= job.professionKey then
        pause(L.REOPEN_PROFESSION_RESUME) return
    end
    if ns.Merchant.IsBusy() then
        pause(L.WAIT_PURCHASES_RESUME) return
    end
    if (UnitCastingInfo and UnitCastingInfo("player")) or (UnitChannelInfo and UnitChannelInfo("player")) then
        -- The launch was attempted: the visible project stays at rest with the
        -- quantity Create All chose, so "click Create" resumes exactly it.
        commitAllQuantity()
        pause(L.WAIT_ACTION_RESUME)
        explainRefusal(L.WAIT_ACTION_RESUME)
        return
    end
    ns.Refresh()
    if not ns.plan or not ns.plan.craftable then
        pause(L.INVENTORY_CHANGED_MISSING) return
    end
    if bankMessage() then pause(bankMessage()); return end
    if next(ns.plan.purchases) then
        pause(L.OPEN_MERCHANT_NEEDED) return
    end
    local step = ns.plan.steps[1]
    if not step then pause(L.NO_CRAFT_STEP) return end
    local recipe = job.recipes[step.recipeID]
    local ready, reason = ns.API.RecipeReady(step.recipeID)
    if not ready then pause(reason or L.RECIPE_TEMPORARILY_UNAVAILABLE) return end
    local baseline = ns.API.CountItem(recipe.outputItemID)
    local batchCount = recipe.canCreateMultiple == false and 1 or step.crafts
    -- A real click submits one native batch of one recipe. Events can confirm
    -- its progress, but never authorize another recipe or another batch.
    job.pending = {
        recipeID = step.recipeID, itemID = recipe.outputItemID,
        before = baseline, lastCount = baseline, received = 0,
        unitOutput = recipe.outputCount, expected = recipe.outputCount * batchCount,
        requested = batchCount, successes = 0, credited = 0, completedGUIDs = {},
        started = now(), lastProgress = now(), succeeded = false, sawStart = false, castSerial = 0,
    }
    job.running = true
    ns.status = L.CRAFTING_BATCH:format(recipe.name, batchCount)
    local ok, err, kind = ns.API.Craft(step.recipeID, batchCount)
    -- Started or refused by the client, this launch belongs to a visible project:
    -- a borrowed Create All quantity stays with it (Cancel abandons it).
    commitAllQuantity()
    if not ok then
        job.pending = nil
        pause(L.CRAFT_REJECTED_RESUME:format(tostring(err)))
        -- A blocked protected call was already reported by API.Craft.
        if kind ~= "protected" then explainRefusal(ns.status) end
    end
    ns.Refresh()
end

function ns.Start(purchaseOnlyIntent, allowCraft, actionIntent)
    if ns.BankTransfer and ns.BankTransfer.IsBusy and ns.BankTransfer.IsBusy() then
        ns.status = L.BANK_TRANSFER_BUSY
        return false
    end
    purchaseOnlyIntent = purchaseOnlyIntent == true
    if actionIntent == "buy" then allowCraft = false end
    if ns.pendingStart or ns.bankConfirmation then return end
    if ns.Merchant.IsBusy() or (ns.job and ns.job.awaitingPurchase) then
        ns.status = L.WAIT_PURCHASES_RESUME
        ns.Refresh()
        return
    end
    if ns.job and ns.job.pending then
        ns.status = L.WAIT_CRAFT_CONFIRMATION
        ns.Refresh()
        return
    end
    -- Without a project nothing was paused: use a neutral refusal.
    if combat() then refuseClick(ns.job and L.CRAFT_PAUSED_COMBAT or L.ACTION_BLOCKED_COMBAT); return end
    local id = ns.job and ns.job.recipeID or ns.selectedID
    local key = ns.job and ns.job.professionKey or ns.selectedProfessionKey or ns.professionKey
    if not id or not key then pause(L.SELECT_RECIPE); return end
    ns.Refresh()
    -- Inventory may have changed since the action label was rendered. A Buy
    -- click never turns into a cast; a Craft click never authorizes a purchase.
    if not matchesActionIntent(actionIntent) then refuseClick(L.ACTION_CHANGED); return end
    -- Preserve the action the user clicked through a bank confirmation or a
    -- profession switch, even if a station becomes available while waiting.
    if not purchaseOnlyIntent and ns.API.IsOwnProfession() and ns.API.GetProfessionKey() == key then
        local readinessPlan = ns.plan
        if bankMessage() and ns.Bank then readinessPlan = ns.Bank.Alternative(activeRecipes(), ns.plan) end
        if readinessPlan and next(readinessPlan.purchases or {}) then
            local _, _, kind = ns.CraftReadiness(id, readinessPlan)
            purchaseOnlyIntent = kind == "requirements"
        end
    end
    if requestBankConfirmation(purchaseOnlyIntent, actionIntent) then return end
    if ns.plan and next(ns.plan.purchases) and not CraftAutoBuyDB.autoBuy then
        pause(L.AUTO_BUY_DISABLED); return
    end
    if not ns.API.IsOwnProfession() or ns.API.GetProfessionKey() ~= key then
        if not ns.API.OpenProfession then pause(L.REOPEN_PROFESSION_RESUME); return end
        ns.pendingStart = {
            recipeID = id, professionKey = key, quantity = ns.job and ns.job.remaining or ns.quantity,
            started = now(), restoreCatalogue = ns.catalogueActive,
            requiresMerchant = ns.plan and next(ns.plan.purchases) ~= nil,
            ignoreBank = bankOverride ~= nil or (ns.job and ns.job.ignoreBank),
            bankApproval = bankOverride or (ns.job and ns.job.bankApproval),
            catalogueIncludeBank = catalogueIncludesBank(),
            purchaseOnly = purchaseOnlyIntent,
        }
        if ns.pendingStart.requiresMerchant and not ns.Merchant.IsOpen() then
            ns.pendingStart = nil; pause(L.OPEN_MERCHANT_NEEDED); return
        end
        ns.status = L.CATALOGUE_SWITCHING
        ns.Refresh()
        local ok, reason = ns.API.OpenProfession(key)
        if not ok then
            ns.pendingStart = nil
            refuseClick(reason or L.CATALOGUE_SWITCH_FAILED)
        else
            scanAttempts = 0
            rescanAt = now() + 0.2
        end
        return
    end
    -- Cached recipes are for browsing only. Re-read the live profession before
    -- any purchase, then plan from current bags, even without a BAG_UPDATE event.
    local recipes, err = ns.Scan(true)
    if not recipes or not recipes[id] or recipes[id].supported == false then
        refuseClick(err or L.CATALOGUE_RECIPE_CHANGED); return
    end
    if ns.job then ns.job.recipes = recipes; ns.Refresh() end
    if not matchesActionIntent(actionIntent) then refuseClick(L.ACTION_CHANGED); return end
    if requestBankConfirmation(purchaseOnlyIntent, actionIntent) then return end
    if not approvedBasket(ns.plan, ns.quote, bankOverride or (ns.job and ns.job.bankApproval)) then
        clearBankApproval()
        pause(L.BANK_OVERRIDE_CHANGED); return
    end
    local existingProject = ns.job ~= nil and not ns.job.purchaseOnly
    if not ns.job and not prepareJob() then return end
    if purchaseOnlyIntent then ns.job.purchaseOnly = true end
    local ready, reason, kind = ns.CraftReadiness(id, ns.plan)
    if not ready and kind ~= "requirements" then pause(reason); return end
    if not matchesActionIntent(actionIntent) then refuseClick(L.ACTION_CHANGED); return end
    local purchaseOnly = purchaseOnlyIntent or (not ready and kind == "requirements")
    local nothingToBuy = not ns.plan or not ns.plan.craftable or not next(ns.plan.purchases)
    if purchaseOnly and nothingToBuy and existingProject and not purchaseOnlyIntent then
        -- The station or tool left before the page caught up: refuse this click
        -- but keep the project, its remaining count and its bags-only choice.
        -- Nothing is bought, so no spending ceiling may outlive this click.
        -- The page derives the missing requirement from live state.
        clearSpendingApproval()
        ns.Refresh()
        local shown = ns.UI and ns.UI.StatusText and ns.UI.StatusText()
        if reason and not (shown and shown:find(reason, 1, true)) then ns.Print(reason) end
        return
    end
    if purchaseOnly then
        ns.job.purchaseOnly = true
        if nothingToBuy then pause(ready and L.BUY_ONLY_READY or reason); return end
    end
    if ns.plan and ns.plan.craftable and next(ns.plan.purchases) then
        -- A changed live recipe can introduce purchases absent from the preview.
        if not CraftAutoBuyDB.autoBuy then pause(L.AUTO_BUY_DISABLED); return end
        if not ns.Merchant.IsOpen() then pause(L.OPEN_MERCHANT_NEEDED) return end
        if not ns.quote or not ns.quote.canBuy then
            pause(ns.quote and ns.Merchant.QuoteReason(ns.quote) or L.PURCHASES_CANNOT_START)
            return
        end
        ns.job.awaitingPurchase = true
        if not buyForCraft() then
            ns.job.awaitingPurchase = nil
            -- A refused purchase start is a pause like any other refusal;
            -- buyForCraft already printed a changed quote.
            local reason = ns.status
            pause(reason, reason == L.BANK_OVERRIDE_CHANGED)
            explainRefusal(reason)
        else
            ns.status = purchaseOnly and L.BUY_ONLY_HELP or L.BUY_THEN_CRAFT
        end
        ns.Refresh()
        return
    end
    if allowCraft == false then
        -- Supplies may have reached the bags while the bank popup was open.
        -- Its now-unneeded spending approval must not survive this ready state.
        clearSpendingApproval()
        commitAllQuantity() -- The confirmed job is ready for its next click.
        pause(L.BANK_OVERRIDE_READY_CLICK)
    else castBatch() end
end

-- Create All (CAB page or native page) borrows the maximum only while its
-- explicit action is pending. recipeID/key name the recipe the action selects
-- when it differs from the current CAB selection (native page); onRestore lets
-- that page restore its own input when nothing was committed.
local function borrowQuantity(start, recipeID, key, onRestore)
    local job = ns.job
    local request = {job = job, remaining = job and job.remaining, total = job and job.total,
        ignoreBank = job and job.ignoreBank, executing = true, onRestore = onRestore}
    if recipeID then
        local owned = quantityRecipeID == recipeID and quantityProfessionKey == key
        request.quantity = owned and ns.quantity or 1
        request.recipeID, request.professionKey = recipeID, key
        request.quantityRecipeID, request.quantityProfessionKey = recipeID, key
    else
        request.quantity, request.recipeID, request.professionKey = ns.quantity, ns.selectedID, ns.selectedProfessionKey
        request.quantityRecipeID, request.quantityProfessionKey = quantityRecipeID, quantityProfessionKey
    end
    allQuantityRequest = request
    lastPause, lastPrinted = nil, nil
    local ok, err = pcall(start)
    request.executing = false
    settleAllQuantity()
    ns.Refresh()
    if not ok then error(err) end
    reportUnstartedAll(request)
    return request.committed == true or ns.bankConfirmation ~= nil or ns.pendingStart ~= nil
end

function ns.StartAll(purchaseOnlyIntent)
    if not ns.CanEditQuantity() then return false end
    if combat() then ns.Start(purchaseOnlyIntent); return false end
    ns.Refresh()
    local maximum = tonumber(ns.maxCrafts)
    if not maximum or maximum < 1 then return false end
    return borrowQuantity(function()
        ns.SetQuantity(maximum)
        ns.Start(purchaseOnlyIntent)
    end)
end

-- The native Create All uses the same transaction: a cancelled confirmation or
-- a refusal before its project exists leaves CAB's quantity, and the native
-- input through onRestore, as they were for the next Create.
function ns.StartNativeAll(recipeID, maximum, purchaseOnlyIntent, onRestore)
    if ns.job then return ns.StartNative(recipeID, maximum, purchaseOnlyIntent) end
    if not ns.CanEditQuantity() then return false end
    local started = false
    borrowQuantity(function()
        started = ns.StartNative(recipeID, maximum, purchaseOnlyIntent) == true
    end, recipeID, ns.professionKey, onRestore)
    return started
end

-- Explicit clicks in the native profession page use exactly the same live
-- planning, purchase and cast continuation as clicks in the catalogue.
function ns.StartNative(recipeID, quantity, purchaseOnlyIntent, actionIntent)
    if ns.catalogueActive or combat() or not ns.API.IsOwnProfession()
        or ns.API.GetProfessionKey() ~= ns.professionKey
        or ns.API.SelectedRecipeID() ~= recipeID then return false end
    if ns.pendingStart or ns.bankConfirmation or ns.Merchant.IsBusy() then return false end
    if ns.job then
        if ns.job.recipeID ~= recipeID or ns.job.professionKey ~= ns.professionKey then return false end
        ns.Start(purchaseOnlyIntent, nil, actionIntent)
        return true
    end
    local recipe = ns.recipes[recipeID]
    if not recipe or recipe.supported == false then return false end
    quantity = tonumber(quantity)
    if not quantity or quantity ~= quantity or quantity == math.huge or quantity == -math.huge then return false end
    ns.selectedID, ns.selectedProfessionKey = recipeID, ns.professionKey
    ns.SetQuantity(quantity)
    ns.Start(purchaseOnlyIntent, nil, actionIntent)
    return true
end

-- Called by the native spell-action overlay's click notification. Opening is
-- performed by that button, never by a protected API from this Lua callback.
-- Schedule a data refresh only: a failed open must not leave a fake busy job.
function ns.ProfessionOpenClicked(recipeID, key)
    if ns.job or ns.pendingStart or ns.bankConfirmation or ns.Merchant.IsBusy() or ns.InCombat() then return false end
    local selectedKey = ns.selectedProfessionKey or ns.professionKey
    local recipe = activeRecipes()[recipeID]
    if recipeID ~= ns.selectedID or not sameProfession(key, selectedKey)
        or not recipe or recipe.supported == false then return false end
    scanAttempts, rescanAt = 0, now() + 0.2
    ns.status = L.CATALOG_VERIFY_HELP
    ns.Refresh()
    return true
end

-- Verification may rescan an already open profession. Opening another source
-- requires the native spell-action button or the profession's own native tab.
function ns.VerifySelectedRecipe()
    if ns.job or ns.pendingStart or ns.bankConfirmation or ns.Merchant.IsBusy() then return false end
    if combat() then refuseClick(L.ACTION_BLOCKED_COMBAT); return false end
    local id, key = ns.selectedID, ns.selectedProfessionKey or ns.professionKey
    if not id or not key then pause(L.SELECT_RECIPE); return false end
    if ns.API.IsOwnProfession() and sameProfession(ns.API.GetProfessionKey(), key) then
        local recipes, reason = ns.Scan(true)
        if not recipes or not recipes[id] or recipes[id].supported == false then
            refuseClick(reason or L.CATALOGUE_RECIPE_CHANGED); return false
        end
        ns.status = L.VERIFY_READY_CLICK
        ns.Refresh()
        return true
    end
    refuseClick(L.CATALOG_VERIFY_HELP)
    return false
end

local function finishProfessionSwitch()
    local pending = ns.pendingStart
    if not pending then return end
    if now() - pending.started > 10 then
        ns.pendingStart = nil
        pause(L.CATALOGUE_SWITCH_TIMEOUT)
        return
    end
    if not ns.API.IsOwnProfession() or ns.API.GetProfessionKey() ~= pending.professionKey
        or ns.professionKey ~= pending.professionKey or ns.scanError then return end
    if pending.requiresMerchant and not ns.Merchant.IsOpen() then
        ns.pendingStart = nil; pause(L.OPEN_MERCHANT_NEEDED); return
    end
    ns.pendingStart = nil
    local recipe = ns.recipes[pending.recipeID]
    if not recipe or recipe.supported == false then pause(L.CATALOGUE_RECIPE_CHANGED); return end
    ns.selectedID, ns.selectedProfessionKey = pending.recipeID, pending.professionKey
    ns.quantity = pending.quantity
    quantityRecipeID, quantityProfessionKey = pending.recipeID, pending.professionKey
    if ns.job then ns.job.recipes = ns.recipes end
    clearBankApproval()
    if pending.restoreCatalogue and ns.UI and ns.UI.Show then ns.UI.Show() end
    ns.status = L.VERIFY_READY_CLICK
    ns.Refresh()
end

local function finishPending()
    local job = ns.job
    local pending = job and job.pending
    if not pending then return end
    local count = ns.API.CountItem(pending.itemID)
    -- Count receipts cumulatively: depositing an already received output in the
    -- bank must not erase its confirmation or prevent the rest of a batch ending.
    pending.received = pending.received + math.max(0, count - pending.lastCount)
    pending.lastCount = count
    local received = math.floor(pending.received / pending.unitOutput)
    local confirmed = math.min(pending.requested, pending.successes, received)
    if confirmed > pending.credited then
        local added = confirmed - pending.credited
        pending.credited, pending.lastProgress = confirmed, now()
        if pending.recipeID == job.recipeID then job.remaining = math.max(0, job.remaining - added) end
        ns.Refresh()
    end
    if pending.credited >= pending.requested
        or (pending.stopped and pending.credited >= pending.successes
            and (not pending.settleAt or now() >= pending.settleAt)) then
        job.pending, job.running = nil, false
        if job.remaining <= 0 then
            ns.status = L.PROJECT_COMPLETE:format(job.total)
            ns.Print(ns.status)
            ns.job = nil
            ns.Refresh()
        else
            ns.status = (pending.stopped and pending.credited < pending.requested)
                and L.CRAFT_INTERRUPTED or L.CRAFT_NEXT_CLICK
            ns.Refresh()
        end
    elseif now() - pending.lastProgress > 45 then
        -- Keep the pending record: an ambiguous operation must not be retried.
        job.running = false
        ns.status = L.CRAFT_CONFIRMATION_MISSING
        ns.Refresh()
    end
end

local function castEvent(event, unit, castGUID, spellID)
    if unit ~= "player" then return end
    local job = ns.job
    local pending = job and job.pending
    if not pending then return end
    spellID = cleanNumber(spellID)
    if spellID ~= pending.recipeID then return end
    if issecretvalue and issecretvalue(castGUID) then castGUID = nil end
    if event == "UNIT_SPELLCAST_START" then
        if pending.completedGUIDs[castGUID or ""] then return end
        pending.castGUID, pending.sawStart = castGUID, true
        pending.castSerial, pending.lastProgress = pending.castSerial + 1, now()
    elseif pending.castGUID and castGUID and pending.castGUID ~= castGUID then
        return
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local identity = castGUID or ("serial:" .. pending.castSerial)
        if pending.completedGUIDs[identity] then return end
        pending.completedGUIDs[identity] = true
        pending.successes = math.min(pending.requested, pending.successes + 1)
        pending.succeeded, pending.castGUID, pending.lastProgress = true, nil, now()
        finishPending()
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        if pending.completedGUIDs[castGUID or ""] then return end
        pending.stopped, pending.castGUID = true, nil
        job.running = false
        ns.status = L.CRAFT_INTERRUPTED
        finishPending()
        ns.Refresh()
    end
end

function ns.OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            CraftAutoBuyDB = CraftAutoBuyDB or {}
            CraftAutoBuyDB.vendorItems = CraftAutoBuyDB.vendorItems or {}
            if CraftAutoBuyDB.autoBuy == nil then CraftAutoBuyDB.autoBuy = true end
            if CraftAutoBuyDB.openAtMerchant == nil then CraftAutoBuyDB.openAtMerchant = false end
            -- Saved language preferences must apply before any persistent UI
            -- label is created. Settings resolves the preference once per login.
            if ns.Settings then ns.Settings.Install()
            else ns.Locale.SetLocale(ns.Locale.GetClientLocale()) end
            ns.status = L.OPEN_PROFESSION_SELECT_RECIPE
            initialized = true
            for id in pairs(defaultVendors) do ns.vendorItems[id] = true end
            for id, enabled in pairs(CraftAutoBuyDB.vendorItems) do ns.vendorItems[id] = enabled end
            if ns.Catalogue then ns.Catalogue.Load() end
            if ns.Stock then ns.Stock.Init() end
            if ns.BankTransferAPI then ns.BankTransferAPI.Init() end
            if ns.BankTransferUI then ns.BankTransferUI.Init() end
            if ns.Bootstrap then ns.Bootstrap.Init() end
            if ns.BootstrapUI then ns.BootstrapUI.Init() end
        elseif not initialized then return end
        if ns.NativeCraft then ns.NativeCraft.Install() end
        if ns.NativeUI then ns.NativeUI.Install() end
        if ns.UI and ns.UI.Install then ns.UI.Install() end
        if ns.StockUI then ns.StockUI.Install() end
        if ... ~= addonName then
            if ns.Settings then ns.Settings.Install() end
            return
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "SKILL_LINES_CHANGED" then
        if ns.Catalogue then ns.Catalogue.Load() end
        if ns.Catalogue and ns.Catalogue.RefreshMetadata then ns.Catalogue.RefreshMetadata() end
        if ns.Bootstrap then ns.Bootstrap.Wake() end
        if ns.API.IsOwnProfession() then scanAttempts = 0; rescanAt = now() + 0.2 end
        if ns.UI and ns.UI.Install then ns.UI.Install() end
        if ns.StockUI then ns.StockUI.Install() end
        ns.Refresh()
    elseif event == "TRADE_SKILL_FAVORITES_CHANGED" then
        -- Favorite changes only update browsing metadata. They neither open a
        -- profession nor schedule another scan/purchase/cast.
        if ns.Catalogue and ns.Catalogue.RefreshMetadata then ns.Catalogue.RefreshMetadata(...) end
        ns.Refresh()
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_DETAILS_UPDATE"
        or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "NEW_RECIPE_LEARNED" then
        if event == "TRADE_SKILL_SHOW" then professionClosed = false end
        local closedSource = event == "TRADE_SKILL_DATA_SOURCE_CHANGED" and professionClosed and not ns.API.GetProfessionKey()
        if (event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED")
            and not ns.job and not closedSource and not ns.catalogueActive and not ns.pendingStart then
            ns.selectedID = nil
        end
        scanAttempts = 0
        rescanAt = now() + 0.2
        if ns.NativeUI then ns.NativeUI.Install() end
        if ns.NativeCraft then ns.NativeCraft.Install() end
        if ns.UI and ns.UI.Install then ns.UI.Install() end
        if ns.StockUI then ns.StockUI.Install() end
    elseif event == "TRADE_SKILL_CLOSE" then
        ns.CancelBankConfirmation()
        professionClosed = true
        if ns.NativeCraft then ns.NativeCraft.Refresh() end
        ns.PausePurchaseContinuation()
        if ns.job then
            ns.Merchant.Stop()
            ns.job.running = false
            ns.status = L.PROJECT_PAUSED_REOPEN
            ns.Refresh()
        end
    elseif event == "MERCHANT_SHOW" then
        if not ns.Merchant.IsOpen() then
            openOnMerchantVisit = CraftAutoBuyDB.openAtMerchant == true
        end
        ns.Merchant.Open()
        local sold = learnVendors()
        ns.Refresh()
        if ns.Settings then ns.Settings.Install() end
        openAtSupplier(sold)
    elseif event == "MERCHANT_CLOSED" then
        ns.CancelBankConfirmation()
        openOnMerchantVisit = false
        if ns.pendingStart and ns.pendingStart.requiresMerchant then
            ns.pendingStart = nil
            ns.status = L.OPEN_MERCHANT_NEEDED
        end
        ns.PausePurchaseContinuation()
        ns.Merchant.Close()
        ns.Refresh()
    elseif event == "BANKFRAME_OPENED" or event == "BANKFRAME_CLOSED" then
        invalidateCatalogue()
        ns.Refresh()
    elseif event == "BAG_UPDATE" then
        -- Personal bank containers are read and published by Stock, only when
        -- their counts change: a bank sort must not rebuild every frame.
        local bag = ...
        bagUpdates = true
        if not (ns.Stock and ns.Stock.IsPersonalBankContainer and ns.Stock.IsPersonalBankContainer(bag)) then
            inventoryChanged = true
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        -- Without any BAG_UPDATE (other clients, synthetic updates) assume the bags changed.
        local refresh = inventoryChanged or not bagUpdates
        bagUpdates, inventoryChanged = false, false
        if refresh then invalidateCatalogue() end
        finishPending()
        ns.Merchant.Tick(now())
        if refresh then ns.Refresh() end
    elseif event == "MERCHANT_UPDATE" or event == "PLAYER_MONEY" then
        ns.Merchant.Tick(now())
        if event == "MERCHANT_UPDATE" and ns.Merchant.IsOpen() then openAtSupplier(learnVendors()) end
        ns.Refresh()
    elseif event == "PLAYER_REGEN_DISABLED" then
        combatEvent = true
        ns.CancelBankConfirmation()
        openOnMerchantVisit = false
        ns.pendingStart = nil
        ns.PausePurchaseContinuation()
        if ns.job then ns.job.running = false end
        ns.Merchant.Stop()
        ns.status = L.PROJECT_PAUSED_COMBAT
        ns.Refresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Display only: a combat pause message is replaced by the resume
        -- instruction at rest. Nothing is bought or crafted without a click.
        combatEvent = false
        ns.Refresh()
    elseif event == "UPDATE_TRADESKILL_CAST_STOPPED" then
        local pending = ns.job and ns.job.pending
        if not ... and pending then
            pending.stopped, pending.settleAt = true, now() + 0.2
            ns.job.running = false
            ns.Refresh()
        end
    elseif event:find("UNIT_SPELLCAST_", 1, true) == 1 then
        castEvent(event, ...)
    end
end

frame:SetScript("OnEvent", function(_, event, ...) ns.OnEvent(event, ...) end)
frame:SetScript("OnUpdate", function()
    local time = now()
    if rescanAt and time >= rescanAt then rescanAt = nil; ns.Scan() end
    if ns.Bootstrap then ns.Bootstrap.Tick(time) end
    if ns.BootstrapUI then ns.BootstrapUI.Update(time) end
    if time - lastSelectionCheck < 0.2 then return end
    lastSelectionCheck = time
    ns.Merchant.Tick(time)
    if not ns.catalogueActive and not ns.pendingStart and not ns.job
        and ns.API.IsOwnProfession() and ns.API.GetProfessionKey() == ns.professionKey then
        selectRecipe(ns.API.SelectedRecipeID())
    end
    -- Station proximity can change without a bag or recipe-list event: compare
    -- the live readiness with the one last displayed, and refresh on a change.
    -- The poll never buys, crafts or approves anything.
    local readiness = readinessState()
    if not readiness then readinessSnapshot = nil
    elseif not sameReadiness(readiness, readinessSnapshot) then ns.Refresh() end
    finishProfessionSwitch()
    finishPending()
    local job = ns.job
    if job and job.awaitingPurchase and not ns.Merchant.IsBusy() then
        job.awaitingPurchase = nil
        ns.Refresh()
        -- End the monetary approval in every case. Only a completed phase keeps
        -- the accepted bag-only choice for the next explicit craft click.
        -- Completed means the bags alone cover the plan: a phase stopped because
        -- the bank now holds the supplies did not deliver them to the bags.
        local readyWithoutPurchase = ns.plan and ns.plan.craftable and not next(ns.plan.purchases)
            and not next(ns.plan.bankWithdrawals or {})
        if job.purchaseOnly or not readyWithoutPurchase then clearBankApproval() else clearSpendingApproval() end
        if job.purchaseOnly then
            local complete = readyWithoutPurchase
            local approvalChanged = ns.Merchant.GetStatus() == L.BANK_OVERRIDE_CHANGED
            -- Supplies from another source can complete the bags of an order that
            -- timed out, or of a phase that sent no order: never announce that
            -- a purchase was received then.
            local unconfirmed = ns.Merchant.HasUnconfirmedOrder and ns.Merchant.HasUnconfirmedOrder()
                or (ns.Merchant.PhaseOrdered and not ns.Merchant.PhaseOrdered())
            ns.job, job = nil, nil
            ns.status = complete and (unconfirmed and L.BUY_ONLY_READY or L.BUY_ONLY_COMPLETE)
                or (approvalChanged and L.BANK_OVERRIDE_CHANGED or L.PURCHASE_CRAFT_INCOMPLETE)
            if complete then ns.Print(ns.status) end
            ns.Refresh()
        elseif readyWithoutPurchase then
            pause(L.PURCHASE_READY_CLICK)
        elseif ns.Merchant.GetStatus() == L.BANK_OVERRIDE_CHANGED then
            pause(L.BANK_OVERRIDE_CHANGED, true)
        else
            pause(L.PURCHASE_CRAFT_INCOMPLETE)
        end
    end
end)

for _, event in ipairs({
    "ADDON_LOADED", "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_DETAILS_UPDATE", "TRADE_SKILL_FAVORITES_CHANGED",
    "NEW_RECIPE_LEARNED", "BAG_UPDATE_DELAYED",
    "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE", "PLAYER_MONEY", "PLAYER_ENTERING_WORLD", "SKILL_LINES_CHANGED",
    "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "UPDATE_TRADESKILL_CAST_STOPPED",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

SLASH_CRAFTAUTOBUY1 = "/cab"
SLASH_CRAFTAUTOBUY2 = "/craftautobuy"
SlashCmdList.CRAFTAUTOBUY = function(message)
    local command, arg = (message or ""):match("^(%S*)%s*(.-)$")
    command = command:lower()
    if command == "stop" then ns.Cancel()
    elseif command == "scan" then ns.Scan()
    elseif command == "config" or command == "options" then
        if ns.Settings then ns.Settings.Open() end
    elseif command == "debug" then
        local addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")
        ns.Print(L.DEBUG_ADDON_VERSION:format(addonVersion or "?"))
        local version, build, _, interface = GetBuildInfo()
        ns.Print(L.DEBUG_CLIENT:format(tostring(version), tostring(build), tostring(interface)))
        -- Report what the page shows: resting statuses are derived from live state.
        local shown = ns.UI and ns.UI.StatusText and ns.UI.StatusText()
        ns.Print(L.DEBUG_RECIPE:format(tostring(ns.selectedID), tostring(ns.professionKey), tostring(shown or ns.status)))
        local key = ns.API.GetProfessionKey() or ns.professionKey
        local parent = ns.API.GetProfessionParentKey and ns.API.GetProfessionParentKey(key) or key
        local function count(entries)
            local total = 0
            for _ in pairs(entries or {}) do total = total + 1 end
            return total
        end
        local cached = ns.Catalogue and ns.Catalogue.GetRecipes(key)
        -- With no native profession open, report the whole saved catalogue.
        -- Counting GetRecipes(nil) hides successful background discovery.
        if not key and ns.Catalogue and ns.API.GetProfessions then
            cached = {}
            for _, profession in ipairs(ns.API.GetProfessions()) do
                for id, recipe in pairs(ns.Catalogue.GetRecipes(profession.key)) do cached[id] = recipe end
            end
        end
        local visible = ns.Catalogue and ns.Catalogue.Rows and #ns.Catalogue.Rows() or 0
        ns.Print(L.DEBUG_CATALOGUE:format(tostring(key), tostring(parent), count(ns.recipes), count(cached), visible))
        if ns.Bootstrap then
            local status = ns.Bootstrap.StatusText()
            if status then ns.Print(status) end
            local discovery = ns.Bootstrap.GetState()
            if status and discovery.lastReason then
                local progress = string.format("%s (%d/%d)", tostring(discovery.professionKey),
                    discovery.progress or 0, discovery.recipeTotal or 0)
                ns.Print(L.DEBUG_RECIPE:format(tostring(discovery.recipeID), progress, discovery.lastReason))
            end
        end
        if ns.scanError then ns.Print(ns.scanError) end
    elseif command == "vendor" and tonumber(arg) then
        local id = math.floor(tonumber(arg))
        if id > 0 then
            ns.vendorItems[id] = not ns.vendorItems[id] or nil
            CraftAutoBuyDB.vendorItems[id] = ns.vendorItems[id] or false
            ns.Print((ns.vendorItems[id] and L.VENDOR_ITEM_ENABLED or L.VENDOR_ITEM_DISABLED):format(ns.ItemName(id)))
            invalidateCatalogue()
            ns.Refresh()
        end
    else
        if ns.Settings then ns.Settings.Open() end
    end
end
