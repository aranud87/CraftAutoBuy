local _, ns = ...
local L = ns.L
local UI = {}
ns.BankTransferUI = UI

local deposit, observer, listenerBound, rendering, updating, updateAgain, contextChanging
local forcedClosed, wasOpen, combatEvent, castingEvent = false, false, false, false
local previewDirty, previewKey, previewText, previewReason, previewEmpty = true, nil, nil, nil, true
local previewPartial, previewTargets, previewRecipes
local refreshDependents
local previewRetry, clock, lastContext, guardToken, awaitingFeedback = 0, 0, nil, nil, false

local function secret(value) return issecretvalue and issecretvalue(value) end
local function text(value)
    return not secret(value) and type(value)=="string" and value~="" and value or nil
end
local function integer(value, maximum)
    return not secret(value) and type(value)=="number" and value>=1
        and value<=(maximum or 2147483647) and value==math.floor(value)
end
local function requestCopy(request)
    if secret(request) or type(request)~="table" or not integer(request.professionKey)
        or not integer(request.recipeID) or not integer(request.quantity,1000) then return nil end
    return {professionKey=request.professionKey,recipeID=request.recipeID,quantity=request.quantity}
end
local function sameRequest(a,b)
    return a and b and a.professionKey==b.professionKey and a.recipeID==b.recipeID and a.quantity==b.quantity
end
local function requestKey(request)
    return request and request.professionKey..":"..request.recipeID..":"..request.quantity or ""
end
local function currentRequest()
    local job=ns.job
    if type(job)=="table" and not secret(job) then
        return requestCopy({professionKey=job.professionKey,recipeID=job.recipeID,quantity=job.remaining})
    end
    return requestCopy({professionKey=ns.selectedProfessionKey or ns.professionKey,
        recipeID=ns.selectedID,quantity=ns.quantity or 1})
end
local function engineState()
    local engine=ns.BankTransfer
    return engine and type(engine.GetState)=="function" and engine.GetState() or {}
end
local function busy()
    return ns.BankTransfer and type(ns.BankTransfer.IsBusy)=="function" and ns.BankTransfer.IsBusy()==true
end
local function stop(reason)
    if busy() and engineState().phase~="cancelling" and type(ns.BankTransfer.Cancel)=="function" then
        return ns.BankTransfer.Cancel(reason)
    end
    return false
end
local function personalOpen()
    if forcedClosed then return false end
    local api=ns.BankTransferAPI
    local fn=api and api.IsOpen or ns.Stock and ns.Stock.IsBankOpen
    if type(fn)~="function" then return false end
    local ok,value=pcall(fn)
    return ok and not secret(value) and value==true
end
local function blockReason(mode)
    if not personalOpen() then return "BANK_TRANSFER_BANK_CLOSED" end
    if combatEvent then return "BANK_TRANSFER_COMBAT" end
    if castingEvent then return "BANK_TRANSFER_CRAFTING" end
    local fn=ns.BankTransferAPI and ns.BankTransferAPI.BlockReason
    if type(fn)~="function" then return "BANK_TRANSFER_LOADING" end
    local ok,reason=pcall(fn,mode)
    return ok and text(reason) or (not ok and "BANK_TRANSFER_LOADING" or nil)
end
local function message(key)
    if not key then return "" end
    local fn=ns.BankTransferAPI and ns.BankTransferAPI.MessageText
    if type(fn)=="function" then
        local ok,value=pcall(fn,key)
        if ok and text(value) then return value end
    end
    return text(L[key]) or ""
end
local function count(value)
    return not secret(value) and type(value)=="number" and value>=0 and value<math.huge and math.floor(value) or 0
end
local function formatted(key,value)
    local ok,result=pcall(string.format,text(L[key]) or "",count(value))
    return ok and result or ""
end
-- One moved item has its own sentence; a pack without it keeps the counted form.
local function movedText(value)
    local one=count(value)==1 and text(L.BANK_TRANSFER_PROGRESS_ONE)
    if one and one:find("%d",1,true) then return formatted("BANK_TRANSFER_PROGRESS_ONE",value) end
    return formatted("BANK_TRANSFER_PROGRESS",value)
end
local function append(lines,value)
    if text(value) then lines[#lines+1]=value end
end
local function progress(state)
    local lines={}
    local key=state.messageKey
    if busy() and state.phase~="cancelling" and (key=="BANK_TRANSFER_BUSY" or key=="BANK_TRANSFER_LOADING") then
        key="BANK_TRANSFER_RUNNING"
    elseif key=="BANK_TRANSFER_UNKNOWN_ITEMS" then
        key=count(state.moved)>0 and "BANK_TRANSFER_DONE" or "BANK_TRANSFER_EMPTY"
    end
    -- A recipe withdrawal that still leaves components missing is not "finished".
    if key=="BANK_TRANSFER_DONE" and state.mode=="withdraw_recipe" and state.partial==true then
        append(lines,L.BANK_TRANSFER_PARTIAL_HINT)
    else append(lines,message(key)) end
    if count(state.moved)>0 or busy() then append(lines,movedText(state.moved)) end
    if count(state.skippedUnknown)>0 then append(lines,formatted("BANK_TRANSFER_UNKNOWN_ITEMS",state.skippedUnknown)) end
    return table.concat(lines,"\n")
end
local function preview(request,fresh)
    local key=requestKey(request)
    if fresh or previewDirty or key~=previewKey or (previewReason=="BANK_TRANSFER_LOADING" and clock>=previewRetry) then
        previewKey,previewDirty,previewText,previewReason,previewEmpty=key,false,nil,nil,true
        previewTargets,previewRecipes=nil,nil
        local fn=ns.BankTransferAPI and ns.BankTransferAPI.Preview
        local ok,targets,reason,partial=false,nil,"BANK_TRANSFER_LOADING",false
        local memo={}
        if type(fn)=="function" then ok,targets,reason,partial=pcall(fn,requestCopy(request),memo) end
        previewPartial=partial==true
        if not ok or secret(targets) or type(targets)~="table" then
            previewReason=text(reason) or "BANK_TRANSFER_LOADING"
        else
            -- What the button announces: the click may not exceed it.
            local shown={}
            for id,quantity in pairs(targets) do
                if integer(id) and integer(quantity) then previewEmpty=false;shown[id]=quantity end
            end
            if not previewEmpty then previewTargets,previewRecipes=shown,memo.recipes end
            if not previewEmpty and ns.Bank and type(ns.Bank.Message)=="function" then
                local read,value=pcall(ns.Bank.Message,{bankWithdrawals=targets})
                if read then previewText=text(value) end
            end
            if not previewEmpty then previewText=previewText or L.BANK_TRANSFER_RECIPE_HINT end
        end
        previewRetry=clock+1
    end
    return previewText,previewReason,previewEmpty
end

-- The craft tab supplies its visible recipe and committed quantity. This
-- module never keeps a separate recipe selection or launches work on render.
function UI.GetRecipeState(request)
    request=requestCopy(request)
    if not request or not sameRequest(request,currentRequest()) then return {visible=false,enabled=false} end
    local result={visible=true,enabled=false,text=L.BANK_TRANSFER_RETRIEVE}
    if not personalOpen() then
        result.text,result.tooltip=L.BANK_TRANSFER_CLOSED_LABEL,message("BANK_TRANSFER_BANK_CLOSED")
        return result
    end
    local state=engineState()
    if busy() then
        local matching=state.mode=="withdraw_recipe" and sameRequest(request,state.request)
        result.text=matching and L.BANK_TRANSFER_STOP or L.BANK_TRANSFER_RUNNING
        result.enabled=matching and state.phase~="cancelling"
        result.tooltip=progress(state)
        result.status=movedText(state.moved)
        result.statusDetail=result.tooltip
        return result
    end
    local reason=blockReason()
    if reason then result.tooltip=message(reason);return result end
    local details,why,empty=preview(request)
    if why then result.tooltip=message(why);return result end
    result.enabled=not empty
    -- The list this render announces: the click may not exceed it.
    if not empty and previewTargets then
        result.targets={}
        for id,quantity in pairs(previewTargets) do result.targets[id]=quantity end
    end
    local lines={}
    append(lines,L.BANK_TRANSFER_RECIPE_HINT)
    append(lines,empty and message("BANK_TRANSFER_EMPTY") or details)
    if previewPartial and not empty then append(lines,L.BANK_TRANSFER_PARTIAL_HINT) end
    result.tooltip=table.concat(lines,"\n\n")
    return result
end

-- announced (optional): the per-item list the button showed before the click
-- handler repainted. Without it the click only follows its own live re-read.
function UI.WithdrawRecipe(request,announced)
    request=requestCopy(request)
    if not request or not sameRequest(request,currentRequest()) then return false,"BANK_TRANSFER_INVALID_RECIPE" end
    if not personalOpen() then return false,"BANK_TRANSFER_BANK_CLOSED" end
    if busy() then
        local state=engineState()
        if state.mode=="withdraw_recipe" and sameRequest(request,state.request) then
            return stop("BANK_TRANSFER_CANCELLED")
        end
        return false,"BANK_TRANSFER_BUSY"
    end
    local reason=blockReason()
    if reason then return false,reason end
    -- Render previews are advisory. Re-read the live slots at the click.
    local _,why,empty=preview(request,true)
    if why or empty or not previewTargets then return false,why or "BANK_TRANSFER_EMPTY" end
    if not sameRequest(request,currentRequest()) then return false,"BANK_TRANSFER_INVALID_RECIPE" end
    reason=blockReason()
    if reason then return false,reason end
    -- The click authorizes what the button announced. A new item or a larger
    -- quantity is displayed first and needs its own click; a shorter list is
    -- applied at once.
    if type(announced)=="table" then
        for id,quantity in pairs(previewTargets) do
            local shown=announced[id]
            if not integer(shown) or quantity>shown then
                if ns.Print then ns.Print(L.BANK_TRANSFER_LIST_CHANGED) end
                refreshDependents()
                return false,"BANK_TRANSFER_LIST_CHANGED"
            end
        end
    end
    local transfer=ns.BankTransfer
    if not transfer or type(transfer.Start)~="function" then return false,"BANK_TRANSFER_LOADING" end
    -- The engine gets the ceilings and the recipe map now: a late first read
    -- of the slots, a scan or a stock change cannot enlarge this batch.
    local approval={targets={},recipes=previewRecipes}
    for id,quantity in pairs(previewTargets) do approval.targets[id]=quantity end
    return transfer.Start("withdraw_recipe",request,approval)
end

function UI.OnContextChanged()
    if contextChanging then return end
    contextChanging=true
    local request=currentRequest()
    -- The preview follows Core's recipe source: a scan, a closed profession
    -- window or a project replaces it without any bank or bag event.
    local key=requestKey(request)..":"..tostring(ns.recipeRevision)..":"..tostring(ns.job)
    if key~=lastContext then lastContext=key;previewDirty=true end
    local state=engineState()
    if busy() and state.mode=="withdraw_recipe" and not sameRequest(request,state.request) then
        stop("BANK_TRANSFER_CANCELLED")
    end
    contextChanging=false
end

local function showTooltip(button)
    if not GameTooltip or not text(button.help) then return end
    GameTooltip:SetOwner(button,"ANCHOR_RIGHT")
    GameTooltip:SetText(L.BANK_TRANSFER_TITLE)
    GameTooltip:AddLine(button:GetText(),1,.82,0,true)
    GameTooltip:AddLine(button.help,1,1,1,true)
    GameTooltip:Show()
end
local function depositClick()
    if not personalOpen() then return false end
    if busy() then
        if engineState().mode=="deposit" then return stop("BANK_TRANSFER_CANCELLED") end
        return false
    end
    local reason=blockReason("deposit")
    if reason then UI.Refresh();return false end
    local transfer=ns.BankTransfer
    if not transfer or type(transfer.Start)~="function" then return false end
    local ok,why=transfer.Start("deposit")
    if not ok and why and ns.Print then ns.Print(message(why)) end
    UI.Refresh()
    return ok
end
local function createDeposit()
    if not BankFrame or type(CreateFrame)~="function" then return end
    local search=BankFrame.BankItemSearchBox or BankFrame.SearchBox or BankItemSearchBox
    if not search or not search.IsShown or not search:IsShown() then return end
    if not deposit then
        deposit=CreateFrame("Button","CraftAutoBuyBankTransferDeposit",BankFrame,"UIPanelButtonTemplate")
        deposit:SetSize(180,22)
        if GameFontNormalSmall then deposit:SetNormalFontObject(GameFontNormalSmall) end
        if GameFontHighlightSmall then deposit:SetHighlightFontObject(GameFontHighlightSmall) end
        if GameFontDisableSmall then deposit:SetDisabledFontObject(GameFontDisableSmall) end
        if ns.UI and ns.UI.ConstrainButtonText then ns.UI.ConstrainButtonText(deposit,180) end
        deposit:SetScript("OnClick",depositClick)
        deposit:SetScript("OnEnter",showTooltip)
        deposit:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    end
    if deposit:GetParent()~=BankFrame then deposit:SetParent(BankFrame) end
    deposit:ClearAllPoints()
    -- Camelot inherits BankItemSearchBox from BankFrameTemplate; some bank
    -- replacements retain the older SearchBox parent key instead.
    deposit:SetPoint("RIGHT",search,"LEFT",-8,0)
    return search
end

function UI.Refresh()
    if rendering then return end
    rendering=true
    local open=personalOpen()
    local previouslyOpen=wasOpen
    wasOpen=open
    if not open then
        previewDirty=true
        if deposit then deposit:Hide() end
        if previouslyOpen then stop("BANK_TRANSFER_BANK_CLOSED") end
        rendering=false
        return
    end
    local reason=blockReason("deposit")
    -- No replacement window: the deposit control belongs to the native bank.
    local search=BankFrame and BankFrame:IsShown() and createDeposit()
    if not search then if deposit then deposit:Hide() end;rendering=false;return end
    local state=engineState()
    local running=busy()
    local ownJob=running and state.mode=="deposit"
    deposit:SetText(ownJob and L.BANK_TRANSFER_STOP or L.BANK_TRANSFER_DEPOSIT)
    deposit:SetEnabled(running and ownJob and state.phase~="cancelling" or not running and not reason)
    local lines={}
    append(lines,L.BANK_TRANSFER_COMPONENT_SCOPE)
    if reason then append(lines,message(reason))
    elseif running or (state.mode=="deposit" and state.messageKey~="BANK_TRANSFER_BANK_CLOSED") then
        append(lines,progress(state))
    else append(lines,message("BANK_TRANSFER_READY")) end
    deposit.help=table.concat(lines,"\n\n")
    deposit:Show()
    if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(deposit) then showTooltip(deposit) end
    rendering=false
end

refreshDependents=function()
    if updating then updateAgain=true;return end
    updating=true
    local ok,why=pcall(function()
        repeat
            updateAgain=false
            UI.Refresh()
            if type(ns.Refresh)=="function" then ns.Refresh()
            else
                if ns.NativeCraft and type(ns.NativeCraft.Refresh)=="function" then ns.NativeCraft.Refresh() end
                if ns.catalogueActive and ns.UI and type(ns.UI.Render)=="function" then ns.UI.Render() end
            end
        until not updateAgain
    end)
    updating=false
    if not ok then error(why) end
end
local function transferChanged(state)
    previewDirty=true
    state=type(state)=="table" and state or engineState()
    if state.phase=="running" or state.phase=="awaiting" or state.phase=="cancelling" then awaitingFeedback=true
    elseif awaitingFeedback then
        awaitingFeedback=false
        local value=progress(state)
        -- A finished recipe withdrawal says what the page still asks for:
        -- the rest waits for a new click.
        if state.mode=="withdraw_recipe" and state.phase=="completed"
            and (state.messageKey=="BANK_TRANSFER_DONE" or state.messageKey=="BANK_TRANSFER_EMPTY") then
            local request=requestCopy(state.request)
            if request and sameRequest(request,currentRequest()) and not blockReason() then
                local rest,why,empty=preview(request,true)
                if not why and not empty and text(rest) then
                    value=rest
                    if count(state.moved)>0 then value=movedText(state.moved).."\n"..rest end
                    if previewPartial then value=value.."\n"..L.BANK_TRANSFER_PARTIAL_HINT end
                end
            end
        end
        if text(value) and ns.Print then ns.Print(value) end
    end
    refreshDependents()
end

function UI.Init()
    if not observer and type(CreateFrame)=="function" then
        observer=CreateFrame("Frame")
        for _,event in ipairs({"BANKFRAME_OPENED","BANKFRAME_CLOSED","PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
            "PLAYER_INTERACTION_MANAGER_FRAME_HIDE","BAG_UPDATE","BAG_UPDATE_DELAYED","BANK_TABS_CHANGED",
            "PLAYERBANKSLOTS_CHANGED","PLAYERBANKBAGSLOTS_CHANGED","GET_ITEM_INFO_RECEIVED",
            "TRADE_SKILL_LIST_UPDATE","SPELL_UPDATE_COOLDOWN","PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED","PLAYER_LOGIN",
            "UNIT_SPELLCAST_START","UNIT_SPELLCAST_CHANNEL_START","UNIT_SPELLCAST_STOP",
            "UNIT_SPELLCAST_CHANNEL_STOP","UNIT_SPELLCAST_FAILED","UNIT_SPELLCAST_INTERRUPTED"}) do
            pcall(observer.RegisterEvent,observer,event)
        end
        observer:SetScript("OnEvent",function(_,event,arg)
            if event:find("UNIT_SPELLCAST",1,true) and (secret(arg) or arg~="player") then return end
            previewDirty=true
            if event=="BANKFRAME_CLOSED" then forcedClosed=true;stop("BANK_TRANSFER_BANK_CLOSED")
            elseif event=="BANKFRAME_OPENED" then forcedClosed=false
            elseif event=="PLAYER_REGEN_DISABLED" then combatEvent=true;stop("BANK_TRANSFER_COMBAT")
            elseif event=="PLAYER_REGEN_ENABLED" then combatEvent=false
            elseif event=="UNIT_SPELLCAST_START" or event=="UNIT_SPELLCAST_CHANNEL_START" then
                castingEvent=true;stop("BANK_TRANSFER_CRAFTING")
            elseif event:find("UNIT_SPELLCAST",1,true) then castingEvent=false
            elseif event=="PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event=="PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
                local kinds=Enum and Enum.PlayerInteractionType
                if not kinds or secret(arg) or arg==nil or (arg~=kinds.Banker and arg~=kinds.CharacterBanker) then return end
                forcedClosed=event=="PLAYER_INTERACTION_MANAGER_FRAME_HIDE"
                if forcedClosed then stop("BANK_TRANSFER_BANK_CLOSED") end
            end
            if event=="BAG_UPDATE" or not (wasOpen or personalOpen() or busy()) then return end
            refreshDependents()
        end)
        local elapsed=0
        observer:SetScript("OnUpdate",function(_,delta)
            clock=clock+delta
            elapsed=elapsed+delta
            if elapsed<.2 then return end
            elapsed=0
            local open=personalOpen()
            if not open and not wasOpen and not busy() then guardToken=nil;return end
            local reason=blockReason()
            local token=tostring(open)..":"..tostring(reason)..":"..requestKey(currentRequest())
            if token~=guardToken then guardToken=token;refreshDependents()
            elseif open and not reason and previewReason=="BANK_TRANSFER_LOADING" and clock>=previewRetry
                and previewKey==requestKey(currentRequest()) then
                -- A data request need not emit an inventory event. Retry the
                -- displayed preview, with a one-second ceiling even if CAB
                -- is hidden and its render does not read this cache.
                previewRetry,previewDirty=clock+1,true
                refreshDependents()
            elseif wasOpen or personalOpen() then UI.Refresh() end
        end)
    end
    if not listenerBound and ns.BankTransfer and type(ns.BankTransfer.SetListener)=="function" then
        listenerBound=true
        ns.BankTransfer.SetListener(transferChanged)
    end
    UI.Refresh()
end
