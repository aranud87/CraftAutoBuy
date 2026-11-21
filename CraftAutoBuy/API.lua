local _, ns = ...
local L = ns.L
local API = {}
ns.API = API

-- Signatures verified against Blizzard's WoW Forever (Camelot) UI source.
-- Ordinary item recipes come from the live profession or a scoped passive scan.
local function ordinaryNumber(value)
    return type(value) == "number" and not (issecretvalue and issecretvalue(value))
        and value == value and value > -math.huge and value < math.huge
end

local function positiveInteger(value)
    return ordinaryNumber(value) and value > 0 and value == math.floor(value)
end

local function nonnegativeInteger(value)
    return ordinaryNumber(value) and value >= 0 and value == math.floor(value)
end

local function call(func, ...)
    if type(func) ~= "function" then return false end
    return pcall(func, ...)
end

-- Client arrays are dense. A hole while data is incomplete must fail the
-- complete read, rather than let ipairs silently omit a recipe or ingredient.
local function arraySize(value)
    if type(value) ~= "table" or (issecretvalue and issecretvalue(value)) then return nil end
    local count = 0
    for index in pairs(value) do
        -- Table keys themselves cannot be secret values.
        if type(index) ~= "number" or index < 1 or index >= math.huge
            or index ~= math.floor(index) then return nil end
        count = count + 1
    end
    for index = 1, count do if value[index] == nil then return nil end end
    return count
end

local craftObserver, craftDispatch
local function observeCraftRejections()
    if craftObserver or type(CreateFrame) ~= "function" then return end
    craftObserver = CreateFrame("Frame")
    for _, event in ipairs({"ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN"}) do
        pcall(craftObserver.RegisterEvent, craftObserver, event)
    end
    craftObserver:SetScript("OnEvent", function(_, event, source, functionName)
        -- These client events are synchronous. Attribute only a CraftRecipe
        -- rejection inside our own dispatch, never an unrelated addon's error.
        if craftDispatch and type(functionName) == "string"
            and not (issecretvalue and issecretvalue(functionName))
            and functionName:find("CraftRecipe", 1, true) then
            craftDispatch.blocked = true
        end
    end)
end

function API.GetForm()
    return ProfessionsFrame and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
end

function API.SelectedRecipeID()
    local form = API.GetForm()
    if not form or type(form.GetRecipeInfo) ~= "function" then return nil end
    local ok, info = pcall(form.GetRecipeInfo, form)
    if ok and type(info) == "table" and positiveInteger(info.recipeID) then
        return info.recipeID
    end
end

function API.GetProfessionKey()
    if not C_TradeSkillUI then return nil end
    local ok, info = call(C_TradeSkillUI.GetChildProfessionInfo)
    if ok and type(info) == "table" and positiveInteger(info.professionID) then
        return info.professionID
    end
    ok, info = call(C_TradeSkillUI.GetBaseProfessionInfo)
    if ok and type(info) == "table" and positiveInteger(info.professionID) then
        return info.professionID
    end
end

-- The active recipe skill line can be a child (for example classic alchemy
-- 2485) while GetProfessionInfo and the native tabs identify its parent (171).
-- Keep GetProfessionKey unchanged for recipe membership checks; normalize only
-- when matching known professions, naming them or opening their native window.
function API.GetProfessionParentKey(key)
    if not positiveInteger(key) then return nil end
    if not C_TradeSkillUI then return key end
    local ok, info = call(C_TradeSkillUI.GetChildProfessionInfo)
    if ok and type(info) == "table" and info.professionID == key then
        if positiveInteger(info.parentProfessionID) then return info.parentProfessionID end
        local baseOK, base = call(C_TradeSkillUI.GetBaseProfessionInfo)
        if baseOK and type(base) == "table" and positiveInteger(base.professionID) then
            return base.professionID
        end
    end
    ok, info = call(C_TradeSkillUI.GetProfessionInfoBySkillLineID, key)
    if ok and type(info) == "table" and positiveInteger(info.parentProfessionID) then
        return info.parentProfessionID
    end
    -- An unavailable relation is not evidence that the skill is unknown.
    return key
end

-- Forever's right profession tabs use these global profession indices, followed
-- by the profession spell to exclude skills without a crafting window. The
-- seven return slots may contain holes (for example, no second primary skill).
-- The second result tells cache consumers whether absence is authoritative.
function API.GetProfessions()
    if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then return {}, false end
    local indices = {call(GetProfessions)}
    if not indices[1] then return {}, false end
    local result, seen, complete = {}, {}, true
    local spellBank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    local canCheckSpell = spellBank ~= nil and C_SpellBook and type(C_SpellBook.GetSpellBookItemInfo) == "function"
        and C_TradeSkillUI and type(C_TradeSkillUI.CanTradeSkillShowCraftingUI) == "function"
    for slot = 2, 8 do
        local index = indices[slot]
        if issecretvalue and issecretvalue(index) then
            complete = false
        elseif index ~= nil then
            local ok, name, texture, _, _, _, spellOffset, key = call(GetProfessionInfo, index)
            if ok and positiveInteger(key) and type(name) == "string"
                and not (issecretvalue and issecretvalue(name)) and name ~= "" then
                local include, openingSpell = true, nil
                if canCheckSpell then
                    if not ordinaryNumber(spellOffset) or spellOffset < 0 or spellOffset ~= math.floor(spellOffset) then
                        include, complete = false, false
                    else
                        local spellOK, spell = call(C_SpellBook.GetSpellBookItemInfo, spellOffset + 1, spellBank)
                        if not spellOK or type(spell) ~= "table" or (issecretvalue and issecretvalue(spell))
                            or not positiveInteger(spell.spellID) then
                            include, complete = false, false
                        else
                            local showOK, canShow = call(C_TradeSkillUI.CanTradeSkillShowCraftingUI, spell.spellID)
                            if not showOK or (issecretvalue and issecretvalue(canShow)) or type(canShow) ~= "boolean" then
                                include, complete = false, false
                            else
                                include = canShow
                                if canShow then openingSpell = spell.spellID end
                            end
                        end
                    end
                end
                if include and not seen[key] then
                    result[#result + 1] = {key = key, name = name, icon = texture, spellID = openingSpell}
                    seen[key] = true
                end
            else
                complete = false
            end
        end
    end
    return result, complete
end

-- Resolve the learned profession's own grimoire spell. The normal out-of-combat
-- action template may cast it; this lookup never opens a source or casts a spell.
function API.GetProfessionOpenSpell(key)
    if not positiveInteger(key) then return nil, L.PROFESSION_OPEN_FAILED end
    local parentKey = API.GetProfessionParentKey(key)
    for _, profession in ipairs(API.GetProfessions()) do
        if profession.key == key or profession.key == parentKey then
            if positiveInteger(profession.spellID) then return profession.spellID end
            return nil, L.CATALOG_VERIFY_HELP
        end
    end
    return nil, L.CATALOG_VERIFY_HELP
end

function API.ProfessionName(key)
    local parentKey = API.GetProfessionParentKey(key)
    for _, profession in ipairs(API.GetProfessions()) do
        if profession.key == key or profession.key == parentKey then return profession.name end
    end
    if positiveInteger(key) and C_TradeSkillUI then
        local ok, info = call(C_TradeSkillUI.GetProfessionInfoBySkillLineID, key)
        if ok and type(info) == "table" then
            local name = info.professionName or info.parentProfessionName
            if type(name) == "string" and name ~= "" then return name end
        end
    end
    return L.PROFESSION_FALLBACK:format(tostring(key))
end

-- Legacy Lua callers cannot use the Blizzard-only OpenTradeSkill route on
-- Forever. Profession buttons use their native spell action instead.
function API.OpenProfession(key)
    if not positiveInteger(key) then return false, L.PROFESSION_OPEN_FAILED end
    if InCombatLockdown and InCombatLockdown() then return false, L.PROFESSION_OPEN_COMBAT end
    if not C_TradeSkillUI then
        return false, L.PROFESSION_API_UNAVAILABLE
    end
    local parentKey = API.GetProfessionParentKey(key)
    local professions, complete = API.GetProfessions()
    if complete then
        local known = false
        for _, profession in ipairs(professions) do if profession.key == parentKey then known = true; break end end
        if not known then return false, L.PROFESSION_NOT_KNOWN end
    end
    return false, L.CATALOG_VERIFY_HELP
end

function API.IsOwnProfession()
    if not C_TradeSkillUI then return false, L.PROFESSION_API_UNAVAILABLE end
    for _, name in ipairs({"IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting"}) do
        if C_TradeSkillUI[name] then
            local ok, external = call(C_TradeSkillUI[name])
            if not ok or external then return false, L.OPEN_OWN_PROFESSION end
        end
    end
    if C_TradeSkillUI.IsDataSourceChanging then
        local ok, changing = call(C_TradeSkillUI.IsDataSourceChanging)
        if not ok or changing then return false, L.LOADING_RECIPES end
    end
    if C_TradeSkillUI.IsTradeSkillReady then
        local ok, ready = call(C_TradeSkillUI.IsTradeSkillReady)
        if not ok or not ready then return false, L.OPEN_PROFESSION_WAIT end
    end
    if not API.GetProfessionKey() then return false, L.OPEN_PROFESSION end
    return true
end

local function unsupported(recipe, reason)
    recipe.supported = false
    recipe.reason = reason
    return recipe
end

local function ordinaryBoolean(value)
    return type(value) == "boolean" and not (issecretvalue and issecretvalue(value))
end

local metadataContextToken = {}

-- This snapshot belongs to one synchronous metadata pass. Keep no global
-- context: opening another profession must be reflected by the next pass.
function API.BeginRecipeMetadataRead()
    local context = {token = metadataContextToken, source = C_TradeSkillUI, categories = {}}
    if not C_TradeSkillUI then return context end
    for _, name in ipairs({"IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting"}) do
        if C_TradeSkillUI[name] then
            local ok, external = call(C_TradeSkillUI[name])
            if not ok or not ordinaryBoolean(external) or external then return context end
        end
    end
    context.available = true
    context.own = API.IsOwnProfession() and not (ns.IsProfessionClosed and ns.IsProfessionClosed())
    if context.own then context.professionKey = API.GetProfessionKey() end
    return context
end

-- Optional metadata is read independently of schematics. A cold recipe-info
-- result is contextual (including false learned/favorite/skill-up fields), so
-- only the current, ready, personal profession can authoritatively clear it.
-- A positive native favorite is useful even before its profession is opened.
function API.GetRecipeMetadata(recipeID, professionKey, suppliedInfo, context)
    local metadata = {}
    if not positiveInteger(recipeID) or not C_TradeSkillUI then return metadata end
    if type(context) ~= "table" or context.token ~= metadataContextToken or context.source ~= C_TradeSkillUI then
        context = API.BeginRecipeMetadataRead()
    end
    if not context.available then return metadata end
    local scoped = context.own and context.professionKey == professionKey
    local info = suppliedInfo
    if not info and scoped then
        local ok, value = call(C_TradeSkillUI.GetRecipeInfo, recipeID)
        if ok and type(value) == "table" and not (issecretvalue and issecretvalue(value)) then info = value end
    end
    scoped = scoped and type(info) == "table" and not (issecretvalue and issecretvalue(info))
        and ordinaryBoolean(info.learned) and info.learned
        and (info.recipeID == nil or positiveInteger(info.recipeID) and info.recipeID == recipeID)
    if scoped and C_TradeSkillUI.IsRecipeInSkillLine then
        local ok, belongs = call(C_TradeSkillUI.IsRecipeInSkillLine, recipeID, professionKey)
        scoped = ok and ordinaryBoolean(belongs) and belongs
    end
    local ok, favorite = call(C_TradeSkillUI.IsRecipeFavorite, recipeID)
    if ok and ordinaryBoolean(favorite) and (scoped or favorite) then
        metadata.favorite = favorite
    elseif scoped and ordinaryBoolean(info.favorite) then
        metadata.favorite = info.favorite
    end
    if not scoped then return metadata end
    -- A current learned recipe is authoritative even when one optional field
    -- is absent. Consumers must replace this tuple, not keep an old difficulty
    -- beside a newly read canSkillUp flag.
    metadata.progressionRead = true
    if ordinaryBoolean(info.canSkillUp) then metadata.canSkillUp = info.canSkillUp end
    if ordinaryBoolean(info.disabled) and info.disabled then metadata.canSkillUp = false end
    if nonnegativeInteger(info.relativeDifficulty) and info.relativeDifficulty <= 3 then
        metadata.relativeDifficulty = info.relativeDifficulty
    end
    if nonnegativeInteger(info.numSkillUps) then metadata.numSkillUps = info.numSkillUps end
    local categoryID, path, seen = info.categoryID, {}, {}
    while positiveInteger(categoryID) and not seen[categoryID] and #path < 16 do
        seen[categoryID] = true
        local category = context.categories[categoryID]
        if category == nil then
            local categoryOK, value = call(C_TradeSkillUI.GetCategoryInfo, categoryID)
            if categoryOK and type(value) == "table" and not (issecretvalue and issecretvalue(value))
                and type(value.name) == "string" and not (issecretvalue and issecretvalue(value.name))
                and value.name ~= "" then category = value
            else category = false end
            context.categories[categoryID] = category
        end
        if not category then return metadata end
        table.insert(path, 1, {id = categoryID, name = category.name,
            sortIndex = nonnegativeInteger(category.uiOrder) and category.uiOrder or nil})
        local parent = category.parentCategoryID
        if parent == nil or nonnegativeInteger(parent) and parent == 0 then
            metadata.categoryPath = path
            return metadata
        end
        if not positiveInteger(parent) then return metadata end
        categoryID = parent
    end
    return metadata
end

local function readRecipe(recipeID, info, professionKey, suppliedSchematic)
    local recipe = {
        id = recipeID, name = info.name or L.RECIPE_FALLBACK:format(recipeID),
        reagents = {}, craftingReagents = {}, professionKey = professionKey,
        supported = true, canCreateMultiple = info.canCreateMultiple ~= false,
    }
    -- Optional progression metadata is independent of the item's output yield.
    -- Missing or invalid fields must not make an otherwise valid recipe unusable.
    if type(info.canSkillUp) == "boolean" and not (issecretvalue and issecretvalue(info.canSkillUp)) then
        recipe.canSkillUp = info.canSkillUp
    end
    if type(info.disabled) == "boolean" and not (issecretvalue and issecretvalue(info.disabled)) and info.disabled then
        recipe.canSkillUp = false
    end
    if nonnegativeInteger(info.relativeDifficulty) and info.relativeDifficulty <= 3 then
        recipe.relativeDifficulty = info.relativeDifficulty
    end
    if nonnegativeInteger(info.numSkillUps) then recipe.numSkillUps = info.numSkillUps end
    for field, value in pairs(API.GetRecipeMetadata(recipeID, professionKey, info)) do recipe[field] = value end
    if not info.learned then return unsupported(recipe, L.RECIPE_NOT_LEARNED) end
    if info.isRecraft or info.isDummyRecipe or info.isGatheringRecipe
        or info.isEnchantingRecipe or info.isSalvageRecipe then
        return unsupported(recipe, L.RECIPE_NOT_SIMPLE_ITEM)
    end
    if info.supportsQualities then
        return unsupported(recipe, L.QUALITY_RECIPES_UNSUPPORTED)
    end
    local ok, schematic = true, suppliedSchematic
    if schematic == nil then ok, schematic = call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false) end
    if not ok or type(schematic) ~= "table" or arraySize(schematic.reagentSlotSchematics) == nil then
        return nil, L.LOADING_REAGENTS
    end
    local itemRecipeType = Enum and Enum.TradeskillRecipeType and Enum.TradeskillRecipeType.Item or 1
    if schematic.recipeType and schematic.recipeType ~= itemRecipeType then
        return unsupported(recipe, L.RECIPE_NOT_SIMPLE_ITEM)
    end
    recipe.outputItemID = schematic.outputItemID
    if not positiveInteger(recipe.outputItemID) and C_TradeSkillUI.GetRecipeOutputItemData then
        local outputOK, output = call(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        if outputOK and type(output) == "table" then recipe.outputItemID = output.itemID end
    end
    if not positiveInteger(recipe.outputItemID) then
        return nil, L.LOADING_OUTPUT
    end
    recipe.outputCount = schematic.quantityMin
    if not positiveInteger(recipe.outputCount) then return nil, L.RECIPE_YIELD_UNAVAILABLE end
    local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
    local itemSlotType = Enum and Enum.TradeskillSlotDataType and Enum.TradeskillSlotDataType.Reagent or 1
    local byItem = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        if type(slot) ~= "table" or (issecretvalue and issecretvalue(slot))
            or (issecretvalue and issecretvalue(slot.required))
            or (slot.required ~= nil and type(slot.required) ~= "boolean") then
            return nil, L.LOADING_REAGENTS
        end
        -- Basic slots are mandatory even when older exports omit the required flag.
        local required = slot.required == true or slot.reagentType == basicType
        if required then
            if slot.dataSlotType and slot.dataSlotType ~= itemSlotType then
                return unsupported(recipe, L.SPECIAL_REAGENT_UNSUPPORTED)
            end
            local reagentCount = arraySize(slot.reagents)
            if not reagentCount or reagentCount == 0 then
                return nil, L.LOADING_REAGENTS
            end
            local variableCount = 0
            if slot.variableQuantities ~= nil then variableCount = arraySize(slot.variableQuantities) end
            if variableCount == nil then
                return nil, L.LOADING_REAGENT_QUANTITIES
            end
            if reagentCount ~= 1 or variableCount > 0 then
                return unsupported(recipe, L.RECIPE_REQUIRES_REAGENT_CHOICE)
            end
            local reagent = slot.reagents[1]
            if type(reagent) ~= "table" or (issecretvalue and issecretvalue(reagent)) then
                return nil, L.LOADING_REAGENTS
            end
            if not positiveInteger(reagent.itemID) or reagent.currencyID then
                return unsupported(recipe, L.REQUIRED_REAGENT_UNSUPPORTED)
            end
            if not positiveInteger(slot.quantityRequired) or not positiveInteger(slot.dataSlotIndex) then
                return nil, L.LOADING_REAGENT_QUANTITIES
            end
            byItem[reagent.itemID] = (byItem[reagent.itemID] or 0) + slot.quantityRequired
            recipe.craftingReagents[#recipe.craftingReagents + 1] = {
                reagent = {itemID = reagent.itemID},
                dataSlotIndex = slot.dataSlotIndex, quantity = slot.quantityRequired,
            }
        elseif slot.required == nil and slot.reagentType == nil then
            return nil, L.REAGENT_TYPE_UNAVAILABLE
        else
            -- CAB plans the basic recipe. Native crafting must retain the
            -- player's optional allocations for this form.
            recipe.hasOptionalSlots = true
        end
    end
    for itemID, quantity in pairs(byItem) do
        recipe.reagents[#recipe.reagents + 1] = {itemID = itemID, quantity = quantity}
    end
    table.sort(recipe.reagents, function(a, b) return a.itemID < b.itemID end)
    -- An empty or incomplete schematic must never become an unlimited free recipe.
    if #recipe.reagents == 0 then
        return unsupported(recipe, L.RECIPE_NO_VERIFIABLE_REAGENTS)
    end
    return recipe
end

function API.GetRecipe(recipeID)
    local own, reason = API.IsOwnProfession()
    if not own then return nil, reason end
    if not positiveInteger(recipeID) then return nil, L.INVALID_RECIPE end
    local key = API.GetProfessionKey()
    if C_TradeSkillUI.IsRecipeInSkillLine then
        local ok, belongs = call(C_TradeSkillUI.IsRecipeInSkillLine, recipeID, key)
        if not ok or type(belongs) ~= "boolean" or (issecretvalue and issecretvalue(belongs)) then return nil, L.LOADING_PROFESSION end
        if not belongs then return nil, L.RECIPE_OTHER_PROFESSION end
    end
    local ok, info = call(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if not ok or type(info) ~= "table" or (issecretvalue and issecretvalue(info))
        or type(info.learned) ~= "boolean" or (issecretvalue and issecretvalue(info.learned)) then return nil, L.LOADING_RECIPE end
    return readRecipe(recipeID, info, key)
end

-- Background discovery still requires every recipe. A fresh action scan can
-- proceed with its selected recipe and planned steps while unrelated records
-- load. Partial scans must not replace the saved profession catalogue.
function API.ScanRecipes(required)
    local own, reason = API.IsOwnProfession()
    if not own then return nil, reason end
    local key = API.GetProfessionKey()
    local ok, ids = call(C_TradeSkillUI.GetAllRecipeIDs)
    local count = ok and arraySize(ids)
    if not count or count == 0 then return nil, L.RECIPES_LOADING end
    local recipes, complete, unreadable = {}, true, {}
    for _, recipeID in ipairs(ids) do
        local infoOK, info = call(C_TradeSkillUI.GetRecipeInfo, recipeID)
        local err
        if not infoOK or type(info) ~= "table" or (issecretvalue and issecretvalue(info))
            or type(info.learned) ~= "boolean" or (issecretvalue and issecretvalue(info.learned)) then
            err = L.RECIPES_LOADING
        elseif info.learned then
            local belongsOK, belongs = true, true
            if C_TradeSkillUI.IsRecipeInSkillLine then
                belongsOK, belongs = call(C_TradeSkillUI.IsRecipeInSkillLine, recipeID, key)
            end
            if not belongsOK or type(belongs) ~= "boolean" or (issecretvalue and issecretvalue(belongs)) then
                err = L.LOADING_PROFESSION
            elseif belongs then
                recipes[recipeID], err = readRecipe(recipeID, info, key)
            end
        end
        if err then
            if not required or required[recipeID] then return nil, err end
            complete, unreadable[recipeID] = false, true
        end
    end
    if key ~= API.GetProfessionKey() or not API.IsOwnProfession() then return nil, L.PROFESSION_CHANGED end
    return recipes, nil, complete, unreadable
end

-- A passive catalogue read never changes the active profession, selects a
-- recipe or calls a crafting API. Explicit profession/recipe identifiers are
-- used instead of the active-source GetAllRecipeIDs/IsRecipeInSkillLine pair.
local function backgroundContext()
    if type(C_TradeSkillUI) ~= "table" then return false, L.PROFESSION_API_UNAVAILABLE end
    for _, name in ipairs({"IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting"}) do
        if C_TradeSkillUI[name] then
            local ok, external = call(C_TradeSkillUI[name])
            if not ok or (issecretvalue and issecretvalue(external)) or external then
                return false, L.OPEN_OWN_PROFESSION
            end
        end
    end
    return true
end

local function backgroundKnownProfession(key)
    if not positiveInteger(key) then return nil, L.PROFESSION_NOT_KNOWN end
    local professions, complete = API.GetProfessions()
    if not complete then return nil, L.LOADING_PROFESSION end
    for _, profession in ipairs(professions) do
        if profession.key == key then return key end
    end
    -- Only an explicitly addressed relation may resolve a cold child key. A
    -- linked or unrelated active source must never supply its parent instead.
    local ok, info = call(C_TradeSkillUI.GetProfessionInfoBySkillLineID, key)
    if ok and type(info) == "table" and not (issecretvalue and issecretvalue(info))
        and positiveInteger(info.professionID) and info.professionID == key and positiveInteger(info.parentProfessionID) then
        for _, profession in ipairs(professions) do
            if profession.key == info.parentProfessionID then return profession.key end
        end
    end
    return nil, L.PROFESSION_NOT_KNOWN
end

local function backgroundSpellIDs(key)
    -- Forever exposes schematics and IsSpellKnown before a profession opens,
    -- but its contextual recipe list is empty and GetRecipeInfo.learned is
    -- false at cold login. Enumerate the pinned client-data index instead.
    local index = ns.RecipeIndex
    local ok, _, build, _, interface = call(GetBuildInfo)
    if not ok or (issecretvalue and (issecretvalue(build) or issecretvalue(interface)))
        or not tonumber(build) or not ordinaryNumber(interface) then return nil, nil, L.RECIPES_LOADING end
    if type(index) ~= "table" or index.schema ~= 1 or type(index.professions) ~= "table"
        or tonumber(build) ~= index.build or interface ~= index.interface then
        return nil, nil, L.CATALOG_VERIFY_HELP, true
    end
    local spells = index.professions[key]
    local total = arraySize(spells)
    if total == nil then return nil, nil, L.CATALOG_VERIFY_HELP, true end
    local ids, seen = {}, {}
    for index = 1, total do
        local id = spells[index]
        if not positiveInteger(id) or seen[id] then return nil, nil, L.RECIPES_LOADING end
        ids[index], seen[id] = id, true
    end
    return ids, seen
end

function API.BeginBackgroundScan(key)
    local allowed, reason = backgroundContext()
    if not allowed then return nil, reason end
    local parent, why = backgroundKnownProfession(key)
    if not parent then return nil, why end
    if not C_SpellBook or type(C_SpellBook.IsSpellKnown) ~= "function"
        or not Enum or not Enum.SpellBookSpellBank or Enum.SpellBookSpellBank.Player == nil then
        return nil, L.PROFESSION_API_UNAVAILABLE
    end
    local ids, idSet, failure, manual = backgroundSpellIDs(parent)
    if not ids then return nil, failure, manual end
    return {professionKey = key, parentProfessionKey = parent, ids = ids,
        idSet = idSet, cursor = 1, progress = 0, total = #ids, recipes = {}, known = {},
        phase = "read", verifyCursor = 1}
end

local function backgroundRecipe(job, id)
    local info
    if type(C_TradeSkillUI.GetRecipeInfo) == "function" then
        local ok, value = call(C_TradeSkillUI.GetRecipeInfo, id)
        if not ok then return nil, L.LOADING_RECIPE end
        if value ~= nil then
            if type(value) ~= "table" or (issecretvalue and issecretvalue(value))
                or (issecretvalue and issecretvalue(value.learned))
                or (value.learned ~= nil and type(value.learned) ~= "boolean")
                or (value.recipeID ~= nil and (not positiveInteger(value.recipeID) or value.recipeID ~= id)) then
                return nil, L.LOADING_RECIPE
            end
            -- Cold contextual metadata cannot override the independently
            -- verified learned spell or provide reliable progression flags.
            if value.learned == true then
                info = {}
                for key, field in pairs(value) do info[key] = field end
            end
            for _, key in ipairs({"isRecraft", "isDummyRecipe", "isGatheringRecipe", "isEnchantingRecipe",
                "isSalvageRecipe", "supportsQualities", "canCreateMultiple"}) do
                local field = info and info[key]
                if field ~= nil and ((issecretvalue and issecretvalue(field)) or type(field) ~= "boolean") then
                    return nil, L.LOADING_RECIPE
                end
            end
        end
    end
    if type(C_TradeSkillUI.GetProfessionInfoByRecipeID) == "function" then
        local ok, profession = call(C_TradeSkillUI.GetProfessionInfoByRecipeID, id)
        if not ok then return nil, L.LOADING_PROFESSION end
        if profession ~= nil then
            if type(profession) ~= "table" or (issecretvalue and issecretvalue(profession))
                or not nonnegativeInteger(profession.professionID)
                or (profession.parentProfessionID ~= nil and not nonnegativeInteger(profession.parentProfessionID)) then
                return nil, L.LOADING_PROFESSION
            end
            local parent = positiveInteger(profession.parentProfessionID) and profession.parentProfessionID or profession.professionID
            if parent > 0 and parent ~= job.parentProfessionKey then
                return nil, L.RECIPE_OTHER_PROFESSION
            end
        end
    end
    local schematic
    local needsName = not info or type(info.name) ~= "string" or (issecretvalue and issecretvalue(info.name)) or info.name == ""
    do
        local ok, value = call(C_TradeSkillUI.GetRecipeSchematic, id, false)
        if not ok or type(value) ~= "table" or (issecretvalue and issecretvalue(value))
            or (value.recipeID ~= nil and (not positiveInteger(value.recipeID) or value.recipeID ~= id)) then
            return nil, L.LOADING_REAGENTS
        end
        schematic = value
    end
    if needsName then
        if type(schematic.name) ~= "string" or (issecretvalue and issecretvalue(schematic.name)) or schematic.name == ""
            or (schematic.isRecraft ~= nil and ((issecretvalue and issecretvalue(schematic.isRecraft))
                or type(schematic.isRecraft) ~= "boolean")) then return nil, L.LOADING_RECIPE end
        -- The client-data index supplies membership, IsSpellKnown supplies
        -- ownership, and the live schematic supplies name, output and slots.
        info = info or {learned = true, isRecraft = schematic.isRecraft}
        info.name = schematic.name
    end
    local ok, recipe, reason = pcall(readRecipe, id, info, job.professionKey, schematic)
    if not ok then return nil, L.LOADING_REAGENTS end
    if not recipe then return nil, reason or L.LOADING_RECIPE end
    recipe.learned = true
    return recipe
end

local function failBackgroundScan(job, reason)
    job.failed, job.recipes = reason or L.RECIPES_LOADING, {}
    return nil, false, job.failed
end

local function completeBackgroundScan(job)
    -- A client callback during the last read can change or close the source.
    -- Recheck ownership before publishing even an empty or unsupported map.
    local allowed, reason = backgroundContext()
    if not allowed then return failBackgroundScan(job, reason) end
    local parent, why = backgroundKnownProfession(job.professionKey)
    if parent ~= job.parentProfessionKey then return failBackgroundScan(job, why or L.PROFESSION_CHANGED) end
    job.complete = true
    return job.recipes, true
end

function API.StepBackgroundScan(job, limit)
    if type(job) ~= "table" or not positiveInteger(job.professionKey)
        or not nonnegativeInteger(job.total) or not positiveInteger(job.cursor)
        or job.cursor > job.total + 1 or type(job.ids) ~= "table"
        or type(job.idSet) ~= "table" or type(job.recipes) ~= "table"
        or type(job.known) ~= "table" or not positiveInteger(job.verifyCursor)
        or (job.phase ~= "read" and job.phase ~= "verify") then
        return nil, false, L.RECIPES_LOADING
    end
    if job.failed then return nil, false, job.failed end
    if job.complete then return job.recipes, true end
    limit = limit == nil and 5 or limit
    if not positiveInteger(limit) then return failBackgroundScan(job, L.RECIPES_LOADING) end
    local allowed, reason = backgroundContext()
    if not allowed then return failBackgroundScan(job, reason) end
    local parent, why = backgroundKnownProfession(job.professionKey)
    if not parent or parent ~= job.parentProfessionKey then
        return failBackgroundScan(job, why or L.PROFESSION_CHANGED)
    end
    -- Validate the index independently of the active profession. No client
    -- calls are made per candidate here; both live passes below share a budget.
    local ids, idSet = backgroundSpellIDs(job.parentProfessionKey)
    if not ids or #ids ~= job.total then return failBackgroundScan(job, L.RECIPES_LOADING) end
    for position, id in ipairs(job.ids) do
        if ids[position] ~= id or not job.idSet[id] or not idSet[id] then
            return failBackgroundScan(job, L.RECIPES_LOADING)
        end
    end
    local processed = 0
    while processed < limit do
        if job.phase == "read" and job.cursor > job.total then job.phase = "verify" end
        local cursor = job.phase == "read" and job.cursor or job.verifyCursor
        if cursor > job.total then
            return completeBackgroundScan(job)
        end
        local id = job.ids[cursor]
        local ok, known = call(C_SpellBook and C_SpellBook.IsSpellKnown, id, Enum.SpellBookSpellBank.Player)
        if not ok or (issecretvalue and issecretvalue(known)) or type(known) ~= "boolean" then
            return failBackgroundScan(job, L.RECIPES_LOADING)
        end
        if job.phase == "read" then
            job.known[id] = known
            if known then
                local recipe, failure = backgroundRecipe(job, id)
                if not recipe then return failBackgroundScan(job, failure) end
                job.recipes[id] = recipe
            end
            job.cursor = cursor + 1
            job.progress = cursor
        else
            if known ~= job.known[id] then return failBackgroundScan(job, L.RECIPES_LOADING) end
            job.verifyCursor = cursor + 1
        end
        processed = processed + 1
    end
    if job.phase == "verify" and job.verifyCursor > job.total then
        return completeBackgroundScan(job)
    end
    return nil, false
end

local function itemCount(itemID, includeBank)
    if not positiveInteger(itemID) then return nil end
    local countFunction = C_Item and C_Item.GetItemCount
    if type(countFunction) ~= "function" then return nil end
    -- Forever ItemDocumentation.lua: item, bank, uses, reagent bank, account bank.
    -- Include only this character's storage; never count charges or account items.
    local ok, count = call(countFunction, itemID, includeBank, false, includeBank, false)
    if not ok or not ordinaryNumber(count) or count < 0 then return nil end
    return math.floor(count)
end

-- Purchase authorization and acknowledgments must distinguish an unreadable
-- inventory from a verified empty stack. Legacy display callers expect zero.
function API.ReadBagCount(itemID)
    return itemCount(itemID, false)
end

function API.CountItem(itemID)
    return API.ReadBagCount(itemID) or 0
end

local function bankCount(itemID, bags)
    -- The saved personal-bank scan and the client's own count are both evidence
    -- for the withdrawal/repurchase decision. The client can forget its bank
    -- counts after /reload, and a saved scan can miss a change CAB could not
    -- read (crash before saving, reply during /reload, another computer).
    -- Never let one hide items the other still reports: an over-estimate only
    -- asks for a bank visit or the existing confirmation, an under-estimate
    -- would buy reagents the player already owns.
    local client
    -- An unavailable bags count cannot safely be subtracted from a combined count.
    if bags ~= nil then
        local combined = itemCount(itemID, true)
        client = combined and math.max(0, combined - bags) or nil
    end
    if positiveInteger(itemID) and ns.Stock and ns.Stock.BankCount then
        local stored = (ns.Stock.BankEvidence or ns.Stock.BankCount)(itemID)
        if ordinaryNumber(stored) and stored >= 0 then
            stored = math.floor(stored)
            -- A higher client count is recorded as evidence to check, so the
            -- protection survives a later session where the client forgets it.
            if client and client > stored and ns.Stock.NoteClientBankCount then
                ns.Stock.NoteClientBankCount(itemID, client)
            end
            return math.max(stored, client or 0)
        end
    end
    return client or 0
end

function API.BankCount(itemID)
    return bankCount(itemID, itemCount(itemID, false))
end

function API.Inventory(recipes)
    local inventory, unknown = {}, {}
    local function add(itemID)
        if positiveInteger(itemID) and inventory[itemID] == nil then
            local bags = API.ReadBagCount(itemID)
            inventory[itemID] = bags or 0
            if bags == nil then unknown[itemID] = true end
        end
    end
    for _, recipe in pairs(recipes or {}) do
        add(recipe.outputItemID)
        for _, reagent in ipairs(recipe.reagents or {}) do add(reagent.itemID) end
    end
    return inventory, unknown
end

function API.InventoryWithBank(recipes)
    local inventory, bank, unknown = {}, {}, {}
    local function add(itemID)
        if positiveInteger(itemID) and inventory[itemID] == nil then
            local bags = API.ReadBagCount(itemID)
            if bags == nil then unknown[itemID] = true end
            bank[itemID] = bankCount(itemID, bags)
            inventory[itemID] = (bags or 0) + bank[itemID]
        end
    end
    for _, recipe in pairs(recipes or {}) do
        add(recipe.outputItemID)
        for _, reagent in ipairs(recipe.reagents or {}) do add(reagent.itemID) end
    end
    -- Bag counts are always live; only the personal bank may use its saved scan.
    return inventory, bank, unknown
end

-- A later successful read cannot certify an earlier zero. Only unreadable
-- reagents in the selected material chain invalidate its purchase plan.
function API.MarkUnknownPurchaseCounts(plan, recipes, unknown)
    if not unknown or not next(unknown) or not plan or not next(plan.purchases or {}) then return end
    local intermediateOutputs = {}
    for _, step in ipairs(plan.steps or {}) do
        local recipe = recipes[step.recipeID]
        for _, reagent in ipairs(recipe and recipe.reagents or {}) do
            if unknown[reagent.itemID] then plan.inventoryUnknown = true; return end
        end
        if recipe and step.recipeID ~= plan.recipeID then
            intermediateOutputs[recipe.outputItemID] = step.recipeID
        end
    end
    if not next(intermediateOutputs) then return end
    -- An unreadable ingredient can make the first producer appear unusable
    -- and divert the plan to a second producer that requires a purchase.
    -- Examine alternate branches only for intermediates actually being made.
    local producers, queue, seen = {}, {}, {}
    for id, recipe in pairs(recipes) do
        if recipe.supported ~= false and recipe.learned ~= false and recipe.outputItemID then
            local output = recipe.outputItemID
            producers[output] = producers[output] or {}
            producers[output][#producers[output] + 1] = id
            if intermediateOutputs[output] and id ~= intermediateOutputs[output] then queue[#queue + 1] = id end
        end
    end
    while #queue > 0 do
        local id = table.remove(queue)
        if not seen[id] then
            seen[id] = true
            for _, reagent in ipairs(recipes[id].reagents or {}) do
                if unknown[reagent.itemID] then plan.inventoryUnknown = true; return end
                if not (ns.vendorItems and ns.vendorItems[reagent.itemID]) then
                    for _, producer in ipairs(producers[reagent.itemID] or {}) do
                        if not seen[producer] then queue[#queue + 1] = producer end
                    end
                end
            end
        end
    end
end

-- A cooldown of the recipe's own, read from the spell itself, in seconds. The
-- client's answer for a ready recipe carries neither a duration nor charges
-- (Transmute: Iron to Gold answers nil, false, 0, 0), so it sets no limit, yet
-- the first craft starts the cooldown again. GetSpellBaseCooldown answers in
-- milliseconds, 0 for an ordinary recipe; spell data does not change during a
-- session, so each readable answer is kept. An unreadable one limits nothing,
-- as before, and is asked again later.
local baseCooldowns = {}
local function baseCooldown(id)
    if baseCooldowns[id] then return baseCooldowns[id] end
    if type(GetSpellBaseCooldown) ~= "function" or not positiveInteger(id) then return 0 end
    local ok, value = call(GetSpellBaseCooldown, id)
    if not ok or not ordinaryNumber(value) or value < 0 then return 0 end
    baseCooldowns[id] = value / 1000
    return baseCooldowns[id]
end

local function now()
    local ok, value = call(GetTime)
    if ok and ordinaryNumber(value) then return value end
end

-- When a recipe's cooldown ends, by GetTime(): as last read in its open
-- profession, or started by a successful cast. A profession that is not open
-- is never asked, so without this memory its recipe on cooldown was listed at
-- its full count while another profession was open. Kept for the session only.
local cooldownEnds, castAt = {}, {}

-- For a profession that is not open: none while a remembered cooldown runs,
-- one craft for a recipe with a cooldown of its own, otherwise no limit.
local function rememberedLimit(id)
    local ends = cooldownEnds[id]
    if ends then
        local time = now()
        if not time or time < ends then return 0 end
        cooldownEnds[id] = nil
    end
    if baseCooldown(id) > 0 then return 1 end
end

-- A successful cast of a recipe with a cooldown of its own starts that
-- cooldown, whoever launched it (CAB or the native window).
function API.NoteRecipeCast(id)
    local seconds = positiveInteger(id) and baseCooldown(id) or 0
    local time = seconds > 0 and now()
    if not time then return end
    castAt[id] = time
    if (cooldownEnds[id] or 0) < time + seconds then cooldownEnds[id] = time + seconds end
end

local function recipeLimit(id)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeCooldown then return nil end
    local ok, cooldown, _, charges, maximum = call(C_TradeSkillUI.GetRecipeCooldown, id)
    if not ok or (issecretvalue and (issecretvalue(cooldown) or issecretvalue(charges) or issecretvalue(maximum)))
        or (maximum ~= nil and not nonnegativeInteger(maximum))
        or (cooldown ~= nil and not ordinaryNumber(cooldown)) then
        return 0, L.COOLDOWN_UNAVAILABLE
    end
    if maximum and maximum > 0 then
        if not nonnegativeInteger(charges) or charges > maximum then return 0, L.COOLDOWN_UNAVAILABLE end
        return charges, charges == 0 and L.RECIPE_ON_COOLDOWN or L.CRAFT_CHARGES_INSUFFICIENT
    end
    if ordinaryNumber(cooldown) and cooldown > 0 then
        if positiveInteger(charges) then return charges, L.CRAFT_CHARGES_INSUFFICIENT end
        local time = now()
        if time then cooldownEnds[id] = time + cooldown end
        return 0, L.RECIPE_ON_COOLDOWN
    end
    -- Ready. A cooldown of the recipe's own allows one craft before it starts
    -- again, although the answer carries no limit (F5). A ready answer in the
    -- two seconds after a noted cast may come before the client starts the
    -- cooldown: what the cast noted is kept.
    local time, cast = now(), castAt[id]
    if not (cast and time and time - cast < 2) then cooldownEnds[id] = nil end
    if baseCooldown(id) > 0 then return 1, L.CRAFT_CHARGES_INSUFFICIENT end
end

-- Snapshot on demand for one plan/maximum. Charges can change without a bag
-- event and belong to the active profession, never to saved recipe records.
-- A profession that is not open is not asked: its recipes are limited by what
-- the spells and this session's readings tell (rememberedLimit). Without the
-- spell cooldown API nothing is known of them, and there is no limit, as before.
function API.RecipeLimits(key)
    if not key then return nil end
    local live = C_TradeSkillUI and C_TradeSkillUI.GetRecipeCooldown and API.IsOwnProfession()
    if live then
        local active = API.GetProfessionKey()
        live = active and (key == active or API.GetProfessionParentKey(key) == API.GetProfessionParentKey(active))
    end
    if not live and type(GetSpellBaseCooldown) ~= "function" then return nil end
    return setmetatable({}, {__index = function(limits, id)
        local value
        if live then value = recipeLimit(id) else value = rememberedLimit(id) end
        if value == nil then value = math.huge end
        rawset(limits, id, value)
        return value
    end})
end

function API.RecipeReady(recipeID, executions)
    local recipe, reason = API.GetRecipe(recipeID)
    if not recipe then return false, reason end
    if not recipe.supported then return false, recipe.reason end
    local infoOK, info = call(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if not infoOK or not info or not info.learned then return false, L.RECIPE_NOT_LEARNED end
    if info.disabled then return false, info.disabledReason or L.RECIPE_UNAVAILABLE end
    local limit, blocked = recipeLimit(recipeID)
    if limit and (executions or 1) > limit then return false, blocked end
    if C_TradeSkillUI.GetRecipeRequirements then
        local ok, requirements = call(C_TradeSkillUI.GetRecipeRequirements, recipeID)
        if not ok or arraySize(requirements) == nil then return false, L.CRAFT_REQUIREMENTS_UNAVAILABLE end
        local missingRequirement
        for _, requirement in ipairs(requirements) do
            if type(requirement) ~= "table" or type(requirement.met) ~= "boolean"
                or (issecretvalue and issecretvalue(requirement.met)) then
                return false, L.CRAFT_REQUIREMENTS_UNAVAILABLE
            end
            if requirement.met == false and not missingRequirement then
                local name = requirement.name
                missingRequirement = type(name) == "string" and name ~= ""
                    and not (issecretvalue and issecretvalue(name)) and name or L.REQUIREMENT_TOOL_OR_LOCATION
            end
        end
        -- Forever requirements cover SpellFocus (station), Totem (tool) and
        -- Area (location). This diagnostic never authorizes an actual craft;
        -- callers may use it solely to prepare purchases for a later click.
        if missingRequirement then return false, L.REQUIREMENT_NEEDED:format(missingRequirement), "requirements" end
    end
    -- Forever's native validation rejects an explicitly uncraftable recipe.
    -- Keep missing station/tool diagnostics above so the purchase-only action
    -- remains available when those requirements are the reason it is blocked.
    if not (issecretvalue and issecretvalue(info.craftable)) and info.craftable == false then
        return false, info.disabledReason or L.RECIPE_UNAVAILABLE
    end
    return true
end

function API.Craft(recipeID, crafts)
    if ns.BankTransfer and ns.BankTransfer.IsBusy and ns.BankTransfer.IsBusy() then
        return false, L.BANK_TRANSFER_BUSY
    end
    if not positiveInteger(crafts) then return false, L.INVALID_QUANTITY end
    if InCombatLockdown and InCombatLockdown() then return false, L.CRAFT_SUSPENDED_COMBAT end
    local ready, reason = API.RecipeReady(recipeID, crafts)
    if not ready then return false, reason end
    local recipe, readError = API.GetRecipe(recipeID)
    if not recipe then return false, readError end
    if crafts > 1 and not recipe.canCreateMultiple then return false, L.RECIPE_SINGLE_CRAFT_ONLY end
    for _, reagent in ipairs(recipe.reagents) do
        local held = (API.ReadBagCount or API.CountItem)(reagent.itemID)
        if held == nil then return false, L.INVENTORY_UNAVAILABLE end
        if held < reagent.quantity * crafts then return false, L.REAGENTS_MISSING_BAGS end
    end
    observeCraftRejections()
    local previous, dispatch = craftDispatch, {}
    craftDispatch = dispatch
    local ok, result = call(C_TradeSkillUI.CraftRecipe, recipeID, crafts, recipe.craftingReagents)
    craftDispatch = previous
    if dispatch.blocked then
        if ns.Print then ns.Print(L.CRAFT_CLIENT_BLOCKED) end
        return false, L.CRAFT_CLIENT_BLOCKED, "protected"
    end
    if not ok then return false, L.CRAFT_REFUSED_REASON:format(tostring(result or L.API_UNAVAILABLE)) end
    if result == false then return false, L.CRAFT_REFUSED end
    -- Success means the call was accepted, not that the cast completed. The queue
    -- must await the player's spell and inventory events before advancing.
    return true
end

-- Read-only eligibility for the client's supported out-of-combat macro button.
-- Unknown cast identity must never authorize stopping an unrelated player spell.
function API.CanStopCraft(recipeID)
    if not positiveInteger(recipeID) or (ns.InCombat and ns.InCombat())
        or (InCombatLockdown and InCombatLockdown()) then
        return false, L.CRAFT_STOP_UNCONFIRMED, "unavailable"
    end
    local casting, channeling = {call(UnitCastingInfo, "player")}, {call(UnitChannelInfo, "player")}
    if not casting[1] or not channeling[1] then
        return false, L.CRAFT_STOP_UNCONFIRMED, "unavailable"
    end
    local active = false
    for index, info in ipairs({casting, channeling}) do
        local name, tradeskill, spellID = info[2], info[7], info[index == 1 and 10 or 9]
        if issecretvalue and (issecretvalue(name) or issecretvalue(tradeskill) or issecretvalue(spellID)) then
            return false, L.CRAFT_STOP_UNCONFIRMED, "unavailable"
        end
        if name ~= nil then
            if type(name) ~= "string" or name == "" or not positiveInteger(spellID)
                or type(tradeskill) ~= "boolean" then
                return false, L.CRAFT_STOP_UNCONFIRMED, "unavailable"
            end
            if not tradeskill or spellID ~= recipeID then
                return false, L.CRAFT_STOP_OTHER_ACTION, "other_action"
            end
            active = true
        end
    end
    if not active then return false, L.CRAFT_STOP_UNCONFIRMED, "unavailable" end
    return true
end

-- Retained for callers that need the failure diagnostic. An ordinary Lua
-- handler cannot stop a cast on Forever; only the native macro action may do it.
function API.StopCraft(recipeID)
    local eligible, reason, kind = API.CanStopCraft(recipeID)
    if not eligible then return false, reason, kind end
    return false, L.CRAFT_STOP_UNCONFIRMED, "secure_action_required"
end
