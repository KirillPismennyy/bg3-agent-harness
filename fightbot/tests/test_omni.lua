-- Offline tests for Server/Omni.lua (the fightbot's roll log) and fightbot/FightBotLoad.lua, Script Extender mocked.
--   lua fightbot/tests/test_omni.lua mod/Mods/BG3AI/ScriptExtender/Lua
local LUA = arg and arg[1] or "mod/Mods/BG3AI/ScriptExtender/Lua"
local pass, fail = 0, 0
local function ok(c, n) if c then pass = pass + 1 print("ok   " .. n) else fail = fail + 1 print("FAIL " .. n) end end

local listeners, events = {}, {}
local function mockExt(server)
    Ext = {
        IsServer = function() return server end,
        Utils = { MonotonicTime = function() return 1000 end, Print = function() end, PrintWarning = print },
        Osiris = { RegisterListener = function(n, _, _, fn) listeners[n] = fn end },
        Events = setmetatable({}, { __index = function(_, k)
            return { Subscribe = function(_, fn) events[k] = fn end }
        end }),
    }
end
mockExt(true)

local P, G, FAR = "00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000b",
    "00000000-0000-0000-0000-00000000000c"
local combatOf = { [P] = "C1", [G] = "C1", [FAR] = "C2" }
Osi = { CombatGetGuidFor = function(u) return combatOf[u] end }
local ops = {}
BG3AI = {
    RPC = { register = function(n, f) ops[n] = f end },
    Visibility = {
        uuid = function(s) return type(s) == "string" and s:match("%x+%-%x+%-%x+%-%x+%-%x+$") or nil end,
        name = function(u) return ({ [P] = "Lae'zel", [G] = "Imp", [FAR] = "Far" })[u] end,
        osi = function(fn, ...) local okc, v = pcall(fn, ...) return okc and v or nil end,
        context = function() return { party = { P }, is_party = { [P] = true } } end,
    },
}
dofile(LUA .. "/Server/Omni.lua")

-- engine-like objects: enums with Label, entity handles with Uuid.EntityUuid, arrays as Lua lists
local function enum(l) return setmetatable({}, { __index = function(_, k) if k == "Label" then return l end end }) end
local function ent(u) return { Uuid = { EntityUuid = u } } end
local function hit(guid, natural, total, ac, dmg)
    return { SpellCastGuid = guid, SpellId = "Target_MainHandAttack", TotalDamageDone = dmg or 0,
        ConditionRolls = { { RollType = "ConditionRollType(AttackRoll)", Difficulty = ac,
            Roll = { Roll = { Advantage = false, Disadvantage = true },
                Result = { NaturalRoll = natural, Total = total, Critical = enum("None"),
                    RollsCount = { { RollValue = natural }, { RollValue = 3 } } } } } },
        Damage = dmg and { FinalDamagePerType = { Slashing = dmg }, DamageRolls = { Slashing = { {
            Roll = { Roll = { DiceValue = enum("D12"), AmountOfDices = 1, DiceAdditionalValue = 3 } },
            Result = { NaturalRoll = dmg - 3, Total = dmg } } } } } or nil }
end

events.DealDamage({ Caster = ent(P), Target = ent(G), Hit = hit("g1", 12, 17, 7) })
ok(#BG3AI.Omni.log == 0, "nothing until omni.rolls_enable")
ops["omni.rolls_enable"]({ on = true })

events.DealDamage({ Caster = ent(P), Target = ent(G), Hit = hit("g1", 12, 17, 7) })
events.BeforeDealDamage({ Hit = hit("g1", 12, 17, 7, 10) })
listeners.AttackedBy(G, P, P, "Slashing", 10, "Attack", 1)
listeners.CastedSpell(P, "Target_MainHandAttack", "target", "", 1)
-- a miss: no damage events, AttackedBy 0
listeners.AttackedBy(P, G, G, "", 0, "Attack", 1)
-- someone else's fight
events.DealDamage({ Caster = ent(FAR), Target = ent(FAR), Hit = hit("g9", 20, 25, 10) })
listeners.RollResult("GAMEPLAY_SpellSavingThrowSave", G, P, 1, 0, 0)

local r = ops["omni.rolls"]({ since = 0 })
ok(#r.rows == 3, "three rows: the hit, the miss, the save (the other fight left out): " .. #r.rows)
local h = r.rows[1]
ok(h.kind == "hit" and h.attacker.name == "Lae'zel" and h.target.name == "Imp", "the hit names attacker and target")
local a = h.rolls[1]
ok(a.type == "AttackRoll" and a.natural == 12 and a.total == 17 and a.vs == 7 and a.disadvantage == true
    and a.critical == "None" and #a.dice == 2, "the attack roll: d20, total, AC, disadvantage, both dice")
ok(h.damage and h.damage.total == 10 and h.damage.by_type.Slashing == 10 and h.damage.dice[1].die == "D12"
    and h.damage.dice[1].natural == 7, "the damage dice from BeforeDealDamage")
ok(h.taken == 10, "what the target took")
ok(r.rows[2].kind == "no_damage" and r.rows[2].attacker.name == "Imp", "a miss is a row without numbers")
ok(r.rows[3].kind == "roll_result" and r.rows[3].result == 1, "a save keeps the engine's raw result")
ok(#ops["omni.rolls"]({ since = r.latest }).rows == 0, "since skips what was read")

------------------------------------------------------------------------
-- FightBotLoad.lua: loads the files in order from the Script Extender folder and switches the fightbot on
------------------------------------------------------------------------
local loaded = {}
mockExt(true)
Ext.IO = { LoadFile = function(p)
    if p == "FightBotLoad.lua" then return nil end
    return ("FB_LOADED[#FB_LOADED + 1] = %q"):format(p)
        .. (p == "BG3AI/Shared/RPC.lua" and " BG3AI.RPC = { ops = {}, register = function(n, f) BG3AI.RPC.ops[n] = f end }" or "")
        .. (p == "BG3AI/Server/Visibility.lua" and " BG3AI.Visibility = {}" or "")
        .. (p == "BG3AI/Server/Omni.lua" and " BG3AI.RPC.register('omni.rolls_enable', function(a) FB_ROLLS = a.on return { hooks = { DealDamage = 'ok', X = 'nil' } } end)" or "")
end }
FB_LOADED = loaded
BG3AI = nil
dofile("fightbot/FightBotLoad.lua")
ok(#loaded == 12 and loaded[1] == "BG3AI/Shared/RPC.lua" and loaded[12] == "BG3AI/Server/Omni.lua",
    "the loader runs the 12 server files in BootstrapServer's order")
ok(BG3AI.Visibility.OMNISCIENT == true and FB_ROLLS == true and BG3AI.FightBotLoaded, "omniscient and the roll log on")
local again = #loaded
dofile("fightbot/FightBotLoad.lua")
ok(#loaded == again, "a second load does nothing")
mockExt(false)
BG3AI = nil
dofile("fightbot/FightBotLoad.lua")
ok(BG3AI == nil, "the client context loads nothing")

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
