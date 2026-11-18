local addonName, ns = ...
local Stock = {SCHEMA = 1}
ns.Stock = Stock

local frame, bankOpen, loadedDB, snapshot = nil, false, nil, nil
local pendingRefresh, publishQueued
local publishPending = false
-- A personal-bank notification arrived and no complete read has followed it.
local changePending = false
-- This visit has not completed a read yet; readFailed records that a read was
-- attempted and returned incomplete data. A visit closed before any attempt
-- changed nothing and keeps the previous complete reading.
local firstReadPending, readFailed = false, false
local loggingOut = false
-- Time of the last close in this Lua session (true when the client has no clock).
-- Late transfer replies land shortly after a close; notifications long after
-- it, or after a reload, are not treated as unread transfers by themselves.
local closedAt
local LATE_NOTIFICATION_WINDOW = 10
local personalContainers = {}
-- Containers this visit has already read with slots. A container that held
-- items and reports no slots afterwards had its bag removed in front of CAB;
-- before that, an emptied bank-bag slot and a container still loading look alike.
local loadedThisVisit = {}
local closingRead = false
-- A rejected read of this visit raised the saved evidence from the client count.
local raisedThisVisit = false
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local normalized = ns.Locale.SearchText

local function secret(value) return issecretvalue and issecretvalue(value) end
local function integer(value, minimum)
    return type(value) == "number" and not secret(value) and value == value
        and value >= (minimum or 0) and value < math.huge and value == math.floor(value)
end
local function call(callback, ...)
    if type(callback) ~= "function" then return false end
    return pcall(callback, ...)
end
local function text(value)
    return type(value) == "string" and not secret(value) and value ~= "" and value or nil
end
local function guid()
    local ok, value = call(UnitGUID, "player")
    return ok and text(value) or nil
end

local function ensureLoaded()
    if type(CraftAutoBuyDB) ~= "table" then CraftAutoBuyDB = {} end
    local character = guid()
    if loadedDB == CraftAutoBuyDB and snapshot == CraftAutoBuyDB.stock
        and (not character or snapshot.character == character) then return end
    local saved = CraftAutoBuyDB.stock
    local valid = type(saved) == "table" and saved.schema == Stock.SCHEMA
        and type(saved.counts) == "table" and (not character or not saved.character or saved.character == character)
    snapshot = {schema = Stock.SCHEMA, character = character or (valid and saved.character or nil),
        known = valid and saved.known == true or false, complete = valid and saved.complete == true or false,
        unverified = valid and saved.unverified == true or false,
        counts = {}, knownItems = {}}
    if snapshot.unverified then snapshot.complete = false end
    if valid then
        local invalidCounts = {}
        for id, count in pairs(saved.counts) do
            if integer(id, 1) and integer(count) then
                if count > 0 then snapshot.counts[id] = count end
                if not snapshot.unverified then snapshot.knownItems[id] = true end
            else
                snapshot.complete = false
                invalidCounts[id] = true
            end
        end
        for id, known in pairs(type(saved.knownItems) == "table" and saved.knownItems or {}) do
            -- A former knowledge flag cannot turn an unreadable quantity into
            -- a confirmed zero. A later successful bank scan will restore it.
            if integer(id, 1) and known == true and not invalidCounts[id] then snapshot.knownItems[id] = true end
        end
        if ns.StockInventory then
            snapshot.capacity = ns.StockInventory.SanitizeCapacity(saved.capacity)
            snapshot.extensions = ns.StockInventory.SanitizeExtensions(saved.extensions)
        end
        -- Items per container in the last complete reading. An unreadable
        -- memory is dropped as a whole; the next complete reading rebuilds it.
        if type(saved.containers) == "table" then
            local containers = {}
            for bag, items in pairs(saved.containers) do
                if not integer(bag, -128) or type(items) ~= "table" then containers = nil; break end
                local held = {}
                for id, count in pairs(items) do
                    if not integer(id, 1) or not integer(count, 1) then held = nil; break end
                    held[id] = count
                end
                if not held then containers = nil; break end
                if next(held) then containers[bag] = held end
            end
            snapshot.containers = containers

        end
    end
    CraftAutoBuyDB.stock, loadedDB = snapshot, CraftAutoBuyDB
end

-- Only ingredients of learned recipes in currently known professions belong
-- in the view. Outputs appear when another learned recipe actually uses them.
local function ingredientIDs()
    local ids = {}
    local professions = ns.API.GetProfessions()
    for _, profession in ipairs(professions or {}) do
        local recipes = ns.Catalogue and ns.Catalogue.GetRecipes(profession.key) or {}
        for _, recipe in pairs(recipes or {}) do
            if recipe.supported ~= false and recipe.learned ~= false then
                for _, reagent in ipairs(recipe.reagents or {}) do
                    if integer(reagent.itemID, 1) then ids[reagent.itemID] = true end
                end
            end
        end
    end
    return ids
end

-- Forever loads Camelot/BankFrame.lua, not Vanilla/BankFrame.lua. Its personal
-- bank is a list of purchased containers from C_Bank, including the initial
-- storage. Only ask for Character: account-bank containers must stay excluded.
-- Source: Gethe/wow-ui-source, forever, Blizzard_UIPanels_Game/Camelot/BankFrame.lua.
local function bankContainers()
    if C_Bank and type(C_Bank.FetchPurchasedBankTabData) == "function" then
        local character = Enum and Enum.BankType and Enum.BankType.Character
        if not integer(character) then return nil, "pending" end
        local canView = false
        if type(C_Bank.CanViewBank) == "function" then
            local ok, viewable = call(C_Bank.CanViewBank, character)
            if not ok or secret(viewable) or viewable ~= true then return nil, "pending" end
            canView = true
        end
        local ok, tabs = call(C_Bank.FetchPurchasedBankTabData, character)
        if not ok or secret(tabs) or type(tabs) ~= "table" then return nil, "pending" end
        local purchased
        if type(C_Bank.FetchNumPurchasedBankTabs) == "function" then
            local countOK, count = call(C_Bank.FetchNumPurchasedBankTabs, character)
            if not countOK or not integer(count) then return nil, "pending" end
            purchased = count
        end
        local containers, seen = {}, {}
        local tabCount = 0
        for index in pairs(tabs) do
            if not integer(index, 1) then return nil, "pending" end
            tabCount = tabCount + 1
        end
        for index = 1, tabCount do
            local tab = tabs[index]
            if secret(tab) or type(tab) ~= "table" or not integer(tab.ID, 1)
                or (tab.bankType ~= nil and (secret(tab.bankType) or tab.bankType ~= character)) then
                return nil, "pending"
            end
            if not seen[tab.ID] then
                containers[#containers + 1], seen[tab.ID] = tab.ID, true
            end
        end
        -- An empty response alone can mean loading. Only the explicit count
        -- for a viewable personal bank can confirm that no tab is owned yet.
        if #containers == 0 and not (canView and purchased == 0) then return nil, "pending" end
        -- Owned tabs cannot be removed. Previously observed items prove that
        -- this character already has personal storage: a later zero is loading.
        if #containers == 0 and snapshot and next(snapshot.counts) then return nil, "pending" end
        if purchased ~= nil and purchased ~= #containers then return nil, "pending" end
        personalContainers = seen
        return containers, "modern"
    end
    -- Compatibility with clients that still expose the old personal bank.
    -- Missing globals during login are not evidence of an empty bank.
    if not integer(BANK_CONTAINER, -128) or BANK_CONTAINER >= 0
        or not integer(NUM_BAG_SLOTS) or not integer(NUM_BANKBAGSLOTS)
        or NUM_BAG_SLOTS > 64 or NUM_BANKBAGSLOTS > 64 then return nil, "pending" end
    local containers = {BANK_CONTAINER}
    for index = 1, NUM_BANKBAGSLOTS do containers[#containers + 1] = NUM_BAG_SLOTS + index end
    personalContainers = {}
    for _, bag in ipairs(containers) do personalContainers[bag] = true end
    return containers, "legacy"
end

-- The client's own count of an item in this character's bank, never account
-- storage (same query as raiseEvidence). nil when the client cannot answer.
local function clientBankCount(id)
    local bagOK, bags = call(C_Item and C_Item.GetItemCount, id, false, false, false, false)
    local totalOK, total = call(C_Item and C_Item.GetItemCount, id, true, false, true, false)
    if bagOK and totalOK and integer(bags) and integer(total) and total >= bags then return total - bags end
end

-- Forever keeps the bag of each optional personal tab in Characterbanktab, at
-- that tab's position (Camelot/BankFrame.lua: RefreshBagButtons, GetBagAndSlot,
-- GetExactBankTabSlot). A purchased bank-bag slot without a bag reports no
-- slots and can hold nothing. Returns the zero-slot optional tabs of this
-- reading proven to hold no bag. Only definite answers count: a missing enum,
-- an error or a secret proves nothing, and the holder must also report the bag
-- of every optional tab this reading loaded, or its nil answers prove nothing.
local function emptyBagSlots(slotsByBag)
    local bagIndex = Enum and Enum.BagIndex
    local holder = bagIndex and bagIndex.Characterbanktab
    local first, last = bagIndex and bagIndex.CharacterBankTab_1, bagIndex and bagIndex.CharacterBankTab_9
    if not integer(holder, -128) or holder >= 0 or not integer(first) or not integer(last) then return {} end
    local empty = {}
    for bag, slots in pairs(slotsByBag) do
        if integer(bag) and bag > first and bag <= last then
            local ok, info = call(C_Container and C_Container.GetContainerItemInfo, holder, bag - first + 1)
            if not ok or secret(info) then return {} end
            if slots > 0 and type(info) ~= "table" then return {} end
            if slots == 0 and info == nil then empty[bag] = true end
        end
    end
    return empty
end

-- A missing container or a former filled bag with no slots is ambiguous:
-- revisiting it does not prove it empty. Preserve its evidence until a readable
-- container and the client confirm the decrease. At the beginning of a visit,
-- compare relevant client counters too, even on a fresh profile without history.
local function contradictsEvidence(counts, slotsByBag, mode)
    local blocked = false
    local relevant
    local function relevantIDs()
        if not relevant then
            relevant = ingredientIDs()
            for id, enabled in pairs(ns.vendorItems or {}) do if enabled then relevant[id] = true end end
        end
        return relevant
    end
    local inspect, lowered = {}, {}
    for id, recorded in pairs(snapshot.counts) do
        if (counts[id] or 0) < recorded then inspect[id] = true end
    end
    if firstReadPending then
        for id in pairs(relevantIDs()) do inspect[id] = true end
    end
    for id in pairs(inspect) do
        local found, recorded = counts[id] or 0, snapshot.counts[id] or 0
        local client = clientBankCount(id)
        if client and client > found and relevantIDs()[id] then
            blocked = true
            -- Save this new evidence even if a first/incomplete visit closes
            -- before a recipe is selected, and before the client forgets it.
            if client > recorded then snapshot.counts[id] = client; recorded = client; raisedThisVisit = true end
        end
        if found < recorded then
            lowered[id] = not closingRead and client ~= nil and client <= found
        end
    end
    local proven
    local function provenEmpty()
        if not proven then proven = mode == "modern" and emptyBagSlots(slotsByBag) or {} end
        return proven
    end
    -- Older snapshots did not map items to containers. A zero-capacity bag
    -- could hold any of their lowered items: keep the evidence until a later
    -- readable scan can disambiguate it, even if the client also forgot them.
    -- A purchased bag slot proven empty holds no bag and hides nothing: an old
    -- profile is not blocked forever by a slot that never received a bag. How
    -- many visits happened proves nothing and plays no part here. An item no
    -- learned recipe uses yet still counts while the client does not confirm it
    -- left: a recipe learned later can need it.
    if not snapshot.containers then
        local atStake = false
        for id, confirmed in pairs(lowered) do
            if relevantIDs()[id] or not confirmed then atStake = true; break end
        end
        if atStake then
            local empty = provenEmpty()
            for bag, slots in pairs(slotsByBag) do
                if slots == 0 and not empty[bag] then blocked = true; break end
            end
        end
    end
    for bag, items in pairs(snapshot.containers or {}) do
        local involved, agrees = false, true
        for id in pairs(items) do
            -- An item no learned recipe uses yet only frees its container once
            -- the client confirms it left a bank-bag slot proven to hold no bag:
            -- a recipe learned later can still need it.
            if lowered[id] ~= nil and (relevantIDs()[id] or not lowered[id]
                or not (slotsByBag[bag] == 0 and provenEmpty()[bag])) then
                involved, agrees = true, agrees and lowered[id]
            end
        end
        local slots = slotsByBag[bag]
        if involved and slots == nil then blocked = true
        elseif involved and slots == 0 and (not loadedThisVisit[bag] or not agrees) then blocked = true end
    end
    return blocked
end

local function captureContainers()
    if not C_Container or type(C_Container.GetContainerNumSlots) ~= "function"
        or type(C_Container.GetContainerItemInfo) ~= "function" then return nil, "unsupported" end
    local containers, mode = bankContainers()
    if not containers then return nil, mode end
    local counts, held, slotsByBag = {}, {}, {}
    local capacity, capacityKnown = {}, true
    for index, bag in ipairs(containers) do
        local ok, slots = call(C_Container.GetContainerNumSlots, bag)
        if not ok or not integer(slots) or slots > 1000 or (index == 1 and slots == 0) then return nil, "pending" end
        slotsByBag[bag] = slots
        local used = 0
        for slot = 1, slots do
            local infoOK, info = call(C_Container.GetContainerItemInfo, bag, slot)
            if not infoOK or secret(info) then return nil, "pending" end
            if info ~= nil then
                if type(info) ~= "table" or not integer(info.itemID, 1) or not integer(info.stackCount, 1) then
                    return nil, "pending"
                end
                counts[info.itemID] = (counts[info.itemID] or 0) + info.stackCount
                used = used + 1
                held[bag] = held[bag] or {}
                held[bag][info.itemID] = (held[bag][info.itemID] or 0) + info.stackCount
            end
        end
        if ns.StockInventory then
            local descriptor, reason = ns.StockInventory.DescribeContainer(bag, slots, used)
            if reason == "contradiction" then return nil, "pending" end
            if descriptor then capacity[#capacity + 1] = descriptor else capacityKnown = false end
        end
    end
    if ns.StockInventory and mode == "modern" then
        local empty
        for bag, slots in pairs(slotsByBag) do
            if slots == 0 then
                if not empty then empty = emptyBagSlots(slotsByBag) end
                -- All also presents objects for which no recipe or former
                -- evidence exists. An equipped tab still loading must not
                -- become a complete empty bank merely for lack of evidence.
                if not empty[bag] then return nil, "pending" end
            end
        end
    end
    if contradictsEvidence(counts, slotsByBag, mode) then return nil, "pending" end
    -- A rejected read cannot prove that a bag loaded during this visit. Only
    -- a complete, coherent snapshot permits a later zero to mean bag removal.
    for bag, slots in pairs(slotsByBag) do
        if slots > 0 then loadedThisVisit[bag] = true end
    end
    return counts, "complete", held,
        ns.StockInventory and (capacityKnown and ns.StockInventory.Capacity(capacity) or {known = false, containers = {}}) or nil
end

local function captureKnownItems()
    -- Older/custom clients can lack container enumeration. In that case retain
    -- explicit knowledge per item; a future recipe's unseen ingredient is nil,
    -- never a fabricated zero. Query the raw API to avoid a cache-fallback loop.
    local ids = ingredientIDs()
    for id in pairs(snapshot.counts) do ids[id] = true end
    for id in pairs(snapshot.knownItems) do ids[id] = true end
    local observed, updated, allObserved = false, false, true
    for id in pairs(ids) do
        local bagOK, bags = call(C_Item and C_Item.GetItemCount, id, false, false, false, false)
        local totalOK, total = call(C_Item and C_Item.GetItemCount, id, true, false, true, false)
        if bagOK and totalOK and integer(bags) and integer(total) and total >= bags then
            local count = total - bags
            if (snapshot.counts[id] or 0) ~= count or not snapshot.knownItems[id] then updated = true end
            snapshot.counts[id] = count > 0 and count or nil
            snapshot.knownItems[id] = true
            observed = true
        else
            allObserved = false
        end
    end
    if observed then
        updated = updated or not snapshot.known or snapshot.complete
        snapshot.known, snapshot.complete = true, false
    end
    if observed and allObserved then snapshot.unverified = false end
    return updated, observed and allObserved
end

function Stock.IsBankOpen() return bankOpen end

-- Live personal storage only. A remembered bank is never a transfer source.
-- The third result identifies optional bank containers proven unequipped.
function Stock.GetOpenBankContainers()
    if not bankOpen then return nil end
    local ids, mode = bankContainers()
    if not ids then return nil end
    local indices = Enum and Enum.BagIndex
    local first, last = indices and indices.CharacterBankTab_1, indices and indices.CharacterBankTab_9
    if mode=="modern" and (not integer(first,1) or not integer(last,first)) then return nil end
    local result, sizes = {}, {}
    for index, bag in ipairs(ids) do
        if mode=="modern" and (bag<first or bag>last) then return nil end
        local ok, size = call(C_Container and C_Container.GetContainerNumSlots, bag)
        if not ok or not integer(size) or size > 1000 then return nil end
        result[index], sizes[bag] = bag, size
    end
    return result, mode, emptyBagSlots(sizes)
end

function Stock.IsBankUnverified()
    ensureLoaded()
    return snapshot.unverified or changePending or (bankOpen and firstReadPending)
end

-- These counts are evidence for the withdrawal/repurchase decision, not an
-- assertion that the bank still contains them. Losing freshness must never
-- silently authorize buying items previously observed in the bank.
function Stock.BankEvidence(itemID)
    if not integer(itemID, 1) then return nil end
    ensureLoaded()
    local unverified = Stock.IsBankUnverified()
    if unverified then return snapshot.counts[itemID] or 0, true end
    return Stock.BankCount(itemID)
end

function Stock.BankCount(itemID)
    if not integer(itemID, 1) then return nil end
    ensureLoaded()
    -- Stock's visible list only presents verified quantities. Planning uses
    -- BankEvidence instead, with a warning and a repurchase confirmation.
    if Stock.IsBankUnverified() then return nil, true end
    if not snapshot.known then return nil end
    if snapshot.complete or snapshot.knownItems[itemID] then return snapshot.counts[itemID] or 0 end
    return nil, snapshot.unverified
end

-- Reads the open personal bank. force marks the read as a change even when the
-- counts are identical, e.g. to clear a notice left by an unread notification.
-- Returns updated, read (read is false when the client data are incomplete).
local function capture(force)
    local counts, result, held, capacity = captureContainers()
    if counts then
        changePending, firstReadPending = false, false
        -- Kept even when the totals are unchanged: a sort moves stacks.
        snapshot.containers = held
        -- Optional presentation metadata is committed only with the same
        -- complete reading as its item counts. It never alters bank evidence.
        local metadataChanged = false
        if ns.StockInventory then
            local extensions = ns.StockInventory.BankExtensions()
            metadataChanged = not ns.StockInventory.SameMetadata(snapshot.capacity, capacity,
                snapshot.extensions, extensions)
            snapshot.capacity = capacity
            snapshot.extensions = extensions
        end
        local updated = force or metadataChanged or snapshot.unverified or not snapshot.known or not snapshot.complete
        for id, count in pairs(counts) do if snapshot.counts[id] ~= count then updated = true; break end end
        for id, count in pairs(snapshot.counts) do if counts[id] ~= count then updated = true; break end end
        if updated then
            snapshot.counts, snapshot.knownItems = counts, {}
            snapshot.known, snapshot.complete = true, true
            snapshot.unverified = false
        end
        return updated, true
    elseif result == "unsupported" then
        local updated, observed = captureKnownItems()
        if observed then changePending, firstReadPending = false, false else readFailed = true end
        return updated or (observed and force) or false, observed
    end
    readFailed = true
    return false, false
end

local function publish(updated)
    publishPending, publishQueued = false, nil
    if updated and ns.Catalogue and ns.Catalogue.Invalidate then ns.Catalogue.Invalidate() end
    if updated and ns.Refresh then ns.Refresh()
    elseif ns.StockUI and ns.StockUI.Render then ns.StockUI.Render() end
end

-- Bank-tab notifications arrive in bursts (sorting, deposit-all). Each one is
-- read at once, so a close in the same frame cannot lose it; the expensive
-- catalogue rebuild and page refresh run once on the next frame.
local function schedulePublish()
    -- At logout the saved state is final; no page will be shown again.
    if loggingOut then publishPending = false; return end
    publishPending = true
    if publishQueued then return end
    if not (C_Timer and type(C_Timer.After) == "function") then publish(true); return end
    local request = {}
    publishQueued = request
    local ok = call(C_Timer.After, 0, function()
        if publishQueued == request and publishPending then publish(true) end
    end)
    if not ok then publish(true) end
end

function Stock.Refresh()
    pendingRefresh = nil -- An explicit refresh also satisfies a queued event.
    ensureLoaded()
    local updated = false
    if bankOpen then updated = capture(changePending or firstReadPending) end
    publish(updated or publishPending)
    return updated
end

local function scheduleRefresh()
    if pendingRefresh then return end
    if not (C_Timer and type(C_Timer.After) == "function") then Stock.Refresh(); return end
    local request = {}
    pendingRefresh = request
    local ok = call(C_Timer.After, 0, function()
        if pendingRefresh == request then Stock.Refresh() end
    end)
    if not ok then Stock.Refresh() end
end

local function now()
    local ok, value = call(GetTime)
    if ok and type(value) == "number" and not secret(value) and value == value and value < math.huge then return value end
end

-- Raise the saved evidence to what the client itself reports for relevant
-- items. Never lower it: a client that forgot its bank reports zero. Returns
-- raised (the client shows more items than CAB recorded) and lowered (the
-- client, which still counts some bank items, shows fewer for one of them).
local function raiseEvidence()
    local ids = ingredientIDs()
    -- A first login or catalogue migration may not know any recipes yet.
    -- Vendor supplies still need their late bank deposits preserved for reload.
    for id, enabled in pairs(ns.vendorItems or {}) do
        if enabled and integer(id, 1) then ids[id] = true end
    end
    for id in pairs(snapshot.counts) do ids[id] = true end
    for id in pairs(snapshot.knownItems) do ids[id] = true end
    local raised, lowered, counting = false, false, false
    for id in pairs(ids) do
        local bagOK, bags = call(C_Item and C_Item.GetItemCount, id, false, false, false, false)
        local totalOK, total = call(C_Item and C_Item.GetItemCount, id, true, false, true, false)
        if bagOK and totalOK and integer(bags) and integer(total) and total >= bags then
            local count = total - bags
            local recorded = snapshot.counts[id] or 0
            if count > 0 then counting = true end
            if count > recorded then snapshot.counts[id], raised = count, true
            elseif count < recorded then lowered = true end
        end
    end
    return raised, lowered and counting
end

-- The previous counts stay as evidence for the withdrawal/repurchase decision,
-- but are no longer presented as a current bank reading.
local function markUnverified()
    ensureLoaded()
    raiseEvidence()
    snapshot.known, snapshot.complete, snapshot.unverified = false, false, true
    snapshot.knownItems = {}
    changePending = false
    schedulePublish()
end

-- A personal notification with the bank closed is a late transfer reply when it
-- follows a close of this session. Otherwise (login, /reload, remote changes) it
-- only matters when the client really reports more items than the snapshot.
local function closedNotification()
    ensureLoaded()
    local current = now()
    local recent = closedAt == true
        or (type(closedAt) == "number" and (current or closedAt) - closedAt <= LATE_NOTIFICATION_WINDOW)
    if recent then markUnverified(); return end
    -- Beyond that window only a real difference reported by the client counts:
    -- more items than recorded, or fewer while it still counts its bank. A client
    -- that forgot its bank reports zero everywhere and changes nothing.
    local raised, lowered = raiseEvidence()
    if raised or lowered then markUnverified() end
end

-- API.BankCount saw the client report more of an item than CAB recorded while
-- the bank is closed (reading made stale by a crash before saving, another
-- computer...). Keep that count as evidence to check: it survives a session in
-- which the client no longer counts its bank, and Stock stops presenting the
-- lower reading as current. A profile that never read its bank is left alone.
function Stock.NoteClientBankCount(itemID, count)
    if bankOpen or not integer(itemID, 1) or not integer(count, 1) then return end
    ensureLoaded()
    if not snapshot.known and not snapshot.unverified then return end
    if count <= (snapshot.counts[itemID] or 0) then return end
    -- Keep it for an item that may have to be bought: a vendor item, or a
    -- reagent of a learned recipe (it may become a known vendor item later).
    -- The client also counts items CAB cannot read, such as bags placed in bank
    -- bag slots: those are not reagents and never make a reading "to check".
    if not (ns.vendorItems and ns.vendorItems[itemID]) and not ingredientIDs()[itemID] then return end
    snapshot.counts[itemID] = count
    if not snapshot.unverified then markUnverified() end
end

local function canViewPersonalBank()
    if not (C_Bank and type(C_Bank.FetchPurchasedBankTabData) == "function") then return true end
    local character = Enum and Enum.BankType and Enum.BankType.Character
    local ok, viewable = call(C_Bank.CanViewBank, character)
    return integer(character) and ok and not secret(viewable) and viewable == true
end

local function setBankOpen(value)
    if value then
        if not bankOpen then
            firstReadPending, readFailed, loadedThisVisit = true, false, {}
            raisedThisVisit = false
        end
        bankOpen = true
        return
    end
    if bankOpen then
        -- An unread notification, or a visit whose reads all failed, cannot
        -- confirm the previous counts. A visit closed before any read attempt
        -- (same frame) changed nothing and keeps the previous complete reading;
        -- it is still read once here while access remains: a success only helps.
        local failedBefore = readFailed
        if changePending or firstReadPending then
            -- Some close notifications arrive while the personal bank can still
            -- be read. Never flush blindly after access has already disappeared.
            local character = Enum and Enum.BankType and Enum.BankType.Character
            local ok, viewable = call(C_Bank and C_Bank.CanViewBank, character)
            if integer(character) and ok and not secret(viewable) and viewable == true then
                -- The client may already forget its bank here: its agreement
                -- cannot confirm that items left (its higher count still counts).
                closingRead = true
                local updated = capture(true)
                closingRead = false
                if updated then schedulePublish() end
            end
            -- A first read made only at closing and rejected still leaves a
            -- reading to check: when it raised the evidence from the client
            -- count, or when no complete reading was ever known.
            local closingFailed = readFailed and not failedBefore
            if changePending or (firstReadPending and (failedBefore or raisedThisVisit
                or (closingFailed and not snapshot.known))) then markUnverified() end
        end
        firstReadPending, readFailed = false, false
        closedAt = now() or true
    end
    bankOpen = false
end

local function personalBankChange(event, value)
    if event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED" then return true end
    if event == "BANK_TABS_CHANGED" then
        local character = Enum and Enum.BankType and Enum.BankType.Character
        return integer(character) and not secret(value) and value == character
    end
    if event ~= "BAG_UPDATE" or not integer(value, -128) then return false end
    local bags = Enum and Enum.BagIndex
    if bags and integer(bags.CharacterBankTab_1) and integer(bags.CharacterBankTab_9) then
        return value >= bags.CharacterBankTab_1 and value <= bags.CharacterBankTab_9
    end
    if C_Bank and type(C_Bank.FetchPurchasedBankTabData) == "function" then return personalContainers[value] == true end
    return value == BANK_CONTAINER or (integer(NUM_BAG_SLOTS) and integer(NUM_BANKBAGSLOTS)
        and value > NUM_BAG_SLOTS and value <= NUM_BAG_SLOTS + NUM_BANKBAGSLOTS)
end

-- Core skips its inventory refresh for these containers: Stock reads them and
-- publishes a change itself.
function Stock.IsPersonalBankContainer(bag)
    return personalBankChange("BAG_UPDATE", bag) == true
end

function Stock.Rows(search)
    ensureLoaded()
    local query = normalized(type(search) == "string" and search or "")
    local bags, bank, bankKnown = {}, {}, snapshot.known and not Stock.IsBankUnverified()
    for id in pairs(ingredientIDs()) do
        local nameOK, name = call(C_Item and C_Item.GetItemNameByID, id)
        name = nameOK and text(name) or nil
        if not name then
            local fallbackOK, fallback = call(ns.ItemName, id)
            name = fallbackOK and text(fallback) or ns.L.ITEM_FALLBACK:format(tostring(id))
        end
        local stored = Stock.BankCount(id)
        if stored == nil then bankKnown = false end
        if query == "" or normalized(name):find(query, 1, true) or tostring(id):find(query, 1, true) then
            local iconOK, icon = call(C_Item and C_Item.GetItemIconByID or GetItemIcon, id)
            icon = iconOK and not secret(icon) and (integer(icon, 1) or text(icon)) and icon or QUESTION_MARK
            local countOK, count = call(ns.API.CountItem, id)
            if countOK and integer(count, 1) then bags[#bags + 1] = {itemID = id, name = name, icon = icon, count = count} end
            if stored and stored > 0 then bank[#bank + 1] = {itemID = id, name = name, icon = icon, count = stored} end
        end
    end
    local function before(a, b)
        local left, right = normalized(a.name), normalized(b.name)
        if left ~= right then return left < right end
        return a.itemID < b.itemID
    end
    table.sort(bags, before); table.sort(bank, before)
    local missing = ns.Catalogue and ns.Catalogue.MissingProfessions() or {}
    return bags, bank, bankKnown, missing
end

function Stock.View(search, options)
    ensureLoaded()
    return ns.StockInventory.Build(snapshot, search, options, Stock.BankCount,
        Stock.IsBankUnverified(), bankOpen)
end

local function installEvents()
    if frame or type(CreateFrame) ~= "function" then return end
    frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", function(_, event, name)
        if event == "ADDON_LOADED" and name ~= addonName then return end
        if event == "PLAYER_LOGOUT" then
            -- SavedVariables can be written before the deferred scan or a bank
            -- close event. Finalize the same way without scheduling more work.
            loggingOut = true
            setBankOpen(false)
            loggingOut = false
            pendingRefresh, publishQueued, publishPending = nil, nil, false
            return
        end
        -- This is the opening path used by Forever's native bank frame. Keep
        -- the legacy bank events too; their bursts share one deferred read.
        if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
            local kinds = Enum and Enum.PlayerInteractionType
            if not kinds or name == nil or secret(name)
                or (name ~= kinds.Banker and name ~= kinds.CharacterBanker and name ~= kinds.AccountBanker) then return end
            local open = event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
            if open then open = canViewPersonalBank() end
            setBankOpen(open)
        elseif event == "BANKFRAME_OPENED" then setBankOpen(canViewPersonalBank())
        elseif event == "BANKFRAME_CLOSED" then setBankOpen(false)
        elseif event == "ADDON_LOADED" or event == "PLAYER_LOGIN" then Stock.Init() end
        if personalBankChange(event, name) then
            if bankOpen then
                -- A real transfer must be observed while access still exists.
                -- Only cosmetic and non-personal events wait until next frame.
                local wasPending = changePending or firstReadPending
                changePending = true
                -- Incomplete data stay pending: the client announces their
                -- arrival with further bank events, and a close marks them.
                -- Entering that pending state is published once, so CAB and the
                -- professions show it although Core skips bank-only updates.
                local updated, read = capture(wasPending)
                if updated or (not read and not wasPending) then schedulePublish() end
            else
                closedNotification()
            end
            return
        end
        scheduleRefresh()
    end)
    for _, event in ipairs({"ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
        "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
        "BAG_UPDATE", "BAG_UPDATE_DELAYED", "BAG_CONTAINER_UPDATE",
        "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED", "BANK_TABS_CHANGED",
        "SKILL_LINES_CHANGED", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
        "NEW_RECIPE_LEARNED", "GET_ITEM_INFO_RECEIVED"}) do
        pcall(frame.RegisterEvent, frame, event)
    end
end

function Stock.Init()
    ensureLoaded()
    installEvents()
    if BankFrame and type(BankFrame.IsShown) == "function" then
        local ok, visible = call(BankFrame.IsShown, BankFrame)
        if ok and visible then setBankOpen(canViewPersonalBank()) end
    end
    return Stock
end

installEvents()
