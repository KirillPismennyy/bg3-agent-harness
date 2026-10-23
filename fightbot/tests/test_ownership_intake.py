"""Synthetic ownership facets over retained capture: API integration only,
never new native evidence or modification of the retained trial."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import replay_trial as r
TRIAL=Path(os.environ['BG3_REPLAY_TEST_TRIAL']) if os.environ.get('BG3_REPLAY_TEST_TRIAL') else None
PROFILE=Path(os.environ['BG3_REPLAY_TEST_PROFILE']) if os.environ.get('BG3_REPLAY_TEST_PROFILE') else None

def add_synthetic(i,snapshot,*,after=False,inactive_target=False):
    actors=[];global_rows=[]
    for n,role in enumerate(('actor','target')):
        u=snapshot['native'][role]['uuid'];owner=str(9007199254740993+n)
        cp,_=i.resolve_checkpoint(u,snapshot['finished_ms'] if after else snapshot['started_ms'])
        rows=sorted([{'id':x['id'],'instance':str(x['instance']),'owner_handle':owner,'type':'TEST_SYNTHETIC','active':role!='target' or not inactive_target} for x in cp['statuses']],key=lambda x:x['instance'])
        actors.append({'uuid':u,'owner_handle':owner,'role':'party' if role=='actor' else 'combat','container_present':True,'container_rows':[{'id':x['id'],'instance':x['instance']} for x in rows],'owned_rows':copy.deepcopy(rows)})
        global_rows.extend(rows)
        snapshot['native'][role]['status_container_entries']={'ok':False,'error':'synthetic direct-component unavailable'}
    identity=snapshot['recording']
    binding={'server_session':identity['session_id'],'combat_id':identity['combat_id'],'recorder_hash':snapshot['native']['recorder_hash'],'file_prefix':identity['file_prefix']}
    snapshot['native']['validated_status_inventory']={'ok':True,'result':{
        'schema':1,'helper_sha256':r.INVENTORY_HELPER_SHA256,'source':'ServerStatus + ServerStatusOwnership.Owner; container set positive controls','coverage':'complete-server-status-ownership-at-callback','complete':True,'route_validated':True,'errors':[],'lifecycle_semantics_qualified':False,
        'begin_ms':snapshot['started_ms'],'end_ms':snapshot['finished_ms'],'max_duration_ms':250,'max_entities':50000,
        'binding_before':binding,'binding_after':copy.deepcopy(binding),'total':len(global_rows),'scanned':len(global_rows),'global_rows':sorted(global_rows,key=lambda x:x['instance']),
        'actors':sorted(actors,key=lambda x:x['uuid']),'selected':{role:snapshot['native'][role]['uuid'] for role in ('actor','target')},'controls':2,'positive_controls':2,
        'roster':{'party':{snapshot['native']['actor']['uuid']:True},'combat':{snapshot['native']['target']['uuid']:True}}}}

@unittest.skipUnless(TRIAL and PROFILE,'Private integration fixtures explicitly required')
class OwnershipIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.out=Path(self.tmp.name)
    def intake(self):
        i=r.Intake(TRIAL,r.load_profile(PROFILE));i.verify();i.profile['controlled']['acceptValidatedOwnershipInventory']=True;return i
    def test_before_complete_proof_overrides_unknown_direct_and_checkpoint(self):
        i=self.intake();add_synthetic(i,i.before)
        original=i.resolve_checkpoint
        def unknown(u,t):
            cp,receipt=original(u,t);cp=copy.deepcopy(cp);cp['statuses']={'unavailable':'component_absent','component_absent':True};return cp,receipt
        with patch.object(i,'resolve_checkpoint',unknown),patch.object(r,'status_probe',side_effect=AssertionError('no fallback')):
            payload,q=r.request(i,i.before,i.profile)
        self.assertEqual(len(payload['before']['units'][0]['statuses']),4)
        self.assertEqual(q['statusProbe']['globalOwnershipCompleteness'],'validated-at-callback')
        self.assertNotIn('global-owned-status-completeness',q['missingNativeInputs'])
        self.assertFalse(q['statusProbe']['directContainerDiagnostic']['ok'])
    def test_corrupt_present_proof_refuses_before_engine(self):
        i=self.intake();add_synthetic(i,i.before);i.before['native']['validated_status_inventory']['result']['scanned']-=1
        with patch.object(r.subprocess,'run',side_effect=AssertionError('no engine')),self.assertRaises(r.Refusal):r.request(i,i.before,i.profile)
    def test_real_api_after_proof_isolation_and_retained_history_unchanged(self):
        original_verify=r.Intake.verify;original_load=r.Intake.load;original_profile=r.load_profile
        def profile(path):
            p=original_profile(path);p['controlled']['acceptValidatedOwnershipInventory']=True;p['controlled']['acceptStaleStatusProbe']=False;return p
        def verify(i):
            result=original_verify(i);add_synthetic(i,i.before);return i.before,result[1]
        reports=[]
        for inactive in (False,True):
            output=self.out/('after-inactive' if inactive else 'after-active')
            def load(i,path,expected=None):
                v=original_load(i,path,expected)
                if path==i.trial/'after.json':
                    self.assertTrue((output/'adapter.stdout.json').exists(),'AFTER inventory must only be consumed after actual API')
                    add_synthetic(i,v,after=True,inactive_target=inactive)
                return v
            with patch.object(r,'load_profile',profile),patch.object(r.Intake,'verify',verify),patch.object(r.Intake,'load',load),patch.object(r,'status_probe',side_effect=AssertionError('no fallback')):
                reports.append(r.run(TRIAL,PROFILE,output))
        self.assertEqual(reports[0]['operandSha256'],reports[1]['operandSha256'])
        for report in reports:
            self.assertEqual(report['mismatches'],[]);self.assertEqual(len(report['knownProjectionExclusions']),2)
            self.assertEqual(sum(x['matched'] for x in report['comparison'] if x['kind']!='coverage-exclusion'),27)
            self.assertTrue(report['fullSceneAdmissionBlocked'])
        self.assertFalse(reports[1]['postRawCheckpoints']['targetStatusEvidence']['rows'][0]['active'])
        self.assertEqual(reports[1]['postRawCheckpoints']['targetStatusEvidence']['source'],'native.validated_status_inventory')

if __name__=='__main__':unittest.main()
