local _, ns = ...
local Inventory = {}
ns.StockInventory = Inventory

-- Read-only presentation data. These helpers never move items or change the
-- bank evidence that the planner uses to protect repurchases.
local MAX_SLOTS, MAX_CONTAINERS = 1000, 32
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local function secret(value) return issecretvalue and issecretvalue(value) end
local function integer(value, minimum, maximum)
    return not secret(value) and type(value) == "number" and value == value
        and value >= (minimum or 0) and value <= (maximum or 2147483647)
        and value == math.floor(value)
end
local function call(callback, ...)
    if type(callback) ~= "function" then return false end
    return pcall(callback, ...)
end
local function text(value)
    return not secret(value) and type(value) == "string" and value ~= "" and value or nil
end
local function unknown() return {known = false, containers = {}} end

-- Free-slot families are supplied by the client. An unavailable family is
-- unknown, not a claim that a specialized bag accepts every item.
function Inventory.DescribeContainer(id, size, used)
    if not integer(id, -128) or not integer(size, 0, MAX_SLOTS)
        or not integer(used, 0, size) then return nil end
    local descriptor = {id = id, size = size, used = used, free = size - used}
    -- Unequipped optional bags have no slots and need no free-slot/family
    -- response. The caller verifies empty equipment slots for physical bags.
    if size == 0 then return descriptor end
    if C_Container and type(C_Container.GetContainerNumFreeSlots) == "function" then
        local ok, free, family = call(C_Container.GetContainerNumFreeSlots, id)
        if not ok or not integer(free, 0, size) then return nil end
        if free ~= descriptor.free then return nil, "contradiction" end
        if integer(family, 0) then descriptor.family = family end
    elseif id == 0 then
        descriptor.family = 0 -- The backpack is always general-purpose.
    end
    return descriptor
end

function Inventory.SanitizeCapacity(saved)
    if secret(saved) or type(saved) ~= "table" or secret(saved.known) or saved.known ~= true
        or not integer(saved.total, 0, MAX_SLOTS * MAX_CONTAINERS)
        or not integer(saved.used, 0, saved.total)
        or not integer(saved.free, 0, saved.total) or saved.used + saved.free ~= saved.total
        or secret(saved.containers) or type(saved.containers) ~= "table" then return unknown() end
    local result = {known = true, total = saved.total, used = saved.used, free = saved.free, containers = {}}
    local total, used, free, general, specialized, families, seen, entries = 0, 0, 0, 0, 0, true, {}, 0
    for index in pairs(saved.containers) do
        if not integer(index, 1, MAX_CONTAINERS) then return unknown() end
        entries = entries + 1
    end
    for index = 1, entries do
        local value = saved.containers[index]
        if secret(value) or type(value) ~= "table" or not integer(value.id, -128)
            or seen[value.id] or not integer(value.size, 0, MAX_SLOTS)
            or not integer(value.used, 0, value.size) or not integer(value.free, 0, value.size)
            or value.used + value.free ~= value.size then return unknown() end
        local entry = {id = value.id, size = value.size, used = value.used, free = value.free}
        if integer(value.family, 0) then
            entry.family = value.family
            if entry.family == 0 then general = general + entry.free else specialized = specialized + entry.free end
        elseif value.size > 0 then families = false end
        if integer(value.itemID, 1) then entry.itemID = value.itemID end
        result.containers[index], seen[value.id] = entry, true
        total, used, free = total + entry.size, used + entry.used, free + entry.free
    end
    if total ~= result.total or used ~= result.used or free ~= result.free then return unknown() end
    if families then result.generalFree, result.specializedFree = general, specialized end
    return result
end

function Inventory.Capacity(containers)
    local value = {known = true, total = 0, used = 0, free = 0, containers = containers}
    for _, entry in ipairs(containers) do
        value.total, value.used, value.free = value.total + entry.size, value.used + entry.used, value.free + entry.free
    end
    return Inventory.SanitizeCapacity(value)
end

-- Only the optional personal-bank containers are replaceable bags. The fixed
-- initial storage is not a bag, even when Forever gives it a positive index.
-- Derive this view from recorded metadata; never query a closed bank for it.
function Inventory.BankBags(saved)
    local capacity = Inventory.SanitizeCapacity(saved)
    if not capacity.known or #capacity.containers == 0 then return capacity end
    local base, first, last
    -- Compatibility clients may expose modern enums while still using the
    -- negative legacy bank container. Its presence identifies that layout.
    if integer(BANK_CONTAINER, -128, -1) then
        for _, entry in ipairs(capacity.containers) do
            if entry.id == BANK_CONTAINER then
                if not integer(NUM_BAG_SLOTS, 0, MAX_CONTAINERS)
                    or not integer(NUM_BANKBAGSLOTS, 0, MAX_CONTAINERS) then return unknown() end
                base, first, last = BANK_CONTAINER, NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS
                break
            end
        end
    end
    if base == nil then
        local indices = Enum and Enum.BagIndex
        local initial, final = indices and indices.CharacterBankTab_1, indices and indices.CharacterBankTab_9
        if not integer(initial, 1) or not integer(final, initial, initial + MAX_CONTAINERS) then return unknown() end
        for _, entry in ipairs(capacity.containers) do
            if entry.id == initial then base, first, last = initial, initial + 1, final; break end
        end
    end
    if base == nil then return unknown() end
    local bags = {}
    for _, entry in ipairs(capacity.containers) do
        if entry.id ~= base then
            if not integer(entry.id, first, last) then return unknown() end
            bags[#bags + 1] = entry
        end
    end
    return Inventory.Capacity(bags)
end

function Inventory.SanitizeExtensions(saved)
    if secret(saved) or type(saved) ~= "table" or secret(saved.known) or saved.known ~= true
        or not integer(saved.purchased, 0, MAX_CONTAINERS)
        or not integer(saved.max, saved.purchased, MAX_CONTAINERS) then return {known = false} end
    local result = {known = true, purchased = saved.purchased, max = saved.max,
        remaining = saved.max - saved.purchased}
    if integer(saved.nextCost, 0, 1000000000000) and result.remaining > 0 then result.nextCost = saved.nextCost end
    return result
end

function Inventory.SameMetadata(leftCapacity, rightCapacity, leftExtensions, rightExtensions)
    local left, right = Inventory.SanitizeCapacity(leftCapacity), Inventory.SanitizeCapacity(rightCapacity)
    for _, field in ipairs({"known", "total", "used", "free", "generalFree", "specializedFree"}) do
        if left[field] ~= right[field] then return false end
    end
    if #left.containers ~= #right.containers then return false end
    for index, entry in ipairs(left.containers) do
        for _, field in ipairs({"id", "size", "used", "free", "family", "itemID"}) do
            if entry[field] ~= right.containers[index][field] then return false end
        end
    end
    left, right = Inventory.SanitizeExtensions(leftExtensions), Inventory.SanitizeExtensions(rightExtensions)
    for _, field in ipairs({"known", "purchased", "max", "remaining", "nextCost"}) do
        if left[field] ~= right[field] then return false end
    end
    return true
end

function Inventory.BankExtensions()
    local character = Enum and Enum.BankType and Enum.BankType.Character
    if not integer(character) or not C_Bank then return {known = false} end
    local accessible, viewable = call(C_Bank.CanViewBank, character)
    if not accessible or secret(viewable) or viewable ~= true then return {known = false} end
    local countOK, purchased = call(C_Bank.FetchNumPurchasedBankTabs, character)
    local maxOK, maximum = call(C_Bank.FetchMaxNumBankTabs, character)
    if not countOK or not maxOK then return {known = false} end
    local value = {known = true, purchased = purchased, max = maximum}
    local nextOK, nextTab = call(C_Bank.FetchNextPurchasableBankTabData, character)
    if nextOK and not secret(nextTab) and type(nextTab) == "table" then value.nextCost = nextTab.tabCost end
    return Inventory.SanitizeExtensions(value)
end

local function bagIDs()
    local bagIndex = Enum and Enum.BagIndex
    local backpack = bagIndex and bagIndex.Backpack or BACKPACK_CONTAINER
    if backpack == nil then backpack = 0 end
    if not integer(backpack, 0, 0) then return nil end
    local last = NUM_BAG_SLOTS or (bagIndex and bagIndex.Bag_4)
    -- Modern Forever reserves 6..14 for personal bank and 15..23 for account.
    -- Never infer that bank indices belong to the bags from a broad maximum.
    if not integer(last, 0, 5) then return nil end
    local total, reagentSlots = NUM_TOTAL_EQUIPPED_BAG_SLOTS, NUM_REAGENTBAG_SLOTS
    if total ~= nil then
        if not integer(total, last, 5) then return nil end
        last = total
    end
    local result = {backpack}
    for id = 1, last do result[#result + 1] = id end
    local reagent = bagIndex and bagIndex.ReagentBag
    -- The BagIndex enum is shared with clients whose optional reagent-bag
    -- equipment slot is disabled. Honor runtime equipment constants first.
    if total == nil and reagentSlots ~= nil and not integer(reagentSlots, 0, 1) then return nil end
    if total == nil and reagentSlots ~= 0 and integer(reagent, 1, 5) and reagent > last then
        result[#result + 1] = reagent
    end
    return result
end

function Inventory.GetBagIDs()
    return bagIDs()
end

function Inventory.ReadBags()
    local failed = {known = false, counts = {}, capacity = unknown()}
    local ids = bagIDs()
    if not ids or not C_Container then return failed end
    local counts, containers, capacityKnown = {}, {}, true
    for _, id in ipairs(ids) do
        local sizeOK, size = call(C_Container.GetContainerNumSlots, id)
        if not sizeOK or not integer(size, 0, MAX_SLOTS) or (id == 0 and size == 0) then return failed end
        if id > 0 and size == 0 then
            -- Zero can mean a bag that is not equipped, or one still loading.
            -- Confirm the equipment slot is empty before treating it as zero.
            local slotOK, equipmentSlot = call(C_Container.ContainerIDToInventoryID, id)
            if not slotOK or not integer(equipmentSlot, 1) then return failed end
            local itemOK, equipped = call(GetInventoryItemID, "player", equipmentSlot)
            if not itemOK or secret(equipped) or equipped ~= nil then return failed end
        end
        local used = 0
        for slot = 1, size do
            local ok, info = call(C_Container.GetContainerItemInfo, id, slot)
            if not ok or secret(info) then return failed end
            if info ~= nil then
                if type(info) ~= "table" or not integer(info.itemID, 1)
                    or not integer(info.stackCount, 1) then return failed end
                counts[info.itemID], used = (counts[info.itemID] or 0) + info.stackCount, used + 1
            end
        end
        local descriptor, reason = Inventory.DescribeContainer(id, size, used)
        if reason == "contradiction" then return failed end
        if descriptor then containers[#containers + 1] = descriptor else capacityKnown = false end
    end
    return {known = true, counts = counts, capacity = capacityKnown and Inventory.Capacity(containers) or unknown()}
end

local function bagCount(id, reading)
    if reading.known then return reading.counts[id] or 0 end
    -- A per-item successful read can still be useful while enumeration is
    -- loading. API.CountItem deliberately collapses failure to zero for the
    -- planner, so do not use it to fabricate a known zero in the inventory.
    local ok, count = call(C_Item and C_Item.GetItemCount, id, false, false, false, false)
    if ok and integer(count) then return count end
end

local function professionsAndIngredients(options)
    local ok, professions, complete = call(ns.API and ns.API.GetProfessions)
    if not ok or secret(professions) or type(professions) ~= "table" then professions, complete = {}, false end
    local result, ids = {}, {}
    for _, profession in ipairs(professions) do
        if not secret(profession) and type(profession) == "table" and integer(profession.key, 1) then
            result[#result + 1] = profession
            if options.professionKey == nil or options.professionKey == profession.key then
                local readOK, recipes = call(ns.Catalogue and ns.Catalogue.GetRecipes, profession.key)
                if readOK and not secret(recipes) and type(recipes) == "table" then
                    for _, recipe in pairs(recipes) do
                        if type(recipe) == "table" and recipe.supported ~= false and recipe.learned ~= false then
                            for _, reagent in ipairs(recipe.reagents or {}) do
                                if integer(reagent.itemID, 1) then ids[reagent.itemID] = true end
                            end
                        end
                    end
                end
            end
        end
    end
    return result, ids, not secret(complete) and complete == true
end

local function itemMetadata(id)
    local ok, name = call(C_Item and C_Item.GetItemNameByID, id)
    name = ok and text(name) or nil
    if not name then
        local fallbackOK, fallback = call(ns.ItemName, id)
        name = fallbackOK and text(fallback) or ns.L.ITEM_FALLBACK:format(tostring(id))
    end
    local iconOK, icon = call(C_Item and C_Item.GetItemIconByID or GetItemIcon, id)
    if not iconOK or not (integer(icon, 1) or text(icon)) then icon = QUESTION_MARK end
    return name, icon
end

function Inventory.Build(snapshot, search, options, bankCount, unverified, bankOpen)
    options = type(options) == "table" and not secret(options) and options or {}
    local professions, ingredients, professionsComplete = professionsAndIngredients(options)
    local reading, ids = Inventory.ReadBags(), {}
    local all = options.content == "all"
    if all then
        for id in pairs(reading.counts) do ids[id] = true end
        for id in pairs(snapshot.counts) do ids[id] = true end
    else ids = ingredients end
    local view = {bags = {}, bank = {}, inventory = {}, bagsKnown = reading.known,
        bankKnown = snapshot.known and not unverified and (not all or snapshot.complete),
        bankUnverified = unverified == true, professions = professions, professionsComplete = professionsComplete,
        missing = {}, capacity = {bags = reading.capacity, bank = unknown()}, extensions = {bank = {known = false}}}
    local missingOK, missing = call(ns.Catalogue and ns.Catalogue.MissingProfessions)
    if missingOK and not secret(missing) and type(missing) == "table" then view.missing = missing end
    local query = ns.Locale.SearchText(type(search) == "string" and not secret(search) and search or "")
    for id in pairs(ids) do
        local bag, bank = bagCount(id, reading), bankCount(id)
        if bank == nil then view.bankKnown = false end
        local evidence = snapshot.counts[id] or 0
        -- Only objects present in at least one source belong to the common
        -- list. Old bank evidence supplies an identity, never its current count.
        if (bag and bag > 0) or (bank and bank > 0) or (bank == nil and evidence > 0) then
            local name, icon = itemMetadata(id)
            if query == "" or ns.Locale.SearchText(name):find(query, 1, true) or tostring(id):find(query, 1, true) then
                if bag and bag > 0 then view.bags[#view.bags + 1] = {itemID = id, name = name, icon = icon, count = bag} end
                if bank and bank > 0 then view.bank[#view.bank + 1] = {itemID = id, name = name, icon = icon, count = bank} end
                view.inventory[#view.inventory + 1] = {itemID = id, name = name, icon = icon,
                    bagCount = bag, bankCount = bank, total = bag ~= nil and bank ~= nil and bag + bank or nil}
            end
        end
    end
    local function before(a, b)
        local left, right = ns.Locale.SearchText(a.name), ns.Locale.SearchText(b.name)
        if left ~= right then return left < right end
        return a.itemID < b.itemID
    end
    table.sort(view.bags, before); table.sort(view.bank, before); table.sort(view.inventory, before)
    if snapshot.known and snapshot.complete and not unverified then
        view.capacity.bank = Inventory.SanitizeCapacity(snapshot.capacity)
        view.extensions.bank = Inventory.SanitizeExtensions(snapshot.extensions)
    end
    view.capacity.bank.memory, view.capacity.bank.unverified = not bankOpen, unverified == true
    view.bankBags = Inventory.BankBags(view.capacity.bank)
    return view
end
