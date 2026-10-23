-- Production: lua fightbot/tests/test_actions_source_gate.lua [repo=.]
-- Staging: pass repo, staged Server directory, and staged test directory.
local repo = (arg[1] or "."):gsub("\\", "/")
local serverDir = (arg[2] or (repo .. "/mod/Mods/BG3AI/ScriptExtender/Lua/Server")):gsub("\\", "/")
local testsDir = (arg[3] or (repo .. "/fightbot/tests")):gsub("\\", "/")
local actionsFile, castFile = serverDir .. "/Actions.lua", serverDir .. "/CastRolls.lua"
local original = dofile
function dofile(path)
    local normalized = path:gsub("\\", "/")
    if normalized:match("/Server/Actions%.lua$") then
        local result = original(actionsFile)
        -- The original 225 fixtures predate source metadata and isolate Actions;
        -- stub only this read-only interface for those legacy unit tests.
        BG3AI.CastRolls = { check_legacy_source = function() return {route="legacy",equivalence="unproven"} end }
        return result
    elseif normalized:match("/Server/CastRolls%.lua$") then
        return original(castFile)
    end
    return original(path)
end
local function read(path)
    local file = assert(io.open(path,"r")); local value=file:read("*a"); file:close(); return value
end
arg[1] = repo .. "/mod/Mods/BG3AI/ScriptExtender/Lua"
local source = read(repo .. "/tools/dev/test_act_lua.lua")
local extra = "\nlocal sourceGateCastRolls = " .. string.format("%q", castFile) .. "\n"
    .. read(testsDir .. "/test_actions_source_gate.inc.lua")
local marker = '\nprint(string.format("%d/%d passed", count - failures, count))'
local at = assert(source:find(marker,1,true),"legacy harness summary marker changed")
source = source:sub(1,at-1) .. extra .. source:sub(at)
return assert(load(source,"@Actions source-gate regressions","t",_G))()
