local _, ns = ...
local View = {}
ns.CatalogueView = View

-- Presentation preferences belong to this character, independently of the
-- recipe catalogue and stock. None of these writes starts a purchase/craft.
local loadedDB, loadedState
local MAX_ID, MAX_SCROLL, MAX_GROUPS = 2147483647, 10000000, 2048

local function secret(value)
    return issecretvalue and issecretvalue(value)
end

local function positiveID(value)
    return not secret(value) and type(value) == "number" and value == value
        and value >= 1 and value <= MAX_ID and value == math.floor(value)
end

local function groupKey(value)
    return not secret(value) and type(value) == "string" and #value > 0 and #value <= 160
        and value:match("^[%w_:.%-]+$") ~= nil
end

local function scrollValue(value)
    if secret(value) or type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge then return nil end
    return math.max(0, math.min(MAX_SCROLL, value))
end

local function sanitize(saved)
    local state = {schema = 1, includeBank = true, progressionOnly = false, collapsed = {}, scroll = 0}
    if type(saved) ~= "table" or saved.schema ~= 1 then return state end
    if type(saved.includeBank) == "boolean" and not secret(saved.includeBank) then
        state.includeBank = saved.includeBank
    end
    if type(saved.progressionOnly) == "boolean" and not secret(saved.progressionOnly) then
        state.progressionOnly = saved.progressionOnly
    end
    if type(saved.collapsed) == "table" then
        local count = 0
        for key, value in pairs(saved.collapsed) do
            if groupKey(key) and not secret(value) and value == true then
                state.collapsed[key] = true
                count = count + 1
                if count >= MAX_GROUPS then break end
            end
        end
    end
    if positiveID(saved.selectedID) and positiveID(saved.selectedProfessionKey) then
        state.selectedID, state.selectedProfessionKey = saved.selectedID, saved.selectedProfessionKey
    end
    state.scroll = scrollValue(saved.scroll) or 0
    return state
end

function View.Get()
    if type(CraftAutoBuyDB) ~= "table" then CraftAutoBuyDB = {} end
    if loadedDB ~= CraftAutoBuyDB or loadedState ~= CraftAutoBuyDB.catalogueView then
        loadedState = sanitize(CraftAutoBuyDB.catalogueView)
        CraftAutoBuyDB.catalogueView = loadedState
        loadedDB = CraftAutoBuyDB
    end
    return loadedState
end

function View.SetFilter(name, value)
    if (name ~= "includeBank" and name ~= "progressionOnly")
        or secret(value) or type(value) ~= "boolean" then return false end
    View.Get()[name] = value
    return true
end

function View.SetCollapsed(key, value)
    if not groupKey(key) or secret(value) or type(value) ~= "boolean" then return false end
    local state = View.Get()
    if value then
        if not state.collapsed[key] then
            local count = 0
            for _ in pairs(state.collapsed) do count = count + 1 end
            if count >= MAX_GROUPS then return false end
        end
        state.collapsed[key] = true
    else
        state.collapsed[key] = nil
    end
    return true
end

function View.SetSelection(recipeID, professionKey)
    if recipeID == nil and professionKey == nil then
        local state = View.Get()
        state.selectedID, state.selectedProfessionKey = nil, nil
        return true
    end
    if not positiveID(recipeID) or not positiveID(professionKey) then return false end
    local state = View.Get()
    state.selectedID, state.selectedProfessionKey = recipeID, professionKey
    return true
end

function View.SetScroll(offset)
    local value = scrollValue(offset)
    if value == nil then return false end
    View.Get().scroll = value
    return true
end
