-- CC-CEDICT lookups in data/cedict.sqlite through KOReader's bundled SQLite
-- binding (lua-ljsqlite3). Opened on the first tap and kept open.

local DB = {}
DB.__index = DB

-- nil, err when the file or the binding is missing.
function DB.open(path, SQ3)
    local f = io.open(path, "rb")
    if not f then return nil, "missing " .. path end
    f:close()
    if not SQ3 then
        local ok, mod = pcall(require, "lua-ljsqlite3/init")
        if not ok then return nil, "SQLite binding not available: " .. tostring(mod) end
        SQ3 = mod
    end
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok or not conn then return nil, "cannot open " .. path .. ": " .. tostring(conn) end
    return setmetatable({ conn = conn, stmts = {} }, DB)
end

function DB:close()
    for _, stmt in pairs(self.stmts) do pcall(stmt.close, stmt) end
    self.stmts = {}
    if self.conn then pcall(self.conn.close, self.conn) end
    self.conn = nil
end

-- The SQL for n candidate words (prepared statements are cached per n; n is
-- at most 36 for 7+1+7 characters and words up to 8).
function DB.sql(n)
    local marks = string.rep("?,", n - 1) .. "?"
    return "SELECT simp, trad, pinyin, defs FROM entries WHERE simp IN (" .. marks
        .. ") OR trad IN (" .. marks .. ") ORDER BY rowid"
end

-- Rows { {simp=, trad=, pinyin=, defs=}, ... } for every entry whose simplified
-- or traditional form is one of `words`, in CC-CEDICT order.
function DB:lookup(words)
    local n = #words
    if n == 0 or not self.conn then return {} end
    local stmt = self.stmts[n]
    if not stmt then
        stmt = self.conn:prepare(DB.sql(n))
        self.stmts[n] = stmt
    end
    local args = {}
    for k = 1, n do args[k], args[n + k] = words[k], words[k] end
    stmt:reset()
    stmt:bind((table.unpack or unpack)(args))
    local rows = {}
    local row = stmt:step()
    while row do
        rows[#rows + 1] = { simp = row[1], trad = row[2], pinyin = row[3], defs = row[4] }
        row = stmt:step()
    end
    stmt:clearbind()
    return rows
end

return DB
