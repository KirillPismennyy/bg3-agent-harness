-- Read-only, bounded server diagnostic. No game/component writes.
-- Optional MissRollProbeConfig={dir='FightBotProbe/miss-UNIQUE/',max_records=48,max_callbacks=192,max_ticks=3600,party_guids={...}}
if MissRollProbe and MissRollProbe.active then error('MissRollProbe already active; stop it before reloading') end
local cfg=MissRollProbeConfig or {}
MissRollProbeCounter=(MissRollProbeCounter or 0)+1
local stamp=tostring(Ext.Utils.MonotonicTime())..'-'..tostring(MissRollProbeCounter)
local dir=cfg.dir or ('FightBotProbe/miss-'..stamp..'/')
if dir:sub(-1)~='/' then dir=dir..'/' end
local maxRecords=math.min(tonumber(cfg.max_records) or 48,128)
local maxCallbacks=math.min(tonumber(cfg.max_callbacks) or 192,1024)
local maxTicks=math.min(tonumber(cfg.max_ticks) or 3600,18000)
local P={active=false,dir=dir,records={},subs={},errors={},registrations={},callbacks=0,ticks=0,filtered=0,writes=0,write_failures=0}
MissRollProbe=P
local allowed={};for _,u in ipairs(cfg.party_guids or {}) do allowed[tostring(u):lower()]=true end
local function atom(v)
    local t=type(v)
    if t=='nil' or t=='string' or t=='boolean' or t=='number' then return v end
    return {text=tostring(v),numeric=tonumber(v)}
end
local function read(o,k,errors,path)
    if o==nil then return nil end
    local ok,v=pcall(function() return o[k] end)
    if not ok then errors[#errors+1]={path=path or tostring(k),error=tostring(v)};return nil end
    return v
end
local function fields(o,names,errors,path)
    if o==nil then return nil end
    local out={};for _,k in ipairs(names) do out[k]=atom(read(o,k,errors,path..'.'..k)) end;return out
end
local function array(a,copy,errors,path)
    if a==nil then return {available=false} end
    local ok,n=pcall(function()return #a end)
    if not ok or type(n)~='number' then errors[#errors+1]={path=path,error='length unavailable: '..tostring(n)};return {available=false} end
    local out={available=true,declared_count=n,values={},truncated=n>128}
    for i=1,math.min(n,128) do local v=read(a,i,errors,path..'['..i..']');out.values[i]=copy(v,errors,path..'['..i..']') end
    return out
end
local function map(a,errors,path)
    if a==nil then return {available=false} end
    local out={available=true,values={}};local count=0
    local ok,err=pcall(function()for k,v in pairs(a) do count=count+1;if count>64 then out.truncated=true;break end;out.values[tostring(k)]=atom(v) end end)
    if not ok then out.available=false;errors[#errors+1]={path=path,error=tostring(err)} end
    return out
end
local function statsRoll(s,errors,path)
    if s==nil then return {available=false} end
    local r=read(s,'Roll',errors,path..'.Roll');local result=read(s,'Result',errors,path..'.Result');local meta=read(s,'Metadata',errors,path..'.Metadata')
    local out={available=true,Result=fields(result,{'Total','NaturalRoll','DiscardedDiceTotal','Critical','CriticalThreshold'},errors,path..'.Result'),Roll=fields(r,{'RollType','Advantage','Disadvantage'},errors,path..'.Roll'),Metadata=fields(meta,{'ProficiencyBonus','RollBonus','HighGroundBonus','LowGroundPenalty','BaseUnarmedDamage','AutoAbilityCheckFail','AutoSkillCheckFail','AutoAbilitySavingThrowFail','HasCustomMetadata','IsCritical'},errors,path..'.Metadata')}
    out.Roll=out.Roll or {};out.Metadata=out.Metadata or {};out.Result=out.Result or {}
    out.Roll.Roll=fields(read(r,'Roll',errors,path..'.Roll.Roll'),{'AmountOfDices','DiceValue','DiceNegative','DiceAdditionalValue'},errors,path..'.Roll.Roll')
    out.Roll.RerollConditions=array(read(r,'RerollConditions',errors,path..'.Roll.RerollConditions'),function(v,e,p)return fields(v,{'RollValue','KeepNew'},e,p) end,errors,path..'.Roll.RerollConditions')
    out.Result.RollsCount=array(read(result,'RollsCount',errors,path..'.Result.RollsCount'),function(v,e,p)return fields(v,{'RollValue','RerollType'},e,p) end,errors,path..'.Result.RollsCount')
    out.Metadata.AbilityBoosts=map(read(meta,'AbilityBoosts',errors,path..'.Metadata.AbilityBoosts'),errors,path..'.Metadata.AbilityBoosts')
    out.Metadata.SkillBonuses=map(read(meta,'SkillBonuses',errors,path..'.Metadata.SkillBonuses'),errors,path..'.Metadata.SkillBonuses')
    for _,k in ipairs({'ResolvedRollBonuses','FixedRollBonuses'}) do out.Metadata[k]=array(read(meta,k,errors,path..'.Metadata.'..k),function(v,e,p)return fields(v,{'DiceSize','NumDice','Bonus','RollBonus','SourceName'},e,p) end,errors,path..'.Metadata.'..k) end
    return out
end
local function condition(c,errors,path)
    local out=fields(c,{'DataType','Difficulty','RollType','RollUuid','Ability','Skill','SwappedSourceAndTarget'},errors,path) or {}
    local s=read(c,'Roll',errors,path..'.Roll');out.Roll=statsRoll(s,errors,path..'.Roll')
    -- Variant may instead be StatsExpressionResolved; preserve its independent branch.
    if not read(s,'Result',{},'') then
        out.Roll={variant='StatsExpressionResolved_or_unreadable',StatExpression=atom(read(s,'StatExpression',errors,path..'.Roll.StatExpression')),
            RollParams=array(read(s,'RollParams',errors,path..'.Roll.RollParams'),statsRoll,errors,path..'.Roll.RollParams')}
    end
    return out
end
local function uuid(e,errors,path)
    local u=read(e,'Uuid',errors,path..'.Uuid');local id=read(u,'EntityUuid',errors,path..'.Uuid.EntityUuid');return id and tostring(id) or nil
end
local function identity(e,errors,path)return {entity=atom(e),uuid=uuid(e,errors,path)} end
local function save(path,rec)
    local ok,result=pcall(function()return Ext.IO.SaveFile(path,Ext.Json.Stringify(rec,{Beautify=true})) end)
    if ok and result~=false then P.writes=P.writes+1 else P.write_failures=P.write_failures+1;P.errors[#P.errors+1]={path=path,error=tostring(result)} end
end
local function manifest(reason)
    save(dir..'manifest.json',{schema=1,kind='miss_roll_probe_manifest',dir=dir,active=P.active,stop_reason=reason,registrations=P.registrations,errors=P.errors,callbacks=P.callbacks,records=#P.records,filtered=P.filtered,writes=P.writes,write_failures=P.write_failures,
        completeness='Unknown until live event and numerical roll data are observed; registration success is not delivery proof.',limits={max_records=maxRecords,max_callbacks=maxCallbacks,max_ticks=maxTicks},source_api='One-frame supports deferred create only; snapshots copied immediately inside callback.'})
end
function P.stop(reason)
    P.active=false
    for _,s in ipairs(P.subs) do local ok,err=pcall(s.off);if not ok then P.errors[#P.errors+1]={path='unsubscribe',error=tostring(err)} end end
    P.subs={};manifest(reason or 'explicit_stop')
end
local function capture(component,entity,raw)
    if not P.active then return end
    P.callbacks=P.callbacks+1
    if P.callbacks>maxCallbacks then P.stop('callback_limit');return end
    local errors={};local c=raw or read(entity,component,errors,'event.'..component)
    local hit=read(c,'Hit',errors,'Hit');local caster=read(hit,'Inflicter',errors,'Hit.Inflicter')
    local cast
    if component=='SpellCastTargetHitEvent' then cast=read(c,'SpellCast',errors,'SpellCast') end
    if component=='SpellCastTargetReactionEvent' then cast=read(c,'CastEntity',errors,'CastEntity') end
    -- Optional relation lookup is not an event-schema read. Missing cast state
    -- remains explicitly unavailable; do not fabricate a source from Hit.SpellId.
    if not cast then cast=read(read(caster,'SpellCastIsCasting',{},''),'Cast',{},'') end
    local entityState=read(entity,'SpellCastState',{},'entity.SpellCastState')
    if not cast and entityState then cast=entity end
    local state=read(cast,'SpellCastState',errors,'cast.SpellCastState') or entityState
    caster=caster or read(state,'Caster',errors,'cast.Caster')
    local target=read(c,'Target',errors,'Target');local casterId=uuid(caster,{},'caster');local targetId=uuid(target,{},'target')
    if next(allowed) and not allowed[(casterId or ''):lower()] and not allowed[(targetId or ''):lower()] then P.filtered=P.filtered+1;return end
    local n=#P.records+1;local path=dir..string.format('%03d-%s.json',n,component)
    local out={schema=1,n=n,path=path,component=component,hook='OnCreateDeferred',at_ms=Ext.Utils.MonotonicTime(),event_entity=identity(entity,errors,'entity'),caster=identity(caster,errors,'caster'),target=identity(target,errors,'target'),cast=identity(cast,errors,'cast'),errors=errors,
        component_available=c~=nil,hit_available=hit~=nil,complete=false,party_filter_enabled=next(allowed)~=nil}
    out.Hit=fields(hit,{'SpellId','SpellCastGuid','StoryActionId','AttackRollAbility','SpellAttackType','EffectFlags','AttackFlags','TotalDamageDone','DamageType','CauseType','SpellLevel','SpellPowerLevel'},errors,'Hit') or {}
    out.Hit.ConditionRolls=array(read(hit,'ConditionRolls',errors,'Hit.ConditionRolls'),condition,errors,'Hit.ConditionRolls')
    out.CastState=fields(state,{'SpellCastGuid','CastOptions'},errors,'CastState') or {}
    out.CastState.SpellId=fields(read(state,'SpellId',errors,'CastState.SpellId'),{'Prototype','OriginatorPrototype','SourceType','Source','ProgressionSource'},errors,'CastState.SpellId')
    out.CastCache=fields(read(cast,'SpellCastCache',errors,'cast.SpellCastCache'),{'SpellCastingAbility'},errors,'CastCache')
    if component=='SpellCastTargetHitEvent' or component=='SpellCastTargetHitInterruptEvent' then
        out.Attack=fields(read(c,'Attack',errors,'Attack'),{'TotalDamageDone','TotalHealDone','InitialHPPercentage'},errors,'Attack')
    end
    if component=='SpellCastTargetHitInterruptEvent' then
        out.InterruptSpell=fields(read(c,'Spell',errors,'Spell'),{'Prototype','OriginatorPrototype','SourceType','Source','ProgressionSource'},errors,'InterruptSpell')
    end
    out.numerical_roll_seen=false
    for _,row in ipairs(out.Hit.ConditionRolls.values or {}) do if row.Roll and row.Roll.Result and type(row.Roll.Result.NaturalRoll)=='number' then out.numerical_roll_seen=true end end
    out.complete=c~=nil and hit~=nil and #errors==0 and out.Hit.ConditionRolls.available==true and not out.Hit.ConditionRolls.truncated
    P.records[n]=out;save(path,out)
    if n>=maxRecords then P.stop('record_limit') end
end
if not Ext.IsServer() then P.errors[#P.errors+1]={error='server context required'};manifest('wrong_context');return end
P.active=true
for _,component in ipairs({'SpellCastSpellRollAbortEvent','SpellCastTargetHitEvent','SpellCastEvent','SpellCastTargetHitInterruptEvent','SpellCastTargetReactionEvent'}) do
    local ok,id=pcall(Ext.Entity.OnCreateDeferred,component,function(entity,_,raw)
        local worked,err=pcall(capture,component,entity,raw)
        if not worked then P.errors[#P.errors+1]={component=component,error=tostring(err)};manifest('callback_error') end
    end)
    P.registrations[#P.registrations+1]={component=component,api='OnCreateDeferred',ok=ok and id~=nil,error=(not ok) and tostring(id) or nil}
    if ok and id~=nil then P.subs[#P.subs+1]={off=function()Ext.Entity.Unsubscribe(id)end} end
end
local tickOk,tickId=pcall(function()return Ext.Events.Tick:Subscribe(function()
    if not P.active then return end;P.ticks=P.ticks+1;if P.ticks>=maxTicks then P.stop('tick_limit') end
end)end)
if tickOk then P.subs[#P.subs+1]={off=function()Ext.Events.Tick:Unsubscribe(tickId)end} else P.errors[#P.errors+1]={path='tick',error=tostring(tickId)} end
manifest('armed')
Ext.Utils.Print('[MissRollProbe] armed '..dir..'; deferred hooks='..tostring(#P.subs)..'; delivery and numerical data remain unverified')
