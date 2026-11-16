local _, ns = ...

-- Pure planning: no game API, inventory mutation, or purchases happen here.
-- A recipe's outputCount is its guaranteed yield per execution, not a maximum.
-- If several recipes produce the same item, the lowest recipe ID wins. This
-- planner deliberately does not optimize costs or search alternative recipes.
-- Cycles requiring an initial stock may be usable if that stock breaks the
-- dependency chain; otherwise they are reported as missing, never recursed.
local Planner = {}
ns.Planner = Planner

local MAX_INTEGER = 2147483647
local MAX_DEPTH = 64
local CONTEXT_KEY = {}

local function preparedContext(handle)
    local meta = getmetatable(handle)
    return type(meta) == "table" and rawget(meta, CONTEXT_KEY) or nil
end

local function integer(value, minimum)
    return type(value) == "number" and value == value and value >= minimum
        and value <= MAX_INTEGER and value == math.floor(value)
end

local function validRecipe(recipe)
    if type(recipe) ~= "table" or recipe.supported == false then return false end
    if not integer(recipe.outputItemID, 1) then return false end
    if not integer(recipe.outputCount or 1, 1) then return false end
    if type(recipe.reagents) ~= "table" then return false end
    for _, reagent in ipairs(recipe.reagents) do
        if type(reagent) ~= "table" or not integer(reagent.itemID, 1)
            or not integer(reagent.quantity, 1) then
            return false
        end
    end
    return true
end

-- Explicit snapshots, never an implicit cache keyed by a mutable recipe map.
-- One maximum search or catalogue rebuild can reuse this validated producer
-- index. New calls with ordinary tables still observe every source mutation.
function Planner.Prepare(recipes)
    if type(recipes) ~= "table" then return nil end
    if preparedContext(recipes) then return recipes end
    local context = {recipes = {}, producers = {}}
    for id, recipe in pairs(recipes) do
        if integer(id, 1) and validRecipe(recipe) then
            local copied = {outputItemID = recipe.outputItemID,
                outputCount = recipe.outputCount or 1, reagents = {}}
            for index, reagent in ipairs(recipe.reagents) do
                copied.reagents[index] = {itemID = reagent.itemID, quantity = reagent.quantity}
            end
            context.recipes[id] = copied
            local output = copied.outputItemID
            if not context.producers[output] or id < context.producers[output] then
                context.producers[output] = id
            end
        end
    end
    -- The snapshot is owned by its empty handle, not a global weak-key registry.
    -- In Lua 5.1 such registries retain values for an extra collection after a
    -- key dies. Here a discarded handle and its snapshot become ordinary garbage.
    return setmetatable({}, {[CONTEXT_KEY] = context})
end

local function addError(plan, reason)
    for _, existing in ipairs(plan.errors) do
        if existing == reason then return end
    end
    plan.errors[#plan.errors + 1] = reason
end

local function addCount(counts, itemID, quantity)
    counts[itemID] = (counts[itemID] or 0) + quantity
end

local function stockReader(source)
    return {__index = function(_, itemID)
        local count = source and source[itemID]
        if integer(itemID, 1) and integer(count, 0) then return count end
    end}
end

local function materializeInventory(plan, inventory)
    if getmetatable(plan.inventory) then
        for itemID, count in pairs(inventory) do
            if rawget(plan.inventory, itemID) == nil and integer(itemID, 1) and integer(count, 0) then
                plan.inventory[itemID] = count
            end
        end
        setmetatable(plan.inventory, nil)
    end
    return plan
end

local function calculate(recipes, inventory, vendors, recipeID, crafts, bankCounts, sparse)
    local plan = {
        recipeID = recipeID,
        crafts = crafts,
        craftable = false,
        steps = {},
        purchases = {},
        bankWithdrawals = {},
        missing = {},
        errors = {},
        inventory = {},
    }
    if type(recipes) ~= "table" or type(inventory) ~= "table"
        or type(vendors) ~= "table" or not integer(recipeID, 1)
        or (bankCounts ~= nil and type(bankCounts) ~= "table") then
        addError(plan, "invalid_input")
        return plan
    end
    if not integer(crafts, 0) then
        addError(plan, "invalid_quantity")
        return plan
    end
    local context = preparedContext(recipes) or preparedContext(Planner.Prepare(recipes))
    recipes = context.recipes
    if not recipes[recipeID] then
        addError(plan, "unknown_or_unsupported_recipe")
        return plan
    end
    if sparse then
        -- Binary-search probes only need touched stock. Materialize the final
        -- returned inventory once, instead of copying every bag for every probe.
        setmetatable(plan.inventory, stockReader(inventory))
    else
        for itemID, count in pairs(inventory) do
            if integer(itemID, 1) and integer(count, 0) then
                plan.inventory[itemID] = count
            end
        end
    end
    -- Bank stock is a separate, consumable pool. It contributes to planning
    -- only; callers must require these withdrawals before buying or crafting.
    local bank = setmetatable({}, stockReader(bankCounts))
    if crafts == 0 then
        plan.craftable = true
        return plan
    end

    local producers = context.producers

    local active = {}
    local craft
    local function consume(itemID, quantity, depth)
        local available = plan.inventory[itemID] or 0
        local taken = math.min(available, quantity)
        plan.inventory[itemID] = available - taken
        local shortfall = quantity - taken
        if shortfall == 0 then return true end

        local bankAvailable = bank[itemID] or 0
        local withdrawal = math.min(bankAvailable, shortfall)
        if withdrawal > 0 then
            bank[itemID] = bankAvailable - withdrawal
            addCount(plan.bankWithdrawals, itemID, withdrawal)
            shortfall = shortfall - withdrawal
            if shortfall == 0 then return true end
        end

        if vendors[itemID] then
            addCount(plan.purchases, itemID, shortfall)
            return true
        end

        local producerID = producers[itemID]
        if not producerID then
            addCount(plan.missing, itemID, shortfall)
            return false
        end
        if active[producerID] then
            addCount(plan.missing, itemID, shortfall)
            addError(plan, "cycle")
            return false
        end
        if depth > MAX_DEPTH then
            addCount(plan.missing, itemID, shortfall)
            addError(plan, "depth_limit")
            return false
        end

        local yield = recipes[producerID].outputCount or 1
        local executions = math.ceil(shortfall / yield)
        if not craft(producerID, executions, depth) then return false end
        plan.inventory[itemID] = plan.inventory[itemID] - shortfall
        return true
    end

    craft = function(id, executions, depth)
        local recipe = recipes[id]
        local outputCount = recipe.outputCount or 1
        local produced = executions * outputCount
        if not integer(produced, 1) then
            addError(plan, "quantity_overflow")
            return false
        end
        -- Check quantities before modifying the virtual stock.
        for _, reagent in ipairs(recipe.reagents) do
            if not integer(reagent.quantity * executions, 1) then
                addError(plan, "quantity_overflow")
                return false
            end
        end

        active[id] = true
        local possible = true
        for _, reagent in ipairs(recipe.reagents) do
            if not consume(reagent.itemID, reagent.quantity * executions, depth + 1) then
                possible = false
            end
        end
        active[id] = nil
        if not possible then return false end

        addCount(plan.inventory, recipe.outputItemID, produced)
        plan.steps[#plan.steps + 1] = {
            recipeID = id,
            crafts = executions,
            outputItemID = recipe.outputItemID,
            outputCount = outputCount,
            produced = produced,
        }
        return true
    end

    -- Request executions of the selected recipe even when its result is already
    -- in the bags. Existing results only count as stock for its dependencies.
    plan.craftable = craft(recipeID, crafts, 0)
    if not plan.craftable and #plan.errors == 0 then
        addError(plan, "insufficient_reagents")
    end
    return plan
end

function Planner.Plan(recipes, inventory, vendors, recipeID, crafts, bankCounts)
    return calculate(recipes, inventory, vendors, recipeID, crafts, bankCounts, false)
end

-- Returns the maximum feasible executions up to limit (default 1000), plus its
-- plan. If none is possible, return the failing one-execution plan for an UI's
-- missing-material list. atLimit warns that the answer is a bounded maximum.
-- Reciprocal multi-output cycles can be non-monotone: in that exceptional case
-- binary search can underestimate the maximum, but every positive result is a
-- verified feasible plan. This is not an exhaustive cyclic production solver.
function Planner.MaxCrafts(recipes, inventory, vendors, recipeID, limit, bankCounts)
    limit = limit == nil and 1000 or limit
    if not integer(limit, 1) then
        local invalid = Planner.Plan(recipes, inventory, vendors, recipeID, 0, bankCounts)
        invalid.craftable = false
        invalid.maxCrafts = 0
        addError(invalid, "invalid_limit")
        return 0, invalid
    end

    recipes = Planner.Prepare(recipes)

    local first = calculate(recipes, inventory, vendors, recipeID, 1, bankCounts, true)
    if not first.craftable then
        first.maxCrafts = 0
        first.atLimit = false
        return 0, materializeInventory(first, inventory)
    end

    local low, high, best = 1, limit, first
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        local candidate = calculate(recipes, inventory, vendors, recipeID, middle, bankCounts, true)
        if candidate.craftable then
            low, best = middle, candidate
        else
            high = middle - 1
        end
    end
    if best.crafts ~= low then
        best = calculate(recipes, inventory, vendors, recipeID, low, bankCounts, true)
    end
    best.maxCrafts = low
    best.atLimit = low == limit
    return low, materializeInventory(best, inventory)
end
