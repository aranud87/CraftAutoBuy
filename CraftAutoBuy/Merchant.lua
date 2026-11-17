local _, ns = ...
local L = ns.L
local Merchant = {}
ns.Merchant = Merchant

-- Forever still uses the global BuyMerchantItem(index, itemQuantity).
-- C_MerchantFrame.GetItemInfo supplies price per stackCount objects.
-- Blizzard's stack splitter passes OBJECTS, in multiples of stackCount.
-- Source: Gethe/wow-ui-source, forever branch, MerchantFrame.lua's
-- MerchantItemButton_BuyMultipleStacks and StackSplitFrame.lua's minSplit.
Merchant.AUTO_LEARN_MAX_UNIT_PRICE = 10000 -- 1 gold; learning is also filtered by recipe reagents.
local ACK_TIMEOUT, BUY_INTERVAL = 5, 0.20
local opened, active = false, false
local queue, cursor, pending = {}, 1, nil
local nextBuyAt, status = 0, L.OPEN_MERCHANT_PURCHASE
local approvalBudget
-- The quote of the click that armed this phase: a ceiling in objects and copper
-- even without a bank approval. phaseGuard is the caller's check run before
-- each new order (Core: bank supplies reported after the click).
local phaseBudget, phaseGuard
-- Orders actually sent by this phase: a phase whose needs were covered by
-- supplies from another source sent none and must not announce a purchase.
local phaseOrders = 0
local purchaseUnconfirmed = false
local unconfirmedOrder

local function clock()
    return GetTime and GetTime() or 0
end

local function notify(message, printMessage)
    status = message
    if printMessage and ns.Print then ns.Print(message) end
    if ns.Refresh then ns.Refresh() end
end

local function itemCount(itemID)
    if ns.API and ns.API.CountItem then return ns.API.CountItem(itemID) end
    if C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(itemID, false, false, false, false)
    end
    return nil
end

local function itemInfo(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        return C_MerchantFrame.GetItemInfo(index)
    end
    if GetMerchantItemInfo then
        local name, texture, price, stackCount, numAvailable, isPurchasable, isUsable, hasExtendedCost = GetMerchantItemInfo(index)
        if name then
            return { name = name, texture = texture, price = price, stackCount = stackCount,
                numAvailable = numAvailable, isPurchasable = isPurchasable,
                isUsable = isUsable, hasExtendedCost = hasExtendedCost }
        end
    end
end

local function itemIDAt(index)
    if GetMerchantItemID then return GetMerchantItemID(index) end
    local link = GetMerchantItemLink and GetMerchantItemLink(index)
    return link and tonumber(link:match("item:(%d+)"))
end

local function finiteNumber(value)
    return type(value) == "number" and not (issecretvalue and issecretvalue(value))
        and value == value and value > -math.huge and value < math.huge
end

local function reconcileUnconfirmedOrder()
    if not unconfirmedOrder then return end
    local count = itemCount(unconfirmedOrder.itemID)
    if finiteNumber(count) and count >= unconfirmedOrder.expected then
        unconfirmedOrder = nil
    end
    -- Elapsed time and reopening are not proof that the server rejected an
    -- order. Only observed supplies reconcile it; the current visit stays
    -- disarmed even after receipt until the player explicitly reopens.
end

local function copyApproval(approval)
    if type(approval) ~= "table" or not finiteNumber(approval.totalCost) or approval.totalCost < 0
        or approval.totalCost ~= math.floor(approval.totalCost) or type(approval.purchaseQuantities) ~= "table" then return nil end
    local copy = {totalCost = approval.totalCost, purchaseQuantities = {}, spent = 0, purchased = {}}
    for itemID, quantity in pairs(approval.purchaseQuantities) do
        if not finiteNumber(itemID) or itemID < 1 or itemID ~= math.floor(itemID)
            or not finiteNumber(quantity) or quantity < 0 or quantity ~= math.floor(quantity) then return nil end
        copy.purchaseQuantities[itemID] = quantity
    end
    return copy
end

local function withinApproval(approval, quote)
    if not approval then return true end
    if quote.totalCost > approval.totalCost - approval.spent then return false end
    for itemID, quantity in pairs(quote.purchaseQuantities) do
        if quantity > (approval.purchaseQuantities[itemID] or 0) - (approval.purchased[itemID] or 0) then return false end
    end
    return true
end

local function reserve(budget, itemID, quantity, price)
    if not budget then return end
    budget.spent = budget.spent + price
    budget.purchased[itemID] = (budget.purchased[itemID] or 0) + quantity
end

local function pricedInfo(info)
    return info and not info.hasExtendedCost
        and not info.currencyID and not info.spellID
        and finiteNumber(info.price) and info.price > 0 and info.price == math.floor(info.price)
        and finiteNumber(info.stackCount) and info.stackCount >= 1
        and info.stackCount == math.floor(info.stackCount)
end

local function validInfo(info)
    return pricedInfo(info) and info.isPurchasable == true
        and finiteNumber(info.numAvailable) and (info.numAvailable == -1 or info.numAvailable > 0)
end

local function priceCache(create)
    if type(CraftAutoBuyDB) ~= "table" then
        if not create then return {} end
        CraftAutoBuyDB = {}
    end
    if type(CraftAutoBuyDB.vendorPrices) ~= "table" then
        if not create then return {} end
        CraftAutoBuyDB.vendorPrices = {}
    end
    return CraftAutoBuyDB.vendorPrices
end

local function catalog()
    local result = {}
    if not opened or not GetMerchantNumItems then return result end
    for index = 1, GetMerchantNumItems() do
        local itemID, info = itemIDAt(index), itemInfo(index)
        if itemID and pricedInfo(info) then
            local previous = result[itemID]
            local usable, previousUsable = validInfo(info), previous and validInfo(previous.info)
            if not previous or (usable and not previousUsable)
                or (usable == previousUsable and info.price / info.stackCount < previous.info.price / previous.info.stackCount) then
                result[itemID] = { index = index, info = info }
            end
        end
    end
    return result
end

-- true describes a known PNJ source with no complete merchant inventory open.
-- 'here' and false describe this vendor's actual offer; a number is its stock.
-- Reading stock must not learn vendors, cache prices, or start a purchase.
function Merchant.GetReagentSourceStock(itemID)
    if not ns.vendorItems or ns.vendorItems[itemID] ~= true then return nil end
    if opened and GetMerchantNumItems then
        local count = GetMerchantNumItems()
        local complete = finiteNumber(count) and count > 0 and count == math.floor(count)
        for index = 1, complete and count or 0 do
            local offeredID = itemIDAt(index)
            if not finiteNumber(offeredID) or offeredID < 1 or offeredID ~= math.floor(offeredID) then complete = false end
            if offeredID == itemID then
                local info = itemInfo(index)
                if info and finiteNumber(info.numAvailable) and info.numAvailable >= 0 then
                    return math.floor(info.numAvailable)
                end
                return "here"
            end
        end
        if complete then return false end
    end
    return true
end

function Merchant.GetLastVendorName(itemID)
    local entry = priceCache(false)[itemID]
    local name = type(entry) == "table" and entry.vendorName
    if type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then return name end
end

local function relevantPriceItems()
    local items = {}
    for id, enabled in pairs(ns.vendorItems or {}) do if enabled then items[id] = true end end
    local function collect(recipes)
        for _, recipe in pairs(recipes or {}) do
            for _, reagent in ipairs(recipe.reagents or {}) do
                if reagent.itemID then items[reagent.itemID] = true end
            end
        end
    end
    collect(ns.recipes)
    if ns.ActiveRecipes then collect(ns.ActiveRecipes()) end
    local complete = false
    if ns.Catalogue and ns.API and ns.API.GetProfessions then
        local professions, known = ns.API.GetProfessions()
        complete = known == true
        for _, profession in ipairs(professions or {}) do
            collect(ns.Catalogue.GetRecipes(profession.key))
        end
    end
    return items, complete
end

local function rememberPrices(available)
    local cache = priceCache(true)
    local relevant, complete = relevantPriceItems()
    -- Do not keep a history of every weapon and piece of armour encountered.
    -- Prune old broad caches only when the profession inventory is authoritative.
    if complete then
        for id in pairs(cache) do if not relevant[id] then cache[id] = nil end end
    end
    -- Use the actual merchant unit, as Blizzard's merchant title does. This is
    -- an observation of a named seller, never a guess based on its profession.
    local vendorName = UnitName and UnitName("npc")
    if type(vendorName) ~= "string" or vendorName == "" or (issecretvalue and issecretvalue(vendorName)) then
        vendorName = nil
    end
    for itemID, entry in pairs(available) do
        if relevant[itemID] then
            local info, previous = entry.info, cache[itemID]
            local name = vendorName or Merchant.GetLastVendorName(itemID)
            if type(previous) ~= "table" or previous.price ~= info.price
                or previous.stackCount ~= info.stackCount or previous.vendorName ~= name then
                -- Copy numeric values, never the merchant's mutable catalog record.
                cache[itemID] = {price = info.price, stackCount = info.stackCount,
                    unitPrice = info.price / info.stackCount, vendorName = name}
            end
        end
    end
end

-- A price away from a vendor is only the last observed estimate. The caller
-- must label it as such. Purchases always require the complete LIVE quote.
local function quoteBasket(purchases, available)
    local money = GetMoney and GetMoney()
    local moneyKnown = finiteNumber(money) and money >= 0
    local result = {
        totalCost = 0, complete = true, live = true,
        money = moneyKnown and math.floor(money) or 0,
        affordable = false, shortfall = 0, canBuy = false,
        missingPrices = {}, unavailable = {}, insufficientStock = {},
        purchaseQuantities = {}, surplus = {}, hasSurplus = false,
        unconfirmed = purchaseUnconfirmed and type(purchases) == "table" and next(purchases) ~= nil or false,
    }
    if type(purchases) ~= "table" then
        result.invalid = true
        result.complete, result.live = false, false
        return result
    end
    available = available or catalog()
    local cache = priceCache(false)
    for itemID, quantity in pairs(purchases) do
        if not finiteNumber(itemID) or itemID < 1 or itemID ~= math.floor(itemID)
            or not finiteNumber(quantity) or quantity < 0 or quantity ~= math.floor(quantity) then
            result.invalid = true
            result.complete, result.live = false, false
        elseif quantity > 0 then
            local entry = available[itemID]
            local price = entry and entry.info or cache[itemID]
            if not entry then result.live = false end
            if not entry or not validInfo(entry.info) then result.unavailable[itemID] = true end
            if not pricedInfo(price) then
                result.missingPrices[itemID] = true
                result.complete = false
            else
                local bundles = math.ceil(quantity / price.stackCount)
                local purchased = bundles * price.stackCount
                result.purchaseQuantities[itemID] = purchased
                result.totalCost = result.totalCost + price.price * bundles
                if purchased > quantity then
                    result.surplus[itemID] = purchased - quantity
                    result.hasSurplus = true
                end
                if entry and finiteNumber(entry.info.numAvailable) and entry.info.numAvailable >= 0
                    and entry.info.numAvailable < purchased then result.insufficientStock[itemID] = true end
            end
        end
    end
    if not finiteNumber(result.totalCost) then
        result.totalCost, result.complete, result.invalid = 0, false, true
    end
    result.affordable = result.complete and moneyKnown and result.totalCost <= result.money
    result.shortfall = math.max(0, result.totalCost - result.money)
    result.canBuy = opened and not result.unconfirmed and not result.invalid and result.complete and result.live and result.affordable
        and not next(result.unavailable) and not next(result.insufficientStock)
    return result
end

function Merchant.Quote(purchases)
    return quoteBasket(purchases)
end

function Merchant.QuoteReason(quote)
    if quote and quote.canBuy then return nil end
    if not opened then
        -- A timed-out order blocks every merchant until it is observed in bags,
        -- so a closed vendor must not hide it behind "open a merchant".
        if type(quote) == "table" and quote.unconfirmed and unconfirmedOrder then return L.PURCHASE_STILL_UNCONFIRMED end
        return L.MERCHANT_IS_CLOSED
    end
    if type(quote) ~= "table" then return L.INVALID_SHOPPING_LIST end
    if quote.invalid then return L.INVALID_SHOPPING_LIST end
    if quote.unconfirmed then
        return unconfirmedOrder and L.PURCHASE_STILL_UNCONFIRMED or L.PURCHASE_NOT_CONFIRMED
    end
    if not quote.live or next(quote.unavailable) then return L.MERCHANT_REAGENTS_UNAVAILABLE end
    if not quote.complete then return L.PURCHASE_PRICES_UNKNOWN end
    if next(quote.insufficientStock) then return L.MERCHANT_STOCK_INSUFFICIENT end
    if not quote.affordable then return L.PURCHASE_MONEY_INSUFFICIENT end
end

-- Only discover unlimited, ordinary, inexpensive items. The caller must
-- intersect this set with actual recipe reagents before storing it.
function Merchant.Scan()
    local vendors = {}
    local available = catalog()
    if opened then rememberPrices(available) end
    for itemID, entry in pairs(available) do
        local info = entry.info
        if validInfo(info) and info.numAvailable == -1 and info.price / info.stackCount <= Merchant.AUTO_LEARN_MAX_UNIT_PRICE then
            vendors[itemID] = true
        end
    end
    return vendors
end

-- Returns nil when item data are not cached. In that case the game checks
-- capacity, and an unacknowledged purchase stops the queue without retrying.
local function bagCapacity(itemID)
    if not (C_Container and C_Container.GetContainerNumFreeSlots
        and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo
        and C_Item and C_Item.GetItemInfo) then return nil end
    local stackSize = select(8, C_Item.GetItemInfo(itemID))
    if not stackSize or stackSize < 1 then return nil end
    local family = C_Item.GetItemFamily and C_Item.GetItemFamily(itemID)
    local capacity = 0
    for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
        local slots, bagFamily = C_Container.GetContainerNumFreeSlots(bag)
        if slots and bagFamily then
            local compatible = bagFamily == 0
                or (family and bit and bit.band and bit.band(family, bagFamily) ~= 0)
            if compatible then capacity = capacity + slots * stackSize end
        end
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and not info.isLocked then
                capacity = capacity + math.max(0, stackSize - info.stackCount)
            end
        end
    end
    return capacity
end

local function halt(message)
    active, queue, cursor = false, {}, 1
    notify(message, true)
end

function Merchant.IsOpen() return opened end
function Merchant.IsBusy() return active or pending ~= nil end
-- One sent order still awaits its acknowledgment (it may be preserved after Close).
function Merchant.HasPending() return pending ~= nil end
-- A timed-out order that was never reconciled by the expected bag count.
function Merchant.HasUnconfirmedOrder() return unconfirmedOrder ~= nil end
-- Whether the last armed phase sent at least one order.
function Merchant.PhaseOrdered() return phaseOrders > 0 end
function Merchant.GetStatus() return status end

function Merchant.Open()
    if opened then return end -- duplicate MERCHANT_SHOW must not reset purchases
    opened, active = true, false
    reconcileUnconfirmedOrder()
    purchaseUnconfirmed = unconfirmedOrder ~= nil
    queue, cursor, nextBuyAt = {}, 1, clock()
    rememberPrices(catalog())
    notify(pending and L.VERIFY_LAST_PURCHASE
        or (purchaseUnconfirmed and L.PURCHASE_STILL_UNCONFIRMED or L.MERCHANT_OPEN))
end

function Merchant.Close()
    opened, active, queue, cursor = false, false, {}, 1
    -- Preserve one in-flight acknowledgment so closing/reopening cannot buy
    -- the same objects again while the first transaction reaches the bags.
    notify(pending and L.LAST_PURCHASE_PENDING or L.MERCHANT_CLOSED)
end

function Merchant.Stop()
    active, queue, cursor = false, {}, 1
    notify(pending and L.STOP_REQUESTED_PENDING_PURCHASE or L.PURCHASES_STOPPED)
end

-- Only explicit creation actions start a fresh deficit. Passive events never
-- call Start, and a deliberate retry cannot replace an unacknowledged order.
-- guard (optional) is called before each new order; false stops the queue.
function Merchant.Start(purchases, approval, guard)
    if not opened then return false, L.MERCHANT_IS_CLOSED end
    if pending or active then return false, L.PURCHASES_ALREADY_HANDLED end
    if guard ~= nil and type(guard) ~= "function" then return false, L.INVALID_SHOPPING_LIST end
    local quote = Merchant.Quote(purchases)
    local approved = approval ~= nil and copyApproval(approval) or nil
    if (approval ~= nil and not approved) or not withinApproval(approved, quote) then
        return false, L.BANK_OVERRIDE_CHANGED
    end
    if not quote.canBuy then return false, Merchant.QuoteReason(quote) end
    -- The bag targets below follow later receipts, but a bag decrease after the
    -- click (sale, use, a late bank deposit) must not enlarge the basket shown.
    local shown = copyApproval(quote)
    if not shown then return false, L.INVALID_SHOPPING_LIST end
    local prepared = {}
    for itemID, quantity in pairs(purchases) do
        if quantity > 0 then
            local count = itemCount(itemID)
            if not finiteNumber(count) or count < 0 then return false, L.INVENTORY_UNAVAILABLE end
            prepared[#prepared + 1] = {
                itemID = itemID,
                requiredTarget = count + quantity,
            }
        end
    end
    table.sort(prepared, function(a, b) return a.itemID < b.itemID end)
    queue, cursor = prepared, 1
    approvalBudget, phaseBudget, phaseGuard = approved, shown, guard
    phaseOrders = 0
    active = #queue > 0
    if not active then
        notify(L.NO_PURCHASES_NEEDED)
    else
        notify(L.PURCHASING_REAGENTS)
    end
    return true
end

function Merchant.Tick(now)
    now = now or clock()
    reconcileUnconfirmedOrder()
    if pending then
        local count = itemCount(pending.itemID)
        if type(count) == "number" and count >= pending.expected then
            pending = nil
            nextBuyAt = now + BUY_INTERVAL
            if not active then
                notify(opened and L.LAST_PURCHASE_CONFIRMED_REOPEN or L.LAST_PURCHASE_CONFIRMED)
            end
        elseif now >= pending.deadline then
            unconfirmedOrder = pending
            pending = nil
            purchaseUnconfirmed = true
            halt(L.PURCHASE_STILL_UNCONFIRMED)
        end
        return
    end
    if not opened or not active or now < nextBuyAt then return end
    if InCombatLockdown and InCombatLockdown() then halt(L.PURCHASES_STOPPED_COMBAT); return end
    -- A replacement merchant UI may hide Blizzard's frame while keeping the
    -- interaction open. MERCHANT_CLOSED, not frame visibility, ends the visit.
    -- Revalidate the whole remaining basket before every transaction. Changes
    -- to prices, cash, stock, or inventory may invalidate an earlier quote.
    local remainingBasket = {}
    for index = cursor, #queue do
        local request = queue[index]
        local count = itemCount(request.itemID)
        if not finiteNumber(count) or count < 0 then halt(L.INVENTORY_UNAVAILABLE); return end
        local needed = math.max(0, request.requiredTarget - count)
        if needed > 0 then remainingBasket[request.itemID] = needed end
    end
    -- One fresh catalog snapshot prices the whole basket and the transaction
    -- below consistently, including any changed merchant bundle sizes.
    local available = catalog()
    local quote = quoteBasket(remainingBasket, available)
    if not withinApproval(approvalBudget, quote) or not withinApproval(phaseBudget, quote) then
        halt(L.BANK_OVERRIDE_CHANGED); return
    end
    if not quote.canBuy then halt(Merchant.QuoteReason(quote)); return end
    while queue[cursor] do
        local request = queue[cursor]
        local count = itemCount(request.itemID)
        if type(count) ~= "number" then halt(L.INVENTORY_UNAVAILABLE); return end
        local remaining = request.requiredTarget - count
        if remaining <= 0 then
            cursor = cursor + 1
        else
            local entry = available[request.itemID]
            if not entry or not validInfo(entry.info) then halt(L.MERCHANT_REAGENT_SOLD_OUT); return end
            local info, index = entry.info, entry.index
            local rounded = quote.purchaseQuantities[request.itemID]
            if not rounded or rounded <= 0 then halt(L.INVALID_SHOPPING_LIST); return end
            local maxStack = GetMerchantItemMaxStack and GetMerchantItemMaxStack(index) or info.stackCount
            if not finiteNumber(maxStack) or maxStack < 1 then maxStack = info.stackCount end
            local quantity = math.min(rounded, math.max(info.stackCount, maxStack))
            if info.numAvailable > 0 then quantity = math.min(quantity, info.numAvailable) end
            quantity = math.floor(quantity / info.stackCount) * info.stackCount
            if quantity <= 0 then halt(L.MERCHANT_STOCK_INSUFFICIENT); return end
            local price = info.price * quantity / info.stackCount
            -- Match the native merchant UI: only an explicit false is a veto.
            -- An absent answer is not evidence of insufficient funds; the live
            -- basket and this transaction's copper price are checked separately.
            if not GetMoney or GetMoney() < price or (CanAffordMerchantItem and CanAffordMerchantItem(index) == false) then
                halt(L.PURCHASE_MONEY_INSUFFICIENT)
                return
            end
            local capacity = bagCapacity(request.itemID)
            if capacity and capacity < quantity then
                halt(L.PURCHASE_BAG_SPACE_INSUFFICIENT)
                return
            end
            if not BuyMerchantItem then halt(L.PURCHASE_API_UNAVAILABLE); return end
            -- Last check before this order: what the caller learned since the
            -- click (bank supplies) may require its choice again. A refusal or an
            -- error stops the queue; only a new click may ask that question.
            if phaseGuard then
                local guardedPhase = phaseBudget
                local guardOK, allowed, reason = pcall(phaseGuard, remainingBasket, quote)
                -- A callback may synchronously close/cancel/rearm the phase.
                -- Its old transaction must not escape that cancellation.
                if not opened or not active or pending or phaseBudget ~= guardedPhase then return end
                if not guardOK or not allowed then
                    halt(guardOK and reason or L.BANK_OVERRIDE_CHANGED); return
                end
            end
            pending = { itemID = request.itemID, expected = count + quantity, deadline = now + ACK_TIMEOUT }
            -- Reserve submitted purchases immediately; an ambiguous client
            -- failure keeps the ACK pending and must never free a budget.
            reserve(approvalBudget, request.itemID, quantity, price)
            reserve(phaseBudget, request.itemID, quantity, price)
            phaseOrders = phaseOrders + 1
            local ok, result = pcall(BuyMerchantItem, index, quantity)
            if not ok or result == false then
                -- Keep the pending acknowledgment even after an error: the
                -- client may already have submitted part of the operation.
                halt(L.PURCHASE_REFUSED)
            end
            return
        end
    end
    active = false
    notify(phaseOrders > 0 and L.REAGENTS_PURCHASED or L.NO_PURCHASES_NEEDED, true)
end
