-- Offline tests for Client/CombatLog.lua (the combat log reader) and Server/Recorder.lua (the raw fight log),
-- both read by tools/record_fight.py.
--   lua tools/dev/test_combatlog.lua mod/Mods/BG3AI/ScriptExtender/Lua
local LUA = arg and arg[1] or "mod/Mods/BG3AI/ScriptExtender/Lua"
local pass, fail = 0, 0
local function ok(cond, name)
    if cond then pass = pass + 1; print("ok   " .. name) else fail = fail + 1; print("FAIL " .. name) end
end

local ops = {}
local listeners, subscribed = {}, {}
local mono = 0
Ext = {
    UI = { GetRoot = function() return ROOT end },
    Utils = { MonotonicTime = function() return mono end, PrintWarning = function() end },
    Events = setmetatable({ Tick = { Subscribe = function() end } }, { __index = function(_, k)
        if k == "DealtDamage" then return { Subscribe = function(_, fn) subscribed[k] = fn end } end
        return nil
    end }),
    Osiris = { RegisterListener = function(name, arity, _, fn) listeners[name] = { arity = arity, fn = fn } end },
    Json = { Stringify = function(x) if type(x) == "table" then return "{}" end return tostring(x) end,
             Parse = function() return { parsed = true } end },
    Stats = { Get = function(id) return { DisplayName = id .. "_name" } end },
    Loca = { GetTranslatedString = function(h) return h end },
}
Osi = { CombatGetGuidFor = function(u) return ({ party1 = "c1", goblin = "c1", far = "c2" })[u] end,
        GetStatusTurns = function() return 2 end }
BG3AI = { RPC = { register = function(name, fn) ops[name] = fn end, now_ms = function() return 0 end } }

------------------------------------------------------------------------
-- CombatLog.lua against a mock Noesis tree
------------------------------------------------------------------------
dofile(LUA .. "/Client/UI.lua")

local propsCalls = {}   -- type names GetAllProperties ran on
local Obj = {}
Obj.__index = Obj
function Obj:GetAllProperties() propsCalls[#propsCalls + 1] = self.Type; return self.p or {} end
function Obj:GetProperty(n)
    if n == "Count" and self.items then return #self.items end
    if self.el and self.el[n] ~= nil then return self.el[n] end
    error("no property " .. n)
end
function Obj:At(i) return self.items[i] end
function Obj:ToString() return self.text or "" end
local function obj(ty, fields) local o = fields or {}; o.Type = ty; return setmetatable(o, Obj) end
local function coll(items) return obj("Noesis::ObservableCollection<BaseComponent>", { items = items }) end

local button = obj("Button", { text = "never props me", p = { Danger = "x" } })
local function entry(title, rolls)
    local r = {}
    for i, t in ipairs(rolls or {}) do r[i] = obj("ls::VMCombatLogRoll", { p = { Text = t } }) end
    return obj("ls::CombatLogEntry", { p = { Title = title, Rolls = coll(r), Expand = obj("ls::DelegateCommand"),
        Element = button } })
end
local entries = coll({ entry("Lae'zel hits Goblin", { "Attack Roll 17 vs AC 15", "9 Slashing" }),
                       entry("Goblin saves", { "WIS save 14 vs DC 13" }) })
local dc = obj("gui::DCCombatLog", { p = { Unrelated = coll({}), CombatLogEntries = entries,
    CurrentPlayer = obj("ls::VMPlayer", { p = { Huge = true } }), IsOpen = true } })
local page = obj("ls::UIWidget", { Name = "CombatLog", DataContext = dc, VisualChildrenCount = 0,
    el = { IsVisible = true } })
local cr = obj("Grid", { Name = "ContentRoot", VisualChildrenCount = 1, kids = { page },
    el = { Children = coll({ page }) } })
function cr:VisualChild(i) return self.kids[i] end
ROOT = obj("Border", { VisualChildrenCount = 1 })
function ROOT:Find(n) return n == "ContentRoot" and cr or nil end

dofile(LUA .. "/Client/CombatLog.lua")

local p = ops["combatlog.probe"]({})
ok(p.found and p.how == "widget", "probe finds the page by its DC type")
ok(p.chosen == "CombatLogEntries", "probe names the entry collection (a known name, not the first collection)")
ok(p.props.IsOpen == true and p.props.CurrentPlayer == nil, "probe lists plain props and skips the DC base")
ok(p.collections.CombatLogEntries.count == 2, "probe counts the entries")

propsCalls = {}
local r = ops["combatlog.read"]({ first = 2 })
ok(r.count == 2 and #r.entries == 1 and r.entries[1].i == 2, "read returns from `first` to the end")
local d = r.entries[1].d
ok(d.Title == "Goblin saves" and d.Rolls._items[1].Text == "WIS save 14 vs DC 13", "entry dump keeps nested rolls")
ok(d.Expand._cmd ~= nil, "commands are named, not walked")
ok(d.Element._type == "Button" and d.Element._text == "never props me", "an element gives its type and text only")
local onElement = false
for _, t in ipairs(propsCalls) do if t == "Button" then onElement = true end end
ok(not onElement, "GetAllProperties never runs on an element")

BG3AI.CombatLog.chosen = nil
dc.p.CombatLogEntries = nil
dc.p.Mystery = entries
ok(ops["combatlog.read"]({}).collection == "Mystery", "an unknown name is found by its entries' type")

------------------------------------------------------------------------
-- Recorder.lua
------------------------------------------------------------------------
BG3AI.Visibility = {
    uuid = function(s) return type(s) == "string" and s or nil end,
    name = function(u) return "N:" .. u end,
    osi = function(fn, ...) local okc, v = pcall(fn, ...); return okc and v or nil end,
    context = function() return { party = { "party1" }, is_party = { party1 = true } } end,
}
dofile(LUA .. "/Server/Recorder.lua")
local R = BG3AI.Recorder

listeners.AttackedBy.fn("goblin", "party1", "party1", "Slashing", 9, "Attack", 1)
ok(#R.buf == 0, "nothing is recorded until rec.enable")

local en = ops["rec.enable"]({ on = true })
ok(en.on and en.hooks.AttackedBy == "ok" and en.hooks["Ext.Events.DealtDamage"] == "ok", "enable reports the hooks")
ok(en.hooks["Ext.Events.BeforeDealDamage"] ~= "ok", "a missing extender event is reported, not fatal")

listeners.AttackedBy.fn("goblin", nil, "party1", "Slashing", 9, "Attack", 1)
listeners.AttackedBy.fn("far", "far2", "far2", "Fire", 3, "Attack", 1)
listeners.StatusApplied.fn("goblin", "BLESS", "party1", 1)
local rs = ops["rec.since"]({ seq = 0 })
ok(#rs.records == 2, "only the party's fight is recorded")
ok(rs.records[1].kind == "damage" and rs.records[1].data.amount == 9, "damage is recorded with its amount")
ok(rs.records[2].data.status == "BLESS" and rs.records[2].data.name == "BLESS_name" and rs.records[2].data.turns == 2,
    "a status keeps its id, shown name and turns")

subscribed.DealtDamage({ Caster = { Uuid = { EntityUuid = "party1" } }, Target = { Uuid = { EntityUuid = "goblin" } },
    Hit = {}, Attack = {} })
local last = R.buf[#R.buf]
ok(last.kind == "dealt_damage" and last.data.caster.uuid == "party1" and last.data.hit.parsed, "DealtDamage dumps its hit")
ok(#ops["rec.since"]({ seq = rs.latest }).records == 1, "rec.since starts after seq")

ops["rec.enable"]({ on = false })
listeners.Died.fn("party1")
ok(R.buf[#R.buf].kind == "dealt_damage", "off again: nothing more is recorded")

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
