local _, ns = ...
local BookArt = {}
ns.BookArt = BookArt
local states = setmetatable({}, {__mode = "k"})

-- Forever's native Refresh rewrites the profession title and portrait. Leave
-- those regions intact underneath our own presentation; revealing them on exit
-- then restores the latest native profession, without racing refresh events.
local function create(book)
    local state = {}
    local title = book.GetTitleText and book:GetTitleText()
    if title then
        local parent = book.TitleContainer or book
        state.nativeTitle = title
        state.title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        state.title:SetAllPoints(title)
        if title.GetFontObject then state.title:SetFontObject(title:GetFontObject()) end
        state.title:SetJustifyH("CENTER")
        state.title:SetWordWrap(false)
        state.title:Hide()
    end
    local portrait = book.GetPortrait and book:GetPortrait()
    if portrait then
        local parent = book.PortraitContainer or book
        local mask = parent.CircleMask
        state.nativePortrait = portrait
        -- Share the exact native circular mask; never put a square background
        -- outside the portrait if an unsupported frame has no such mask.
        if mask then
            state.background = parent:CreateTexture(nil, "ARTWORK")
            state.background:SetAllPoints(portrait)
            state.background:SetColorTexture(.04, .03, .02, 1)
            state.background:AddMaskTexture(mask)
            state.background:Hide()
        end
        state.icon = parent:CreateTexture(nil, "OVERLAY")
        state.icon:SetAllPoints(portrait)
        state.icon:SetTexCoord(0, 1, 0, 1)
        if mask then state.icon:AddMaskTexture(mask) end
        state.icon:Hide()
    end
    states[book] = state
    book.CraftAutoBuyBookArt = state
    return state
end

function BookArt.Release(book, owner)
    local state = book and states[book]
    if not state or state.owner ~= owner then return end
    state.owner = nil
    if state.title then
        state.title:Hide()
        state.nativeTitle:SetAlpha(state.titleAlpha)
    end
    if state.icon then
        state.icon:Hide()
        state.nativePortrait:SetAlpha(state.portraitAlpha)
    end
    if state.background then state.background:Hide() end
end

function BookArt.Acquire(book, owner, title, icon)
    if not book then return end
    local state = states[book] or create(book)
    if state.owner ~= owner then
        if state.owner then BookArt.Release(book, state.owner) end
        state.owner = owner
        if state.nativeTitle then
            state.titleAlpha = state.nativeTitle:GetAlpha()
            state.nativeTitle:SetAlpha(0)
        end
        if state.nativePortrait then
            state.portraitAlpha = state.nativePortrait:GetAlpha()
            state.nativePortrait:SetAlpha(0)
        end
    end
    if state.title then
        if state.title:GetText() ~= title then state.title:SetText(title) end
        if not state.title:IsShown() then state.title:Show() end
    end
    if state.icon then
        -- GetTexture may resolve an asset path to a numeric FileID. Remember
        -- our own argument instead of treating that resolution as a change.
        if state.iconAsset ~= icon then state.icon:SetTexture(icon); state.iconAsset = icon end
        if not state.icon:IsShown() then state.icon:Show() end
    end
    if state.background and not state.background:IsShown() then state.background:Show() end
end
