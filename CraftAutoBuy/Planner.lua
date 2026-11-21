local _, ns = ...

-- Pure planning: no game API, inventory mutation, or purchases happen here.
-- A recipe's outputCount is its guaranteed yield per execution, not a maximum.
-- Prefer the lowest feasible recipe ID. When producers share ingredients,
-- replay alternative allocations from the original stock before accepting one.
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
    if type(recipe) ~= "table" or recipe.supported == false or recipe.learned == false then return false end
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
-- The same eligibility decides elsewhere whether a record can produce its
-- output at all (Core keeps saved records of loading producers with it).
Planner.IsUsableRecipe = validRecipe

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
            local ids = context.producers[output] or {}
            if ids[1] then context.hasAlternatives = true end
            context.producers[output] = ids
            ids[#ids + 1] = id
        end
    end
    for _, ids in pairs(context.producers) do table.sort(ids) end
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

local function attempt(recipes, inventory, vendors, recipeID, crafts, bankCounts, sparse, limits, route, options)
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

    local active, used = {}, {}
    -- Once any material fails, this attempt fails whatever is chosen later:
    -- stop recording route choices so the odometer varies earlier ones.
    local doomed = false
    local allProducers = type(options) == "table" and options.allProducers == true
    local reserved = context.hasAlternatives and {} or nil
    local craft

    -- Upper bound for one route. Shared inputs may be counted in different
    -- branches here. The actual draft must still reserve each unit once.
    local visiting, probes = {}, 0
    local function capacity(id, requested)
        if active[id] or visiting[id] then return 0 end
        local ceiling = limits and limits[id]
        if integer(ceiling, 0) then requested = math.min(requested, ceiling - (used[id] or 0)) end
        if requested <= 0 then return 0 end
        probes = probes + 1
        if probes > 128 then return requested end
        visiting[id] = true
        for _, reagent in ipairs(recipes[id].reagents) do
            local raw = reagent.itemID
            if not vendors[raw] then
                local count = (plan.inventory[raw] or 0) + (bank[raw] or 0) - (reserved[raw] or 0)
                local need = requested * reagent.quantity
                for _, producer in ipairs(producers[raw] or {}) do
                    if count >= need then break end
                    local yield = recipes[producer].outputCount
                    count = count + yield * capacity(producer, math.ceil((need - count) / yield))
                end
                requested = math.min(requested, math.floor(count / reagent.quantity))
                if requested <= 0 then break end
            end
        end
        visiting[id] = nil
        return math.max(0, requested)
    end

    local function produce(id, itemID, executions, shortfall, depth)
        if active[id] then
            addCount(plan.missing, itemID, shortfall)
            addError(plan, "cycle")
            for ancestor, ancestorDepth in pairs(active) do
                local output = recipes[ancestor].outputItemID
                local bagged = inventory[output]
                local stored = bankCounts and bankCounts[output]
                if ancestorDepth >= active[id] and (integer(bagged, 1) or integer(stored, 1)) then
                    plan.seededCycle = true
                    break
                end
            end
            return false
        end
        if not craft(id, executions, depth) then return false end
        plan.inventory[itemID] = plan.inventory[itemID] - shortfall
        return true
    end

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

        local ids = producers[itemID]
        if not ids then
            addCount(plan.missing, itemID, shortfall)
            return false
        end
        if depth > MAX_DEPTH then
            addCount(plan.missing, itemID, shortfall)
            addError(plan, "depth_limit")
            return false
        end

        for index, id in ipairs(ids) do
            local yield = recipes[id].outputCount
            local runs = math.ceil(shortfall / yield)
            if index < #ids then
                probes = 0
                local upper = capacity(id, runs)
                local other = 0
                for n = index + 1, #ids do
                    local alt = ids[n]
                    local altYield = recipes[alt].outputCount
                    other = other + capacity(alt, math.ceil(shortfall / altYield)) * altYield
                end
                local lower = math.max(0, math.ceil((shortfall - other) / yield))
                if lower <= upper then
                    runs = upper
                    if lower < upper and doomed then
                        -- Skipped choice: MaxCrafts may still need a gap check.
                        plan.prunedChoice = true
                    elseif lower < upper then
                        -- Try the preferred and the alternative route first,
                        -- then mixed batches. A later reagent may need the
                        -- stock consumed here, so the choice spans the plan.
                        route.cursor = route.cursor + 1
                        local n = route.cursor
                        local choice = route[n] or 0
                        route[n], route.last[n] = choice, upper - lower
                        if choice == 1 then runs = lower
                        elseif choice > 1 then runs = upper - choice + 1 end
                    end
                else
                    -- No split covers the shortfall (capacities are upper
                    -- bounds), so this attempt fails.
                    doomed = true
                    if upper == 0 and other > 0 then
                        runs = 0
                    elseif allProducers and upper > 0 then
                        -- Withdrawal previews: let each producer bring its
                        -- capacity so the failing plan lists every usable
                        -- bank withdrawal, not only the first route's.
                        runs = upper
                    end
                end
            end
            if runs > 0 then
                local consumed = math.min(shortfall, runs * yield)
                if not produce(id, itemID, runs, consumed, depth) then return false end
                shortfall = shortfall - consumed
                if shortfall == 0 then return true end
            end
        end
        return false
    end

    craft = function(id, executions, depth)
        local recipe = recipes[id]
        local ceiling = limits and limits[id]
        if integer(ceiling, 0) and (used[id] or 0) + executions > ceiling then
            addError(plan, "craft_limit")
            return false
        end
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

        active[id] = depth
        -- A later raw ingredient of this recipe cannot be substituted. Hold
        -- its units while choosing how to produce an earlier intermediate.
        if reserved then
            for _, reagent in ipairs(recipe.reagents) do
                if not vendors[reagent.itemID] and not producers[reagent.itemID] then
                    addCount(reserved, reagent.itemID, reagent.quantity * executions)
                end
            end
        end
        local possible = true
        for _, reagent in ipairs(recipe.reagents) do
            if reserved and reserved[reagent.itemID] then
                addCount(reserved, reagent.itemID, -reagent.quantity * executions)
            end
            if not consume(reagent.itemID, reagent.quantity * executions, depth + 1) then
                possible = false
                doomed = true
            end
        end
        active[id] = nil
        if not possible then return false end

        if integer(ceiling, 0) then used[id] = (used[id] or 0) + executions end
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

local function calculate(recipes, inventory, vendors, recipeID, crafts, bankCounts, sparse, limits, budget, options)
    if type(recipes) == "table" and not preparedContext(recipes) then recipes = Planner.Prepare(recipes) end
    local route, first = {last = {}}, nil
    -- Bound synchronous work on pathological graphs. Only fully verified
    -- routes can escape as craftable. Ordinary single-producer plans run once.
    -- budget (optional) is shared by several calls; the caller checks that
    -- it is positive before calling, so at least one attempt always runs.
    for trial = 1, 128 do
        if budget then
            if budget.left <= 0 and first then break end
            budget.left = budget.left - 1
        end
        route.cursor = 0
        local plan = attempt(recipes, inventory, vendors, recipeID, crafts, bankCounts, sparse, limits, route, options)
        if plan.craftable then return plan end
        first = first or plan
        if plan.seededCycle then first.seededCycle = true end
        if plan.prunedChoice then first.prunedChoice = true end
        local index = route.cursor
        while index > 0 and route[index] >= route.last[index] do index = index - 1 end
        if index == 0 then return first end
        route[index] = route[index] + 1
        for n = #route, index + 1, -1 do route[n] = nil end
    end
    return first
end

-- options (optional): {allProducers = true} lets a failing plan draw on every
-- alternative producer; bank withdrawal previews use it to retrieve all the
-- useful stock of a batch that cannot be completed yet.
function Planner.Plan(recipes, inventory, vendors, recipeID, crafts, bankCounts, limits, options)
    return calculate(recipes, inventory, vendors, recipeID, crafts, bankCounts, false, limits, nil, options)
end

-- Returns the maximum feasible executions up to limit (default 1000), plus its
-- plan. If none is possible, return the failing one-execution plan for an UI's
-- missing-material list. atLimit warns that the answer is a bounded maximum.
-- Reciprocal multi-output conversions with seed stock can fail at one quantity
-- and succeed at a higher one. Check gaps when a bounded UI probe hits one.
function Planner.MaxCrafts(recipes, inventory, vendors, recipeID, limit, bankCounts, limits)
    limit = limit == nil and 1000 or limit
    if not integer(limit, 1) then
        local invalid = Planner.Plan(recipes, inventory, vendors, recipeID, 0, bankCounts)
        invalid.craftable = false
        invalid.maxCrafts = 0
        addError(invalid, "invalid_limit")
        return 0, invalid
    end

    recipes = Planner.Prepare(recipes)

    local maximum = limit
    if limits and integer(recipeID, 1) and integer(limits[recipeID], 0) then
        maximum = math.min(maximum, limits[recipeID])
    end
    -- Shared walk over the producers reachable from a recipe through its
    -- non-vendor reagents (vendor items are bought, never crafted).
    local context = preparedContext(recipes)
    local function eachProducer(id, visit)
        local recipe = context and context.recipes[id]
        for _, reagent in ipairs(recipe and recipe.reagents or {}) do
            if not vendors[reagent.itemID] then
                for _, producer in ipairs(context.producers[reagent.itemID] or {}) do visit(producer) end
            end
        end
    end
    local function stock(itemID)
        local bags, stored = inventory[itemID], type(bankCounts) == "table" and bankCounts[itemID]
        return (integer(bags, 0) and bags or 0) + (integer(stored, 0) and stored or 0)
    end
    -- Physical ceiling. When every reachable producer consumes at least as
    -- many non-vendor units as it yields, crafting never creates matter: the
    -- target cannot run more often than the reachable stock pays for. The
    -- target's own output only exists after its batch, so it cannot feed it.
    -- No ceiling (nil) as soon as one producer could multiply units.
    -- Stock that only limited recipes can consume counts up to what their
    -- remaining charges can take: the rest of it can never reach the target.
    local function stockCeiling()
        if not context or type(vendors) ~= "table" or type(inventory) ~= "table" then return nil end
        local target = context.recipes[recipeID]
        if not target then return nil end
        local items, seen, queue = {}, {[recipeID] = true}, {}
        -- items[id]: units its consumers may take, or true when one of them
        -- is unlimited (the target always is: its own limit bounds maximum).
        local function units(recipe, id)
            local count = 0
            local allowance = id ~= recipeID and limits and limits[id]
            for _, reagent in ipairs(recipe.reagents) do
                if not vendors[reagent.itemID] then
                    count = count + reagent.quantity
                    local taken = items[reagent.itemID]
                    if not integer(allowance, 0) then
                        items[reagent.itemID] = true
                    elseif taken ~= true then
                        items[reagent.itemID] = (taken or 0) + allowance * reagent.quantity
                    end
                end
            end
            return count
        end
        local perCraft = units(target, recipeID)
        if perCraft < 1 then return nil end
        eachProducer(recipeID, function(id) if not seen[id] then seen[id] = true; queue[#queue + 1] = id end end)
        while #queue > 0 do
            local id = table.remove(queue)
            local recipe = context.recipes[id]
            if units(recipe, id) < (recipe.outputCount or 1) then return nil end
            eachProducer(id, function(next) if not seen[next] then seen[next] = true; queue[#queue + 1] = next end end)
        end
        local total = 0
        for itemID, taken in pairs(items) do
            total = total + (taken == true and stock(itemID) or math.min(stock(itemID), taken))
            if total >= 2^40 then return nil end
        end
        return math.floor(total / perCraft)
    end
    local ceiling = stockCeiling()
    local first = calculate(recipes, inventory, vendors, recipeID, 1, bankCounts, true, limits)
    -- A verified plan above the ceiling would disprove it: never trust it then.
    if ceiling and first.craftable and ceiling < 1 then ceiling = nil end
    -- Highest quantity worth probing in the gap search.
    local top = ceiling and math.min(maximum, ceiling) or maximum
    -- Skipped route choices (failed attempts) may hide a seeded cycle that
    -- beta.9 noticed in a later trial. Check statically, once, on demand:
    -- a producer cycle reachable from the target with stock on one output.
    local seeded
    local function seededGraph()
        if seeded ~= nil then return seeded end
        seeded = false
        if not context or type(vendors) ~= "table" or type(inventory) ~= "table" then return seeded end
        local reachable, queue = {[recipeID] = true}, {recipeID}
        while #queue > 0 do
            local id = table.remove(queue)
            eachProducer(id, function(next)
                if not reachable[next] then reachable[next] = true; queue[#queue + 1] = next end
            end)
        end
        for id in pairs(reachable) do
            local output = context.recipes[id] and context.recipes[id].outputItemID
            if output and stock(output) > 0 then
                -- Does this stocked recipe lie on a producer cycle?
                local visited, pending = {}, {id}
                while #pending > 0 and not seeded do
                    local current = table.remove(pending)
                    eachProducer(current, function(next)
                        if next == id then seeded = true
                        elseif not visited[next] then visited[next] = true; pending[#pending + 1] = next end
                    end)
                end
                if seeded then break end
            end
        end
        return seeded
    end
    -- The gap search is bounded. low + 1 already failed (the last refused
    -- binary probe, or the one-craft plan). Two quantities get a complete
    -- plan, as every quantity did in beta.9: the top, which under a stock
    -- ceiling is often the true maximum, and low + 2, the nearest gap. The
    -- climb then shares one attempt budget: each quantity gets a small slice
    -- so one failing quantity cannot spend it all, and a quantity that used
    -- its whole slice is costly to refute, so the stride doubles across such
    -- failures. Every result is a fully verified plan: the bound may miss a
    -- gap (conservative), never overstate one. Known misses: a maximum
    -- below the top whose quantities each need more than one slice to
    -- verify, and a quantity that the doubled stride steps over.
    local function checkCycleGaps(low, best)
        if limit <= 1000 and top >= low + 2 then
            local candidate = calculate(recipes, inventory, vendors, recipeID, top, bankCounts, true, limits)
            if candidate.craftable then return top, candidate end
            local budget = {left = 128}
            -- complete: all 128 attempts for this quantity, charged as one slice.
            local function probe(quantity, complete)
                local granted = complete and 128 or math.min(16, budget.left)
                local slice = {left = granted}
                local plan = calculate(recipes, inventory, vendors, recipeID, quantity, bankCounts, true, limits, slice)
                local used = granted - slice.left
                budget.left = budget.left - math.min(used, 16)
                return plan, used >= math.min(granted, 16), used > 16
            end
            local quantity, stride, costly, complete, late = low + 2, 1, false, true, false
            while quantity < top and budget.left > 0 do
                candidate, costly, late = probe(quantity, complete)
                complete = false
                if candidate.craftable and late then
                    -- Verified with more than one slice: keep the result, but
                    -- move on as after a costly failure. The next quantity is
                    -- likely as costly, and the climb must keep its reach.
                    low, best = quantity, candidate
                    quantity, stride = quantity + stride, stride * 2
                elseif candidate.craftable then
                    low, best, stride = quantity, candidate, 1
                    quantity = quantity + 1
                elseif costly then
                    quantity, stride = quantity + stride, stride * 2
                else
                    quantity, stride = quantity + 1, 1
                end
            end
        end
        return low, best
    end
    if not first.craftable then
        local count = 0
        if first.seededCycle or (first.prunedChoice and seededGraph()) then count, first = checkCycleGaps(0, first) end
        first.maxCrafts, first.atLimit = count, count == limit
        return count, materializeInventory(first, inventory)
    end

    local low, high, best, sawCycle, skipped = 1, maximum, first, false, false
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if ceiling and middle > ceiling then
            -- The reachable stock cannot pay for this many: same answer as a
            -- failed probe, without planning it. The probe sequence is unchanged.
            skipped, high = true, middle - 1
        else
            local candidate = calculate(recipes, inventory, vendors, recipeID, middle, bankCounts, true, limits)
            if candidate.craftable then
                low, best = middle, candidate
            else
                sawCycle = sawCycle or candidate.seededCycle or (candidate.prunedChoice and seededGraph())
                high = middle - 1
            end
        end
    end
    -- A skipped probe could not report a seeded cycle: ask the static check.
    if not sawCycle and skipped and seededGraph() then sawCycle = true end
    if sawCycle then low, best = checkCycleGaps(low, best) end
    if best.crafts ~= low then
        best = calculate(recipes, inventory, vendors, recipeID, low, bankCounts, true, limits)
    end
    best.maxCrafts = low
    best.atLimit = low == limit
    return low, materializeInventory(best, inventory)
end
