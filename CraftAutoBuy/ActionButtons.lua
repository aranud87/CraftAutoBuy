local _, ns = ...
local ActionButtons = {}
ns.ActionButtons = ActionButtons

-- Use the selected number of crafts, including the remaining target of a
-- paused project, rather than the recipe's yield or the possible maximum.
function ActionButtons.CraftText(quantity)
    return ns.L.ACTION_CRAFT .. " × " .. tostring(quantity or 1)
end

-- The button inherits InsecureActionButtonTemplate (Forever's supported macro
-- actions outside combat). Keep its native OnClick; hooks only manage CAB state.
function ActionButtons.BindCancel(button)
    if not button or button.cabCancelBound then return button ~= nil end
    button.cabCancelBound = true
    button:SetAttribute("type", "macro")
    button:SetAttribute("useOnKeyDown", false)
    button:SetAttribute("macrotext", "")
    button:RegisterForClicks("LeftButtonUp")
    button:HookScript("PreClick", function(self)
        self:SetAttribute("macrotext", "")
        self.cabCancelContext = nil
        if (self.IsShown and not self:IsShown()) or (self.IsVisible and not self:IsVisible())
            or (ns.InCombat and ns.InCombat()) or (InCombatLockdown and InCombatLockdown()) then return end
        local job = ns.job
        local context = {job = job, pendingStart = ns.pendingStart, confirmation = ns.bankConfirmation,
            active = job ~= nil or ns.pendingStart ~= nil or ns.bankConfirmation ~= nil
                or (ns.Merchant and ns.Merchant.IsBusy and ns.Merchant.IsBusy()),
            stopRequested = false}
        self.cabCancelContext = context
        local pending = job and job.pending
        if pending and ns.API and ns.API.CanStopCraft then
            local ok, eligible = pcall(ns.API.CanStopCraft, pending.recipeID)
            if ok and eligible == true then
                self:SetAttribute("macrotext", "/stopcasting")
                context.stopRequested = true
            end
        end
    end)
    button:HookScript("PostClick", function(self)
        local context = self.cabCancelContext
        self.cabCancelContext = nil
        self:SetAttribute("macrotext", "")
        if not context or not context.active or ns.job ~= context.job
            or ns.pendingStart ~= context.pendingStart or ns.bankConfirmation ~= context.confirmation then return end
        ns.Cancel(context.stopRequested)
    end)
    return true
end

local function positiveID(value)
    return type(value) == "number" and not (issecretvalue and issecretvalue(value))
        and value > 0 and value < math.huge and value == math.floor(value)
end

local function professionClickAvailable()
    return not (ns.InCombat and ns.InCombat()) and not (InCombatLockdown and InCombatLockdown())
        and not ns.job and not ns.pendingStart and not ns.bankConfirmation
        and not (ns.Merchant and ns.Merchant.IsBusy and ns.Merchant.IsBusy())
end

local function professionParent(key)
    if not positiveID(key) then return nil end
    if ns.API and ns.API.GetProfessionParentKey then
        local ok, parent = pcall(ns.API.GetProfessionParentKey, key)
        if ok and positiveID(parent) then return parent end
        return nil
    end
    return key
end

-- A separate overlay inherits the client's native spell-action OnClick. No
-- OpenTradeSkill call, artificial pending switch or crafting intent is involved.
function ActionButtons.BindProfession(button)
    if not button or button.cabProfessionBound then return button ~= nil end
    button.cabProfessionBound = true
    button:SetAttribute("type", "spell")
    button:SetAttribute("useOnKeyDown", false)
    button:SetAttribute("spell", nil)
    button:RegisterForClicks("LeftButtonUp")
    button:HookScript("PreClick", function(self)
        self:SetAttribute("spell", nil)
        self.cabProfessionContext = nil
        if (self.IsShown and not self:IsShown()) or (self.IsVisible and not self:IsVisible())
            or not professionClickAvailable() then return end
        local id = ns.selectedID
        local key = ns.selectedProfessionKey or ns.professionKey
        local parent = professionParent(key)
        if not positiveID(id) or not parent or not ns.API then return end
        local context = {recipeID = id, professionKey = key, parent = parent}
        local ownOK, own = pcall(ns.API.IsOwnProfession)
        local keyOK, currentKey = pcall(ns.API.GetProfessionKey)
        if not ownOK or (issecretvalue and issecretvalue(own)) or type(own) ~= "boolean" or not keyOK then return end
        if own and not professionParent(currentKey) then return end
        local closed = ns.IsProfessionClosed and ns.IsProfessionClosed()
        if not closed and ownOK and own == true and keyOK and professionParent(currentKey) == parent then
            -- Recasting an already open profession can close/toggle its source.
            -- The following PostClick only refreshes its real recipe data.
            self.cabProfessionContext = context
            return
        end
        if not ns.API.GetProfessionOpenSpell then return end
        local ok, spell = pcall(ns.API.GetProfessionOpenSpell, key)
        if not ok or not positiveID(spell) then return end
        self:SetAttribute("spell", spell)
        self.cabProfessionContext = context
    end)
    button:HookScript("PostClick", function(self)
        local context = self.cabProfessionContext
        self.cabProfessionContext = nil
        self:SetAttribute("spell", nil)
        if not context or not professionClickAvailable() or ns.selectedID ~= context.recipeID
            or professionParent(ns.selectedProfessionKey or ns.professionKey) ~= context.parent then return end
        if ns.ProfessionOpenClicked then ns.ProfessionOpenClicked(context.recipeID, context.professionKey) end
    end)
    return true
end
