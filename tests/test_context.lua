-- Tap -> character and neighbours (cp_context.lua), against a fake CreDocument.
--
-- The fake lays a list of paragraphs out like crengine: each character is
-- 40 px wide in 100 px tall line boxes, `per_line` characters per line.
-- XPointers are "p/i" (paragraph p, character offset i). Between paragraphs
-- getTextFromXPointers returns "\n", as crengine does.
local Text = require("cp_text")
local Context = require("cp_context")

local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local CW, LH, TH, X0 = 40, 100, 40, 100

local function fakeDoc(paras, per_line)
    local doc = { cells = {} }    -- flat list of { p=, i=, ch=, box= }
    local line = 0
    for p, s in ipairs(paras) do
        local chars = Text.chars(s)
        for i, ch in ipairs(chars) do
            local col = (i - 1) % per_line
            if i > 1 and col == 0 then line = line + 1 end
            doc.cells[#doc.cells + 1] = { p = p, i = i - 1, ch = ch,
                box = { x = X0 + col * CW, y = line * LH, w = CW, h = LH } }
        end
        doc.cells[#doc.cells + 1] = { p = p, i = #chars, ch = nil }   -- end of paragraph
        line = line + 1
    end
    local index = {}
    for k, c in ipairs(doc.cells) do index[c.p .. "/" .. c.i] = k end
    local function xp(c) return c.p .. "/" .. c.i end

    -- crengine snaps a point to the nearest character on the nearest line
    -- (also in margins and blank space), which is why charAt tests the box.
    function doc:getTextFromPositions(pos)
        local best, bestd
        for k, c in ipairs(self.cells) do
            if c.ch then
                local cx, cy = c.box.x + c.box.w / 2, c.box.y + c.box.h / 2
                local d = math.abs(cy - pos.y) * 1000 + math.abs(cx - pos.x)
                if not bestd or d < bestd then best, bestd = k, d end
            end
        end
        local c = self.cells[best]
        return { text = c.ch, pos0 = xp(c), pos1 = c.p .. "/" .. (c.i + 1), sboxes = { c.box } }
    end
    function doc:getPrevVisibleChar(x)
        local k = index[x]
        if not k or k == 1 then return nil end
        local c = self.cells[k]
        if c.i == 0 then return xp(self.cells[k - 1]) end      -- end of the previous paragraph
        return xp(self.cells[k - 1])
    end
    function doc:getNextVisibleChar(x)
        local k = index[x]
        if not k or k == #self.cells then return nil end
        return xp(self.cells[k + 1])
    end
    function doc:getTextFromXPointers(a, b)
        local ka, kb = index[a], index[b]
        local out = {}
        for k = ka, kb - 1 do
            local c = self.cells[k]
            out[#out + 1] = c.ch or "\n"
        end
        return table.concat(out)
    end
    return doc
end

local function tapAt(doc, line, col, dy)
    return { x = X0 + col * CW + CW / 2, y = line * LH + (dy or LH / 2) }
end

local function around(doc, pos)
    local hit = Context.charAt(doc, pos, TH)
    if not hit then return nil end
    local l, r = Context.around(doc, hit)
    return hit.char, table.concat(l), table.concat(r)
end

-- One paragraph across lines (5 per line): 他说，这个历 / 史挺靠谱的书 / ，Hello中文。
local doc = fakeDoc({ "他说，这个历史挺靠谱的书，Hello中文。", "第二段开头" }, 5)

-- 历 is line 1 col 0 (他说，这个 / 历史挺靠谱 / ...)
local c, l, r = around(doc, tapAt(doc, 1, 0))
eq(c, "历"); eq(l, "这个", "left across the line break, stops at ，"); eq(r, "史挺靠谱的书", "right stops at ，")

-- Character at the end of a line: right side continues on the next line.
c, l, r = around(doc, tapAt(doc, 0, 4))
eq(c, "个"); eq(l, "这"); eq(r, "历史挺靠谱的书", "7 to the right, across the line")

-- Context capped at 7 each way.
local long = fakeDoc({ "一二三四五六七八九十百千万亿兆京" }, 20)
c, l, r = around(long, tapAt(long, 0, 8))
eq(c, "九"); eq(l, "二三四五六七八"); eq(r, "十百千万亿兆京")

-- Paragraph break stops the walk: 第 starts paragraph 2, 。 ends paragraph 1.
-- Paragraph 1 has 21 characters: lines 0..4, so paragraph 2 is on line 5.
c, l, r = around(doc, tapAt(doc, 5, 0))
eq(c, "第"); eq(l, "", "nothing from the previous paragraph"); eq(r, "二段开头")
local para = fakeDoc({ "前文", "后文" }, 10)
c, l, r = around(para, tapAt(para, 0, 1))
eq(c, "文"); eq(l, "前"); eq(r, "", "paragraph break on the right")

-- Taps that must pass through:
-- punctuation (，is line 0 col 2)
assert(not Context.charAt(doc, tapAt(doc, 0, 2), TH), "punctuation")
-- Latin (H is line 2 col 3: 的书，He / llo中文 ...)
assert(not Context.charAt(doc, tapAt(doc, 2, 3), TH), "Latin")
-- left margin, next to a character
assert(not Context.charAt(doc, { x = 20, y = LH + 50 }, TH), "left margin")
-- right margin
assert(not Context.charAt(doc, { x = X0 + 5 * CW + 30, y = LH + 50 }, TH), "right margin")
-- blank space after the paragraph's last line (第二段开头 is 5 chars and fills its line,
-- so use the 2-char paragraph: blank after 文 on its line)
assert(not Context.charAt(para, { x = X0 + 2 * CW + 60, y = 50 }, TH), "after the paragraph")
-- between lines: in the leading above and below the glyphs
assert(not Context.charAt(doc, tapAt(doc, 1, 0, 5), TH), "leading above the glyph")
assert(not Context.charAt(doc, tapAt(doc, 1, 0, LH - 5), TH), "leading below the glyph")
-- below the last line of text
assert(not Context.charAt(doc, { x = X0 + 20, y = 30 * LH }, TH), "below all text")

-- Glyph edges: the glyph band of a 100 px line with 40 px text is y 30..70.
assert(Context.charAt(doc, tapAt(doc, 1, 0, 31), TH), "just inside the glyph top")
assert(not Context.charAt(doc, tapAt(doc, 1, 0, 29), TH), "just above the glyph top")
assert(Context.onGlyph({ x = 0, y = 0, w = 40, h = 40 }, 60, 20, 20), "text taller than box: whole box")
assert(not Context.onGlyph({ x = 0, y = 0, w = 0, h = 40 }, 40, 0, 20), "empty box")

-- Engine calls that fail are not taps on a character.
assert(not Context.charAt({ getTextFromPositions = function() error("boom") end }, { x = 1, y = 1 }, TH))
assert(not Context.charAt({}, { x = 1, y = 1 }, TH))
