local _, ns = ...
local L = ns.L
local Catalogue = {SCHEMA = 1}
ns.Catalogue = Catalogue

-- Saved data is a recipe catalogue, never a stock snapshot or a shopping list.
-- Counts are rebuilt from the current bags only when invalidated. Each recipe
-- uses its own profession's producers; cross-profession chains are not assumed.
local records, loadedDB, rows = {}, nil, nil
local EMPTY = {}
local MAX_INTEGER = 2147483647
local searchText = ns.Locale.SearchText

local function integer(value)
    return type(value) == "number" and value == value and value >= 1
        and value <= MAX_INTEGER and value == math.floor(value)
end

local function nonnegativeInteger(value)
    return type(value) == "number" and not (issecretvalue and issecretvalue(value))
        and value == value and value >= 0 and value < math.huge and value == math.floor(value)
end

local function characterGUID()
    if type(UnitGUID) ~= "function" then return nil end
    local ok, guid = pcall(UnitGUID, "player")
    return ok and type(guid) == "string" and guid ~= "" and guid or nil
end

local function addonVersion()
    if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
        local ok, version = pcall(C_AddOns.GetAddOnMetadata, "CraftAutoBuy", "Version")
        if ok and type(version) == "string" then return version end
    end
    return "unknown"
end

local function copyRecipe(id, source, key)
    if type(source) ~= "table" or not integer(id) then return nil, false end
    -- API.ScanRecipes normally removes unlearned entries already. Keeping this
    -- check also prevents an older or manually edited cache from reviving them.
    if source.supported == false or source.learned == false then return nil, true end
    if source.professionKey ~= nil and source.professionKey ~= key then return nil, false end
    if not integer(source.outputItemID) or not integer(source.outputCount)
        or type(source.reagents) ~= "table" or #source.reagents == 0 then return nil, false end
    local recipe = {id = id, name = type(source.name) == "string" and source.name ~= "" and source.name
            or L.RECIPE_FALLBACK:format(id), professionKey = key, learned = true, supported = true,
        outputItemID = source.outputItemID, outputCount = source.outputCount,
        canCreateMultiple = source.canCreateMultiple ~= false, reagents = {}}
    -- Schema-one caches without progression fields remain valid. Preserve false
    -- and zero; never derive a skill gain from the number of items produced.
    if type(source.canSkillUp) == "boolean" and not (issecretvalue and issecretvalue(source.canSkillUp)) then
        recipe.canSkillUp = source.canSkillUp
    end
    if nonnegativeInteger(source.relativeDifficulty) and source.relativeDifficulty <= 3 then
        recipe.relativeDifficulty = source.relativeDifficulty
    end
    if nonnegativeInteger(source.numSkillUps) then recipe.numSkillUps = source.numSkillUps end
    local reagentCount = 0
    for index in pairs(source.reagents) do
        if not integer(index) then return nil, false end
        reagentCount = reagentCount + 1
    end
    for index = 1, reagentCount do
        local reagent = source.reagents[index]
        if type(reagent) ~= "table" or not integer(reagent.itemID) or not integer(reagent.quantity) then
            return nil, false
        end
        recipe.reagents[#recipe.reagents + 1] = {itemID = reagent.itemID, quantity = reagent.quantity}
    end
    return recipe, true
end

local function copyRecipes(source, key)
    if type(source) ~= "table" then return nil end
    local result = {}
    for id, recipe in pairs(source) do
        local copied, valid = copyRecipe(id, recipe, key)
        if not valid then return nil end
        result[id] = copied
    end
    return result
end

function Catalogue.Invalidate()
    rows = nil
end

local function parentKey(key, entry)
    local parent = ns.API.GetProfessionParentKey and ns.API.GetProfessionParentKey(key)
    if integer(parent) and parent ~= key then return parent end
    -- The profession API can be incomplete at login or while another book is
    -- open. Preserve the relationship recorded with the complete live scan.
    if entry and integer(entry.parentKey) then return entry.parentKey end
    return key
end

function Catalogue.Load()
    if type(CraftAutoBuyDB) ~= "table" then CraftAutoBuyDB = {} end
    local saved, guid = CraftAutoBuyDB.catalogue, characterGUID()
    local clientLocale = ns.Locale.GetClientLocale()
    local valid = type(saved) == "table" and saved.schema == Catalogue.SCHEMA
        and type(saved.professions) == "table"
        -- Recipe names come from the client, independently of CAB's chosen
        -- interface language. Old caches without a locale need one fresh scan.
        and saved.clientLocale == clientLocale
        and (not guid or not saved.character or saved.character == guid)
    local known, complete = ns.API.GetProfessions()
    local knownKeys = {}
    for _, profession in ipairs(known) do knownKeys[profession.key] = true end
    records = {}
    if valid then
        for key, entry in pairs(saved.professions) do
            -- An empty profession list during login is not enough evidence to
            -- destroy saved scans. Rows still excludes unknown skills when the
            -- API reports a complete list; opening a recipe is revalidated live.
            local parent = parentKey(key, type(entry) == "table" and entry or nil)
            local noLongerKnown = complete and #known > 0 and not knownKeys[key] and not knownKeys[parent]
            if integer(key) and not noLongerKnown and type(entry) == "table"
                and entry.schema == Catalogue.SCHEMA then
                local recipes = copyRecipes(entry.recipes, key)
                if recipes then
                    records[key] = {schema = Catalogue.SCHEMA,
                        parentKey = parent, learnedCount = integer(entry.learnedCount) and entry.learnedCount or nil,
                        background = entry.background == true,
                        version = type(entry.version) == "string" and entry.version or "unknown",
                        name = type(entry.name) == "string" and entry.name ~= "" and entry.name or ns.API.ProfessionName(key),
                        recipes = recipes}
                end
            end
        end
    end
    CraftAutoBuyDB.catalogue = {schema = Catalogue.SCHEMA, clientLocale = clientLocale,
        character = guid or (valid and saved.character or nil), professions = records}
    loadedDB = CraftAutoBuyDB
    Catalogue.Invalidate()
    return Catalogue
end

local function ensureLoaded()
    if loadedDB ~= CraftAutoBuyDB or not loadedDB then Catalogue.Load() end
end

-- Only call after API.ScanRecipes has returned a complete, current own scan.
-- Replacing the map removes forgotten recipes and old intermediate producers.
function Catalogue.Record(key, recipes, background)
    ensureLoaded()
    if not integer(key) then return false end
    local copied = copyRecipes(recipes, key)
    if not copied then return false end
    -- A complete scan can contain learned spells without supported item output
    -- (e.g. enchants). Distinguish it from a transient empty parent scan.
    local learnedCount = 0
    for _, recipe in pairs(recipes) do
        if recipe.learned ~= false then learnedCount = learnedCount + 1 end
    end
    local parent = parentKey(key)
    -- A first background read can use the base profession ID. A complete
    -- native child read is authoritative and must not be hidden by that cache.
    if not background and parent ~= key and records[parent] and records[parent].background then
        records[parent] = nil
    end
    records[key] = {schema = Catalogue.SCHEMA, version = addonVersion(), parentKey = parent,
        background = background == true,
        learnedCount = learnedCount,
        name = ns.API.ProfessionName(key), recipes = copied}
    Catalogue.Invalidate()
    return true
end

function Catalogue.GetRecipes(key)
    ensureLoaded()
    -- A transient parent-only scan may have saved an empty map before the
    -- child skill line loaded. That marker must not hide a later child scan.
    if records[key] and next(records[key].recipes) then return records[key].recipes end
    -- Vendor discovery enumerates native parent IDs. Recipe selection and
    -- crafting keep their exact child ID; only this parent lookup aggregates.
    local found
    for child, entry in pairs(records) do
        if parentKey(child, entry) == key then
            found = found or {}
            for id, recipe in pairs(entry.recipes) do found[id] = recipe end
        end
    end
    return found or EMPTY
end

function Catalogue.GetProfessionName(key)
    ensureLoaded()
    return records[key] and records[key].name or ns.API.ProfessionName(key)
end

function Catalogue.MissingProfessions()
    ensureLoaded()
    local missing = {}
    local scanned = {}
    for key, entry in pairs(records) do
        if next(entry.recipes) or (entry.learnedCount or 0) > 0 then
            scanned[key], scanned[parentKey(key, entry)] = true, true
        end
    end
    for _, profession in ipairs(ns.API.GetProfessions()) do
        if not scanned[profession.key] then
            missing[#missing + 1] = {key = profession.key, name = profession.name, icon = profession.icon}
        end
    end
    return missing
end

local function rebuildRows()
    local known, complete = ns.API.GetProfessions()
    local knownNames = {}
    for _, profession in ipairs(known) do knownNames[profession.key] = profession.name end
    local allRecipes = {}
    for key, entry in pairs(records) do
        if not complete or knownNames[key] or knownNames[parentKey(key, entry)] then
            for _, recipe in pairs(entry.recipes) do allRecipes[#allRecipes + 1] = recipe end
        end
    end
    local inventory, bank
    if ns.Bank then inventory, bank = ns.Bank.Snapshot(allRecipes)
    else inventory = ns.API.Inventory(allRecipes) end
    local result = {}
    for key, entry in pairs(records) do
        local parent = parentKey(key, entry)
        if not complete or knownNames[key] or knownNames[parent] then
            local prepared = ns.Planner.Prepare(entry.recipes)
            for id, recipe in pairs(entry.recipes) do
                local count, plan = ns.Planner.MaxCrafts(prepared, inventory, ns.vendorItems or {}, id, 1000, bank)
                if count > 0 then
                    local bankMessage = ns.Bank and ns.Bank.Message(plan)
                    -- The planner prefers owned bank supplies, but the colour
                    -- answers whether bags plus merchant supplies can make the
                    -- entire displayed quantity without withdrawing anything.
                    local needsBank = bankMessage ~= nil and not ns.Planner.Plan(prepared,
                        inventory, ns.vendorItems or {}, id, count).craftable
                    result[#result + 1] = {recipeID = id, professionKey = key, name = recipe.name,
                        professionName = knownNames[key] or knownNames[parent] or entry.name, count = count, recipe = recipe,
                        bankMessage = bankMessage, needsBank = needsBank}
                end
            end
        end
    end
    table.sort(result, function(a, b)
        if a.professionName ~= b.professionName then return a.professionName < b.professionName end
        if a.name ~= b.name then return a.name < b.name end
        if a.recipeID ~= b.recipeID then return a.recipeID < b.recipeID end
        return a.professionKey < b.professionKey
    end)
    rows = result
end

function Catalogue.Rows(search)
    ensureLoaded()
    if not rows then rebuildRows() end
    -- Lua's %s depends on the system locale and can strip bytes from UTF-8.
    local needle = type(search) == "string" and searchText(search:match("^[ \t\r\n\v\f]*(.-)[ \t\r\n\v\f]*$")) or ""
    local result = {}
    for _, row in ipairs(rows) do
        if needle == "" or string.find(searchText(row.name .. " " .. row.professionName), needle, 1, true) then
            result[#result + 1] = row
        end
    end
    return result
end
