-- Run the offline tests in plain Lua/LuaJIT, no device needed:
--     luajit tests/run.lua        (from the repository root)
local root = arg and arg[0] and arg[0]:match("^(.*)/tests/run%.lua$") or "."
package.path = root .. "/chinesepopup.koplugin/?.lua;" .. root .. "/tests/?.lua;" .. package.path

local files = { "test_text.lua", "test_context.lua" }
local failed = 0
for _, name in ipairs(files) do
    local ok, err = pcall(dofile, root .. "/tests/" .. name)
    if ok then
        print("ok    " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. ": " .. tostring(err))
    end
end
print(string.format("%s (%s)", failed == 0 and "all tests passed" or (failed .. " file(s) failed"), _VERSION))
os.exit(failed == 0 and 0 or 1)
