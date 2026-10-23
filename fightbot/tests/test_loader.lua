-- Offline test of fightbot/FightBotLoad.lua with the Script Extender mocked.
--   lua fightbot/tests/test_loader.lua
local pass, fail = 0, 0
local function ok(c, n) if c then pass = pass + 1 print("ok   " .. n) else fail = fail + 1 print("FAIL " .. n) end end

local printed = {}
local function mockExt(server)
    Ext = {
        IsServer = function() return server end,
        Utils = { Print = function(s) printed[#printed + 1] = s end, PrintWarning = function(s) printed[#printed + 1] = s end },
        IO = { LoadFile = function(p)
            if p:find("Missing", 1, true) then return nil end
            return ("FB_LOADED[#FB_LOADED + 1] = %q"):format(p)
                .. (p == "BG3AI/Server/Visibility.lua" and " BG3AI.Visibility = {}" or "")
        end },
    }
end

FB_LOADED = {}
mockExt(true)
BG3AI, FightRecV2 = nil, nil
dofile("fightbot/FightBotLoad.lua")
ok(#FB_LOADED == 10 and FB_LOADED[1] == "BG3AI/Shared/RPC.lua" and FB_LOADED[10] == "BG3AI/Server/Actions.lua",
    "the 10 server files load in BootstrapServer's order (no recorder of its own)")
ok(BG3AI.Visibility.OMNISCIENT == true and BG3AI.FightBotLoaded, "omniscient on")
ok(printed[#printed]:find("FightRec v2 is not loaded", 1, true), "it says when FightRec v2 is missing")
local n = #FB_LOADED
dofile("fightbot/FightBotLoad.lua")
ok(#FB_LOADED == n, "a second load does nothing")

FB_LOADED = {}
mockExt(true)
BG3AI, FightRecV2 = nil, {}
dofile("fightbot/FightBotLoad.lua")
ok(not printed[#printed]:find("not loaded", 1, true), "with FightRec v2 loaded, no warning")

mockExt(false)
BG3AI = nil
dofile("fightbot/FightBotLoad.lua")
ok(BG3AI == nil, "the client context loads nothing")

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
