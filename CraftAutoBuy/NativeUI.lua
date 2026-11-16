local _, ns = ...
local L = ns.L
local NativeUI = {}
ns.NativeUI = NativeUI

-- Only decorate text after Blizzard has populated its real controls. The game
-- APIs, recipe records, reagent allocations and protected buttons are untouched.
local rowStates, slotStates = setmetatable({}, {__mode = "k"}), setmetatable({}, {__mode = "k"})
local installedForms, installedScrollBoxes = setmetatable({}, {__mode = "k"}), setmetatable({}, {__mode = "k"})
local layoutArguments, pendingLayouts = setmetatable({}, {__mode = "k"}), setmetatable({}, {__mode = "k"})
local layoutHooked
local context
local GREEN, BLUE, GOLD, RESET = "|cff80ff80", "|cff59b3ff", "|cffffd100", "|r"
local LIMIT = 1000
local NATIVE_SLOT_HEIGHT, SOURCE_FONT_HEIGHT = 50, 12
local NAME_LEFT, TOP_PADDING, SOURCE_GAP, BOTTOM_PADDING = 46, 6, 2, 7
local SIZE_TOLERANCE = .01

local function active()
    if ns.Sidebar and ns.Sidebar.IsGamepadMode and ns.Sidebar.IsGamepadMode() then return false end
    return ns.API and ns.API.IsOwnProfession() and ns.professionKey
        and ns.API.GetProfessionKey() == ns.professionKey
end

local function snapshot()
    if not active() then return nil end
    if not context or context.recipes ~= ns.recipes or context.key ~= ns.professionKey then
        local inventory, bank
        if ns.Bank then inventory, bank = ns.Bank.Snapshot(ns.recipes)
        else inventory = ns.API.Inventory(ns.recipes) end
        context = {recipes = ns.recipes, key = ns.professionKey,
            inventory = inventory, bank = bank, counts = {}, bankMessages = {}, needsBank = {}, projections = {}}
    end
    return context
end

local function recipeBank(current, id)
    local job = ns.job
    if job and job.ignoreBank and job.recipeID == id and job.professionKey == current.key then return {} end
    return current.bank
end

local function recipeStock(current, id)
    local job = ns.job
    if job and job.catalogueIncludeBank == false and job.recipeID == id and job.professionKey == current.key then
        -- Returning to the native page must not advertise bank ingredients for
        -- the bag-only project the player already started from CAB. Other
        -- recipes retain the native page's usual bank-aware projection.
        if not current.jobInventory then
            if ns.PlanningStock then current.jobInventory, current.jobBank = ns.PlanningStock(current.recipes)
            else current.jobInventory, current.jobBank = ns.API.Inventory(current.recipes), {} end
        end
        return current.jobInventory, current.jobBank
    end
    return current.inventory, recipeBank(current, id)
end

function NativeUI.FormatQuantity(owned, potential, required, colored)
    local extra = ""
    if potential > owned then
        extra = " " .. (colored and GOLD or "") .. "(" .. potential .. ")" .. (colored and RESET or "")
    end
    return tostring(owned) .. extra .. " / " .. tostring(required)
end

function NativeUI.FormatSources(bankCount, vendorSource, colored)
    local parts = {}
    if type(bankCount) == "number" and bankCount > 0 then
        local unverified = ns.Stock and ns.Stock.IsBankUnverified and ns.Stock.IsBankUnverified()
        parts[#parts + 1] = (unverified and L.BANK_REAGENT_UNVERIFIED or L.BANK_REAGENT):format(bankCount)
    end
    if vendorSource == true then
        parts[#parts + 1] = L.MERCHANT_REAGENT_AVAILABLE
    elseif vendorSource == "here" then
        parts[#parts + 1] = L.MERCHANT_REAGENT_HERE
    elseif vendorSource == false then
        parts[#parts + 1] = L.MERCHANT_REAGENT_NOT_HERE
    elseif type(vendorSource) == "number" and vendorSource >= 0 and vendorSource < math.huge then
        parts[#parts + 1] = L.MERCHANT_REAGENT_STOCK:format(vendorSource)
    end
    local text = table.concat(parts, "\n")
    return colored and text ~= "" and (GOLD .. text .. RESET) or text
end

function NativeUI.VendorHint(itemID)
    if not ns.Merchant or not ns.Merchant.GetLastVendorName then return nil end
    local name = ns.Merchant.GetLastVendorName(itemID)
    if type(name) ~= "string" or (issecretvalue and issecretvalue(name)) or not name:find("%S") then return nil end
    return L.MERCHANT_LAST_SEEN:format(name)
end

-- Per-component potential is evaluated independently. The recipe total below
-- always uses the full planner, which reserves shared materials exactly once.
-- Vendor potential is real stock plus the selected plan's total purchases,
-- including intermediate recipes. The denominator remains a per-craft need.
function NativeUI.Project(recipeID, recipes, inventory, vendors, crafts, purchaseQuantities, bank)
    local recipe = recipes[recipeID]
    if not recipe or recipe.supported == false then return nil end
    local maximum, maximumPlan = ns.Planner.MaxCrafts(recipes, inventory, vendors, recipeID, LIMIT, bank)
    crafts = crafts == nil and math.max(maximum, 1) or crafts
    local plan = crafts == math.max(maximum, 1) and maximumPlan
        or ns.Planner.Plan(recipes, inventory, vendors, recipeID, crafts, bank)
    if not purchaseQuantities and ns.Merchant and ns.Merchant.Quote then
        purchaseQuantities = ns.Merchant.Quote(plan.purchases).purchaseQuantities
    end
    local result = {count = maximum, reagents = {}, bankMessage = ns.Bank and ns.Bank.Message(plan)}
    local withProbe = {}
    for id, value in pairs(recipes) do withProbe[id] = value end
    local probeID = 2147483647
    while withProbe[probeID] do probeID = probeID - 1 end
    local probeOutput = 2147483647
    local usedItems = {}
    for _, value in pairs(recipes) do
        if value.outputItemID then usedItems[value.outputItemID] = true end
        for _, reagent in ipairs(value.reagents or {}) do usedItems[reagent.itemID] = true end
    end
    while usedItems[probeOutput] do probeOutput = probeOutput - 1 end
    for _, reagent in ipairs(recipe.reagents or {}) do
        local owned = inventory[reagent.itemID] or 0
        local inBank = bank and bank[reagent.itemID] or 0
        local potential
        if vendors[reagent.itemID] then
            potential = owned + inBank + ((purchaseQuantities and purchaseQuantities[reagent.itemID])
                or plan.purchases[reagent.itemID] or 0)
        else
            withProbe[probeID] = {id = probeID, outputItemID = probeOutput, outputCount = 1,
                supported = true, reagents = {{itemID = reagent.itemID, quantity = 1}}}
            potential = math.max(owned + inBank, (ns.Planner.MaxCrafts(withProbe, inventory, vendors, probeID, LIMIT, bank)))
        end
        local vendorSource
        if vendors[reagent.itemID] then
            if ns.Merchant and ns.Merchant.GetReagentSourceStock then
                vendorSource = ns.Merchant.GetReagentSourceStock(reagent.itemID)
            else vendorSource = true end
        end
        result.reagents[reagent.itemID] = {itemID = reagent.itemID, owned = owned, bank = inBank, potential = potential,
            required = reagent.quantity, vendorSource = vendorSource}
    end
    return result
end

local function recipeCount(id)
    local current = snapshot()
    local recipe = current and current.recipes[id]
    if not recipe or recipe.supported == false then return nil end
    if current.counts[id] == nil then
        local inventory, bank = recipeStock(current, id)
        local count, plan = ns.Planner.MaxCrafts(current.recipes, inventory, ns.vendorItems, id, LIMIT, bank)
        current.counts[id] = count
        if plan and next(plan.bankWithdrawals or {}) then
            current.bankMessages[id] = ns.Bank and ns.Bank.Message(plan) or L.BANK_NOTICE
            -- The preferred plan can withdraw vials or an intermediate even
            -- though bags + PNJ can make the same displayed quantity. Blue
            -- describes a necessary withdrawal, not that preference.
            local bagsPlan = ns.Planner.Plan(current.recipes, inventory, ns.vendorItems, id, count)
            current.needsBank[id] = not bagsPlan.craftable
        end
    end
    return current.counts[id], current.bankMessages[id], current.needsBank[id] == true
end

local function projection(id)
    local current = snapshot()
    if not current then return nil end
    if current.projections[id] == nil then
        local crafts, quote
        if ns.job and ns.job.recipeID == id and ns.job.professionKey == current.key then
            crafts = ns.job.remaining
            quote = ns.quote
        elseif not ns.job then
            crafts = ns.NativeCraft and ns.NativeCraft.GetQuantity(id)
            quote = crafts and ns.NativeCraft.GetQuote(id)
            if not crafts and ns.selectedID == id then crafts, quote = ns.quantity, ns.quote end
        end
        local inventory, bank = recipeStock(current, id)
        current.projections[id] = NativeUI.Project(id, current.recipes, inventory, ns.vendorItems, crafts,
            quote and quote.purchaseQuantities, bank) or false
    end
    return current.projections[id] or nil
end

local function rowRecipeID(row)
    if not row.GetElementData then return nil end
    local node = row:GetElementData()
    local data = node and (node.GetData and node:GetData() or node.data or node)
    local info = data and data.recipeInfo
    if info and Professions and Professions.GetHighestLearnedRecipe then
        info = Professions.GetHighestLearnedRecipe(info) or info
    end
    return info and info.recipeID
end

local function restoreRow(row, state)
    if state.appliedLabel and row.Label:GetText() == state.appliedLabel then row.Label:SetText(state.label) end
    if state.appliedCount and row.Count:GetText() == state.appliedCount then
        row.Count:SetText(state.count)
        row.Count:SetShown(state.countShown)
    end
    if state.width and row.Label.GetWidth and row.Label:GetWidth() == state.appliedWidth then
        row.Label:SetWidth(state.width)
    end
    state.appliedLabel, state.appliedCount, state.appliedWidth, state.potential, state.bankMessage, state.needsBank = nil, nil, nil, nil, nil, nil
end

local function applyRow(row, nativeCountUpdated)
    if not row or not row.Label or not row.Count then return end
    local state = rowStates[row]
    if not state then return end
    local label, count = row.Label:GetText(), row.Count:GetText()
    if label ~= state.appliedLabel then state.label = label end
    if nativeCountUpdated or count ~= state.appliedCount then
        state.count, state.countShown = count, row.Count:IsShown()
    end
    if row.Label.GetWidth and row.Label:GetWidth() ~= state.appliedWidth then state.width = row.Label:GetWidth() end
    local id = rowRecipeID(row)
    local potential, bankMessage, needsBank
    if id then potential, bankMessage, needsBank = recipeCount(id) end
    if not potential or potential <= 0 then restoreRow(row, state); return end
    local direct = 0
    if C_TradeSkillUI and C_TradeSkillUI.GetCraftableCount then
        local ok, value = pcall(C_TradeSkillUI.GetCraftableCount, id)
        if ok and type(value) == "number" and not (issecretvalue and issecretvalue(value)) then direct = value end
    end
    state.direct, state.potential = direct, potential
    state.bankMessage, state.needsBank = bankMessage, needsBank
    local color = needsBank and BLUE or GREEN
    state.appliedCount = color .. " [" .. potential .. (potential >= LIMIT and "+" or "") .. "] " .. RESET
    row.Count:SetText(state.appliedCount)
    row.Count:Show()
    if state.label then
        state.appliedLabel = color .. state.label .. RESET
        row.Label:SetText(state.appliedLabel)
    elseif state.appliedLabel and row.Label:GetText() == state.appliedLabel then
        row.Label:SetText(state.label)
        state.appliedLabel = nil
    end
    -- Reserve room for the added count; the native Name and icon stay anchored.
    if row.GetWidth and row.Count.GetStringWidth and row.Label.SetWidth then
        local iconWidth = row.SkillUps and row.SkillUps.GetWidth and row.SkillUps:GetWidth() or 26
        local lockedWidth = row.LockedIcon and row.LockedIcon.IsShown and row.LockedIcon:IsShown() and 17 or 0
        state.appliedWidth = math.min(state.width or row:GetWidth(), math.max(20, row:GetWidth() - iconWidth - lockedWidth - row.Count:GetStringWidth() - 14))
        row.Label:SetWidth(state.appliedWidth)
    end
end

local function addTooltipLines(row, direct, potential, bankMessage, needsBank)
    if not GameTooltip or not GameTooltip.AddLine then return end
    if GameTooltip.IsShown and not GameTooltip:IsShown() and GameTooltip.SetOwner then
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    end
    GameTooltip:AddLine("CraftAutoBuy", 1, .82, 0)
    GameTooltip:AddLine((L.CRAFTABLE_NOW):format(direct or 0), 1, 1, 1)
    if needsBank then
        GameTooltip:AddLine((L.CRAFTABLE_WITH_VENDORS):format(potential or 0, (potential or 0) >= LIMIT and "+" or ""), .35, .7, 1)
    else
        GameTooltip:AddLine((L.CRAFTABLE_WITH_VENDORS):format(potential or 0, (potential or 0) >= LIMIT and "+" or ""), .5, 1, .5)
    end
    if bankMessage then GameTooltip:AddLine(bankMessage, .35, .7, 1, true) end
    GameTooltip:Show()
end

local function attachRow(row)
    if not row or not row.Label or not row.Count or not row.GetElementData then return end
    if not rowStates[row] then
        rowStates[row] = {}
        if type(row.SetCraftableCount) == "function" then
            hooksecurefunc(row, "SetCraftableCount", function(self) applyRow(self, true) end)
        end
        if type(row.Init) == "function" then hooksecurefunc(row, "Init", function(self) applyRow(self) end) end
        if row.HookScript then
            row:HookScript("OnEnter", function(self)
                local state = rowStates[self]
                if active() and state and state.potential then addTooltipLines(self, state.direct, state.potential, state.bankMessage, state.needsBank) end
            end)
        end
    end
    applyRow(row)
end

local function reflowSlots()
    for form in pairs(pendingLayouts) do
        pendingLayouts[form] = nil
        local container = form.Reagents
        if container and Professions and Professions.LayoutReagentSlots then
            local args = layoutArguments[container]
            if args then
                Professions.LayoutReagentSlots(unpack(args))
            elseif form.GetSlotsByReagentType and GridLayoutMixin and GridLayoutMixin.Direction then
                -- Initial installation may follow the first native Init. Later
                -- reflows reuse the exact native arguments captured below.
                local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
                local slots = form:GetSlotsByReagentType(basic)
                if slots then
                    Professions.LayoutReagentSlots(slots, container, form.forCraftingOrders and 35 or 5,
                        -5, form.isRecraft and 3 or 4, GridLayoutMixin.Direction.TopLeftToBottomRightVertical)
                end
            end
        end
    end
end

local function restoreSources(slot, state)
    if state.sourceLine then state.sourceLine:Hide(); state.sourceLine:SetText("") end
    if state.nameGeometry then
        local geometry = state.nameGeometry
        slot.Name:SetHeight(geometry.height)
        if geometry.points then
            slot.Name:ClearAllPoints()
            for _, point in ipairs(geometry.points) do slot.Name:SetPoint(unpack(point)) end
        end
        if geometry.justifyV then slot.Name:SetJustifyV(geometry.justifyV) end
        state.nameGeometry = nil
    end
    if state.appliedHeight and slot.GetHeight then
        if math.abs(slot:GetHeight() - state.baseHeight) > SIZE_TOLERANCE then
            slot:SetHeight(state.baseHeight)
        end
        if state.form and math.abs(state.appliedHeight - state.baseHeight) > SIZE_TOLERANCE then
            pendingLayouts[state.form] = true
        end
    end
    state.appliedHeight = nil
end

local function textHeight(region)
    local height = region.GetStringHeight and region:GetStringHeight()
    return type(height) == "number" and height > 0 and math.ceil(height) or SOURCE_FONT_HEIGHT
end

local function saveNameGeometry(name)
    local points
    if name.GetNumPoints and name.GetPoint then
        points = {}
        for index = 1, name:GetNumPoints() do points[#points + 1] = {name:GetPoint(index)} end
    end
    return {height = name:GetHeight(), points = points,
        justifyV = name.GetJustifyV and name:GetJustifyV()}
end

local function applySources(slot, state, sources)
    if sources == "" or not slot.CreateFontString or not slot.GetHeight or not slot.SetHeight
        or not slot.Name.ClearAllPoints or not slot.Name.SetHeight then
        restoreSources(slot, state)
        return
    end
    if not state.sourceLine then
        local line = slot:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        line.ignoreInLayout = true
        line:SetPoint("TOPLEFT", slot.Name, "BOTTOMLEFT", 0, -SOURCE_GAP)
        line:SetJustifyH("LEFT")
        line:SetJustifyV("TOP")
        if line.SetWordWrap then line:SetWordWrap(true) end
        state.sourceLine, slot.CraftAutoBuySourceLine = line, line
    end
    if not state.baseHeight then
        -- Read the native baseline only once, before our first modification.
        -- WoW returns floating-point dimensions, so exact GetHeight comparisons
        -- must never turn an already decorated height into a new baseline.
        state.baseHeight = math.max(NATIVE_SLOT_HEIGHT, math.floor(slot:GetHeight() + .5))
    end
    if not state.nameGeometry then state.nameGeometry = saveNameGeometry(slot.Name) end
    slot.Name:ClearAllPoints()
    slot.Name:SetPoint("TOPLEFT", slot, "TOPLEFT", NAME_LEFT, -TOP_PADDING)
    slot.Name:SetJustifyV("TOP")
    slot.Name:SetHeight(0)
    local nameHeight = textHeight(slot.Name)
    slot.Name:SetHeight(nameHeight)
    state.sourceLine:SetWidth(slot.Name:GetWidth())
    state.sourceLine:SetText(sources)
    state.sourceLine:SetHeight(0)
    local sourceHeight = textHeight(state.sourceLine)
    state.sourceLine:SetHeight(sourceHeight)
    local target = math.max(state.baseHeight, TOP_PADDING + nameHeight + SOURCE_GAP + sourceHeight + BOTTOM_PADDING)
    if math.abs(slot:GetHeight() - target) > SIZE_TOLERANCE then
        slot:SetHeight(target)
        if state.form then pendingLayouts[state.form] = true end
    end
    state.appliedHeight = target
    state.sourceLine:Show()
end

local function restoreSlot(slot, state)
    if state.applied and slot.Name:GetText() == state.applied then slot.Name:SetText(state.original) end
    restoreSources(slot, state)
    state.applied, state.projection = nil, nil
end

local function nativeReagentText(slot, itemData, required, name)
    local owned = tostring(itemData.owned)
    local remainder = " / " .. tostring(required) .. " " .. name
    local ok, color = false, nil
    if type(slot.GetNameColor) == "function" then ok, color = pcall(slot.GetNameColor, slot) end
    if ok and color and type(color.WrapTextInColorCode) == "function" then
        -- Each native part needs its own color code: the gold potential's |r
        -- resets to the font color, not to an enclosing native gray/white code.
        owned = color:WrapTextInColorCode(owned)
        remainder = color:WrapTextInColorCode(remainder)
    end
    return owned .. " " .. GOLD .. "(" .. itemData.potential .. ")" .. RESET .. remainder
end

local function applySlot(slot)
    local state = slotStates[slot]
    if not state or not slot.Name then return end
    local currentText = slot.Name:GetText()
    if currentText ~= state.applied then state.original = currentText end
    local form = ns.API.GetForm()
    state.form = form
    local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
    local schematic = slot.GetReagentSlotSchematic and slot:GetReagentSlotSchematic()
    local data = info and projection(info.recipeID)
    local reagent = schematic and schematic.reagents and #schematic.reagents == 1 and schematic.reagents[1]
    local itemData = reagent and reagent.itemID and data and data.reagents[reagent.itemID]
    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
    if not itemData or not schematic or not (schematic.required or schematic.reagentType == basic) then
        restoreSlot(slot, state)
        return
    end
    local required = schematic.quantityRequired
    if type(required) ~= "number" or required <= 0 then restoreSlot(slot, state); return end
    local name = ns.ItemName and ns.ItemName(reagent.itemID) or tostring(reagent.itemID)
    -- Keep the native font and text width. Source decoration measures the two
    -- text blocks and restores the original geometry when it is removed.
    if itemData.potential > itemData.owned then
        state.applied = nativeReagentText(slot, itemData, required, name)
        slot.Name:SetText(state.applied)
    elseif state.applied then
        if slot.Name:GetText() == state.applied then slot.Name:SetText(state.original) end
        state.applied = nil
    end
    state.projection = itemData
    applySources(slot, state, NativeUI.FormatSources(itemData.bank, itemData.vendorSource, true))
end

local function updateSlot(slot)
    applySlot(slot)
    reflowSlots()
end

local function attachSlot(slot)
    if not slot or not slot.Name or not slot.GetReagentSlotSchematic then return end
    if not slotStates[slot] then
        slotStates[slot] = {}
        if type(slot.Update) == "function" then hooksecurefunc(slot, "Update", updateSlot) end
        if type(slot.UpdateAllocationText) == "function" then hooksecurefunc(slot, "UpdateAllocationText", updateSlot) end
        if slot.Button and slot.Button.HookScript then
            slot.Button:HookScript("OnEnter", function()
                local state = slotStates[slot]
                if active() and state and state.projection and GameTooltip and GameTooltip.AddLine then
                    GameTooltip:AddLine(L.REAGENT_TOOLTIP_TITLE, 1, .82, 0)
                    GameTooltip:AddLine(L.REAGENT_TOOLTIP_EXPLANATION, 1, 1, 1, true)
                    GameTooltip:AddLine(L.NATIVE_QUANTITY_HELP, 1, 1, 1, true)
                    local sources = NativeUI.FormatSources(state.projection.bank, state.projection.vendorSource)
                    if sources ~= "" then
                        GameTooltip:AddLine(sources, 1, .82, 0, true)
                        GameTooltip:AddLine(L.REAGENT_SOURCE_HELP, 1, 1, 1, true)
                    end
                    local vendorHint = NativeUI.VendorHint(state.projection.itemID)
                    if vendorHint then GameTooltip:AddLine(vendorHint, 1, 1, 1, true) end
                    GameTooltip:Show()
                end
            end)
        end
    end
    applySlot(slot)
end

local function updateSlots(form)
    if form and form.GetSlots then
        for _, slot in ipairs(form:GetSlots() or {}) do attachSlot(slot) end
    end
    reflowSlots()
end

function NativeUI.Install()
    if not hooksecurefunc or not ns.API then return false end
    local form = ns.API.GetForm()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local scroll = page and page.RecipeList and page.RecipeList.ScrollBox
    if not form or not scroll then return false end
    if not layoutHooked and Professions and type(Professions.LayoutReagentSlots) == "function" then
        layoutHooked = true
        hooksecurefunc(Professions, "LayoutReagentSlots", function(slots, container, ...)
            layoutArguments[container] = {slots, container, ...}
        end)
    end
    if not installedForms[form] then
        installedForms[form] = true
        if type(form.Init) == "function" then
            hooksecurefunc(form, "Init", function(self) updateSlots(self) end)
        end
        if type(form.UpdateAllSlots) == "function" then hooksecurefunc(form, "UpdateAllSlots", updateSlots) end
    end
    if not installedScrollBoxes[scroll] then
        installedScrollBoxes[scroll] = true
        if ScrollUtil and ScrollUtil.AddInitializedFrameCallback then
            ScrollUtil.AddInitializedFrameCallback(scroll, function(_, row) attachRow(row) end, NativeUI, false)
        elseif scroll.HookScript then
            scroll:HookScript("OnVerticalScroll", function(self)
                if self.ForEachFrame then self:ForEachFrame(attachRow) end
            end)
        end
    end
    if scroll.ForEachFrame then scroll:ForEachFrame(attachRow) end
    updateSlots(form)
    return true
end

function NativeUI.Refresh()
    context = nil
    if not active() then
        for row, state in pairs(rowStates) do restoreRow(row, state) end
        for slot, state in pairs(slotStates) do restoreSlot(slot, state) end
        reflowSlots()
        return
    end
    local form = ns.API.GetForm()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    if not form or not page or (page.IsShown and not page:IsShown()) then return end
    local scroll = page.RecipeList and page.RecipeList.ScrollBox
    if scroll and scroll.ForEachFrame then scroll:ForEachFrame(attachRow) end
    updateSlots(form)
end
