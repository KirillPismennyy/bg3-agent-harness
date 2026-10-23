-- Lua 5.4 syntax check (load without running) of the recorder, the immutable baseline and all harness Lua.
local files = { "recorder/FightRec.lua", "baseline/FightRec.lua", "tests/mock_se.lua", "tests/json.lua",
    "tests/partreader.lua", "tests/harness.lua", "tests/test_recorder.lua", "tests/test_stamped.lua",
    "tests/check_syntax.lua", "bench/bench.lua" }
local bad = 0
for _, f in ipairs(files) do
    local fh = io.open(host.repo .. "/" .. f, "rb")
    if not fh then
        print("MISSING " .. f)
        bad = bad + 1
    else
        local src = fh:read("a")
        fh:close()
        local fn, err = load(src, "@" .. f, "t", {})
        if fn then print("ok   " .. f) else print("FAIL " .. err) bad = bad + 1 end
    end
end
print(host.lua_version .. " (lupa " .. host.lupa_version .. "): " .. bad .. " problem(s)")
return bad > 0 and 1 or 0
