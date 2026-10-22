-- Offline test of FightRec.lua against a mocked Script Extender (no game).
--   lua fightrec/tests/test_fightrec.lua fightrec/mod/Mods/FightRec/ScriptExtender/Lua/FightRec.lua
local SRC = arg and arg[1] or "fightrec/mod/Mods/FightRec/ScriptExtender/Lua/FightRec.lua"
local pass, fail = 0, 0
local function ok(c, n) if c then pass = pass + 1 print("ok   " .. n) else fail = fail + 1 print("FAIL " .. n) end end

local function encode(x)
    local t = type(x)
    if t == "table" then
        if #x > 0 or next(x) == nil then
            local p = {} for i = 1, #x do p[i] = encode(x[i]) end return "[" .. table.concat(p, ",") .. "]"
        end
        local keys = {} for k in pairs(x) do keys[#keys + 1] = tostring(k) end table.sort(keys)
        local p = {} for _, k in ipairs(keys) do p[#p + 1] = string.format("%q:", k) .. encode(x[k]) end
        return "{" .. table.concat(p, ",") .. "}"
    elseif t == "string" then return string.format("%q", x)
    elseif t == "nil" then return "null" end
    return tostring(x)
end

local function mockExt(server)
    local M = { files = {}, listeners = {}, events = {}, mono = 1000 }
    Ext = {
        IsServer = function() return server end,
        Utils = { MonotonicTime = function() return M.mono end, Print = function() end, PrintWarning = print,
                  GameVersion = function() return "4.1" end },
        Timer = { ClockEpoch = function() return 1700000000 end },
        Json = { Stringify = function(x) return encode(x) end, Parse = function(s) return { json = s } end },
        IO = { SaveFile = function(p, c) M.files[p] = c end },
        Osiris = { RegisterListener = function(n, a, _, fn) M.listeners[n] = fn end },
        Events = setmetatable({}, { __index = function(_, k)
            if k == "Missing" then return nil end
            return { Subscribe = function(_, fn) M.events[k] = fn end }
        end }),
        Stats = { Get = function(id) return { DisplayName = "h_" .. id } end },
        Loca = { GetTranslatedString = function(h) return h:sub(3) .. " (shown)" end },
        Entity = { Get = function(u) return M.entities and M.entities[u] end },
    }
    return M
end

local function lines(s)
    local out = {} for l in (s or ""):gmatch("[^\n]+") do out[#out + 1] = l end return out
end

------------------------------------------------------------------------
-- server
------------------------------------------------------------------------
local P1, GOB, FAR = "Laezel_00000000-0000-0000-0000-000000000001", "Goblin_00000000-0000-0000-0000-000000000002",
    "Far_00000000-0000-0000-0000-000000000003"
local u1, ug, uf = P1:match("%x+%-.*$"), GOB:match("%x+%-.*$"), FAR:match("%x+%-.*$")
local M = mockExt(true)
local inCombat = {}
M.entities = { [u1] = { Health = { Hp = 30, MaxHp = 34 }, Resistances = { AC = 14 }, EocLevel = { Level = 3 },
    StatusContainer = { Statuses = { a = "BLESS" } } } }
Osi = {
    DB_Players = { Get = function() return { { P1 } } end },
    DB_Is_InCombat = { Get = function(_, _, c) return c == "C1" and { { P1 }, { GOB } } or {} end },
    CombatGetGuidFor = function(u) return inCombat[u] end,
    GetDisplayName = function(u) return "dn_" .. u end,
    ResolveTranslatedString = function(h) return ({ ["dn_" .. u1] = "Lae'zel", ["dn_" .. ug] = "Goblin" })[h] or h end,
    GetPosition = function() return 1, 2, 3 end,
    IsEnemy = function(a) return a == ug and 1 or 0 end,
    GetStatusTurns = function() return 3 end,
    GetEquippedItem = function(_, slot) return slot == "Melee Main Weapon" and "Sword_00000000-0000-0000-0000-00000000000a" or nil end,
    GetRegion = function() return "WLD_Main_A" end,
}
FightRec = nil
dofile(SRC)
local FR = FightRec
local L = M.listeners

-- preparation, outside combat
L.CastedSpell(P1, "Shout_Bless", "Shout", "None", 1)
L.StatusApplied(P1, "SURPRISED", "NULL_00000000-0000-0000-0000-000000000000", 1)
L.StatusApplied(P1, "BLESS", P1, 1)
L.CastedSpell(FAR, "Projectile_FireBolt", "Projectile", "Fire", 1)   -- not ours
ok(#FR.prep == 3 and FR.fight == nil, "outside combat only party records are kept, as preparation")

-- combat starts; the party joins on round 1
L.CombatStarted("C1")
ok(FR.fight == nil, "a combat without the party is not a fight")
inCombat[u1], inCombat[ug], inCombat[uf] = "C1", "C1", "C2"
M.mono = M.mono + 300
L.CombatRoundStarted("C1", 1)
ok(FR.fight and FR.fight.n == 1, "the fight starts when the party is in the combat")

M.mono = M.mono + 300
L.AttackedBy(GOB, P1, nil, "Slashing", 9, "Attack", 1)         -- nil attacker in the middle
L.AttackedBy(FAR, "Other_00000000-0000-0000-0000-000000000004", nil, "Fire", 3, "Attack", 1)
L.RollResult("x", GOB, P1, 1, 0, 0)
-- a HitDesc Stringify only names: its members come from the extender's type info
local hitDesc = setmetatable({}, {})
local ability = setmetatable({}, { __index = function(_, k) if k == "Label" then return "Strength" end
    if k == "Value" then return 1 end end })
local rawtype = type
type = function(x) if x == hitDesc or x == ability then return "userdata" end return rawtype(x) end   -- plain Lua has no userdata
local HIT = { TotalDamageDone = 9, AttackRollAbility = ability, HitWith = "Weapon",
    ConditionRolls = { { Difficulty = 13, Roll = { Result = { Total = 17, NaturalRoll = 14 } } } } }
Ext.Types = { GetObjectType = function(x) return (x == hitDesc and "HitDesc") or (x == ability and "AbilityId") or nil end,
    GetTypeInfo = function(n)
        if n == "AbilityId" then return { Kind = "Enumeration" } end
        return n == "HitDesc" and { Kind = "Object", Members = { TotalDamageDone = "int32",
            AttackRollAbility = "AbilityId", HitWith = "HitWith", ConditionRolls = "Array" } } or nil
    end,
    Serialize = function() error("not serializable") end }
local hm = getmetatable(hitDesc) or {}
hm.__index = function(_, k) return HIT[k] end
if not getmetatable(hitDesc) then setmetatable(hitDesc, hm) end
M.events.DealtDamage({ Caster = { Uuid = { EntityUuid = u1 } }, Target = { Uuid = { EntityUuid = ug } },
    Hit = hitDesc, Attack = {} })
-- a userdata-like event: reading a field it lacks is an error (BeforeDealDamage has no Caster, live 2026-10-22)
local strict = function(t) return setmetatable({}, { __index = function(_, k)
    if t[k] == nil then error("Property does not exist: " .. k) end return t[k] end }) end
local warned = 0
local printWarning = Ext.Utils.PrintWarning
Ext.Utils.PrintWarning = function() warned = warned + 1 end
M.events.BeforeDealDamage(strict({ Hit = { DamageType = "Slashing" }, DamageSums = {} }))
M.events.BeforeDealDamage(strict({ Hit = { DamageType = "Fire" }, DamageSums = {} }))
Ext.Utils.PrintWarning = printWarning
ok(warned == 0, "an event without Caster is read without errors")
L.CombatEnded("C1")
ok(FR.fight == nil, "the fight ends with its combat")

local path = "FightRec/" .. FR.stamp .. "-fight01.jsonl"
local f = lines(M.files[path])
local kinds = {}
for _, l in ipairs(f) do kinds[#kinds + 1] = l:match('"kind":"([^"]+)","t":') end   -- the record's own kind
local seq = table.concat(kinds, ",")
ok(seq == "meta,prep,prep,prep,snapshot,CombatRoundStarted,AttackedBy,RollResult,DealtDamage,BeforeDealDamage,BeforeDealDamage,snapshot,end",
    "fight file: " .. seq)
local _, shapes = M.files[path]:gsub('"shape":', "")
ok(shapes == 2, "each damage event's shape is dumped once (DealtDamage, BeforeDealDamage)")
ok(M.files[path]:find('"name":"Lae\'zel"', 1, true) ~= nil, "characters are named")
ok(M.files[path]:find('"amount":9') and not M.files[path]:find('"amount":3'), "only the party's combat is recorded")
ok(M.files[path]:find('"name":"BLESS (shown)"', 1, true) ~= nil, "statuses and spells carry their shown names")
ok(M.files[path]:find('"slot":"Melee Main Weapon"', 1, true) ~= nil, "the snapshot lists equipment")
ok(M.files[path]:find('"turns":3', 1, true) ~= nil, "statuses carry their turns")
ok(M.files[path]:find('"AttackRollAbility":{"label":"Strength","value":1}', 1, true) ~= nil,
    "a HitDesc is read member by member, enums by label")
ok(M.files[path]:find('"NaturalRoll":14', 1, true) ~= nil, "the roll is read all the way down")
ok(M.files[path]:find('"ac":14', 1, true) ~= nil, "AC comes from Resistances")
ok(not M.files[path]:find('00000000-0000-0000-0000-000000000000', 1, true), "the null GUID is no one")
ok(M.files[path]:find('"hooks":', 1, true) ~= nil, "meta lists the hooks")
local snap = f[5]
ok(snap:find(ug, 1, true) ~= nil, "the combat's enemies are snapshotted")

------------------------------------------------------------------------
-- client
------------------------------------------------------------------------
local C = mockExt(false)
local Obj = {} Obj.__index = Obj
local propsOn = {}
function Obj:GetAllProperties() propsOn[#propsOn + 1] = self.Type return self.p or {} end
function Obj:GetProperty(n) if n == "Count" and self.items then return #self.items end
    if n == "Children" and self.children then return self.children end error("no " .. n) end
function Obj:At(i) return self.items[i] end
function Obj:ToString() return self.text or "" end
local function obj(ty, f) f = f or {} f.Type = ty return setmetatable(f, Obj) end
local function coll(items) return obj("Noesis::ObservableCollection<BaseComponent>", { items = items }) end
local function entry(t, rolls)
    local r = {} for i, x in ipairs(rolls) do r[i] = obj("ls::VMRoll", { p = { Text = x } }) end
    return obj("ls::CombatLogEntry", { p = { Title = t, Rolls = coll(r), Btn = obj("Button", { text = "x" }) } })
end
local items = { entry("Lae'zel hits Goblin", { "Attack 17 vs AC 15", "9 Slashing" }) }
local logVM = obj("ls::VMCombatLog", { p = { Entries = coll(items), Unrelated = coll({}) } })
local dc = obj("gui::DCCombatLog", { p = { CombatLogCollapsed = true, MarkCombatLogGroupEntrySeen = obj("ui::DeferredCommand"),
    Data = obj("ls::VMData", { p = { CombatLog = logVM, Messages = coll({}) } }) } })
-- live 2026-10-22: the log is not a ContentRoot page; it sits deeper in the visual tree
local logEl = obj("ls::LSUserControl", { Name = "CombatLogPanel", DataContext = dc, VisualChildrenCount = 0 })
local hud = obj("Grid", { Name = "Hud", DataContext = obj("gui::DCHud"), VisualChildrenCount = 1, vkids = { logEl } })
function hud:VisualChild(i) return self.vkids[i] end   -- 1-based here
local page = obj("ls::UIWidget", { Name = "Hud", DataContext = obj("gui::DCHud") })
local cr = obj("Grid", { children = coll({ page }), VisualChildrenCount = 1, vkids = { hud } })
function cr:VisualChild(i) return self.vkids[i] end
local root = obj("Border", { VisualChildrenCount = 1, vkids = { cr } })
function root:VisualChild(i) return self.vkids[i] end
function root:Find(n) return n == "ContentRoot" and cr or nil end
local deferred = 0
Ext.UI = { GetRoot = function() return root end, Defer = function(fn) deferred = deferred + 1 fn() end }
FightRec = nil
dofile(SRC)
local CF = FightRec
local logPath = "FightRec/" .. CF.stamp .. "-combatlog.jsonl"
C.events.Tick()
items[2] = entry("Goblin saves", { "WIS 14 vs DC 13" })
C.mono = C.mono + 3000
C.events.Tick()
local cl = M.files[logPath] or C.files[logPath]
local cl0 = cl
local k = {}
for _, l in ipairs(lines(cl)) do k[#k + 1] = l:match('"kind":"([^"]+)","t":') end
ok(deferred == 2, "the combat log is read inside Ext.UI.Defer")
ok(cl0:find('"chosen":"Data.CombatLog.Entries"', 1, true) ~= nil and cl0:find('"element":"CombatLogPanel"', 1, true) ~= nil, "the entries are found below the DC's shared base")
ok(table.concat(k, ",") == "locate,entry,entry", "combat log: probe then each entry once: " .. table.concat(k, ","))
ok(cl:find("WIS 14 vs DC 13", 1, true) and cl:find("Attack 17 vs AC 15", 1, true), "entries keep their roll lines")
local bad = false for _, t in ipairs(propsOn) do if t == "Button" or t == "Grid" then bad = true end end
ok(not bad, "GetAllProperties never runs on an element")
-- the log dropped its first entry and added one: no duplicates
table.remove(items, 1)
items[2] = entry("Shadowheart misses", { "Attack 8 vs AC 13" })
C.mono = C.mono + 3000
C.events.Tick()
cl = C.files[logPath]
local _, nSaves = cl:gsub("Goblin saves", "")
ok(nSaves == 1 and cl:find("Shadowheart misses", 1, true) ~= nil, "a shifted log resyncs without duplicates")

-- no entries anywhere (live 2026-10-22, third run): the panel's shape is written down instead
local C2 = mockExt(false)
local bare = obj("gui::DCCombatLog", { p = { CombatLogCollapsed = true, Flee = obj("ui::DeferredCommand") } })
local btn = obj("ls::LSButton", { Name = "Expand", VisualChildrenCount = 0 })
local panel = obj("ls::LSUserControl", { Name = "CombatLog", DataContext = bare, VisualChildrenCount = 1, vkids = { btn } })
function panel:VisualChild(i) return self.vkids[i] end
local root2 = obj("Border", { VisualChildrenCount = 1, vkids = { panel } })
function root2:VisualChild(i) return self.vkids[i] end
Ext.UI = { GetRoot = function() return root2 end, Defer = function(fn) fn() end }
FightRec = nil
dofile(SRC)
C2.events.Tick()
local cl2 = C2.files["FightRec/" .. FightRec.stamp .. "-combatlog.jsonl"] or ""
ok(cl2:find('"kind":"shape"', 1, true) and cl2:find('"CombatLogCollapsed":true', 1, true)
    and cl2:find('"name":"Expand"', 1, true), "no entries: the panel's members and elements are written down")

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
