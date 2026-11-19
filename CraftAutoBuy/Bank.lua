local _, ns = ...
local L = ns.L
local Bank = {}
ns.Bank = Bank

local function count(value)
    if (issecretvalue and issecretvalue(value)) or type(value) ~= "number"
        or value ~= value or value < 0 or value == math.huge then return 0 end
    return math.floor(value)
end

-- Keep the two sources separate all the way through planning. Combining them
-- here would make inaccessible bank ingredients look ready for a real craft.
function Bank.Snapshot(recipes)
    if type(ns.API.InventoryWithBank) ~= "function" then
        return ns.API.Inventory(recipes), {}
    end
    local combined, bankCounts = ns.API.InventoryWithBank(recipes)
    if type(combined) ~= "table" or type(bankCounts) ~= "table" then
        return ns.API.Inventory(recipes), {}
    end
    local bags, bank = {}, {}
    for itemID, value in pairs(combined) do
        local total = count(value)
        local stored = math.min(total, count(bankCounts[itemID]))
        bags[itemID] = total - stored
        if stored > 0 then bank[itemID] = stored end
    end
    return bags, bank
end

function Bank.Message(plan)
    local entries = {}
    for itemID, value in pairs(plan and plan.bankWithdrawals or {}) do
        local quantity = count(value)
        if quantity > 0 then
            local name = ns.ItemName and ns.ItemName(itemID) or L.ITEM_FALLBACK:format(tostring(itemID))
            entries[#entries + 1] = {id = itemID, name = name, quantity = quantity}
        end
    end
    if #entries == 0 then return nil end
    table.sort(entries, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = L.BANK_COMPONENT:format(entry.quantity, entry.name)
    end
    local message = L.BANK_RETRIEVE:format(table.concat(parts, ", "))
    if ns.Stock and ns.Stock.IsBankUnverified and ns.Stock.IsBankUnverified() then
        -- At an open bank the reading is still in progress: do not ask the
        -- player to reopen the bank they are standing at.
        local open = ns.Stock.IsBankOpen and ns.Stock.IsBankOpen()
        message = (open and L.STOCK_BANK_LOADING or L.BANK_UNVERIFIED_NOTICE) .. "\n" .. message
    end
    return message
end

-- Buying the missing vendor supplies does not require withdrawing the other
-- ingredients first. Keep this basket bank-aware: banked supplies must not be
-- bought again merely because the character is currently at a merchant.
function Bank.Purchase(recipes, plan, preferBank)
    if not plan or plan.craftable ~= true or not next(plan.purchases or {})
        or not next(plan.bankWithdrawals or {}) then return nil end
    local job, recipe = ns.job, recipes and recipes[plan.recipeID]
    preferBank = preferBank or (job and job.purchaseOnly and job.bankPurchaseOnly
        and job.recipeID == plan.recipeID and job.remaining == plan.crafts
        and (job.recipes == recipes or (recipe and count(recipe.professionKey) > 0
            and recipe.professionKey == job.professionKey)))
    -- Keep the existing "continue without bank" choice when the bank only
    -- holds vendor supplies and this seller can replace some of them. Raw
    -- materials and stored intermediates still use the bank-aware prepurchase:
    -- choosing another route must not silently remake those ingredients.
    local vendorWithdrawals = true
    for itemID, quantity in pairs(plan.bankWithdrawals) do
        if count(quantity) > 0 and not (ns.vendorItems and ns.vendorItems[itemID]) then
            vendorWithdrawals = false
            break
        end
    end
    if vendorWithdrawals and not preferBank then
        local alternative, alternativeQuote, allowed = Bank.Alternative(recipes, plan)
        if allowed then
            local basket = alternativeQuote and alternativeQuote.basket or alternative and alternative.purchases or {}
            for itemID, quantity in pairs(basket) do
                if count(quantity) > 0 and count(plan.bankWithdrawals[itemID]) > 0 then return nil end
            end
        end
    end
    local quote = (ns.PurchaseQuote or ns.Merchant.Quote)(plan.purchases)
    if not CraftAutoBuyDB or CraftAutoBuyDB.autoBuy ~= true then
        return plan, quote, false, L.CATALOG_AUTO_BUY_DISABLED
    end
    if quote.unconfirmed and ns.Merchant.HasUnconfirmedOrder and ns.Merchant.HasUnconfirmedOrder() then
        return plan, quote, false, L.PURCHASE_STILL_UNCONFIRMED
    end
    if not ns.Merchant.IsOpen() then return plan, quote, false, L.OPEN_MERCHANT_NEEDED end
    return plan, quote, quote.canBuy == true, ns.Merchant.QuoteReason(quote)
end

-- An alternative is a new plan for this quantity only, never a preference or
-- a modification of the bank-aware projection displayed beside ingredients.
function Bank.Alternative(recipes, plan)
    if not plan then return nil, nil, false, L.PLAN_UNAVAILABLE end
    local alternative = ns.Planner.Plan(recipes, ns.API.Inventory(recipes), ns.vendorItems or {},
        plan.recipeID, plan.crafts)
    if not alternative.craftable then
        return alternative, nil, false, Bank.Message(plan) or L.PLAN_UNAVAILABLE
    end
    local quote = (ns.PurchaseQuote or ns.Merchant.Quote)(alternative.purchases)
    if not next(alternative.purchases or {}) then return alternative, quote, true end
    if not CraftAutoBuyDB or CraftAutoBuyDB.autoBuy ~= true then
        return alternative, quote, false, L.CATALOG_AUTO_BUY_DISABLED
    end
    -- A timed-out order blocks every merchant: say so even with the vendor closed.
    if quote.unconfirmed and ns.Merchant.HasUnconfirmedOrder and ns.Merchant.HasUnconfirmedOrder() then
        return alternative, quote, false, L.PURCHASE_STILL_UNCONFIRMED
    end
    if not ns.Merchant.IsOpen() then return alternative, quote, false, L.OPEN_MERCHANT_NEEDED end
    return alternative, quote, quote.canBuy == true, ns.Merchant.QuoteReason(quote)
end

local POPUP = "CRAFTAUTOBUY_IGNORE_BANK"
local pendingConfirmation

local function purchaseContents(quote)
    local entries = {}
    for itemID, quantity in pairs(quote.purchaseQuantities or {}) do
        quantity = count(quantity)
        if quantity > 0 then
            local name = ns.ItemName and ns.ItemName(itemID) or L.ITEM_FALLBACK:format(tostring(itemID))
            entries[#entries + 1] = {id = itemID, name = name, quantity = quantity}
        end
    end
    table.sort(entries, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    local parts = {}
    for _, entry in ipairs(entries) do parts[#parts + 1] = L.BANK_COMPONENT:format(entry.quantity, entry.name) end
    return table.concat(parts, ", ")
end

local function finishConfirmation(data, accepted)
    if not data or data.finished then return end
    data.finished = true
    if pendingConfirmation == data then pendingConfirmation = nil end
    local callback
    if accepted == "complement" then callback = data.onComplement
    elseif accepted then callback = data.onAccept else callback = data.onCancel end
    if callback then callback() end
end

function Bank.CancelConfirmation()
    local data = pendingConfirmation
    if not data then return end
    finishConfirmation(data, false)
    if StaticPopup_Hide then StaticPopup_Hide(POPUP, data) end
end

function Bank.RequestConfirmation(message, quote, onAccept, onCancel, complement)
    Bank.CancelConfirmation()
    if not StaticPopupDialogs or not StaticPopup_Show or not ns.UI or not ns.UI.CostSummary then
        if onCancel then onCancel() end
        return false
    end
    local choices = type(complement) == "table" and complement.quote and type(complement.onAccept) == "function"
    StaticPopupDialogs[POPUP] = {
        text = "%s",
        button1 = choices and L.BANK_BUY_WITHOUT or L.BANK_OVERRIDE_CONFIRM,
        button2 = L.CANCEL,
        button3 = choices and L.BANK_BUY_COMPLEMENT or nil,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        wideText = choices and true or nil,
        preferredIndex = 3,
        OnAccept = function(_, data) finishConfirmation(data, true) end,
        OnCancel = function(_, data) finishConfirmation(data, false) end,
        OnAlt = choices and function(_, data) finishConfirmation(data, "complement") end or nil,
        OnHide = function(_, data) finishConfirmation(data, false) end,
    }
    local data = {onAccept = onAccept, onCancel = onCancel,
        onComplement = choices and complement.onAccept or nil}
    pendingConfirmation = data
    local text
    if choices then
        text = L.BANK_OVERRIDE_TITLE .. "\n\n" .. L.BANK_BUY_CHOICE_PROMPT
            .. "\n\n" .. (message or "")
            .. "\n\n" .. L.BANK_BUY_WITHOUT .. "\n" .. L.BANK_BUY_WITHOUT_HELP
            .. "\n" .. purchaseContents(quote) .. "\n" .. ns.UI.CostSummary(quote)
            .. "\n\n" .. L.BANK_BUY_COMPLEMENT .. "\n" .. L.BANK_BUY_COMPLEMENT_HELP
            .. "\n" .. purchaseContents(complement.quote) .. "\n" .. ns.UI.CostSummary(complement.quote)
    else
        text = L.BANK_OVERRIDE_TITLE .. "\n\n"
            .. L.BANK_OVERRIDE_PROMPT:format(message or "", ns.UI.CostSummary(quote))
    end
    local dialog = StaticPopup_Show(POPUP, text, nil, data)
    if not dialog then finishConfirmation(data, false); return false end
    return true
end
