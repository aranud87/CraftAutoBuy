local _, ns = ...
local View = {}
ns.StockView = View

-- Per-character display preferences only. Stock evidence and recipe catalogues
-- remain independent, and no change here can transfer, buy or craft an item.
local loadedDB, loadedState
local MAX_ID, MAX_SCROLL = 2147483647, 10000000
local scrollKeys = {bags = true, bank = true, inventory = true}

local function secret(value)
    return issecretvalue and issecretvalue(value)
end

local function integer(value, minimum, maximum)
    return not secret(value) and type(value) == "number" and value == value
        and value >= minimum and value <= maximum and value == math.floor(value)
end

local function offset(value)
    if secret(value) or type(value) ~= "number" or value ~= value
        or value == math.huge or value == -math.huge then return nil end
    return math.max(0, math.min(MAX_SCROLL, value))
end

local function sanitize(saved)
    local state = {schema = 1, content = "components", inventory = false,
        extensionsExpanded = false, comparisonSize = 20,
        scroll = {bags = 0, bank = 0, inventory = 0}}
    if secret(saved) or type(saved) ~= "table" or secret(saved.schema) or saved.schema ~= 1 then return state end
    if not secret(saved.content) and (saved.content == "components" or saved.content == "all") then
        state.content = saved.content
    end
    if integer(saved.professionKey, 1, MAX_ID) then state.professionKey = saved.professionKey end
    for _, key in ipairs({"inventory", "extensionsExpanded"}) do
        if not secret(saved[key]) and type(saved[key]) == "boolean" then state[key] = saved[key] end
    end
    if integer(saved.comparisonSize, 1, 100) then state.comparisonSize = saved.comparisonSize end
    if not secret(saved.scroll) and type(saved.scroll) == "table" then
        for key in pairs(scrollKeys) do state.scroll[key] = offset(saved.scroll[key]) or 0 end
    end
    return state
end

function View.Get()
    if type(CraftAutoBuyDB) ~= "table" or secret(CraftAutoBuyDB) then CraftAutoBuyDB = {} end
    if loadedDB ~= CraftAutoBuyDB or loadedState ~= CraftAutoBuyDB.stockView then
        loadedState = sanitize(CraftAutoBuyDB.stockView)
        CraftAutoBuyDB.stockView, loadedDB = loadedState, CraftAutoBuyDB
    end
    return loadedState
end

function View.SetContent(value)
    if secret(value) or (value ~= "components" and value ~= "all") then return false end
    View.Get().content = value
    return true
end

function View.SetProfession(key)
    if key ~= nil and not integer(key, 1, MAX_ID) then return false end
    View.Get().professionKey = key
    return true
end

function View.SetInventory(value)
    if secret(value) or type(value) ~= "boolean" then return false end
    View.Get().inventory = value
    return true
end

function View.SetExtensions(value)
    if secret(value) or type(value) ~= "boolean" then return false end
    View.Get().extensionsExpanded = value
    return true
end

function View.SetComparisonSize(value)
    if not integer(value, 1, 100) then return false end
    View.Get().comparisonSize = value
    return true
end

function View.SetScroll(key, value)
    if secret(key) or type(key) ~= "string" or not scrollKeys[key] then return false end
    local bounded = offset(value)
    if bounded == nil then return false end
    View.Get().scroll[key] = bounded
    return true
end
