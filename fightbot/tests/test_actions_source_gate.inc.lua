-- Appended inside the existing Actions harness to use real locals/setup. These
-- additional tests replace the baseline compatibility stub with the REAL gate.
local gateCR = dofile(sourceGateCastRolls)
local gateSpell = "Projectile_SourceGateTest"
local function gateEntry(kind, ability, progression)
    return {Id={Prototype=gateSpell,OriginatorPrototype=gateSpell,SourceType=kind,
        Source="00000000-0000-0000-0000-000000000000",ProgressionSource=progression},
        PrepareType="AlwaysPrepared",SpellCastingAbility=ability}
end
local function gateSetup(entries, ability)
    BG3AI.CastRolls=gateCR
    spell(gateSpell,{TargetRadius="18",SpellType="Projectile",UseCosts="ActionPoint:1",Level=0})
    world[P1].comps.SpellBook={Spells=entries}
    world[P1].comps.Stats={SpellCastingAbility=ability}
    combat_setup(9)
end
test("source gate: racial Intelligence vs Wisdom refuses before Osiris and costs",function()
    gateSetup({gateEntry("ProgressionRace","Intelligence","race")},"Wisdom")
    local j=job(op("cast",{char=P1,spell=gateSpell,target=NPC}))
    eq(j.status,"failed","status");assert(j.error:find("explicit source selector required",1,true),j.error)
    eq(#called("UseSpell"),0,"no order")
    eq(world[P1].comps.ActionResources.Resources.ActionPoint[1].Amount,1,"no action charge")
end)
test("source gate: same-ability distinct sources still require explicit selection",function()
    gateSetup({gateEntry("ProgressionRace","Wisdom","race"),gateEntry("ProgressionClass","Wisdom","class")},"Wisdom")
    local j=job(op("cast",{char=P1,spell=gateSpell,target=NPC}))
    eq(j.status,"failed","status");eq(#called("UseSpell"),0,"no order")
end)
test("source gate: ordinary None weapon keeps the legacy order",function()
    local weapon=gateEntry("WeaponSpell","None","zero");weapon.PrepareType="Unknown"
    gateSetup({weapon},nil)
    local j=job(op("cast",{char=P1,spell=gateSpell,target=NPC}))
    eq(j.status,"running","status "..tostring(j.error));eq(#called("UseSpell"),1,"one order")
    eq(j.source_route,nil,"no experimental mutation arm")
end)
test("source gate: unique same-default class stays legacy without intervention",function()
    gateSetup({gateEntry("ProgressionClass","Wisdom","class")},"Wisdom")
    local j=job(op("cast",{char=P1,spell=gateSpell,target=NPC}))
    eq(j.status,"running","status "..tostring(j.error));eq(#called("UseSpell"),1,"one order")
    eq(j.source_route,nil,"no experimental mutation arm")
end)
test("source gate: actual UI route is not mistaken for prototype-only Osiris",function()
    gateSetup({gateEntry("ProgressionRace","Intelligence","race")},"Wisdom")
    local j=job(op("cast",{char=P1,spell=gateSpell,target=NPC,ui=true}))
    eq(j.status,"running","status "..tostring(j.error));eq(#called("UseSpell"),0,"UI route makes no Osiris order")
    eq(j.ui,true,"UI routing retained")
end)
test("source gate: default changed during checks refuses again before issuing order",function()
    gateSetup({gateEntry("ProgressionClass","Wisdom","class")},"Wisdom")
    local originalCheck=G.check_cast
    G.check_cast=function(...)
        local result=originalCheck(...)
        world[P1].comps.Stats.SpellCastingAbility="Charisma"
        return result
    end
    local ok,j=pcall(function() return job(op("cast",{char=P1,spell=gateSpell,target=NPC})) end)
    G.check_cast=originalCheck
    assert(ok,tostring(j));eq(j.status,"failed","status");eq(#called("UseSpell"),0,"no stale-source order")
end)
