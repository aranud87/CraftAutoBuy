local _, ns = ...
local L = ns.L
local Bootstrap = {}
ns.Bootstrap = Bootstrap

local SCHEMA, INTERVAL, RETRY, CHUNK = 1, 0.10, 2, 5
local state, database, current, total, done = nil, nil, nil, 0, 0
local professions, missing = {}, {}
local dirty, waiting, nextStepAt, retryAt, lastReason = true, false, 0, 0, nil
local professionRetry = {}
local lastKey, lastRecipe, lastProgress, lastTotal

local function text(value)
    return type(value) == "string" and value ~= ""
        and not (issecretvalue and issecretvalue(value)) and value or nil
end

local function character()
    if type(UnitGUID) ~= "function" then return nil end
    local ok, value = pcall(UnitGUID, "player")
    return ok and text(value) or nil
end

local function clock()
    return type(GetTime) == "function" and GetTime() or 0
end

local function busy()
    return ns.job or ns.pendingStart or ns.bankConfirmation
        or (ns.InCombat and ns.InCombat())
        or (InCombatLockdown and InCombatLockdown())
        or (ns.Merchant and ns.Merchant.IsBusy and ns.Merchant.IsBusy())
end

local function ensureState()
    if type(CraftAutoBuyDB) ~= "table" then CraftAutoBuyDB = {} end
    local locale = ns.Locale.GetClientLocale()
    local guid = character()
    if database == CraftAutoBuyDB and state == CraftAutoBuyDB.initialization
        and state.clientLocale == locale and (not guid or state.character == guid) then return end
    local saved = CraftAutoBuyDB.initialization
    local valid = type(saved) == "table" and saved.schema == SCHEMA
        and saved.clientLocale == locale and (not guid or not saved.character or saved.character == guid)
    state = {schema = SCHEMA, clientLocale = locale, character = guid or (valid and saved.character or nil),
        complete = false, professions = {}}
    -- Existing recipe records remain authoritative. This marker is never a
    -- reason to clear a 1.0.0 catalogue, bank evidence or preferences.
    CraftAutoBuyDB.initialization, database = state, CraftAutoBuyDB
    current, total, done, professions, missing = nil, 0, 0, {}, {}
    dirty, waiting, nextStepAt, retryAt, lastReason = true, false, 0, 0, nil
    professionRetry = {}
    lastKey, lastRecipe, lastProgress, lastTotal = nil, nil, 0, 0
end

local function reconcile()
    local known, complete = ns.API.GetProfessions()
    professions = type(known) == "table" and known or {}
    local unscanned = ns.Catalogue.MissingProfessions()
    local wanted = {}
    for _, entry in ipairs(unscanned or {}) do wanted[entry.key] = true end
    missing, total, done = {}, #professions, 0
    local active
    for _, entry in ipairs(professions) do
        if wanted[entry.key] then
            missing[#missing + 1] = entry
            state.professions[entry.key] = nil
            if current and current.professionKey == entry.key then active = true end
        else
            done = done + 1
            state.professions[entry.key] = true
        end
    end
    if current and not active then current = nil end
    state.complete = complete == true and #missing == 0
    -- An unavailable skill list cannot certify an empty installation.
    if complete ~= true then state.complete = false end
    dirty = false
    return complete == true
end

function Bootstrap.Init()
    ensureState()
    reconcile()
    return state
end

function Bootstrap.Wake()
    ensureState()
    dirty = true
    -- Waking can update the view, but cannot bypass an API retry delay.
    nextStepAt = 0
end

function Bootstrap.IsPending()
    ensureState()
    return state.complete ~= true
end

function Bootstrap.StatusText()
    ensureState()
    if state.complete then return nil end
    if waiting then
        local names = {}
        for _, entry in ipairs(missing) do names[#names + 1] = text(entry.name) or ns.API.ProfessionName(entry.key) end
        return L.INITIALIZATION_WAITING:format(#names > 0 and table.concat(names, ", ") or L.LOADING_PROFESSION)
    end
    return L.INITIALIZING_RECIPES:format(done, total)
end

function Bootstrap.GetState()
    ensureState()
    return {complete = state.complete, done = done, total = total, waiting = waiting,
        professionKey = current and current.professionKey or lastKey,
        recipeID = current and current.ids and current.ids[current.cursor] or lastRecipe,
        progress = current and current.progress or lastProgress or 0,
        recipeTotal = current and current.total or lastTotal or 0,
        lastReason = lastReason}
end

local function refresh()
    if ns.Refresh then ns.Refresh() end
end

local function waitForData(time, reason, key)
    local changed = not waiting or lastReason ~= reason
    key = key or (current and current.professionKey)
    if key then professionRetry[key] = time + RETRY else retryAt = time + RETRY end
    current, waiting, lastReason = nil, true, reason
    if changed then refresh() end
end

function Bootstrap.Tick(time)
    ensureState()
    if state.complete and not dirty then return end
    if busy() then return end
    time = type(time) == "number" and time or clock()
    if time < nextStepAt then return end
    nextStepAt = time + INTERVAL
    local previouslyComplete, previousDone = state.complete, done
    local completeList = reconcile()
    if state.complete then
        waiting, lastReason, current = false, nil, nil
        if not previouslyComplete or previousDone ~= done then refresh() end
        return
    end
    if time < retryAt then return end
    if not completeList or #missing == 0 then waitForData(time, L.LOADING_PROFESSION); return end
    if type(ns.API.BeginBackgroundScan) ~= "function" or type(ns.API.StepBackgroundScan) ~= "function" then
        waitForData(time, L.PROFESSION_API_UNAVAILABLE); return
    end
    if not current then
        local candidate
        for _, entry in ipairs(missing) do
            if time >= (professionRetry[entry.key] or 0) then candidate = entry; break end
        end
        if not candidate then return end
        lastKey, lastRecipe, lastProgress, lastTotal = candidate.key, nil, 0, 0
        local ok, scan, reason = pcall(ns.API.BeginBackgroundScan, candidate.key)
        if not ok or type(scan) ~= "table" then
            waitForData(time, ok and reason or L.RECIPES_LOADING, candidate.key); return
        end
        current, waiting, lastReason = scan, false, nil
        refresh()
    end
    lastKey, lastRecipe = current.professionKey, current.ids and current.ids[current.cursor]
    lastProgress, lastTotal = current.progress or 0, current.total or 0
    local ok, recipes, complete, reason = pcall(ns.API.StepBackgroundScan, current, CHUNK)
    lastProgress = current.progress or lastProgress
    lastRecipe = current.ids and current.ids[current.cursor] or lastRecipe
    if not ok then waitForData(time, L.RECIPES_LOADING); return end
    if complete == true and type(recipes) == "table" then
        local key = current.professionKey
        if not ns.Catalogue.Record(key, recipes, true) then waitForData(time, L.RECIPES_LOADING); return end
        professionRetry[key] = nil
        current, waiting, lastReason = nil, false, nil
        reconcile()
        refresh()
    elseif reason then
        waitForData(time, reason)
    end
end
