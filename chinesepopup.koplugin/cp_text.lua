-- Text helpers, candidate generation and result ordering.
-- Pure Lua (no KOReader dependencies), so it is tested offline: tests/run.lua.

local Text = {}

Text.MAX_CONTEXT = 7   -- characters taken on each side of the tapped one
Text.MAX_WORD = 8      -- longest candidate word, in characters

-- Code point of a single UTF-8 character, or nil when s is not exactly one
-- well-formed character.
function Text.codepoint(s)
    if type(s) ~= "string" or s == "" then return nil end
    local b1 = s:byte(1)
    local n, cp
    if b1 < 0x80 then n, cp = 1, b1
    elseif b1 >= 0xC2 and b1 <= 0xDF then n, cp = 2, b1 - 0xC0
    elseif b1 >= 0xE0 and b1 <= 0xEF then n, cp = 3, b1 - 0xE0
    elseif b1 >= 0xF0 and b1 <= 0xF4 then n, cp = 4, b1 - 0xF0
    else return nil end
    if #s ~= n then return nil end
    for k = 2, n do
        local b = s:byte(k)
        if b < 0x80 or b > 0xBF then return nil end
        cp = cp * 64 + (b - 0x80)
    end
    return cp
end

-- CJK Unified Ideographs, all extensions, and the compatibility ideographs.
function Text.isHanCodepoint(cp)
    if not cp then return false end
    return (cp >= 0x4E00 and cp <= 0x9FFF)      -- CJK Unified Ideographs
        or (cp >= 0x3400 and cp <= 0x4DBF)      -- Extension A
        or (cp >= 0x20000 and cp <= 0x2EE5F)    -- Extensions B, C, D, E, F, I
        or (cp >= 0x30000 and cp <= 0x323AF)    -- Extensions G, H
        or (cp >= 0xF900 and cp <= 0xFAFF)      -- Compatibility Ideographs
        or (cp >= 0x2F800 and cp <= 0x2FA1F)    -- Compatibility Ideographs Supplement
end

-- True when s is exactly one Han character.
function Text.isHan(s)
    return Text.isHanCodepoint(Text.codepoint(s))
end

-- The UTF-8 characters of s (malformed bytes come out as single bytes).
function Text.chars(s)
    local out = {}
    for ch in (s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
    return out
end

-- The Han characters directly before the tapped one: the longest run of Han
-- characters at the end of `text`, at most `max` of them, in reading order.
-- Anything else (punctuation, Latin, digits, spaces, a paragraph break) ends it.
function Text.hanSuffix(text, max)
    max = max or Text.MAX_CONTEXT
    local chars, out = Text.chars(text), {}
    for k = #chars, 1, -1 do
        if #out >= max or not Text.isHan(chars[k]) then break end
        table.insert(out, 1, chars[k])
    end
    return out
end

-- The Han characters directly after the tapped one (see hanSuffix).
function Text.hanPrefix(text, max)
    max = max or Text.MAX_CONTEXT
    local chars, out = Text.chars(text), {}
    for k = 1, #chars do
        if #out >= max or not Text.isHan(chars[k]) then break end
        out[#out + 1] = chars[k]
    end
    return out
end

--[[--
Every substring of left .. char .. right that contains the tapped character,
1 to MAX_WORD characters long.

  left   Han characters before the tapped one, in reading order
  char   the tapped character
  right  Han characters after it

Returns { {text=, start=, len=}, ... } with start relative to the tapped
character (0 = starts with it, -2 = starts two characters before it), plus a
list of the distinct texts (for the query). Each text appears once in the
first list: the same string can occur at two positions (e.g. 天天 around a
tapped 天); the earliest start is kept.
]]
function Text.candidates(left, char, right, max_word)
    max_word = max_word or Text.MAX_WORD
    local seq = {}
    for _, c in ipairs(left or {}) do seq[#seq + 1] = c end
    seq[#seq + 1] = char
    local t = #seq
    for _, c in ipairs(right or {}) do seq[#seq + 1] = c end

    local out, texts, seen = {}, {}, {}
    for i = math.max(1, t - max_word + 1), t do
        for j = t, math.min(#seq, i + max_word - 1) do
            local text = table.concat(seq, "", i, j)
            if not seen[text] then
                seen[text] = true
                out[#out + 1] = { text = text, start = i - t, len = j - i + 1 }
                texts[#texts + 1] = text
            end
        end
    end
    return out, texts
end

-- A sense that only says the entry is a variant of the very word being shown
-- ("variant of 着 zháo" on a 着 entry) tells the reader nothing.
local function selfVariant(sense, word)
    local target = sense:match("^[%a ]*variant of (%S+)")
    return target ~= nil and target == word
end

-- Rows for one word: drop self-referring variant senses (and rows left with
-- none), and put ordinary readings before capitalised ones (surnames, place
-- names), keeping CC-CEDICT's order otherwise.
function Text.cleanRows(word, rows)
    local kept = {}
    for k, row in ipairs(rows) do
        local senses = {}
        for sense in (row.defs or ""):gmatch("[^/]+") do
            if not selfVariant(sense, word) then senses[#senses + 1] = sense end
        end
        if #senses > 0 then
            kept[#kept + 1] = { pinyin = row.pinyin, senses = senses, order = k,
                                proper = (row.pinyin or ""):match("^%u") ~= nil }
        end
    end
    table.sort(kept, function(a, b)
        if a.proper ~= b.proper then return not a.proper end
        return a.order < b.order
    end)
    return kept
end

--[[--
Combine candidates with dictionary rows into the popup's entries.

  cands  Text.candidates' first result
  rows   { {simp=, trad=, pinyin=, defs=}, ... } as returned by the query

Returns { {word=, start=, len=, entries={ {pinyin=, senses={...}}, ... }}, ... }:
the tapped character's own entry first (when the dictionary has it), then the
words, longest first, ties broken by the earlier start. A row matches a
candidate through either its simplified or its traditional form; the word is
shown as written in the book.
]]
function Text.order(cands, rows)
    local by_form = {}
    for _, row in ipairs(rows or {}) do
        for _, form in ipairs({ row.simp, row.trad }) do
            if form then
                local list = by_form[form]
                if not list then list = {}; by_form[form] = list end
                if list[#list] ~= row then list[#list + 1] = row end
            end
        end
    end
    local anchor, words = nil, {}
    for _, c in ipairs(cands) do
        local list = by_form[c.text]
        if list then
            local entries = Text.cleanRows(c.text, list)
            if #entries > 0 then
                local m = { word = c.text, start = c.start, len = c.len, entries = entries }
                if c.len == 1 then anchor = m else words[#words + 1] = m end
            end
        end
    end
    table.sort(words, function(a, b)
        if a.len ~= b.len then return a.len > b.len end
        return a.start < b.start
    end)
    if anchor then table.insert(words, 1, anchor) end
    return words
end

--[[--
The popup text for Text.order's result. Each word in bold with its pinyin,
then that reading's senses; further readings of the same word on their own
lines. Words separated by a blank line. b0/b1 are the bold markers
(TextBoxWidget's PTF markers in KOReader).

  靠谱 kàopǔ
  reliable; reasonable; probable
]]
function Text.render(matches, b0, b1)
    b0, b1 = b0 or "", b1 or ""
    local blocks = {}
    for _, m in ipairs(matches) do
        local lines = {}
        for k, e in ipairs(m.entries) do
            local senses = table.concat(e.senses, "; ")
            if k == 1 then
                lines[#lines + 1] = b0 .. m.word .. b1 .. "  " .. (e.pinyin or "")
                lines[#lines + 1] = senses
            else
                lines[#lines + 1] = (e.pinyin or "") .. ": " .. senses
            end
        end
        blocks[#blocks + 1] = table.concat(lines, "\n")
    end
    return table.concat(blocks, "\n\n")
end

-- Lay `items` out in rows of at most `per_row` (the popup's ButtonTable rows).
function Text.rows(items, per_row)
    per_row = per_row or 4
    local rows, row = {}, nil
    for _, item in ipairs(items) do
        if not row or #row >= per_row then
            row = {}
            rows[#rows + 1] = row
        end
        row[#row + 1] = item
    end
    return rows
end

return Text
