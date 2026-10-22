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
M.entities = { [u1] = { Health = { Hp = 30, MaxHp = 34 }, EocLevel = { Level = 3 },
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
    GetEquippedItem = function(_, slot) return slot == "MeleeMainHand" and "Sword_00000000-0000-0000-0000-00000000000a" or nil end,
    GetRegion = function() return "WLD_Main_A" end,
}
FightRec = nil
dofile(SRC)
local FR = FightRec
local L = M.listeners

-- preparation, outside combat
L.CastedSpell(P1, "Shout_Bless", "Shout", "None", 1)
L.StatusApplied(P1, "BLESS", P1, 1)
L.CastedSpell(FAR, "Projectile_FireBolt", "Projectile", "Fire", 1)   -- not ours
ok(#FR.prep == 2 and FR.fight == nil, "outside combat only party records are kept, as preparation")

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
M.events.DealtDamage({ Caster = { Uuid = { EntityUuid = u1 } }, Target = { Uuid = { EntityUuid = ug } },
    Hit = { TotalDamageDone = 9 }, Attack = {} })
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
ok(seq == "meta,prep,prep,snapshot,CombatRoundStarted,AttackedBy,RollResult,DealtDamage,BeforeDealDamage,BeforeDealDamage,snapshot,end",
    "fight file: " .. seq)
local _, shapes = M.files[path]:gsub('"shape":', "")
ok(shapes == 2, "each damage event's shape is dumped once (DealtDamage, BeforeDealDamage)")
ok(M.files[path]:find('"name":"Lae\'zel"', 1, true) ~= nil, "characters are named")
ok(M.files[path]:find('"amount":9') and not M.files[path]:find('"amount":3'), "only the party's combat is recorded")
ok(M.files[path]:find('"name":"BLESS (shown)"', 1, true) ~= nil, "statuses and spells carry their shown names")
ok(M.files[path]:find('"slot":"MeleeMainHand"', 1, true) ~= nil, "the snapshot lists equipment")
ok(M.files[path]:find('"turns":3', 1, true) ~= nil, "statuses carry their turns")
ok(M.files[path]:find('"hooks":', 1, true) ~= nil, "meta lists the hooks")
local snap = f[4]
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
local dc = obj("gui::DCCombatLog", { p = { Entries = coll(items), CurrentPlayer = obj("ls::VMPlayer") } })
local page = obj("ls::UIWidget", { Name = "CombatLog", DataContext = dc })
local cr = obj("Grid", { children = coll({ page }) })
local root = obj("Border")
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
local k = {}
for _, l in ipairs(lines(cl)) do k[#k + 1] = l:match('"kind":"([^"]+)","t":') end
ok(deferred == 2, "the combat log is read inside Ext.UI.Defer")
ok(table.concat(k, ",") == "probe,entry,entry", "combat log: probe then each entry once: " .. table.concat(k, ","))
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

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
