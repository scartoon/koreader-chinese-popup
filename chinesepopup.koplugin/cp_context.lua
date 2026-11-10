-- From a tap to the tapped Chinese character and the Han characters around it,
-- through CreDocument (reflowable documents only). Uses the same engine calls
-- as ReaderHighlight: getTextFromPositions for the text under a point,
-- getPrevVisibleChar/getNextVisibleChar to move by character (they cross line
-- breaks and inline tags), getTextFromXPointers for the text in between.
--
-- No KOReader requires here: the document is passed in, so this is tested
-- offline with a fake document (tests/test_context.lua).

local Text = require("cp_text")

local Context = {}

local function call(object, method, ...)
    if not object or not object[method] then return nil end
    local ok, a, b = pcall(object[method], object, ...)
    if not ok then return nil end
    return a, b
end

-- Vertical band the glyphs occupy inside a line box: crengine's segment boxes
-- are line-height tall, with the extra leading split evenly above and below the
-- text (same estimate as pinyin_layout.lua's textBand in the pinyin plugin).
function Context.glyphBand(box, text_height)
    local height = text_height or box.h
    if height > box.h then height = box.h end
    local half_leading = (box.h - height) / 2
    return box.y + half_leading, box.y + box.h - half_leading
end

-- True when (x, y) is on the glyph of the character whose segment box is `box`.
function Context.onGlyph(box, text_height, x, y)
    if not box or not box.w or box.w <= 0 then return false end
    local top, bottom = Context.glyphBand(box, text_height)
    return x >= box.x and x < box.x + box.w and y >= top and y < bottom
end

--[[--
The Han character under screen point pos, or nil.

Returns { char=, pos0=, pos1=, box= } only when the text under the point is
exactly one Han character and the point is on its glyph: crengine snaps a
point in a margin, between lines or after a paragraph to the nearest text, so
the box test is what lets those taps through.
]]
function Context.charAt(document, pos, text_height)
    local range = call(document, "getTextFromPositions", pos, pos, true)
    if not range or not range.pos0 or not range.pos1 then return nil end
    local char = range.text
    if not Text.isHan(char) then return nil end
    local boxes = range.sboxes
    if not boxes or #boxes == 0 then
        boxes = call(document, "getScreenBoxesFromPositions", range.pos0, range.pos1, true)
    end
    for _, box in ipairs(boxes or {}) do
        if Context.onGlyph(box, text_height, pos.x, pos.y) then
            return { char = char, pos0 = range.pos0, pos1 = range.pos1, box = box }
        end
    end
    return nil
end

-- Move up to n visible characters from xp with `step`; the last position reached.
local function walk(document, xp, step, n)
    local cur = xp
    for _ = 1, n do
        local nxt = call(document, step, cur)
        if not nxt or nxt == cur then break end
        cur = nxt
    end
    return cur
end

--[[--
Up to `max` Han characters before and after the tapped one.

Takes the text from `max` visible characters before pos0 up to pos0 (and from
pos1 to `max` characters after it) in one call each, then keeps only the Han
run touching the tapped character: punctuation, Latin, digits, spaces and the
newline crengine puts between paragraphs all end it. Line wraps do not.
Returns left, right (arrays of characters, in reading order).
]]
function Context.around(document, hit, max)
    max = max or Text.MAX_CONTEXT
    local left, right = {}, {}
    local from = walk(document, hit.pos0, "getPrevVisibleChar", max)
    if from ~= hit.pos0 then
        left = Text.hanSuffix(call(document, "getTextFromXPointers", from, hit.pos0) or "", max)
    end
    -- pos1 is the end of the tapped character; one more step than max because
    -- the first step from pos1 may only reach the start of the next character.
    local to = walk(document, hit.pos1, "getNextVisibleChar", max + 1)
    if to ~= hit.pos1 then
        right = Text.hanPrefix(call(document, "getTextFromXPointers", hit.pos1, to) or "", max)
    end
    return left, right
end

return Context
