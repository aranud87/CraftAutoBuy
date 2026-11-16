local _, ns = ...

-- A conservative starter set of ordinary vendor crafting supplies from the
-- classic item IDs. Recipes and localized names always come from the client.
-- This is not a catalog of every item any NPC can sell: gathered materials,
-- limited-stock supplies, and reusable profession tools are deliberately absent.
-- Membership checked against LibPeriodicTable's Tradeskill.Mat.BySource.Vendor:
-- https://repos.wowace.com/wow/libperiodictable-3-1/trunk/LibPeriodicTable-3.1-Tradeskill/LibPeriodicTable-3.1-Tradeskill.lua
-- No prices are stored here. The open merchant determines actual availability,
-- package sizes, discounts and affordability before any purchase is attempted.
ns.VendorData = {
    DefaultItems = {
        -- Alchemy: vials.
        [3371] = true,  -- Empty Vial
        [3372] = true,  -- Leaded Vial
        [8925] = true,  -- Crystal Vial
        [18256] = true, -- Imbued Vial

        -- Tailoring / leatherworking: threads and dyes.
        [2320] = true,  -- Coarse Thread
        [2321] = true,  -- Fine Thread
        [4291] = true,  -- Silken Thread
        [8343] = true,  -- Heavy Silken Thread
        [14341] = true, -- Rune Thread
        [2324] = true,  -- Bleach
        [2604] = true,  -- Red Dye
        [2605] = true,  -- Green Dye
        [4340] = true,  -- Gray Dye
        [4341] = true,  -- Yellow Dye
        [4342] = true,  -- Purple Dye
        [6260] = true,  -- Blue Dye
        [6261] = true,  -- Orange Dye
        [10290] = true, -- Pink Dye

        -- Blacksmithing / engineering / leatherworking.
        [2880] = true, -- Weak Flux
        [3466] = true, -- Strong Flux
        [3857] = true, -- Coal
        [4289] = true, -- Salt

        -- Cooking: basic drinks and spices used as ingredients.
        [159] = true,  -- Refreshing Spring Water
        [1179] = true, -- Ice Cold Milk
        [2678] = true, -- Mild Spices
        [2692] = true, -- Hot Spices
        [3713] = true, -- Soothing Spices
    },
}
