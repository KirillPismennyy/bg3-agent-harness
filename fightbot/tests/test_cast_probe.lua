-- Regression: full dumps may lose bitfields; the direct read must preserve their labels.
local create, createdState, destroyedState, tick, saved, removed = nil, nil, nil, nil, nil, 0
local options = setmetatable({}, { __tostring = function() return "SpellCastOptions(IgnoreSpellRolls,NoMovement)" end })
local cast = { SpellCastState = { CastOptions = options, SpellId = { Prototype = "Projectile_MainHandAttack" } } }
function cast:GetAllComponents() return { SpellCastState = self.SpellCastState } end
local caster = { Uuid = { EntityUuid = "actor" }, SpellCastIsCasting = { Cast = cast } }
cast.SpellCastState.Caster = caster
Ext = {
    IsServer = function() return true end,
    Utils = { Print = function() end },
    Json = { Stringify = function(x) if x.reads then saved = x end return "{}" end,
        Parse = function() return { CastOptions = "*RECURSION*" } end },
    Entity = { OnCreate = function(_, f) create = f return 1 end,
        OnCreateDeferred = function(_, f) createdState = f return 3 end,
        OnDestroy = function(_, f) destroyedState = f return 4 end,
        Unsubscribe = function() removed = removed + 1 end },
    Events = { Tick = { Subscribe = function(_, f) tick = f return 2 end,
        Unsubscribe = function() removed = removed + 1 end } },
    IO = { SaveFile = function() return true end },
}
Osi = { GetDisplayName = function() return "actor" end, ResolveTranslatedString = function() return "cust" end }
CastProbe = nil
dofile("fightbot/probes/cast_probe.lua")
create(caster)
for _ = 1, 30 do tick() end
assert(saved and #saved.reads == 4, "expected all scheduled reads")
for _, read in ipairs(saved.reads) do
    assert(read.cast_options.text == "SpellCastOptions(IgnoreSpellRolls,NoMovement)", "lost direct bitfield labels")
end
assert(cast.SpellCastState.CastOptions == options, "probe mutated cast flags")
-- A real cast can exist without creating the actor's IsCasting component again.
local executed = { SpellCastState = { CastOptions = options, Caster = caster,
    SpellId = { Prototype = "Projectile_MainHandAttack" } }, GetAllComponents = cast.GetAllComponents }
createdState(executed)
for _ = 1, 30 do tick() end
assert(saved.n == 2 and saved.source == "state_created_deferred", "missed executed cast without IsCasting create")
destroyedState(executed)
assert(saved.reads[#saved.reads].source == "state_destroy", "lost destruction snapshot")
CastProbe.stop()
assert(removed == 4, "subscriptions not retired")
print("cast probe direct bitfield capture: passed")
