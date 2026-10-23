-- FightBot loader for the Windows Script Extender (bg3se), run from its console in the SERVER context:
--   load(Ext.IO.LoadFile("FightBotLoad.lua"))()
-- Loads the server half of the BG3AI mod from the Script Extender folder's BG3AI\ subfolder (install.ps1 copies it
-- there) and turns its visibility filter off. The client half (UI reading) is not loaded: it reads the UI from Tick,
-- which bg3se warns can crash. Recording is FightRec v2's job (load it too); the fightbot reads its files.
-- See fightbot/README.md.

local BASE = "BG3AI/"
-- BootstrapServer.lua's order. Ext.Require only works inside a mod, so each file is loaded with load().
local FILES = {
    "Shared/RPC.lua", "Shared/Util.lua", "Shared/Mem.lua", "Shared/HotbarMap.lua",
    "Server/Visibility.lua", "Server/State.lua", "Server/Events.lua", "Server/Navigation.lua",
    "Server/Guard.lua", "Server/Actions.lua",
}

if not Ext.IsServer() then
    Ext.Utils.PrintWarning("[FightBot] run this in the server context (type: server)")
    return
end
if BG3AI and BG3AI.FightBotLoaded then
    Ext.Utils.Print("[FightBot] already loaded; reset the Lua state (reset) to load a new version")
    return
end

BG3AI = BG3AI or {}
BG3AI.VERSION = "0.1.0-fightbot"
for _, path in ipairs(FILES) do
    local src = Ext.IO.LoadFile(BASE .. path)
    if not src then error("[FightBot] missing " .. BASE .. path .. ": run fightbot\\install.ps1 first", 0) end
    local fn, err = load(src, "@BG3AI/" .. path)
    if not fn then error("[FightBot] " .. path .. ": " .. tostring(err), 0) end
    local ok, e = pcall(fn)
    if not ok then error("[FightBot] " .. path .. ": " .. tostring(e), 0) end
end

BG3AI.Visibility.OMNISCIENT = true
BG3AI.FightBotLoaded = true
Ext.Utils.Print("[FightBot] ready: BG3AI " .. BG3AI.VERSION .. ", omniscient"
    .. (FightRecV2 and "" or " (FightRec v2 is not loaded: no rolls will be recorded)"))
