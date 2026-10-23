local path = arg[1]
local U = "00000000-0000-0000-0000-0000000000a1"
local T = "00000000-0000-0000-0000-0000000000b2"
local X = "00000000-0000-0000-0000-0000000000c3"
local clock, tick, onState, books, actorAbility = 0, nil, nil, {}, "Wisdom"
Ext = { Utils = {MonotonicTime=function() return clock end, PrintWarning=function() end},
    Entity = { Get=function(char) return {SpellBook={Spells=books},Stats={SpellCastingAbility=actorAbility}} end,
        OnCreateDeferred=function(_,fn) onState=fn end },
    Events={Tick={Subscribe=function(_,fn) tick=fn end}} }
BG3AI = {RPC={register=function() end},Guard={prepared_ids=function() return {} end,
    unprepared=function(entry) return entry.unprepared == true end}}
local CR = dofile(path)
local count = 0
local function check(value, name) count=count+1; assert(value,name) end
local function clone(t) local out={} for k,v in pairs(t) do out[k]=v end return out end
local source = {Prototype="Projectile_FireBolt",OriginatorPrototype="Projectile_FireBolt",
    SourceType="ProgressionRace",Source="00000000-0000-0000-0000-000000000000",
    ProgressionSource="30fafb0b-7c8b-4917-bd2a-536233b35d3c",SpellCastingAbility="Intelligence"}
local function entry(s) return {Id=clone(s),SpellCastingAbility=s.SpellCastingAbility,PrepareType="AlwaysPrepared"} end
local function opts(labels) return setmetatable({},{__tostring=function() return "SpellCastOptions("..table.concat(labels,",")..")" end}) end
local function state(config)
    config=config or {}
    local sid=clone(source); sid.SourceType=config.sourceType or "Osiris"
    sid.ProgressionSource="00000000-0000-0000-0000-000000000000"
    local raw={CastOptions=opts(config.labels or {"IgnoreSpellRolls","IgnoreCastChecks","NoMovement"})}
    local st=setmetatable({Caster={Uuid={EntityUuid=U}},SpellId=sid,SpellCastGuid="cast-guid",
        Targets={{Target={Uuid={EntityUuid=config.target or T}}}}}, {
        __index=function(_,k) return raw[k] end,
        __newindex=function(_,k,v) raw[k]=k=="CastOptions" and opts(v) or v end })
    local e={SpellCastState=st,SpellCastCache={SpellCastingAbility="Wisdom"},
        ServerSpellCastState={Phase=config.phase or "ValidationStart"}}
    if config.noCache then e.SpellCastCache=nil end
    if config.refuse then
        e.SpellCastCache=setmetatable({}, {__index=function() return "Wisdom" end,
            __newindex=function() error("read-only cache") end})
    end
    return e,raw
end
local function arm()
    CR.armed,CR.watching={},{}
    books={entry(source)}
    local j={}; CR.arm(j,U,source.Prototype,source,T); return j
end
books={entry(source)}
check(CR.validate_source(U,source.Prototype,source).SpellCastingAbility=="Intelligence","source validated")
local class=clone(source); class.SourceType="ProgressionClass"; class.ProgressionSource="another-source"; class.SpellCastingAbility="Wisdom"
books={entry(source),entry(class)}
check(CR.validate_source(U,source.Prototype,class).SpellCastingAbility=="Wisdom","duplicate prototype can choose class source")
books={entry(source),entry(source)}
check(not pcall(CR.validate_source,U,source.Prototype,source),"identical duplicate source rejected as ambiguous")
books={entry(source)};books[1].SpellCastingAbility="Wisdom"
check(not pcall(CR.validate_source,U,source.Prototype,source),"conflicting actual ability rejected")
books={entry(class)}
check(not pcall(CR.validate_source,U,source.Prototype,source),"missing source rejected")
books={entry(source)}; books[1].unprepared=true
check(not pcall(CR.validate_source,U,source.Prototype,source),"unprepared selected source rejected")
books={entry(source)};books[1].PrepareType=nil
check(not pcall(CR.validate_source,U,source.Prototype,source),"missing PrepareType cannot inherit permissive Guard fallback")
books={entry(source)};books[1].PrepareType="Unknown"
check(not pcall(CR.validate_source,U,source.Prototype,source),"unknown PrepareType explicitly unqualified")
for _,k in ipairs(CR.SOURCE_FIELDS) do
    local bad=clone(source);bad[k]=nil
    check(not pcall(CR.validate_source,U,source.Prototype,bad),"missing "..k.." rejected")
end
local bad=clone(source);bad.SpellCastingAbility=nil
check(not pcall(CR.validate_source,U,source.Prototype,bad),"missing ability rejected")
bad=clone(source);bad.SpellCastingAbility="Unknown";books={entry(bad)}
check(not pcall(CR.validate_source,U,source.Prototype,bad),"explicit selector cannot qualify unknown ability")
local j=arm();local e,raw=state();onState(e)
check(j.source_route.status=="source_written_readback","full source write read back")
check(e.SpellCastCache.SpellCastingAbility=="Intelligence","cache ability uses selected source")
check(e.SpellCastState.SpellId.SourceType=="ProgressionRace","racial source retained")
check(j.source_route.before.SourceType=="Osiris" and j.source_route.before.SpellCastingAbility=="Wisdom","original intervention evidence preserved")
check(j.source_route.after.ProgressionSource==source.ProgressionSource,"selected progression read back")
check(j.source_route.equivalence=="unproven" and j.source_route.experimental,"cannot claim player equivalence")
check(j.rolls.fix=="rolls_restored" and not tostring(raw.CastOptions):find("IgnoreSpellRolls"),"roll stripping retained")
check(tostring(raw.CastOptions):find("IgnoreCastChecks")~=nil,"other options retained")
check(j.source_route.cast_guid=="cast-guid" and j.source_route.phase=="ValidationStart","cast identity and phase reported")
e.SpellCastCache.SpellCastingAbility="Wisdom";tick()
check(j.source_route.status=="source_changed_after_readback","later cache overwrite disqualifies trial")
for _,config in ipairs({{target=X},{sourceType="ProgressionRace"},{sourceType="FromClient"},{labels={"NoMovement"}},
    {labels={"IgnoreSpellRolls","IsPreview"}},{labels={"IgnoreSpellRolls","IsHoverPreview"}},
    {labels={"IgnoreSpellRolls","FromClient"}}, {phase="Execution"}}) do
    j=arm();e,raw=state(config);onState(e)
    check(j.source_route.status=="armed" and CR.armed[U]~=nil,"unmatched cast remains untouched")
    check(e.SpellCastCache.SpellCastingAbility=="Wisdom","unmatched cast cache unchanged")
end
j=arm(); e,raw=state();e.SpellCastState.Targets[1].TargetProxy={Uuid={EntityUuid=X}};onState(e)
check(j.source_route.status=="armed","proxy target rejected")
j=arm(); e,raw=state();e.SpellCastState.Targets[2]={Target={Uuid={EntityUuid=T}}};onState(e)
check(j.source_route.status=="armed","extra target rejected")
for _,targets in ipairs({{},{{}},{{Target={}}},{{Position={1,2,3}}}}) do
    j=arm();e,raw=state();e.SpellCastState.Targets=targets;onState(e)
    check(j.source_route.status=="armed","missing native entity target cannot match")
end
j=arm();e,raw=state({noCache=true});onState(e)
check(j.source_route.status=="source_patch_unavailable","missing cache explicitly unavailable")
check(e.SpellCastState.SpellId.SourceType=="Osiris","missing cache causes no source writes")
check(j.rolls.fix=="rolls_restored","already ordered cast retains roll fix on unavailable source patch")
j=arm();e,raw=state({refuse=true});onState(e)
check(j.source_route.status=="source_write_failed","refused cache write explicit failure")
check(e.SpellCastState.SpellId.SourceType=="Osiris","partial source writes rolled back")
check(j.source_route.rollback_confirmed,"rollback readback reported")
check(j.rolls.fix=="rolls_restored","failure does not suppress ordinary roll fix")
-- Force failure at every source field independently, after earlier writes may
-- have succeeded. Include identity fields unchanged by the real narrow trial.
for _,failedKey in ipairs(CR.SOURCE_FIELDS) do
    j=arm();e,raw=state()
    local stored={};for _,k in ipairs(CR.SOURCE_FIELDS) do stored[k]="old-"..k end
    stored.SourceType="Osiris"
    local original=clone(stored)
    local proxy=setmetatable({}, {__index=function(_,k) return stored[k] end,
        __newindex=function(_,k,v) if k==failedKey then error("refused "..k) end stored[k]=v end})
    e.SpellCastState.SpellId=proxy
    local a={job=j,source=clone(source),caster=U,spell=source.Prototype}
    local success=CR.apply_source(e,e.SpellCastState,a)
    check(not success and j.source_route.status=="source_write_failed","field refusal reported "..failedKey)
    check(j.source_route.rollback_confirmed,"partial writes rollback "..failedKey)
    for _,k in ipairs(CR.SOURCE_FIELDS) do check(stored[k]==original[k],"rollback restored "..k) end
end
j=arm();e,raw=state()
local stored=clone(e.SpellCastState.SpellId)
e.SpellCastState.SpellId=setmetatable({}, {__index=function(_,k) return stored[k] end,
    __newindex=function(_,k,v)
        if stored[k]~=v and v~=source[k] then error("rollback refused") end
        stored[k]=v
    end})
e.SpellCastCache=setmetatable({}, {__index=function() return "Wisdom" end,
    __newindex=function() error("cache refused") end})
onState(e)
check(j.source_route.status=="source_write_failed" and not j.source_route.rollback_confirmed,
    "failed rollback remains explicit unqualified partial mutation")
j=arm()
check(not pcall(CR.arm,{},U,source.Prototype,source,T),"second armed source transaction refused")
clock=CR.ARM_MS+1;tick()
check(j.source_route.status=="matching_cast_not_seen","unmatched source order expires explicitly")
j=arm(); clock=clock+CR.ARM_MS+1; e,raw=state(); onState(e)
check(j.source_route.status=="matching_cast_not_seen" and j.rolls.fix=="cast_state_not_seen","state-triggered expiry never leaves source armed forever")
j=arm();books={entry(class)}; e,raw=state();onState(e)
check(j.source_route.status=="source_no_longer_available" and e.SpellCastState.SpellId.SourceType=="Osiris",
    "source removed after order is revalidated before mutation")
-- Prototype-only gate refuses the verified wrong-ability route without opting
-- any caller into source/cache mutations.
books={entry(source)};actorAbility="Wisdom"
check(not pcall(CR.check_legacy_source,U,source.Prototype),"racial Intelligence versus actor Wisdom requires explicit selector")
actorAbility="Intelligence"
check(CR.check_legacy_source(U,source.Prototype).source.SourceType=="ProgressionRace","unique same-default source keeps disclosed legacy route")
books={entry(source),entry(class)}
check(not pcall(CR.check_legacy_source,U,source.Prototype),"class plus race full identities require explicit selector")
local sameAbility=clone(class);sameAbility.SpellCastingAbility="Intelligence"
books={entry(source),entry(sameAbility)}
check(not pcall(CR.check_legacy_source,U,source.Prototype),"multiple identities require selector even when abilities agree")
books={entry(source),entry(class)};books[2].PrepareType="RequiresPreparation";books[2].unprepared=true
check(CR.check_legacy_source(U,source.Prototype).source.SourceType=="ProgressionRace","qualified unprepared class candidate excluded")
books={entry(class)};actorAbility="Wisdom"
check(CR.check_legacy_source(U,source.Prototype).equivalence=="unproven","unique same-default class stays explicitly unproven")
books={entry(class)};books[1].SpellCastingAbility=nil
check(not pcall(CR.check_legacy_source,U,source.Prototype),"unknown prepared ability refuses")
books={entry(class)};books[1].SpellCastingAbility="Unknown"
check(not pcall(CR.check_legacy_source,U,source.Prototype),"unqualified ability label refuses")
books={entry(class)};books[1].PrepareType="Unknown"
check(not pcall(CR.check_legacy_source,U,source.Prototype),"unknown preparation kind refuses")
books={entry(class)};books[1].Id.ProgressionSource=nil
check(not pcall(CR.check_legacy_source,U,source.Prototype),"missing matching source identity refuses")
books={entry(class)};actorAbility=nil
check(not pcall(CR.check_legacy_source,U,source.Prototype),"missing actor default cannot certify ability match")
local weapon=entry(source);weapon.SpellCastingAbility="None";weapon.PrepareType="Unknown"
weapon.Id.Prototype="Projectile_MainHandAttack";weapon.Id.OriginatorPrototype="Projectile_MainHandAttack"
books={weapon};actorAbility=nil
check(CR.check_legacy_source(U,weapon.Id.Prototype).ability=="None","ordinary None weapon unaffected by missing default or unknown preparation")
books={entry(class)};actorAbility="Wisdom";books[1].PrepareType="RequiresPreparation";books[1].unprepared=true;books[1].SpellCastingAbility=nil
check(not pcall(CR.check_legacy_source,U,source.Prototype),"only unprepared source does not qualify a legacy cast")
print(count.." source cast checks passed")
