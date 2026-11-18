local _, ns = ...
local Transfer = {}
ns.BankTransfer = Transfer

-- The adapter is the only owner of game calls. A job authorizes one direction,
-- a fixed recipe request and initial per-item ceilings. Every move is checked
-- against fresh slots and must be acknowledged at both ends before another.
local adapter, active, listener, pumping
local last = {phase="idle", moved=0, movedStacks=0, skippedUnknown=0}
local MAX_INTEGER, TIMEOUT, POLL = 2147483647, 3, 0.10
local PREFIX = "BANK_TRANSFER_"

local function integer(value, minimum)
    return type(value)=="number" and value==value and value>=minimum
        and value<=MAX_INTEGER and value==math.floor(value)
end

local function requestCopy(request)
    if not request then return nil end
    return {professionKey=request.professionKey, recipeID=request.recipeID, quantity=request.quantity}
end

local function stateCopy(state)
    local result = {}
    for key, value in pairs(state) do result[key] = key=="request" and requestCopy(value) or value end
    return result
end

function Transfer.GetState() return stateCopy(last) end
function Transfer.IsBusy() return active ~= nil end

local function notify(job, phase, reason)
    last = {phase=phase, messageKey=reason, moved=job and job.moved or 0,
        movedStacks=job and job.movedStacks or 0, skippedUnknown=job and job.skippedUnknown or 0,
        mode=job and job.mode or nil, request=job and requestCopy(job.request) or nil}
    if listener then pcall(listener, stateCopy(last)) end
end

function Transfer.SetListener(callback)
    listener = type(callback)=="function" and callback or nil
    if listener then pcall(listener, stateCopy(last)) end
end

local function call(name, ...)
    if not adapter or type(adapter[name])~="function" then return false end
    return pcall(adapter[name], ...)
end

local function now()
    local ok, value = call("Now")
    return ok and type(value)=="number" and value==value and value>=0 and value<math.huge and value or nil
end

local function finish(job, reason, phase)
    if active~=job then return end
    active = nil
    notify(job, phase or "error", reason)
end

local function schedule(job)
    if active~=job or job.scheduled then return end
    job.scheduled = true
    local ok = call("Schedule", function()
        job.scheduled = false
        if active==job then Transfer.Tick() end
    end, POLL)
    if not ok then
        job.scheduled = false
        finish(job, PREFIX..(job.pending and "UNCONFIRMED" or "FAILED"))
    end
end

local function positionKey(slot) return tostring(slot.bag)..":"..tostring(slot.slot) end

local function validate(snapshot)
    if type(snapshot)~="table" or type(snapshot.bags)~="table" or type(snapshot.bank)~="table" then return nil end
    local positions = {}
    for _, slots in ipairs({snapshot.bags,snapshot.bank}) do
        local count = 0
        for key in pairs(slots) do
            if not integer(key,1) then return nil end
            count = count+1
        end
        for index=1,count do
            local slot = slots[index]
            if type(slot)~="table" or not integer(slot.bag,-128) or not integer(slot.slot,1)
                or not integer(slot.count,0) or type(slot.locked)~="boolean" then return nil end
            if slot.count==0 then
                if slot.itemID~=nil then return nil end
            elseif not integer(slot.itemID,1) then return nil end
            if slot.maxStack~=nil and not integer(slot.maxStack,1) then return nil end
            if slot.bagFamily~=nil and not integer(slot.bagFamily,0) then return nil end
            local key = positionKey(slot)
            if positions[key] then return nil end
            positions[key] = slot
        end
    end
    return positions
end

local function slotCopy(slot)
    return {bag=slot.bag,slot=slot.slot,itemID=slot.itemID,count=slot.count,
        bagFamily=slot.bagFamily,itemFamily=slot.itemFamily,maxStack=slot.maxStack,locked=slot.locked}
end

local function genericRank(slot)
    if slot.bagFamily==0 then return 0 end
    if slot.bagFamily and slot.bagFamily>0 then return 1 end
    return 2
end

local function sourceOrder(mode, slots)
    local result = {}
    for _, slot in ipairs(slots) do if slot.count>0 then result[#result+1]=slot end end
    table.sort(result, function(a,b)
        if mode=="deposit" and genericRank(a)~=genericRank(b) then return genericRank(a)<genericRank(b) end
        if a.bag~=b.bag then return a.bag<b.bag end
        return a.slot<b.slot
    end)
    return result
end

local function initialTargets(job, snapshot)
    if job.mode=="withdraw_recipe" then
        local ok, targets, reason = call("PlanWithdrawal",requestCopy(job.request),snapshot)
        if not ok or type(targets)~="table" then return nil, type(reason)=="string" and reason or PREFIX.."INVALID_RECIPE" end
        local result = {}
        for id, quantity in pairs(targets) do
            if not integer(id,1) or not integer(quantity,0) then return nil, PREFIX.."INVALID_RECIPE" end
            if quantity>0 then result[id]=quantity end
        end
        return result
    end
    local result = {}
    local sources = job.mode=="deposit" and snapshot.bags or snapshot.bank
    for _, slot in ipairs(sources) do
        if slot.count>0 then
            local ok, component = call("IsComponent",slot.itemID)
            if ok and component==true then
                result[slot.itemID] = (result[slot.itemID] or 0)+slot.count
                if not integer(result[slot.itemID],1) then return nil, PREFIX.."FAILED" end
            elseif not ok or component~=false then
                job.skippedUnknown=job.skippedUnknown+1
            end
        end
    end
    return result
end

local function currentTargets(job, snapshot)
    if job.mode~="withdraw_recipe" then return job.remaining end
    local targets, reason = initialTargets(job,snapshot)
    if not targets then return nil,reason end
    local result, unapproved = {},false
    for id, quantity in pairs(targets) do
        local ceiling = job.remaining[id] or 0
        if quantity>0 and ceiling==0 then unapproved=true end
        if ceiling>0 then result[id]=math.min(ceiling,quantity) end
    end
    return result,nil,unapproved
end

local function destination(source, desired, slots)
    local choices, unknown, locked = {},false,false
    for _, slot in ipairs(slots) do
        if slot.itemID==nil or slot.itemID==source.itemID then
            local capacity
            if slot.itemID==nil then
                capacity=source.maxStack or source.count
            else
                local max=slot.maxStack or source.maxStack
                if max then capacity=max-slot.count else unknown=true end
            end
            if capacity and capacity>0 then
                if slot.locked then
                    locked=true
                else
                    local ok, compatible, reason = call("CanPlace",source.itemID,slot)
                    if ok and compatible==true then
                        choices[#choices+1]={slot=slot,quantity=math.min(desired,source.count,capacity)}
                    elseif not ok or compatible~=false or reason==PREFIX.."LOADING" then
                        unknown=true
                    elseif reason==PREFIX.."LOCKED" then
                        locked=true
                    end
                end
            end
        end
    end
    table.sort(choices,function(a,b)
        local am,bm=a.slot.itemID~=nil,b.slot.itemID~=nil
        if am~=bm then return am end -- Merge before occupying another slot.
        local ar,br=genericRank(a.slot),genericRank(b.slot)
        -- Specialty storage keeps general-purpose space available.
        if ar~=br then return ar==1 or (ar==0 and br==2) end
        if a.slot.bag~=b.slot.bag then return a.slot.bag<b.slot.bag end
        return a.slot.slot<b.slot.slot
    end)
    return choices[1],unknown,locked
end

local function acknowledged(pending, positions)
    local source,dest=positions[pending.sourceKey],positions[pending.destinationKey]
    if not source or not dest then return false end
    local left=pending.sourceCount-pending.quantity
    local sourceMatches=left==0 and source.count==0 and source.itemID==nil
        or left>0 and source.itemID==pending.itemID and source.count==left
    return sourceMatches and dest.itemID==pending.itemID and dest.count==pending.destinationCount+pending.quantity
end

local function noMore(job)
    local reason=job.skippedUnknown>0 and PREFIX.."UNKNOWN_ITEMS"
        or (job.moved>0 and PREFIX.."DONE" or PREFIX.."EMPTY")
    finish(job,reason,"completed")
end

local function waitForRead(job, time, reason)
    if active~=job then return end
    job.waitStarted=job.waitStarted or time
    if time-job.waitStarted>=TIMEOUT then finish(job,reason or PREFIX.."LOADING")
    else notify(job,job.pending and "awaiting" or "running",reason or PREFIX.."LOADING"); schedule(job) end
end

local function step(job)
    local time=now()
    if not time then finish(job,PREFIX.."FAILED"); return end
    local openOK,open=call("IsOpen")
    local blockedOK,blocked=call("BlockReason")
    if active~=job then return end
    local stopReason
    if not openOK or open~=true then stopReason=PREFIX.."BANK_CLOSED" end
    if not stopReason and (not blockedOK or blocked) then stopReason=type(blocked)=="string" and blocked or PREFIX.."BUSY" end
    if stopReason then
        if not job.pending then finish(job,stopReason,"stopped"); return end
        job.cancelReason=job.cancelReason or stopReason
        if time-job.pending.sentAt>=TIMEOUT then finish(job,PREFIX.."UNCONFIRMED"); return end
        notify(job,"cancelling",job.cancelReason); schedule(job); return
    end
    local readOK,snapshot,readReason=call("Read")
    if active~=job then return end
    local positions=readOK and validate(snapshot) or nil
    if not positions then
        if job.pending and time-job.pending.sentAt>=TIMEOUT then finish(job,PREFIX.."UNCONFIRMED"); return end
        waitForRead(job,time,type(readReason)=="string" and readReason or PREFIX.."LOADING"); return
    end
    if job.pending then
        if not acknowledged(job.pending,positions) then
            if time-job.pending.sentAt>=TIMEOUT then finish(job,PREFIX.."UNCONFIRMED")
            else notify(job,job.cancelReason and "cancelling" or "awaiting",job.cancelReason or PREFIX.."BUSY"); schedule(job) end
            return
        end
        local pending=job.pending
        job.remaining[pending.itemID]=(job.remaining[pending.itemID] or 0)-pending.quantity
        job.moved=job.moved+pending.quantity
        job.movedStacks=job.movedStacks+1
        job.pending=nil
        job.waitStarted=nil
        if job.cancelReason then finish(job,job.cancelReason,"stopped"); return end
    end
    if not job.remaining then
        local targets,reason=initialTargets(job,snapshot)
        if active~=job then return end
        if not targets then finish(job,reason); return end
        job.remaining=targets
    end
    local targets,planReason,unapproved=currentTargets(job,snapshot)
    if active~=job then return end
    if not targets then finish(job,planReason); return end
    local sources=job.mode=="deposit" and snapshot.bags or snapshot.bank
    local destinations=job.mode=="deposit" and snapshot.bank or snapshot.bags
    local eligible,unknown,locked,classificationChanged=false,false,false,false
    for _, source in ipairs(sourceOrder(job.mode,sources)) do
        local desired=targets[source.itemID] or 0
        if desired>0 then
            eligible=true
            if source.locked then
                locked=true
            else
                local component=true
                if job.mode~="withdraw_recipe" then
                    local ok,value=call("IsComponent",source.itemID)
                    if active~=job then return end
                    component=ok and value==true
                    if not ok or value~=true and value~=false then unknown=true end
                    if ok and value==false then classificationChanged=true end
                end
                if component then
                    local choice,u,l=destination(source,desired,destinations)
                    if active~=job then return end
                    unknown,locked=unknown or u,locked or l
                    if choice then
                        -- BlockReason can change while the adapter builds a plan.
                        local stillOpenOK,stillOpen=call("IsOpen")
                        local guardOK,guard=call("BlockReason")
                        if active~=job then return end
                        if not stillOpenOK or stillOpen~=true then finish(job,PREFIX.."BANK_CLOSED","stopped"); return end
                        if not guardOK or guard then finish(job,type(guard)=="string" and guard or PREFIX.."BUSY","stopped"); return end
                        local sentAt=now()
                        if active~=job then return end
                        if not sentAt then finish(job,PREFIX.."FAILED"); return end
                        local pending={sourceKey=positionKey(source),destinationKey=positionKey(choice.slot),
                            itemID=source.itemID,sourceCount=source.count,destinationCount=choice.slot.count,
                            quantity=choice.quantity,sentAt=sentAt}
                        job.pending=pending
                        job.waitStarted=nil
                        local moveOK,moved,reason=call("Move",slotCopy(source),slotCopy(choice.slot),choice.quantity)
                        if not moveOK or moved~=true then
                            job.pending=nil
                            finish(job,type(reason)=="string" and reason or PREFIX.."FAILED"); return
                        end
                        notify(job,job.cancelReason and "cancelling" or "awaiting",job.cancelReason or PREFIX.."BUSY")
                        schedule(job); return
                    end
                end
            end
        end
    end
    if not eligible then
        if unapproved then finish(job,PREFIX.."FAILED") else noMore(job) end
    elseif unknown then waitForRead(job,time,PREFIX.."LOADING")
    elseif locked then waitForRead(job,time,PREFIX.."LOCKED")
    elseif classificationChanged then finish(job,PREFIX.."FAILED")
    else finish(job,PREFIX.."FULL") end
end

function Transfer.Tick()
    if pumping or not active then return end
    pumping=true
    local job=active
    local ok=pcall(step,job)
    pumping=false
    if not ok and active==job then finish(job,PREFIX..(job.pending and "UNCONFIRMED" or "FAILED")) end
end

function Transfer.Configure(value)
    if active or pumping then return false,PREFIX.."BUSY" end
    if type(value)~="table" then return false,PREFIX.."FAILED" end
    for _, name in ipairs({"IsOpen","BlockReason","Read","IsComponent","CanPlace","Move","Now","Schedule"}) do
        if type(value[name])~="function" then return false,PREFIX.."FAILED" end
    end
    adapter=value
    notify(nil,"idle",nil)
    return true
end

function Transfer.Start(mode,request)
    if active or pumping then return false,PREFIX.."BUSY" end
    if not adapter then return false,PREFIX.."FAILED" end
    if mode~="deposit" and mode~="withdraw_all" and mode~="withdraw_recipe" then return false,PREFIX.."FAILED" end
    if mode=="withdraw_recipe" and (type(request)~="table" or not integer(request.professionKey,1)
        or not integer(request.recipeID,1) or not integer(request.quantity,1)) then
        notify(nil,"error",PREFIX.."INVALID_RECIPE")
        return false,PREFIX.."INVALID_RECIPE"
    end
    local ok,open=call("IsOpen")
    if not ok or open~=true then notify(nil,"stopped",PREFIX.."BANK_CLOSED"); return false,PREFIX.."BANK_CLOSED" end
    local guardOK,guard=call("BlockReason")
    if not guardOK or guard then
        local reason=type(guard)=="string" and guard or PREFIX.."BUSY"
        notify(nil,"stopped",reason); return false,reason
    end
    local job={mode=mode,request=mode=="withdraw_recipe" and requestCopy(request) or nil,
        moved=0,movedStacks=0,skippedUnknown=0}
    active=job
    notify(job,"running",PREFIX.."LOADING")
    if active==job then Transfer.Tick() end
    return true
end

function Transfer.Cancel(reason)
    local job=active
    if not job then return false end
    reason=type(reason)=="string" and reason or PREFIX.."CANCELLED"
    if job.pending then
        job.cancelReason=job.cancelReason or reason
        notify(job,"cancelling",job.cancelReason)
        schedule(job)
    else
        finish(job,reason,"stopped")
    end
    return true
end
