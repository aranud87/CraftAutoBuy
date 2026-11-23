local addonName, ns = ...
local Adapter = {}
ns.BankTransferAPI = Adapter
local frame
local requestedItems = {}
local function secret(v) return issecretvalue and issecretvalue(v) end
local function integer(v, minimum, maximum)
    return not secret(v) and type(v)=="number" and v==math.floor(v)
        and v >= (minimum or 0) and v <= (maximum or 2147483647)
end
local function call(fn, ...)
    if type(fn)~="function" then return false end
    return pcall(fn, ...)
end
local function busyTransfer()
    return ns.BankTransfer and ns.BankTransfer.IsBusy and ns.BankTransfer.IsBusy()
end

function Adapter.IsOpen()
    if not ns.Stock or not ns.Stock.IsBankOpen or not ns.Stock.IsBankOpen() then return false end
    local kind = Enum and Enum.BankType and Enum.BankType.Character
    if C_Bank and type(C_Bank.CanViewBank)=="function" then
        if not integer(kind) then return false end
        local ok, visible = call(C_Bank.CanViewBank,kind)
        if not ok or secret(visible) or visible~=true then return false end
        if type(C_Bank.CanUseBank)=="function" then
            local useOK,usable=call(C_Bank.CanUseBank,kind)
            if not useOK or secret(usable) or usable~=true then return false end
        end
        return true
    end
    return true
end

function Adapter.BlockReason(mode)
    local ok, combat = call(InCombatLockdown)
    if not ok or secret(combat) then return "BANK_TRANSFER_LOADING" end
    if combat then return "BANK_TRANSFER_COMBAT" end
    if not Adapter.IsOpen() then return "BANK_TRANSFER_BANK_CLOSED" end
    for _, name in ipairs({"UnitCastingInfo","UnitChannelInfo"}) do
        local fn = name=="UnitCastingInfo" and UnitCastingInfo or UnitChannelInfo
        local castOK, spell = call(fn,"player")
        if not castOK or secret(spell) then return "BANK_TRANSFER_LOADING" end
        if spell then return "BANK_TRANSFER_CRAFTING" end
    end
    local job = ns.job
    if job and job.awaitingPurchase then return "BANK_TRANSFER_BUSY" end
    -- A craft confirmation still pending blocks every transfer but one: a
    -- deposit waits only while the batch may still craft. Core keeps the record
    -- after the batch has ended, and a deposit must not wait for a project to be
    -- cancelled. Any other transfer keeps waiting for the record: an item taken
    -- back into the bags would be read as the receipt of the missing craft.
    -- Without Core's answer the record blocks a deposit too, as before.
    if job and job.pending then
        if job.running or type(ns.CraftBatchActive) ~= "function" or ns.CraftBatchActive() then
            return "BANK_TRANSFER_WAIT_CRAFT_CONFIRMATION"
        end
        if mode ~= "deposit" then return "CRAFT_CONFIRMATION_MISSING" end
    elseif job and job.running then
        return "BANK_TRANSFER_CRAFTING"
    end
    if ns.pendingStart or ns.bankConfirmation then return "BANK_TRANSFER_BUSY" end
    if ns.Merchant and ns.Merchant.IsBusy and ns.Merchant.IsBusy() then return "BANK_TRANSFER_BUSY" end
    local cursorOK, cursor = call(GetCursorInfo)
    if not cursorOK or secret(cursor) then return "BANK_TRANSFER_LOADING" end
    if cursor~=nil then return "BANK_TRANSFER_CURSOR" end
end

local function knownRecipes(key, recipeID)
    if not integer(key,1) or not ns.API or not ns.API.GetProfessions or not ns.Catalogue then return nil end
    local parent = ns.RecipeIndex and ns.RecipeIndex.parents and ns.RecipeIndex.parents[key] or key
    if ns.API.GetProfessionParentKey then parent=ns.API.GetProfessionParentKey(key) or parent end
    local found = false
    for _, p in ipairs(ns.API.GetProfessions() or {}) do
        if p.key==key or p.key==parent then found=true; break end
    end
    if not found then return nil end
    -- The displayed request shares the page's recipe source, so the page and
    -- the preview cannot disagree; a running transfer keeps the map of its
    -- click (PlanWithdrawal).
    local shown = ns.TransferRecipes and ns.TransferRecipes(key, recipeID)
    if shown then return shown end
    return ns.Catalogue.GetRecipes(parent)
end

local function itemInfo(id)
    local info = {call(C_Item and C_Item.GetItemInfo,id)}
    if not info[1] or secret(info[2]) or type(info[2])~="string" or info[2]=="" then
        if not requestedItems[id] and C_Item and C_Item.RequestLoadItemDataByID then
            requestedItems[id]=true
            call(C_Item.RequestLoadItemDataByID,id)
        end
        return nil
    end
    return info
end

function Adapter.IsComponent(id)
    if not integer(id,1) then return nil end
    local info = itemInfo(id)
    if not info then return nil end
    -- Follow the native crafting-reagent marker only (GetItemInfo result 17,
    -- +1 for pcall). An edible raw ingredient can have this marker, while a
    -- drink used by a recipe need not have it. Recipes, item class and vendor
    -- supplies never override it. Explicit recipe withdrawals use their plan.
    if secret(info[18]) or type(info[18])~="boolean" then return nil end
    return info[18]
end

local function readSlots(ids, kind, emptyContainers)
    local result = {}
    for _, bag in ipairs(ids) do
        local ok, size = call(C_Container and C_Container.GetContainerNumSlots,bag)
        if not ok or not integer(size,0,1000) or (bag==0 and size==0) then return nil end
        if size==0 then
            if kind=="bank" and emptyContainers and emptyContainers[bag] then
                -- Optional personal-bank bag positively known to be absent.
            else
                local slotOK, equipment = call(C_Container and C_Container.ContainerIDToInventoryID,bag)
                if not slotOK or not integer(equipment,1) then return nil end
                local itemOK, equipped = call(GetInventoryItemID,"player",equipment)
                if not itemOK or secret(equipped) or equipped~=nil then return nil end
            end
        else
            local freeOK, free, family = call(C_Container and C_Container.GetContainerNumFreeSlots,bag)
            if not freeOK or not integer(free,0,size) then return nil end
            local base = Enum and Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1
            if family==nil and (bag==0 or (kind=="bank" and (bag==base or bag==BANK_CONTAINER))) then family=0 end
            if not integer(family) then return nil end
            local empty = 0
            for slot=1,size do
                local infoOK, info = call(C_Container.GetContainerItemInfo,bag,slot)
                if not infoOK or secret(info) then return nil end
                local idOK, id = call(C_Container.GetContainerItemID,bag,slot)
                if not idOK or secret(id) then return nil end
                local entry = {bag=bag,slot=slot,bagFamily=family,count=0,locked=false}
                if info==nil then
                    if id~=nil then return nil end
                    empty=empty+1
                else
                    if type(info)~="table" or secret(info.itemID) or not integer(info.itemID,1)
                        or id~=info.itemID or not integer(info.stackCount,1)
                        or secret(info.isLocked) or type(info.isLocked)~="boolean" then return nil end
                    entry.itemID,entry.count,entry.locked = id,info.stackCount,info.isLocked
                    local details = itemInfo(id)
                    if details and integer(details[9],1) then entry.maxStack=details[9] end
                    local familyOK, itemFamily = call(C_Item and C_Item.GetItemFamily,id)
                    if familyOK and integer(itemFamily) then entry.itemFamily=itemFamily end
                end
                result[#result+1]=entry
            end
            if empty~=free then return nil end
        end
    end
    return result
end

function Adapter.Read()
    if not Adapter.IsOpen() then return nil,"BANK_TRANSFER_BANK_CLOSED" end
    if ns.Stock.IsBankUnverified and ns.Stock.IsBankUnverified() then return nil,"BANK_TRANSFER_LOADING" end
    local bags = ns.StockInventory and ns.StockInventory.GetBagIDs and ns.StockInventory.GetBagIDs()
    local bank, _, empty = ns.Stock.GetOpenBankContainers()
    if not bags or not bank or not C_Container then return nil,"BANK_TRANSFER_LOADING" end
    local bagSlots = readSlots(bags,"bags")
    local bankSlots = readSlots(bank,"bank",empty)
    if not bagSlots or not bankSlots or not Adapter.IsOpen() then return nil,"BANK_TRANSFER_LOADING" end
    return {bags=bagSlots,bank=bankSlots}
end

function Adapter.CanPlace(id, slot)
    if slot.itemID~=nil then return slot.itemID==id end
    if slot.bagFamily==0 then return true end
    if not integer(slot.bagFamily,1) then return false,"BANK_TRANSFER_LOADING" end
    local ok, family = call(C_Item and C_Item.GetItemFamily,id)
    if not ok or not integer(family) then return false,"BANK_TRANSFER_LOADING" end
    local mask = slot.bagFamily
    while mask>0 and family>0 do
        if mask%2==1 and family%2==1 then return true end
        mask,family=math.floor(mask/2),math.floor(family/2)
    end
    return false
end

function Adapter.PlanWithdrawal(request,snapshot,memo)
    if type(request)~="table" or not integer(request.recipeID,1) or not integer(request.quantity,1,1000) then
        return nil,"BANK_TRANSFER_INVALID_RECIPE"
    end
    -- A running transfer keeps the recipe map its click previewed (handed over
    -- at the start, else that of its first step): a scan or a closed window
    -- must not change it half-way.
    local recipes = type(memo)=="table" and memo.recipes or knownRecipes(request.professionKey, request.recipeID)
    if type(memo)=="table" then memo.recipes = recipes end
    local recipe = recipes and recipes[request.recipeID]
    if not recipe or recipe.learned==false or recipe.supported==false then return nil,"BANK_TRANSFER_INVALID_RECIPE" end
    local bags,bank = {},{}
    for _, pair in ipairs({{snapshot.bags,bags},{snapshot.bank,bank}}) do
        for _, slot in ipairs(pair[1]) do
            if slot.itemID then pair[2][slot.itemID]=(pair[2][slot.itemID] or 0)+slot.count end
        end
    end
    local limits = ns.API.RecipeLimits and ns.API.RecipeLimits(request.professionKey)
    -- The target batch may be prepared before its cooldown expires. Respect
    -- available charges for intermediate recipes when choosing between routes.
    if limits then limits=setmetatable({[request.recipeID]=math.huge},{__index=limits}) end
    local function planWith(options)
        local result = ns.Planner.Plan(recipes,bags,ns.vendorItems or {},request.recipeID,request.quantity,bank,limits,options)
        if limits and result and not result.craftable then
            for _,reason in ipairs(result.errors or {}) do
                if reason=="craft_limit" then
                    result=ns.Planner.Plan(recipes,bags,ns.vendorItems or {},request.recipeID,request.quantity,bank,nil,options)
                    break
                end
            end
        end
        return result
    end
    local plan = planWith(nil)
    if not plan or type(plan.bankWithdrawals)~="table" then return nil,"BANK_TRANSFER_INVALID_RECIPE" end
    local partial = not plan.craftable
    if partial then
        -- A batch that cannot be completed yet may still use the stock of
        -- every alternative producer: keep only those verified withdrawals.
        local exhaustive = planWith({allProducers=true})
        if exhaustive and type(exhaustive.bankWithdrawals)=="table" then
            plan = {bankWithdrawals=exhaustive.bankWithdrawals, missing=exhaustive.missing, errors=plan.errors}
        end
    end
    -- Only structural errors invalidate the request. A cycle or depth limit
    -- reached while covering a shortfall still records it in plan.missing.
    local fatal={invalid_input=true,invalid_quantity=true,unknown_or_unsupported_recipe=true,
        quantity_overflow=true,craft_limit=true}
    for _,reason in ipairs(plan.errors or {}) do
        if fatal[reason] then return nil,"BANK_TRANSFER_INVALID_RECIPE" end
    end
    -- A missing material can coexist with a verified withdrawal for this batch.
    return plan.bankWithdrawals,nil,partial
end

-- memo (optional table) receives the recipe map of this preview, so the click
-- can hand the same map to the transfer it starts.
function Adapter.Preview(request,memo)
    local snapshot,reason=Adapter.Read()
    if not snapshot then return nil,reason end
    return Adapter.PlanWithdrawal(request,snapshot,memo)
end

local function liveSlot(slot)
    local ok, value = call(C_Container and C_Container.GetContainerItemInfo,slot.bag,slot.slot)
    if not ok or secret(value) then return nil end
    if value==nil then return {count=0} end
    if type(value)~="table" or not integer(value.itemID,1) or not integer(value.stackCount,1)
        or secret(value.isLocked) or value.isLocked~=false then return nil end
    return {itemID=value.itemID,count=value.stackCount}
end

function Adapter.Move(source,destination,quantity)
    -- Asked as a deposit first, the least strict question: the direction of the
    -- move is known further down, where anything else is asked in full.
    local reason = Adapter.BlockReason("deposit")
    if reason then return false,reason end
    if type(source)~="table" or type(destination)~="table"
        or not integer(source.bag,-128) or not integer(source.slot,1)
        or not integer(destination.bag,-128) or not integer(destination.slot,1)
        or not integer(source.itemID,1) or not integer(source.count,1) then return false,"BANK_TRANSFER_FAILED" end
    if not integer(quantity,1) or quantity>source.count then return false,"BANK_TRANSFER_FAILED" end
    local bagIDs=ns.StockInventory.GetBagIDs()
    local bankIDs=ns.Stock.GetOpenBankContainers()
    if not bagIDs or not bankIDs then return false,"BANK_TRANSFER_LOADING" end
    local function area(id)
        for _,bag in ipairs(bagIDs) do if bag==id then return "bags" end end
        for _,bag in ipairs(bankIDs) do if bag==id then return "bank" end end
    end
    local sourceArea,destinationArea=area(source.bag),area(destination.bag)
    if not sourceArea or not destinationArea or sourceArea==destinationArea then return false,"BANK_TRANSFER_FAILED" end
    -- Only a move from the bags to the bank is a deposit.
    if sourceArea~="bags" then
        reason = Adapter.BlockReason()
        if reason then return false,reason end
    end
    local before, target = liveSlot(source),liveSlot(destination)
    if not before or not target or before.itemID~=source.itemID or before.count~=source.count
        or target.itemID~=destination.itemID or target.count~=destination.count then return false,"BANK_TRANSFER_LOCKED" end
    local compatible,compatibilityReason=Adapter.CanPlace(source.itemID,destination)
    if not compatible then return false,compatibilityReason or "BANK_TRANSFER_FULL" end
    if target.itemID then
        local details=itemInfo(source.itemID)
        if not details or not integer(details[9],1) then return false,"BANK_TRANSFER_LOADING" end
        if target.count+quantity>details[9] then return false,"BANK_TRANSFER_FULL" end
    end
    local ok
    if quantity==source.count then ok = call(C_Container.PickupContainerItem,source.bag,source.slot)
    else ok = call(C_Container.SplitContainerItem,source.bag,source.slot,quantity) end
    local cursorOK, kind, id = call(GetCursorInfo)
    local owned = cursorOK and not secret(kind) and not secret(id) and kind=="item" and id==source.itemID
    if not owned then return false,"BANK_TRANSFER_FAILED" end
    -- Cursor ownership never spans an event/frame: place or return immediately.
    local placed = false
    if ok and (destinationArea=="bags" or Adapter.IsOpen()) then
        -- Pickup/Split may invoke another addon's hook. Never swap a newly
        -- occupied destination, even if it matched before taking the source.
        local current = liveSlot(destination)
        if current and current.itemID==target.itemID and current.count==target.count then
            placed = call(C_Container.PickupContainerItem,destination.bag,destination.slot)
        end
    end
    local emptyOK, remains = call(GetCursorInfo)
    if placed and emptyOK and not secret(remains) and remains==nil then return true end
    local heldOK, heldKind, heldID = call(GetCursorInfo)
    if heldOK and not secret(heldKind) and not secret(heldID) and heldKind=="item" and heldID==source.itemID then
        local original = liveSlot(source)
        if original and (original.itemID==nil or original.itemID==source.itemID)
            and original.count<=before.count-quantity
            and (sourceArea=="bags" or Adapter.IsOpen()) then
            call(C_Container.PickupContainerItem,source.bag,source.slot)
        end
    end
    -- The client keeps a picked-up stack locked in its origin slot, so the
    -- branch above may not apply. ClearCursor returns this operation's stack
    -- or split part to that slot; BlockReason guaranteed an empty cursor before.
    local leftOK, leftKind, leftID = call(GetCursorInfo)
    if leftOK and not secret(leftKind) and not secret(leftID) and leftKind=="item" and leftID==source.itemID then
        call(ClearCursor)
    end
    return false,"BANK_TRANSFER_FAILED"
end

function Adapter.Now()
    local ok,value=call(GetTime)
    return ok and type(value)=="number" and not secret(value) and value or 0
end
function Adapter.Schedule(callback,delay)
    if C_Timer and C_Timer.After then C_Timer.After(delay,callback) end
end

function Adapter.MessageText(key)
    local L = ns.L
    local messages = {
        BANK_TRANSFER_BANK_CLOSED=L.BANK_TRANSFER_BANK_CLOSED,
        BANK_TRANSFER_BUSY=L.BANK_TRANSFER_BUSY,
        BANK_TRANSFER_COMBAT=L.BANK_TRANSFER_COMBAT,
        BANK_TRANSFER_CRAFTING=L.BANK_TRANSFER_CRAFTING,
        BANK_TRANSFER_WAIT_CRAFT_CONFIRMATION=L.BANK_TRANSFER_WAIT_CRAFT_CONFIRMATION,
        CRAFT_CONFIRMATION_MISSING=L.CRAFT_CONFIRMATION_MISSING,
        BANK_TRANSFER_LOADING=L.BANK_TRANSFER_LOADING,
        BANK_TRANSFER_CURSOR=L.BANK_TRANSFER_CURSOR,
        BANK_TRANSFER_FULL=L.BANK_TRANSFER_FULL,
        BANK_TRANSFER_LOCKED=L.BANK_TRANSFER_LOCKED,
        BANK_TRANSFER_UNCONFIRMED=L.BANK_TRANSFER_UNCONFIRMED,
        BANK_TRANSFER_FAILED=L.BANK_TRANSFER_FAILED,
        BANK_TRANSFER_LIST_CHANGED=L.BANK_TRANSFER_LIST_CHANGED,
        BANK_TRANSFER_DONE=L.BANK_TRANSFER_DONE,
        BANK_TRANSFER_CANCELLED=L.BANK_TRANSFER_CANCELLED,
        BANK_TRANSFER_EMPTY=L.BANK_TRANSFER_EMPTY,
        BANK_TRANSFER_INVALID_RECIPE=L.BANK_TRANSFER_INVALID_RECIPE,
        BANK_TRANSFER_UNKNOWN_ITEMS=L.BANK_TRANSFER_UNKNOWN_ITEMS,
        BANK_TRANSFER_RUNNING=L.BANK_TRANSFER_RUNNING,
        BANK_TRANSFER_READY=L.BANK_TRANSFER_READY,
        BANK_TRANSFER_PROGRESS=L.BANK_TRANSFER_PROGRESS,
    }
    return messages[key] or L.BANK_TRANSFER_FAILED
end

function Adapter.Init()
    if frame or not ns.BankTransfer or not CreateFrame then return end
    ns.BankTransfer.Configure(Adapter)
    frame=CreateFrame("Frame")
    frame:SetScript("OnEvent",function(_,event,unit)
        if event:find("UNIT_SPELLCAST",1,true) and (secret(unit) or unit~="player") then return end
        if event=="PLAYER_LOGOUT" or event=="BANKFRAME_CLOSED" then
            ns.BankTransfer.Cancel("BANK_TRANSFER_BANK_CLOSED")
        elseif event=="PLAYER_REGEN_DISABLED" then
            ns.BankTransfer.Cancel("BANK_TRANSFER_COMBAT")
        elseif event=="UNIT_SPELLCAST_START" or event=="UNIT_SPELLCAST_CHANNEL_START" then
            ns.BankTransfer.Cancel("BANK_TRANSFER_CRAFTING")
        end
        if busyTransfer() then ns.BankTransfer.Tick() end
        if ns.BankTransferUI and (event=="BANKFRAME_CLOSED" or Adapter.IsOpen()) then ns.BankTransferUI.Refresh() end
    end)
    for _,event in ipairs({"BAG_UPDATE_DELAYED","BANKFRAME_CLOSED","PLAYER_REGEN_DISABLED","PLAYER_LOGOUT",
        "UNIT_SPELLCAST_START","UNIT_SPELLCAST_CHANNEL_START","UNIT_SPELLCAST_STOP","UNIT_SPELLCAST_CHANNEL_STOP"}) do
        pcall(frame.RegisterEvent,frame,event)
    end
end
