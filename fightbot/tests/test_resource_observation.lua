-- Pure projection extracted from the real staged/production State source.
local file = assert(io.open(assert(arg[1]),"r"));local src=file:read("*a");file:close()
local first=assert(src:find("local function resourcesView(res)",1,true))
local last=assert(src:find('-- "ActionPoint:1;',first,true))
local S={};local config={blocker="Entangled"};local pool={Movement={amount=5.549888997280449,max=9}}
local BG3AI={Guard={move_blocked=function()if config.fail then error("status route failed")end return config.blocker end}}
local env=setmetatable({S=S,BG3AI=BG3AI,V={entity=function()return {}end},resources=function()return pool end,
    round=function(n,places)local m=10^places;return math.floor(n*m+0.5)/m end},{__index=_G})
local exposed='\nreturn {moveView=moveView}'
local funcs=assert(load(src:sub(first,last-1)..exposed,"movement observation","t",env))()
local count=0
local function check(v,msg)count=count+1;assert(v,msg)end
local out=funcs.moveView("actor",pool)
check(out.Movement[1]==0 and out.Movement[2]==9,"legacy blocked movement remains [0,9]")
check(out.MoveBlocked=="Entangled","legacy blocker unchanged")
check(out.MovementObservation.raw.current==5.549888997280449,"exact raw amount never becomes rounded 5.5 or masked zero")
check(out.MovementObservation.raw.max==9,"raw maximum retained")
check(out.MovementObservation.usable_projection.current==0,"usable guard projection zero separately")
check(out.MovementObservation.usable_projection.mask_applied,"mask provenance explicit")
check(not out.MovementObservation.blocker_check.status_absence_verified,"no hidden absence assertion")
check(not out.MovementObservation.usable_projection.movement_legality_verified,"projection is not complete legality proof")
check(pool.Movement.amount==5.549888997280449,"input pool not mutated")
config.blocker=nil
out=funcs.moveView("actor",pool)
check(out.Movement[1]==5.5 and out.MoveBlocked==nil,"legacy free projection stays rounded")
check(out.MovementObservation.raw.current==5.549888997280449,"unmasked raw precision retained")
check(out.MovementObservation.usable_projection.current==5.549888997280449,"unmasked projection retains precision too")
check(out.MovementObservation.blocker_check.outcome=="no_blocker_reported","nil blocker labelled only as report")
check(not out.MovementObservation.blocker_check.status_absence_verified,"nil blocker cannot certify empty statuses")
config.fail=true
out=funcs.moveView("actor",pool)
check(out.Movement[1]==5.5,"lookup failure preserves old list behavior")
check(out.MovementObservation.raw.available,"raw survives blocker failure")
check(not out.MovementObservation.usable_projection.available,"failed blocker lookup leaves usability unknown")
check(out.MovementObservation.blocker_check.reason=="blocker_lookup_failed","failure reason retained")
BG3AI.Guard=nil
out=funcs.moveView("actor",pool)
check(not out.MovementObservation.blocker_check.available,"missing helper distinct unknown")
check(out.MovementObservation.blocker_check.reason=="blocker_helper_unavailable","missing helper reason")
out=funcs.moveView("actor",{})
check(not out.MovementObservation.raw.available and out.MovementObservation.raw.current==nil,"missing pool unknown, never zero")
pool={Movement={amount=0,max=9}}
check(S.movementObservationFor("actor").raw.current==0,"real zero amount remains observed zero")
pool={Movement={amount=5.549888997280449}}
check(not S.movementObservationFor("actor").raw.available,"missing maximum is incomplete")
check(S.movementObservationFor("actor").raw.current==5.549888997280449,"partial raw current retained")
if arg[2] then
    local actionFile=assert(io.open(arg[2],"r"));local actions=actionFile:read("*a");actionFile:close()
    local af=assert(actions:find("function A.summary(char)",1,true))
    local al=assert(actions:find("-- Start an action job",af,true))
    local A={}
    local G={pos=function()return {1,2,3}end,entity=function()return {Health={Hp=17,MaxHp=17}}end,
        resources=function()return {Movement={[0]=5.549888997280449},ActionPoint={[0]=1}}end,
        in_combat=function()return false end,b=function()return false end,q=function()end}
    local U={round=env.round,comp=function(e,k)return e[k]end}
    pool={Movement={amount=5.549888997280449,max=9}}
    config.fail=false;config.blocker="Entangled"
    BG3AI.Guard={move_blocked=function()return config.blocker end};BG3AI.State=S
    local ae=setmetatable({A=A,G=G,U=U,BG3AI=BG3AI,pos_view=function(p)return p end},{__index=_G})
    assert(load(actions:sub(af,al-1),"actual action summary","t",ae))()
    local summary=A.summary("actor")
    check(summary.movement==5.5,"legacy action after.movement remains raw rounded pool")
    check(summary.movement_observation.raw.current==5.549888997280449,"action after exposes exact pool additively")
    check(summary.movement_observation.usable_projection.current==0,"action after independently exposes Entangled usable projection")
    check(summary.movement_observation.raw.max==9,"action after raw maximum available")
    BG3AI.State=nil
    summary=A.summary("actor")
    check(summary.movement==5.5,"unavailable observation never overwrites legacy pool")
    check(not summary.movement_observation.raw.available,"unavailable State helper remains explicit unknown")
end
print(count.." movement resource observation checks passed")
