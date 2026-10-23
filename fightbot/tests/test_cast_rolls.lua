-- Offline test of Server/CastRolls.lua (IgnoreSpellRolls cleared on our Osiris casts), Script Extender mocked.
--   lua fightbot/tests/test_cast_rolls.lua mod/Mods/BG3AI/ScriptExtender/Lua
local LUA = arg and arg[1] or "mod/Mods/BG3AI/ScriptExtender/Lua"
local pass, fail = 0, 0
local function ok(c, n) if c then pass = pass + 1 print("ok   " .. n) else fail = fail + 1 print("FAIL " .. n) end end

local clock, onState, tick = 0, nil, nil
local ops = {}
local function setup(withDeferred)
    onState, tick = nil, nil
    Ext = {
        Utils = { MonotonicTime = function() return clock end, PrintWarning = function() end },
        Entity = { OnCreateDeferred = withDeferred and function(name, fn) assert(name == "SpellCastState") onState = fn end or nil },
        Events = { Tick = { Subscribe = function(_, fn) tick = fn end } },
    }
    BG3AI = { RPC = { register = function(n, f) ops[n] = f end } }
    dofile(LUA .. "/Server/CastRolls.lua")
    return BG3AI.CastRolls
end

-- a bitfield like bg3se's: tostring "SpellCastOptions(a,b)"; assigning a list of labels sets it
local function opts(labels)
    return setmetatable({ l = labels }, { __tostring = function(t) return "SpellCastOptions(" .. table.concat(t.l, ",") .. ")" end })
end
local OSIRIS = { "IgnoreSpellRolls", "AvoidDangerousAuras", "IgnoreCastChecks", "IgnoreTargetChecks", "NoMovement", "IgnoreHasSpell" }
local function castState(caster, spell, labels, refuse)
    local st = { Caster = { Uuid = { EntityUuid = caster } }, SpellId = { Prototype = spell, OriginatorPrototype = spell } }
    local raw = { CastOptions = opts(labels) }
    return { SpellCastState = setmetatable(st, {
        __index = function(_, k) return raw[k] end,
        __newindex = function(_, k, v)
            if refuse then error("read-only") end
            raw[k] = type(v) == "table" and opts(v) or v
        end }) }, raw
end
local U1 = "00000000-0000-0000-0000-0000000000a1"

local CR = setup(true)
ok(CR.available, "available with OnCreateDeferred")

-- our cast: armed, then its state appears
local job = {}
CR.arm(job, "Astarion_" .. U1, "Projectile_MainHandAttack")
ok(job.rolls.fix == "pending", "armed")
local e, raw = castState(U1, "Projectile_MainHandAttack", OSIRIS)
onState(e)
ok(job.rolls.fix == "rolls_restored", "cleared and read back")
ok(not tostring(raw.CastOptions):find("IgnoreSpellRolls"), "IgnoreSpellRolls is gone")
ok(tostring(raw.CastOptions):find("IgnoreCastChecks") and tostring(raw.CastOptions):find("NoMovement"),
    "the other options stay (the guard checks and charges)")
ok(job.rolls.options_before:find("IgnoreSpellRolls") and not job.rolls.options_after:find("IgnoreSpellRolls"),
    "the result shows before and after")

-- the engine sets it again a tick later: re-cleared
raw.CastOptions = opts(OSIRIS)
tick()
ok(not tostring(raw.CastOptions):find("IgnoreSpellRolls") and job.rolls.reapplied == 1, "re-cleared when set again")

-- a cast of the same caster that is not the ordered one (a reaction) is left alone
local job2 = {}
CR.arm(job2, U1, "Target_MainHandAttack")
local e3, raw3 = castState(U1, "Target_AttackOfOpportunity", OSIRIS)
onState(e3)
ok(tostring(raw3.CastOptions):find("IgnoreSpellRolls") and job2.rolls.fix == "pending", "another spell is not touched")

-- someone else's cast (the enemy's, a player's own) is never touched
local e4, raw4 = castState("00000000-0000-0000-0000-0000000000b2", "Target_MainHandAttack", OSIRIS)
onState(e4)
ok(tostring(raw4.CastOptions):find("IgnoreSpellRolls"), "an unarmed caster's cast is not touched")

-- the ordered cast never shows up: said so after ARM_MS
clock = clock + CR.ARM_MS + 1
tick()
ok(job2.rolls.fix == "cast_state_not_seen", "a cast that never appeared is reported")

-- a write the engine refuses is reported, not hidden
local job3 = {}
CR.arm(job3, U1, "Projectile_FireBolt")
local e5 = castState(U1, "Projectile_FireBolt", OSIRIS, true)
onState(e5)
ok(job3.rolls.fix == "not_cleared", "a refused write says not_cleared")

-- without OnCreateDeferred (bg3le): unavailable, and says why
local CR2 = setup(false)
local job4 = {}
CR2.arm(job4, U1, "Projectile_FireBolt")
ok(not CR2.available and job4.rolls.fix == "unavailable" and job4.rolls.why:find("OnCreateDeferred"), "unavailable, with why")
ok(ops["act.cast_rolls"]().available == false, "act.cast_rolls reports it")

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
