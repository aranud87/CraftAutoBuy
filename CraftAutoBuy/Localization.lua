local _, ns = ...
local Locale = {}
ns.Locale = Locale

-- English is loaded first and supplies every missing translation. Locale packs
-- are registered before the functional modules in the TOC.
-- Keep ns.L stable: modules may retain a local reference while the locale changes.
local FALLBACK = "enUS"
local translations, missing = {}, {}

function Locale.GetFallbackLocale() return FALLBACK end

-- This is the game's language, independent of the character's CAB preference.
-- Cached recipe names and the automatic setting must follow the client.
-- The second result distinguishes a real detection from the default fallback.
function Locale.GetClientLocale()
    if type(GetLocale) == "function" then
        local ok, code = pcall(GetLocale)
        if ok and not (issecretvalue and issecretvalue(code))
            and type(code) == "string" and code ~= "" then return code, true end
    end
    return FALLBACK, false
end

local requested = Locale.GetClientLocale()
local active = FALLBACK

ns.L = setmetatable({}, {
    __index = function(_, key)
        local current, fallback = translations[active], translations[FALLBACK]
        if current and current[key] then return current[key] end
        if fallback and fallback[key] then return fallback[key] end
        missing[key] = true
        -- A coding mistake must not expose an internal identifier to players.
        return fallback and fallback.TEXT_UNAVAILABLE or ""
    end,
})

function Locale.RegisterLocale(code, values)
    assert(type(code) == "string" and code ~= "", "Locale code must be a non-empty string")
    assert(type(values) == "table", "Locale translations must be a table")
    local copy = {}
    for key, value in pairs(values) do
        assert(type(key) == "string" and key:match("^[A-Z][A-Z0-9_]*$"), "Locale keys must be stable uppercase identifiers")
        assert(type(value) == "string" and value ~= "", "Locale values must be non-empty strings")
        copy[key] = value
    end
    translations[code] = copy
    if code == requested then active = code end
end

function Locale.SetLocale(code)
    requested = type(code) == "string" and code or FALLBACK
    active = Locale.ResolveLocale(requested)
    return active
end

function Locale.HasLocale(code)
    return type(code) == "string" and translations[code] ~= nil
end

function Locale.ResolveLocale(code)
    return Locale.HasLocale(code) and code or FALLBACK
end

function Locale.GetAvailableLocales()
    local result = {}
    for code, values in pairs(translations) do
        result[#result + 1] = {code = code, name = values.LANGUAGE_NAME or code}
    end
    table.sort(result, function(a, b) return a.code < b.code end)
    return result
end

function Locale.GetLocale()
    return active
end

function Locale.GetMissingKeys()
    local keys = {}
    for key in pairs(missing) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- Lua 5.1 lower() is byte-based and can use the host C locale, corrupting UTF-8
-- lead bytes. Fold whole characters, then only explicit ASCII capitals.
-- This search key never replaces the displayed item name.
local UTF8_CHARACTER = "[\194-\244][\128-\191]*"
local SEARCH_FOLD = {
    ["À"] = "a", ["à"] = "a", ["Á"] = "a", ["á"] = "a", ["Â"] = "a", ["â"] = "a",
    ["Ã"] = "a", ["ã"] = "a", ["Ä"] = "a", ["ä"] = "a", ["Å"] = "a", ["å"] = "a",
    ["Æ"] = "ae", ["æ"] = "ae", ["Ç"] = "c", ["ç"] = "c",
    ["È"] = "e", ["è"] = "e", ["É"] = "e", ["é"] = "e", ["Ê"] = "e", ["ê"] = "e", ["Ë"] = "e", ["ë"] = "e",
    ["Ì"] = "i", ["ì"] = "i", ["Í"] = "i", ["í"] = "i", ["Î"] = "i", ["î"] = "i", ["Ï"] = "i", ["ï"] = "i",
    ["Ñ"] = "n", ["ñ"] = "n", ["Ò"] = "o", ["ò"] = "o", ["Ó"] = "o", ["ó"] = "o", ["Ô"] = "o", ["ô"] = "o",
    ["Õ"] = "o", ["õ"] = "o", ["Ö"] = "o", ["ö"] = "o", ["Ø"] = "o", ["ø"] = "o", ["Œ"] = "oe", ["œ"] = "oe",
    ["Ù"] = "u", ["ù"] = "u", ["Ú"] = "u", ["ú"] = "u", ["Û"] = "u", ["û"] = "u", ["Ü"] = "u", ["ü"] = "u",
    ["Ý"] = "y", ["ý"] = "y", ["Ÿ"] = "y", ["ÿ"] = "y", ["ß"] = "ss", ["ẞ"] = "ss",
    -- Game names carry the typographic apostrophe; a typed query the straight one.
    ["’"] = "'", ["‘"] = "'",
}
local lowerCyrillic = {}
for character in ("абвгдежзийклмнопрстуфхцчшщъыьэюяё"):gmatch(UTF8_CHARACTER) do
    lowerCyrillic[#lowerCyrillic + 1] = character
end
local index = 0
for character in ("АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯЁ"):gmatch(UTF8_CHARACTER) do
    index = index + 1
    SEARCH_FOLD[character] = lowerCyrillic[index]
end

function Locale.SearchText(text)
    if type(text) ~= "string" then return "" end
    local folded = text:gsub(UTF8_CHARACTER, SEARCH_FOLD)
    return (folded:gsub("[A-Z]", function(character) return string.char(character:byte() + 32) end))
end
