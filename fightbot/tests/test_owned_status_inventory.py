"""Offline generated-Lua and proof-intake checks. Lua tables are normalized by
this mock only; native SE JSON empty-array behavior is separately observed.
No game/debugger connection is used.
"""
import copy
import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
import test_snapshot_statuses as baseline
LuaRuntime=baseline.LuaRuntime
import replay_trial as replay

ACTOR='3ed74f06-3c60-42dc-83f6-f034cb47c679'
TARGET='b5c913f9-f081-45bd-8e95-e34d0735b645'
COMBAT='f4824caa-f975-3620-e155-9edeb3fe0adb'
SETUP='''
local au="3ed74f06-3c60-42dc-83f6-f034cb47c679"
local tu="b5c913f9-f081-45bd-8e95-e34d0735b645"
entities[au]=entities.actor;entities[tu]=entities.target
Ext.Json.Parse=function(v)if type(v)=="string" then return {actor=au,target=tu,spell="Projectile_FireBolt"} else return v end end
Osi={DB_Players={Get=function()return {{"S_Player_Shadowheart_"..au}}end},
 DB_Is_InCombat={Get=function()return {{au},{tu}}end}}
scan_calls=0
Ext.Entity.GetAllEntitiesWithComponent=function(name)assert(name=="ServerStatus");scan_calls=scan_calls+1;return {a,b,t}end
BG3AI.rpc=function()return {ok=true,result={session_id="session",combat_id="f4824caa-f975-3620-e155-9edeb3fe0adb",file_prefix="prefix",recorder_active=true,party_combats={"f4824caa-f975-3620-e155-9edeb3fe0adb"}}}end
FightRecV2.source_content_sha256=string.rep("a",64)
'''

def convert(x,key=None):
    if not hasattr(x,'items'):return x
    vals=dict(x.items())
    if key in ('actors','global_rows','rows','owned_rows','container_rows','errors','party_combats'):
        return [convert(vals[k]) for k in sorted(vals)]
    return {k:convert(v,k) for k,v in vals.items()}

@unittest.skipIf(LuaRuntime is None,'Optional Lua 5.4 runtime required')
class OwnershipChecks(unittest.TestCase):
    def snap(self,mutation=''):
        return baseline.SnapshotStatusChecks().snapshot(SETUP+mutation)
    def proof(self,mutation=''):
        result,lua=self.snap(mutation)
        return result['validated_status_inventory'],result,lua
    def normalized(self,mutation=''):
        f,r,lua=self.proof(mutation)
        self.assertTrue(f['ok'],f['error'])
        recording=convert(r['identity']['result'])
        return {'native':{'actor':{'uuid':ACTOR,'status_container_entries':{'ok':False,'error':'absent container'}},'target':{'uuid':TARGET},'recorder_hash':'a'*64,'validated_status_inventory':convert(f)},'recording':recording,'owner_binding':{'server_session':'session','combat_id':COMBAT,'server_recorder_hash':'a'*64},'started_ms':r['started_ms'],'finished_ms':r['finished_ms']}
    def test_single_global_scan_exact_handles_and_inactive_retained(self):
        f,r,lua=self.proof()
        self.assertTrue(f['ok'],f['error']);self.assertEqual(lua.globals().scan_calls,1)
        self.assertEqual(f['result']['scanned'],3)
        rows=list(f['result']['global_rows'].values())
        self.assertIn('144115235320525612',[x['instance'] for x in rows])
        self.assertIn(False,[x['active'] for x in rows])
        snap=self.normalized();rows,receipt=replay.ownership_inventory(snap,'actor')
        self.assertEqual(len(rows),2);self.assertEqual(receipt['directContainerDiagnostic']['ok'],False)
    def test_absent_container_zero_owned_with_positive_control(self):
        m='entities.actor.StatusContainer=nil;Ext.Entity.GetAllEntitiesWithComponent=function()scan_calls=scan_calls+1;return {t}end'
        snap=self.normalized(m);rows,receipt=replay.ownership_inventory(snap,'actor')
        self.assertEqual(rows,[]);self.assertTrue(receipt['absenceProven'])
    def test_whole_facet_faults_preserve_direct_native_read(self):
        mutations=[
         'Ext.Entity.GetAllEntitiesWithComponent=function()return {a,a,t}end',
         'Ext.Entity.GetAllEntitiesWithComponent=function()return {[1]=a,[3]=t}end',
         't.ServerStatusOwnership=nil',
         't.ServerStatusOwnership.Owner=entities.actor',
         't.handle=0',
         't.HasRawComponent=function()return nil end',
         't.ServerStatus.StatusId="WRONG"',
         'Osi.DB_Players.Get=function()error("roster fault")end',
         'Ext.Entity.GetAllEntitiesWithComponent=function()return setmetatable({},{__len=function()return 50001 end})end',
         'Ext.Utils.MonotonicTime=function()clock=clock+100;return clock end',
         'entities.actor.StatusContainer=nil;entities.target.StatusContainer=nil',
        ]
        for m in mutations:
            with self.subTest(m=m):
                f,r,lua=self.proof(m);self.assertFalse(f['ok']);self.assertIsNone(f['result'])
                self.assertTrue(r['native_actor']['ok'])
    def test_tampered_or_failed_present_never_fallback(self):
        original=self.normalized()
        mutations=[lambda v:v.update(scanned=2),lambda v:v.update(positive_controls=0),lambda v:v.update(errors=['fault']),lambda v:v.update(end_ms=v['begin_ms']+251),lambda v:v['binding_after'].update(server_session='wrong'),lambda v:v['global_rows'][0].update(owner_handle='1'),lambda v:v['actors'][0].update(owned_rows=[]),lambda v:v.update(global_rows=v['global_rows']+[v['global_rows'][0]])]
        for mutate in mutations:
            s=copy.deepcopy(original);mutate(s['native']['validated_status_inventory']['result'])
            with self.assertRaises(replay.Refusal):replay.ownership_inventory(s,'actor')
        for facet in (None,{}, {'ok':False,'error':'fault'}):
            s=copy.deepcopy(original);s['native']['validated_status_inventory']=facet
            with self.assertRaises(replay.Refusal):replay.status_evidence(None,s,'actor',{},'before',{'controlled':{'acceptStaleStatusProbe':True,'acceptContainerListedStatusProjection':True,'acceptValidatedOwnershipInventory':True}})
    def test_optin_and_inactive_refusal_zero_owned_acceptance(self):
        s=self.normalized();profile={'controlled':{'acceptValidatedOwnershipInventory':True}}
        with self.assertRaisesRegex(replay.Refusal,'Inactive'):replay.status_evidence(None,s,'actor',{},'before',profile)
        s=self.normalized('entities.actor.StatusContainer=nil;Ext.Entity.GetAllEntitiesWithComponent=function()return {t}end')
        rows,receipt=replay.status_evidence(None,s,'actor',{},'before',profile);self.assertEqual(rows,[])
        with self.assertRaisesRegex(replay.Refusal,'opt-in'):replay.status_evidence(None,s,'actor',{},'before',{'controlled':{}})

if __name__=='__main__':unittest.main()
