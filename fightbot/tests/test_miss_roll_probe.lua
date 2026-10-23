local probe=assert(arg[1],'pass probe path')
local checks=0
local function check(v,msg)assert(v,msg);checks=checks+1 end
local function clone(v,seen)
    if type(v)~='table' then check(type(v)~='userdata' and type(v)~='function','plain scalar only');return v end
    seen=seen or {};check(not seen[v],'no cyclic/native proxy retention');seen[v]=true
    local out={};for k,x in pairs(v) do out[k]=clone(x,seen) end;seen[v]=nil;return out
end
local hooks,files,tick,unsub,serial,stored,failSave
local function setup(cfg)
    hooks={};files={};unsub={};serial=0;stored={};failSave=false;MissRollProbe=nil;MissRollProbeConfig=cfg or {dir='trial-a/',max_records=8,max_callbacks=16,max_ticks=20}
    Ext={IsServer=function()return true end,Utils={MonotonicTime=function()return 1000 end,Print=function()end},Entity={
        OnCreateDeferred=function(comp,fn)if comp=='SpellCastTargetHitInterruptEvent' and not (cfg and cfg.allow_interrupt) then error('unsupported fake component') end;hooks[comp]=fn;return comp end,
        Unsubscribe=function(id)unsub[id]=true end},Events={Tick={Subscribe=function(_,fn)tick=fn;return 1 end,Unsubscribe=function(_,id)unsub['tick'..id]=true end}},
        Json={Stringify=function(value)serial=serial+1;stored[tostring(serial)]=clone(value);return tostring(serial) end},
        IO={SaveFile=function(path,data)if failSave then return false end;files[path]=stored[data];return true end}}
    assert(loadfile(probe))();return MissRollProbe
end
local function fixture()
    local caster={Uuid={EntityUuid='party-a'}};local target={Uuid={EntityUuid='enemy-t'}}
    local roll={Result={Total=13,NaturalRoll=11,DiscardedDiceTotal=11,Critical='None',CriticalThreshold=20,RollsCount={}},Roll={RollType='RangedSpellAttack',Advantage=false,Disadvantage=false,RerollConditions={},Roll={AmountOfDices=1,DiceValue='D20',DiceNegative=false,DiceAdditionalValue=2}},Metadata={AbilityBoosts={Intelligence=0},ProficiencyBonus=2,RollBonus=0,ResolvedRollBonuses={},FixedRollBonuses={},SkillBonuses={}}}
    local cast={SpellCastState={Caster=caster,SpellCastGuid='cast-g',CastOptions='IgnoreCastChecks',SpellId={Prototype='Projectile_FireBolt',SourceType='ProgressionRace',ProgressionSource='race-id'}},SpellCastCache={SpellCastingAbility='Intelligence'}}
    return {Hit={Inflicter=caster,SpellId='Projectile_FireBolt',SpellCastGuid='cast-g',StoryActionId=900,ConditionRolls={{DataType=0,Difficulty=14,RollType='AttackRoll',RollUuid='roll-g',Roll=roll}}},Target=target,SpellCast=cast,Attack={TotalDamageDone=0}},roll
end
local P=setup();check(P.active,'armed');check(#P.registrations==5,'all attempted');check(P.registrations[4].ok==false,'unsupported registration retained')
local raw,roll=fixture();hooks.SpellCastTargetHitEvent({},'SpellCastTargetHitEvent',raw)
check(#P.records==1,'raw third callback argument used even absent entity component')
local rec=P.records[1];check(rec.numerical_roll_seen,'numerical miss roll captured');check(rec.Hit.ConditionRolls.values[1].Roll.Metadata.AbilityBoosts.values.Intelligence==0,'zero ability modifier preserved')
check(rec.Hit.ConditionRolls.values[1].Roll.Roll.Advantage==false,'false flags preserved');check(rec.CastState.SpellId.SourceType=='ProgressionRace','source preserved');check(rec.CastCache.SpellCastingAbility=='Intelligence','cache preserved')
roll.Result.NaturalRoll=19;raw.Hit.ConditionRolls={};raw.SpellCast=nil
check(rec.Hit.ConditionRolls.values[1].Roll.Result.NaturalRoll==11,'deep snapshot survives engine mutation/destruction')
P.dir='trial-b/';local raw2=fixture();hooks.SpellCastTargetHitEvent({},'SpellCastTargetHitEvent',raw2)
check(files['trial-a/002-SpellCastTargetHitEvent.json']~=nil and files['trial-b/002-SpellCastTargetHitEvent.json']==nil,'directory frozen independent mutable global')
P.stop();check(not P.active and unsub.SpellCastTargetHitEvent and unsub.tick1,'stop retires all handles')
P=setup();raw=fixture();local unknownSourceReads=0
raw.SpellCast.SpellCastState.SpellId=setmetatable({Prototype='Projectile_FireBolt',OriginatorPrototype='Projectile_FireBolt',SourceType='ProgressionRace',Source='zero-guid',ProgressionSource='race-id'},
    {__index=function(_,k)unknownSourceReads=unknownSourceReads+1;error('native SpellId has no property '..tostring(k))end})
hooks.SpellCastTargetHitEvent({},'',raw)
check(unknownSourceReads==0,'native five-field SpellId never queried for unsupported SpellCastSource alias')
check(P.records[1].complete and #P.records[1].errors==0,'declared five-field source yields complete core snapshot')
P=setup({dir='strict-interrupt/',allow_interrupt=true});raw=fixture();unknownSourceReads=0;raw.SpellCast=nil
raw.Spell=setmetatable({Prototype='Projectile_FireBolt',OriginatorPrototype='Projectile_FireBolt',SourceType='ProgressionRace',Source='zero-guid',ProgressionSource='race-id'},
    {__index=function(_,k)unknownSourceReads=unknownSourceReads+1;error('native SpellId has no property '..tostring(k))end})
hooks.SpellCastTargetHitInterruptEvent({},'',raw)
check(unknownSourceReads==0,'native interrupt SpellId never queried for unsupported alias')
check(P.records[1].complete and P.records[1].InterruptSpell.SourceType=='ProgressionRace','interrupt five-field source copied without read errors')
P=setup({dir='filter/',party_guids={'other-party'},max_records=2,max_callbacks=3,max_ticks=5});raw=fixture();hooks.SpellCastTargetHitEvent({},'',raw);check(#P.records==0 and P.filtered==1,'known GUID filter rejects unrelated event')
P=setup({dir='cap/',max_records=1,max_callbacks=3,max_ticks=5});raw=fixture();hooks.SpellCastTargetHitEvent({},'',raw);check(not P.active and #P.records==1,'record cap stops capture');hooks.SpellCastTargetHitEvent({},'',raw);check(#P.records==1,'stopped callback does not append')
P=setup();hooks.SpellCastSpellRollAbortEvent({},'',nil);check(P.records[1].component_available==false and P.records[1].hit_available==false,'expired raw component explicit unknown');check(not P.records[1].complete and not P.records[1].numerical_roll_seen,'absence not numerical miss evidence')
P=setup();raw=fixture();raw.Hit.ConditionRolls=setmetatable({},{__len=function()error('expired rolls')end});hooks.SpellCastTargetHitEvent({},'',raw);check(#P.records[1].errors>0 and not P.records[1].complete,'collection read failure retained')
P=setup();raw=fixture();failSave=true;hooks.SpellCastTargetHitEvent({},'',raw);check(P.write_failures==1 and #P.errors==1,'SaveFile false not called success')
P=setup({dir='time/',max_ticks=1});tick();check(not P.active,'tick cap stops without deferred engine refs')
P=setup({dir='cbcap/',party_guids={'other'},max_callbacks=1,max_ticks=10});raw=fixture();hooks.SpellCastTargetHitEvent({},'',raw);hooks.SpellCastTargetHitEvent({},'',raw);check(not P.active and P.callbacks==2,'filtered callbacks bounded too')
print('miss-roll probe: '..checks..' plain-data and lifecycle assertions passed')
