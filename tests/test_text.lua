-- Han detection, candidate generation, result ordering and popup text (cp_text.lua).
local Text = require("cp_text")

local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function chars(s) return Text.chars(s) end
local function join(list, key, sep)
    local out = {}
    for _, x in ipairs(list) do out[#out + 1] = key and x[key] or x end
    return table.concat(out, sep or ",")
end

------------------------------------------------------------------------
-- Han detection
------------------------------------------------------------------------
for _, c in ipairs({ "中", "国", "饕", "㐀", "䶿", "𠀀", "𪜀", "𰀀", "豈", "丽" }) do
    assert(Text.isHan(c), "should be Han: " .. c)
end
-- 丽 above is U+4E3D; the compatibility supplement U+2F800 is "丽" too:
assert(Text.isHan("\240\175\160\128"), "U+2F800 compatibility supplement")
for _, c in ipairs({ "，", "。", "“", "a", "Z", "1", "１", " ", "\n", "〇", "ー", "あ", "한", "", "中国" }) do
    assert(not Text.isHan(c), "should not be Han: [" .. c .. "]")
end
assert(not Text.isHan("\228\184"), "truncated UTF-8")
assert(not Text.isHan(nil))

------------------------------------------------------------------------
-- Context trimming
------------------------------------------------------------------------
eq(table.concat(Text.hanSuffix("他说：这个历史", 7)), "这个历史", "suffix stops at punctuation")
eq(table.concat(Text.hanSuffix("一二三四五六七八九", 7)), "三四五六七八九", "suffix capped at 7")
eq(table.concat(Text.hanSuffix("第一章\n这个", 7)), "这个", "suffix stops at paragraph break")
eq(table.concat(Text.hanSuffix("in 2008年", 7)), "年", "suffix stops at digits")
eq(table.concat(Text.hanPrefix("靠谱，真的", 7)), "靠谱", "prefix stops at punctuation")
eq(table.concat(Text.hanPrefix("一二三四五六七八九", 7)), "一二三四五六七", "prefix capped at 7")
eq(table.concat(Text.hanPrefix(" 中国", 7)), "", "prefix stops at a leading space")
eq(#Text.hanPrefix("", 7), 0)

------------------------------------------------------------------------
-- Candidates
------------------------------------------------------------------------
-- 历 tapped in 这个[历]史挺靠谱
local cands, texts = Text.candidates(chars("这个"), "历", chars("史挺靠谱"))
-- Every substring containing position 3, length <= 8: starts 1..3, ends 3..7.
eq(#cands, 3 * 5, "candidate count")
eq(#texts, #cands)
local by_text = {}
for _, c in ipairs(cands) do by_text[c.text] = c end
assert(by_text["历"] and by_text["历"].start == 0 and by_text["历"].len == 1)
assert(by_text["历史"] and by_text["历史"].start == 0 and by_text["历史"].len == 2)
assert(by_text["个历"] and by_text["个历"].start == -1)
assert(by_text["这个历史挺靠谱"] and by_text["这个历史挺靠谱"].len == 7)
assert(not by_text["这个"], "must contain the tapped character")
assert(not by_text["靠谱"], "must contain the tapped character")

-- Full context: 7 + 1 + 7 characters, words up to 8.
local left, right = chars("一二三四五六七"), chars("九十百千万亿兆")
cands = Text.candidates(left, "八", right)
local count, maxlen = 0, 0
for len = 1, 8 do count = count + len end   -- a window of length len has len positions containing t
eq(#cands, count, "7+1+7 candidate count")
for _, c in ipairs(cands) do
    if c.len > maxlen then maxlen = c.len end
    assert(c.start <= 0 and c.start + c.len - 1 >= 0, "contains tapped char: " .. c.text)
end
eq(maxlen, 8, "longest candidate")

-- No context: only the character itself.
cands = Text.candidates({}, "中", {})
eq(#cands, 1); eq(cands[1].text, "中")

-- Repeated strings appear once, with the earliest start: 天[天]天
cands = Text.candidates(chars("天"), "天", chars("天"))
local seen = {}
for _, c in ipairs(cands) do
    assert(not seen[c.text], "duplicate " .. c.text)
    seen[c.text] = c
end
eq(seen["天天"].start, -1, "earliest start kept")
eq(#cands, 3, "天, 天天, 天天天")

------------------------------------------------------------------------
-- Ordering
------------------------------------------------------------------------
local function row(simp, trad, pinyin, defs) return { simp = simp, trad = trad, pinyin = pinyin, defs = defs } end
-- Tapped 历 in 这个[历]史挺靠谱; dictionary rows as the query returns them
-- (CC-CEDICT order, i.e. arbitrary with respect to our ranking).
local rows = {
    row("历", "歷", "lì", "to experience/to undergo"),
    row("历", "曆", "lì", "calendar"),
    row("历史", "歷史", "lìshǐ", "history/CL: 门 mén"),
    row("个", "個", "gè", "individual"),  -- would never be returned (no 历), must be ignored
    row("史", "史", "Shǐ", "surname Shi"),
}
cands = Text.candidates(chars("这个"), "历", chars("史挺靠谱"))
local m = Text.order(cands, rows)
eq(join(m, "word"), "历,历史", "anchor first, then words")
eq(#m[1].entries, 2, "both 历 rows grouped")
eq(m[2].entries[1].pinyin, "lìshǐ")
eq(join(m[2].entries[1].senses), "history,CL: 门 mén")

-- Longest first, ties by earlier start. Tapped 中 in 中华人民共和国 context:
-- 华[中]... no: tapped 国 at the end of 中华人民共和国.
cands = Text.candidates(chars("中华人民共和"), "国", {})
rows = {
    row("国", "國", "guó", "country"),
    row("和国", "和國", "x", "fake 2-char ending in 国"),
    row("共和国", "共和國", "gònghéguó", "republic"),
    row("中华人民共和国", "中華人民共和國", "Zhōnghuá Rénmín Gònghéguó", "People's Republic of China"),
    row("民共和国", "民共和國", "x", "fake 4"),
}
m = Text.order(cands, rows)
eq(join(m, "word"), "国,中华人民共和国,民共和国,共和国,和国", "longest first")

-- Tie on length: earlier start first. Tapped 学 in 大学生.
cands = Text.candidates(chars("大"), "学", chars("生"))
rows = {
    row("学生", "學生", "xuésheng", "student"),
    row("大学", "大學", "dàxué", "university"),
    row("大学生", "大學生", "dàxuéshēng", "university student"),
    row("学", "學", "xué", "to learn"),
}
m = Text.order(cands, rows)
eq(join(m, "word"), "学,大学生,大学,学生", "ties broken by earlier start")
eq(m[3].start, -1); eq(m[4].start, 0)

-- No entry for the tapped character itself: words only, no anchor.
cands = Text.candidates({}, "𪜀", chars("𪜀"))
m = Text.order(cands, { row("𪜀𪜀", "𪜀𪜀", "x", "fake") })
eq(join(m, "word"), "𪜀𪜀")
eq(#Text.order(cands, {}), 0, "nothing found")

-- Traditional text matches through the trad column; the word is shown as written.
cands = Text.candidates({}, "歷", chars("史"))
rows = { row("历史", "歷史", "lìshǐ", "history"), row("历", "歷", "lì", "to experience") }
m = Text.order(cands, rows)
eq(join(m, "word"), "歷,歷史", "traditional match")

-- A row whose simp and trad are the same is not listed twice.
cands = Text.candidates({}, "史", {})
m = Text.order(cands, { row("史", "史", "shǐ", "history") })
eq(#m[1].entries, 1, "simp == trad counted once")

------------------------------------------------------------------------
-- Row cleaning
------------------------------------------------------------------------
-- 着: CC-CEDICT has self-referring "variant of 着" rows (traditional 着 as a
-- variant of 著) beside the real ones; proper-noun readings go last.
cands = Text.candidates({}, "着", {})
rows = {
    row("着", "着", "zhāo", "variant of 着 zhāo"),
    row("着", "着", "zhe", "variant of 着 zhe"),
    row("着", "著", "zhe", "aspect particle"),
    row("着", "著", "zháo", "to touch/to feel"),
}
m = Text.order(cands, rows)
eq(#m[1].entries, 2, "self-variant rows dropped")
eq(m[1].entries[1].pinyin, "zhe")
cands = Text.candidates({}, "乐", {})
rows = {
    row("乐", "樂", "Lè", "surname Le"),
    row("乐", "樂", "lè", "happy"),
    row("乐", "樂", "yuè", "music"),
}
m = Text.order(cands, rows)
eq(join(m[1].entries, "pinyin"), "lè,yuè,Lè", "proper-noun readings last, CC-CEDICT order otherwise")
-- A variant of a different character is kept.
m = Text.order(Text.candidates({}, "倂", {}), { row("倂", "倂", "bìng", "variant of 并 bìng") })
eq(#m, 1, "variant of another character kept")
eq(m[1].entries[1].senses[1], "variant of 并 bìng")
m = Text.order(Text.candidates({}, "着", {}), { row("着", "着", "zhāo", "old variant of 着 zhāo") })
eq(#m, 0, "a word left with no senses is dropped")

------------------------------------------------------------------------
-- Popup text and button rows
------------------------------------------------------------------------
cands = Text.candidates({}, "乐", {})
m = Text.order(cands, {
    row("乐", "樂", "lè", "happy/cheerful"),
    row("乐", "樂", "yuè", "music"),
})
eq(Text.render(m, "<b>", "</b>"), "<b>乐</b>  lè\nhappy; cheerful\nyuè: music")
m = Text.order(Text.candidates({}, "靠", chars("谱")), {
    row("靠", "靠", "kào", "to lean"),
    row("靠谱", "靠譜", "kàopǔ", "reliable"),
})
eq(Text.render(m), "靠  kào\nto lean\n\n靠谱  kàopǔ\nreliable")

local items = {}
for k = 1, 9 do items[k] = k end
local r = Text.rows(items, 4)
eq(#r, 3); eq(#r[1], 4); eq(#r[3], 1); eq(r[3][1], 9)
eq(#Text.rows({}, 4), 0)

------------------------------------------------------------------------
-- The SQL must stay identical to tools/build_db.py's lookup_sql, whose
-- query plan the build checks.
------------------------------------------------------------------------
local DB = require("cp_db")
eq(DB.sql(2), "SELECT simp, trad, pinyin, defs FROM entries WHERE simp IN (?,?) OR trad IN (?,?) ORDER BY rowid")
