local _, ns = ...
local L = ns.L
local Catalogue = {SCHEMA = 1}
ns.Catalogue = Catalogue

-- Saved data is a recipe catalogue, never a stock snapshot or a shopping list.
-- Counts are rebuilt from the current bags only when invalidated. Each recipe
-- uses its own profession's producers; cross-profession chains are not assumed.
local records, loadedDB, rows = {}, nil, {}
local displayedLimits = {}
local EMPTY = {}
-- Native favourites, by spell ID, outside the recipe catalogue: a catalogue
-- rebuilt after a reset, a locale change or a new data set starts empty, and a
-- cold passive read cannot tell "not a favourite" from "not known yet".
-- recipes[id] = true is a favourite, false a removal the client confirmed.
-- read[key] marks a profession whose own native window was read completely.
local FAVORITES_SCHEMA = 1
local favorites = {schema = FAVORITES_SCHEMA, recipes = {}, read = {}}
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

local function categoryPath(source)
    if type(source) ~= "table" or (issecretvalue and issecretvalue(source)) or #source > 16 then return nil end
    local copied, seen, length = {}, {}, 0
    for index in pairs(source) do
        if not integer(index) then return nil end
        length = length + 1
    end
    if length ~= #source then return nil end
    for _, category in ipairs(source) do
        if type(category) ~= "table" or (issecretvalue and issecretvalue(category))
            or (issecretvalue and issecretvalue(category.id)) or not integer(category.id) or seen[category.id]
            or type(category.name) ~= "string" or (issecretvalue and issecretvalue(category.name))
            or category.name == "" then return nil end
        seen[category.id] = true
        copied[#copied + 1] = {id = category.id, name = category.name,
            sortIndex = nonnegativeInteger(category.sortIndex) and category.sortIndex or nil}
    end
    return copied
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
    if type(source.favorite) == "boolean" and not (issecretvalue and issecretvalue(source.favorite)) then
        recipe.favorite = source.favorite
    end
    recipe.categoryPath = categoryPath(source.categoryPath)
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

local function ordinaryBoolean(value)
    return type(value) == "boolean" and not (issecretvalue and issecretvalue(value))
end

-- The saved favourites follow the catalogue's character rule. Their spell IDs
-- do not depend on the client language, so a locale change keeps them.
local function loadFavorites(guid)
    local saved = CraftAutoBuyDB.favoriteRecipes
    local valid = type(saved) == "table" and saved.schema == FAVORITES_SCHEMA and type(saved.recipes) == "table"
        and (not guid or not saved.character or saved.character == guid)
    local store = {schema = FAVORITES_SCHEMA, character = guid or (valid and saved.character or nil),
        recipes = {}, read = {}}
    if valid then
        for id, value in pairs(saved.recipes) do
            if integer(id) and ordinaryBoolean(value) then store.recipes[id] = value end
        end
        if type(saved.read) == "table" then
            for key, value in pairs(saved.read) do
                if integer(key) and value == true then store.read[key] = true end
            end
        end
    end
    CraftAutoBuyDB.favoriteRecipes = store
    return store, valid
end

-- Before a catalogue can be replaced, complete the memory with the favourites
-- it already read, for spells the memory does not know yet. A known state,
-- false included, is never overwritten: nothing in a saved catalogue says
-- whether it is newer than the memory or an old backup restored by hand, so
-- only a native read or the native event changes a known state.
-- Its booleans come from native reads or events: a cold read stored none. A
-- native record wins over a passive one. Within one origin a removal wins:
-- before this memory existed, a removal read in the open profession updated
-- that copy only, while an event or an addition updated every copy.
-- legacy: the first migration of a save last written by 1.3.x (no memory yet,
-- and a table without the mark). Its native records whose favourites are all
-- booleans count as read. Afterwards the memory keeps the beta's own read
-- marks: a table 1.3.3 rewrote meanwhile can hold records the beta filled
-- from remembered values, and its reads are resynchronised like its
-- favourites, at the next native opening.
local function importFavorites(store, saved, guid, legacy)
    if type(saved) ~= "table" or saved.schema ~= Catalogue.SCHEMA or type(saved.professions) ~= "table" then return end
    local owner = guid or store.character
    if owner and saved.character and saved.character ~= owner then return end
    -- Without a GUID yet, the memory takes the catalogue's owner, so that the
    -- first load that knows the character rejects both together.
    if not owner and type(saved.character) == "string" and saved.character ~= "" then
        store.character = saved.character
    end
    local found = {}
    for key, entry in pairs(saved.professions) do
        if integer(key) and type(entry) == "table" and entry.schema == Catalogue.SCHEMA
            and type(entry.recipes) == "table" then
            local origin = entry.background == true and "passive" or "native"
            local allRead, readCount = true, 0
            for id, recipe in pairs(entry.recipes) do
                local value
                if type(recipe) == "table" then value = recipe.favorite end
                if integer(id) and ordinaryBoolean(value) then
                    readCount = readCount + 1
                    if store.recipes[id] == nil then
                        found[id] = found[id] or {}
                        if found[id][origin] ~= false then found[id][origin] = value end
                    end
                else
                    allRead = false
                end
            end
            if legacy and entry.background == false and allRead and readCount > 0 then
                store.read[key] = true
                if integer(entry.parentKey) then store.read[entry.parentKey] = true end
            end
        end
    end
    for id, values in pairs(found) do
        if values.native ~= nil then store.recipes[id] = values.native
        else store.recipes[id] = values.passive end
    end
end

-- Only a value actually read (event payload, native or positive metadata)
-- updates the saved state; nil leaves the remembered favourite unchanged.
local function rememberFavorite(id, value)
    if not integer(id) or not ordinaryBoolean(value) or favorites.recipes[id] == value then return false end
    favorites.recipes[id] = value
    return true
end

-- Every snapshot of one spell (parent and child records) shows the saved state.
local function applyFavorites()
    local changed = false
    for _, entry in pairs(records) do
        for id, recipe in pairs(entry.recipes) do
            local value = favorites.recipes[id]
            if value ~= nil and recipe.favorite ~= value then recipe.favorite, changed = value, true end
        end
    end
    return changed
end

function Catalogue.Invalidate()
    rows = {}
    displayedLimits = {}
end

-- Charged recipes can recover while the player keeps the catalogue open.
-- Only query recipes with a live limit in the last catalogue calculation.
function Catalogue.RecipeLimitsChanged()
    for key, counts in pairs(displayedLimits) do
        local live = ns.API.RecipeLimits(key)
        for id, count in pairs(counts) do
            if not live or live[id] ~= count then
                Catalogue.Invalidate()
                return true
            end
        end
    end
    return false
end

local function parentKey(key, entry)
    local parent = ns.API.GetProfessionParentKey and ns.API.GetProfessionParentKey(key)
    if integer(parent) and parent ~= key then return parent end
    -- The profession API can be incomplete at login or while another book is
    -- open. Preserve the relationship recorded with the complete live scan.
    if entry and integer(entry.parentKey) then return entry.parentKey end
    return key
end

-- Whether a catalogue written by 1.3.x showed the Favorites section: 1.3.x
-- listed it as soon as one of its recipes was a favourite.
local function showedFavorites(saved)
    if type(saved) ~= "table" or type(saved.professions) ~= "table" then return false end
    for _, entry in pairs(saved.professions) do
        if type(entry) == "table" and type(entry.recipes) == "table" then
            for _, recipe in pairs(entry.recipes) do
                if type(recipe) == "table" and recipe.favorite == true then return true end
            end
        end
    end
    return false
end

function Catalogue.Load()
    if type(CraftAutoBuyDB) ~= "table" then CraftAutoBuyDB = {} end
    local saved, guid = CraftAutoBuyDB.catalogue, characterGUID()
    local migrating
    favorites, migrating = loadFavorites(guid)
    migrating = not migrating
    -- The mark describes the table's format: 1.3.3 rewrites it without the mark.
    importFavorites(favorites, saved, guid, migrating and type(saved) == "table" and saved.favorites ~= FAVORITES_SCHEMA)
    -- The 1.3.x Collapse all folded Favorites even while the section was
    -- absent. At the first migration of a 1.3.x save (no memory yet), a fold
    -- saved beside a catalogue without any favourite was therefore made in
    -- advance: drop it, so the first favourites do not arrive folded. A fold
    -- chosen on a shown section is kept, under 1.3.x as in the beta, and so is
    -- a beta fold after a 1.3.3 session (UI.lua).
    local view = CraftAutoBuyDB.catalogueView
    if migrating and not showedFavorites(saved) and type(view) == "table" and type(view.collapsed) == "table" then
        view.collapsed.favorites = nil
    end
    local clientLocale = ns.Locale.GetClientLocale()
    local valid = type(saved) == "table" and saved.schema == Catalogue.SCHEMA
        and type(saved.professions) == "table"
        -- Recipe names come from the client, independently of CAB's chosen
        -- interface language. Old caches without a locale need one fresh scan.
        and saved.clientLocale == clientLocale
        and (not guid or not saved.character or saved.character == guid)
    local known, complete = ns.API.GetProfessions()
    local mayPrune = ns.API.GetRecipeIndexBuild()
    local knownKeys = {}
    for _, profession in ipairs(known) do knownKeys[profession.key] = true end
    records = {}
    if valid then
        for key, entry in pairs(saved.professions) do
            -- An empty profession list during login is not enough evidence to
            -- destroy saved scans. Rows still excludes unknown skills when the
            -- API reports a complete list; opening a recipe is revalidated live.
            local parent = parentKey(key, type(entry) == "table" and entry or nil)
            local noLongerKnown = mayPrune and complete and #known > 0 and not knownKeys[key] and not knownKeys[parent]
            if integer(key) and not noLongerKnown and type(entry) == "table"
                and entry.schema == Catalogue.SCHEMA then
                local recipes = copyRecipes(entry.recipes, key)
                if recipes then
                    records[key] = {schema = Catalogue.SCHEMA,
                        parentKey = parent, learnedCount = integer(entry.learnedCount) and entry.learnedCount or nil,
                        background = entry.background == true,
                        backgroundBuild = integer(entry.backgroundBuild) and entry.backgroundBuild or nil,
                        nativeBuild = integer(entry.nativeBuild) and entry.nativeBuild or nil,
                        nativeInterface = integer(entry.nativeInterface) and entry.nativeInterface or nil,
                        version = type(entry.version) == "string" and entry.version or "unknown",
                        name = type(entry.name) == "string" and entry.name ~= "" and entry.name or ns.API.ProfessionName(key),
                        recipes = recipes}
                end
            end
        end
    end
    CraftAutoBuyDB.catalogue = {schema = Catalogue.SCHEMA, clientLocale = clientLocale,
        character = guid or (valid and saved.character or nil), favorites = FAVORITES_SCHEMA, professions = records}
    applyFavorites()
    loadedDB = CraftAutoBuyDB
    Catalogue.Invalidate()
    return Catalogue
end

local function ensureLoaded()
    if loadedDB ~= CraftAutoBuyDB or not loadedDB then Catalogue.Load() end
end

-- Only call after a complete passive or native own-profession scan.
-- Replacing the map removes forgotten recipes and old intermediate producers.
function Catalogue.Record(key, recipes, background)
    ensureLoaded()
    if not integer(key) then return false end
    local copied = copyRecipes(recipes, key)
    if not copied then return false end
    local indexBuild, build, interface = ns.API.GetRecipeIndexBuild()
    if background and not indexBuild then return false end
    local parent = parentKey(key)
    -- Optional metadata can be unavailable during a complete schematic read.
    -- Preserve the last native observation without preserving old recipes.
    local previous = records[key] and records[key].recipes or EMPTY
    local previousParent = parent ~= key and records[parent] and records[parent].recipes or EMPTY
    -- A native read is the newest state, for every learned recipe of this
    -- profession it read, including one CAB cannot list (an enchantment). A
    -- passive read only fills an unknown spell: an event received while it ran
    -- is newer than its snapshot. A cold read leaves the value nil either way.
    -- The profession's favourites count as read only when every learned recipe
    -- of a native read carried a boolean.
    local favoritesRead, readCount = not background, 0
    for id, recipe in pairs(recipes) do
        -- copyRecipes skips an unsupported record before checking its profession.
        if integer(id) and type(recipe) == "table" and not (issecretvalue and issecretvalue(recipe))
            and (recipe.id == nil or recipe.id == id) and (recipe.professionKey == nil or recipe.professionKey == key)
            and recipe.learned ~= false and recipe.reason ~= L.RECIPE_NOT_LEARNED then
            if ordinaryBoolean(recipe.favorite) then
                readCount = readCount + 1
                if not background or favorites.recipes[id] == nil then rememberFavorite(id, recipe.favorite) end
            else
                favoritesRead = false
            end
        elseif copied[id] then
            -- A record rejected here (another spell's ID) shows no favourite
            -- either, so no later import can take it from the catalogue.
            copied[id].favorite = nil
        end
    end
    for id, recipe in pairs(copied) do
        local old = previous[id] or previousParent[id]
        if old then
            for _, field in ipairs({"favorite", "categoryPath"}) do
                if recipe[field] == nil then recipe[field] = old[field] end
            end
        end
    end
    -- A verified passive scan covers the entire parent. Replace older child
    -- snapshots only after that scan succeeds, keeping their native metadata.
    if background and key == parent then
        for child, entry in pairs(records) do
            if child ~= key and parentKey(child, entry) == key then
                for id, old in pairs(entry.recipes) do
                    local recipe = copied[id]
                    if recipe then
                        if recipe.favorite == nil then recipe.favorite = old.favorite end
                        if recipe.categoryPath == nil then recipe.categoryPath = old.categoryPath end
                    end
                end
                records[child] = nil
            end
        end
    end
    -- A complete scan can contain learned spells without supported item output
    -- (e.g. enchants). Distinguish it from a transient empty parent scan.
    local learnedCount = 0
    for _, recipe in pairs(recipes) do
        if recipe.learned ~= false then learnedCount = learnedCount + 1 end
    end
    -- A first background read can use the base profession ID. A complete
    -- native child read is authoritative and must not be hidden by that cache.
    if not background and parent ~= key and records[parent] and records[parent].background then
        records[parent] = nil
    end
    records[key] = {schema = Catalogue.SCHEMA, version = addonVersion(), parentKey = parent,
        background = background == true,
        backgroundBuild = background and indexBuild or nil,
        nativeBuild = not background and build or nil, nativeInterface = not background and interface or nil,
        learnedCount = learnedCount,
        name = ns.API.ProfessionName(key), recipes = copied}
    -- Remembered favourites reach the recipes as they enter the catalogue,
    -- and override an older parent or child copy of the same spell.
    applyFavorites()
    if favoritesRead and readCount > 0 then favorites.read[key], favorites.read[parent] = true, true end
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

-- Initialization checks the provenance of each record. Browsing and stock
-- can still use the recipes that are already available.
function Catalogue.MissingProfessions(currentClient, professions)
    ensureLoaded()
    local missing = {}
    local scanned = {}
    local indexBuild, build, interface
    if currentClient then indexBuild, build, interface = ns.API.GetRecipeIndexBuild() end
    for key, entry in pairs(records) do
        local hasRecipes = next(entry.recipes) or (entry.learnedCount or 0) > 0
        local verified
        if currentClient then
            verified = (entry.background and indexBuild and entry.backgroundBuild == indexBuild)
                or (not entry.background and hasRecipes and build and entry.nativeBuild == build
                    and entry.nativeInterface == interface)
        else
            verified = hasRecipes or (entry.background and ns.RecipeIndex and entry.backgroundBuild == ns.RecipeIndex.build)
        end
        if verified then
            scanned[key], scanned[parentKey(key, entry)] = true, true
        end
    end
    for _, profession in ipairs(professions or ns.API.GetProfessions()) do
        if not scanned[profession.key] then
            missing[#missing + 1] = {key = profession.key, name = profession.name, icon = profession.icon}
        end
    end
    return missing
end

function Catalogue.HasRecipes()
    ensureLoaded()
    local known, complete = ns.API.GetProfessions()
    local keys = {}
    for _, profession in ipairs(known) do keys[profession.key] = true end
    for key, entry in pairs(records) do
        if (not complete or keys[key] or keys[parentKey(key, entry)]) and next(entry.recipes) then return true end
    end
    return false
end

function Catalogue.SectionKeys()
    ensureLoaded()
    local result = {favorites = true}
    local known, complete = ns.API.GetProfessions()
    local keys = {}
    for _, profession in ipairs(known) do keys[profession.key] = true end
    for key, entry in pairs(records) do
        local groupKey = parentKey(key, entry)
        if not complete or keys[key] or keys[groupKey] then
            for _, recipe in pairs(entry.recipes) do
                result["profession:" .. tostring(groupKey)] = true
                for _, category in ipairs(recipe.categoryPath or EMPTY) do
                    result["category:" .. tostring(groupKey) .. ":" .. tostring(category.id)] = true
                end
            end
        end
    end
    return result
end

-- The event payload is authoritative even if a different profession is open.
-- Without it, the API distinguishes unreadable metadata from a real false.
function Catalogue.RefreshMetadata(isFavorite, recipeSpellID)
    ensureLoaded()
    local nativeEvent = type(isFavorite) == "boolean" and not (issecretvalue and issecretvalue(isFavorite))
        and integer(recipeSpellID)
    local changed = false
    if nativeEvent then
        -- The payload is remembered even before the recipe has a CAB row, so a
        -- later scan shows the addition and never revives a removal.
        rememberFavorite(recipeSpellID, isFavorite)
        -- One spell can be present in both parent and child snapshots. The
        -- event describes every occurrence without requiring contextual APIs.
        for _, entry in pairs(records) do
            local recipe = entry.recipes[recipeSpellID]
            if recipe and recipe.favorite ~= isFavorite then
                recipe.favorite, changed = isFavorite, true
            end
        end
        if changed then Catalogue.Invalidate() end
        return changed
    end
    local context = ns.API.BeginRecipeMetadataRead and ns.API.BeginRecipeMetadataRead()
    for key, entry in pairs(records) do
        for id, recipe in pairs(entry.recipes) do
            local metadata = ns.API.GetRecipeMetadata and ns.API.GetRecipeMetadata(id, key, nil, context) or {}
            -- metadata.favorite is nil for a cold, foreign or unavailable read.
            rememberFavorite(id, metadata.favorite)
            if metadata.progressionRead == true then
                for _, field in ipairs({"canSkillUp", "relativeDifficulty", "numSkillUps"}) do
                    if recipe[field] ~= metadata[field] then recipe[field], changed = metadata[field], true end
                end
            end
            for _, field in ipairs({"favorite", "canSkillUp", "relativeDifficulty", "numSkillUps"}) do
                if metadata[field] ~= nil and recipe[field] ~= metadata[field] then
                    recipe[field], changed = metadata[field], true
                end
            end
            local path = categoryPath(metadata.categoryPath)
            if path then
                local old, equal = recipe.categoryPath, true
                if not old or #old ~= #path then equal = false
                else
                    for index, category in ipairs(path) do
                        local other = old[index]
                        if category.id ~= other.id or category.name ~= other.name or category.sortIndex ~= other.sortIndex then
                            equal = false; break
                        end
                    end
                end
                if not equal then recipe.categoryPath, changed = path, true end
            end
        end
    end
    -- A reliable read of one snapshot also updates its other parent or child copy.
    if applyFavorites() then changed = true end
    if changed then Catalogue.Invalidate() end
    return changed
end

-- True while the memory holds no favourite at all (not even one CAB cannot
-- list, such as an enchantment) and a catalogued profession the character
-- still knows has not been read in its own native window: a cold passive scan
-- cannot see favourites. The hint explains where they come from; it never
-- says there are none.
function Catalogue.FavoritesHint()
    ensureLoaded()
    for _, value in pairs(favorites.recipes) do
        if value == true then return false end
    end
    local known, complete = ns.API.GetProfessions()
    local keys = {}
    for _, profession in ipairs(known) do keys[profession.key] = true end
    for key, entry in pairs(records) do
        local group = parentKey(key, entry)
        if next(entry.recipes) and (not complete or keys[key] or keys[group])
            and not favorites.read[key] and not favorites.read[group] then
            return true
        end
    end
    return false
end

-- Native recipe rows only display a skill-gain chevron for canSkillUp plus
-- Optimal (0), Medium (1) or Easy (2). Forever can report canSkillUp=true and
-- numSkillUps=1 even for Trivial (3), so neither flag/count alone is evidence
-- that a craft can advance this character's current profession.
-- Source: Blizzard_ProfessionsRecipeList.lua, Init, skillUpAtlas selection.
function Catalogue.CanSkillUp(recipe)
    return type(recipe) == "table" and not (issecretvalue and issecretvalue(recipe))
        and not (issecretvalue and issecretvalue(recipe.canSkillUp)) and recipe.canSkillUp == true
        and nonnegativeInteger(recipe.relativeDifficulty) and recipe.relativeDifficulty <= 2
end

local function rebuildRows(includeBank)
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
    if ns.Bank and includeBank then inventory, bank = ns.Bank.Snapshot(allRecipes)
    else inventory = ns.API.Inventory(allRecipes) end
    local result = {}
    for key, entry in pairs(records) do
        local parent = parentKey(key, entry)
        if not complete or knownNames[key] or knownNames[parent] then
            local prepared = ns.Planner.Prepare(entry.recipes)
            local limits = ns.API.RecipeLimits and ns.API.RecipeLimits(key)
            for id, recipe in pairs(entry.recipes) do
                local count, plan = ns.Planner.MaxCrafts(prepared, inventory, ns.vendorItems or {}, id, 1000, bank, limits)
                if limits and nonnegativeInteger(limits[id]) then
                    displayedLimits[key] = displayedLimits[key] or {}
                    displayedLimits[key][id] = limits[id]
                end
                if count > 0 or recipe.favorite == true then
                    -- A zero-count favourite keeps the failed one-craft plan:
                    -- its partial withdrawals cannot make the recipe craftable.
                    local bankMessage = count > 0 and ns.Bank and ns.Bank.Message(plan) or nil
                    -- The planner prefers owned bank supplies, but the colour
                    -- answers whether bags plus merchant supplies can make the
                    -- entire displayed quantity without withdrawing anything.
                    local needsBank = bankMessage ~= nil and not ns.Planner.Plan(prepared,
                        inventory, ns.vendorItems or {}, id, count, nil, limits).craftable
                    result[#result + 1] = {recipeID = id, professionKey = key, name = recipe.name,
                        groupProfessionKey = parent,
                        professionName = knownNames[key] or knownNames[parent] or entry.name, count = count, recipe = recipe,
                        bankMessage = bankMessage, needsBank = needsBank, favorite = recipe.favorite == true,
                        categoryPath = recipe.categoryPath or EMPTY}
                end
            end
        end
    end
    local nameBefore = ns.Locale.NameComparator()
    table.sort(result, function(a, b)
        if a.professionName ~= b.professionName then return nameBefore(a.professionName, b.professionName) end
        local ap, bp = a.categoryPath, b.categoryPath
        for index = 1, math.max(#ap, #bp) do
            local ac, bc = ap[index], bp[index]
            if not ac then return true end
            if not bc then return false end
            if ac.id ~= bc.id then
                -- A missing optional native order sorts last. Mixing numeric
                -- comparisons with name-only fallbacks is not transitive.
                local ao, bo = ac.sortIndex or math.huge, bc.sortIndex or math.huge
                if ao ~= bo then return ao < bo end
                if ac.name ~= bc.name then return ac.name < bc.name end
                return ac.id < bc.id
            end
        end
        if a.name ~= b.name then return nameBefore(a.name, b.name) end
        if a.recipeID ~= b.recipeID then return a.recipeID < b.recipeID end
        return a.professionKey < b.professionKey
    end)
    rows[includeBank and "bank" or "bags"] = result
end

-- A child snapshot is the profession's exact skill line, read in its own
-- native window: passive reads always use the parent key. The copy the
-- selection points to comes first, so the recipe sheet and its highlight keep
-- showing the recipe the player chose, whichever copy that is.
local function favoriteRank(row)
    local selected = row.recipeID == ns.selectedID and row.professionKey == ns.selectedProfessionKey
    return (selected and 2 or 0) + (row.professionKey ~= row.groupProfessionKey and 1 or 0)
end

local function filteredRows(search, options, favorites)
    ensureLoaded()
    local includeBank = not options or options.includeBank ~= false
    local cacheKey = includeBank and "bank" or "bags"
    if not rows[cacheKey] then rebuildRows(includeBank) end
    local needle = searchText(ns.Locale.TrimSearch(search))
    local result = {}
    local favoriteSlots = favorites and {}
    for _, row in ipairs(rows[cacheKey]) do
        local show = favorites and row.favorite or not favorites and row.count > 0
            and (not options or not options.progressionOnly or Catalogue.CanSkillUp(row.recipe))
        if show and (needle == "" or string.find(searchText(row.name .. " " .. row.professionName), needle, 1, true)) then
            if favoriteSlots then
                -- A parent and a child snapshot of one profession can hold the
                -- same spell: list it once, from the selected copy, otherwise
                -- from the native child.
                local slot = tostring(row.groupProfessionKey) .. ":" .. tostring(row.recipeID)
                local index = favoriteSlots[slot]
                if not index then
                    result[#result + 1] = row
                    favoriteSlots[slot] = #result
                elseif favoriteRank(row) > favoriteRank(result[index]) then
                    result[index] = row
                end
            else
                result[#result + 1] = row
            end
        end
    end
    return result
end

function Catalogue.Rows(search, options)
    return filteredRows(search, options, false)
end

function Catalogue.Favorites(search, options)
    return filteredRows(search, options, true)
end
