"""Offline synthetic facet tests. No new native status observation is claimed."""
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

def snapshot():
    return {'started_ms':100,'finished_ms':200,'native':{'actor':{'uuid':'actor'}}}

def facet(rows=None,owner='9007199254740993',uuid='actor',begin=110,end=190):
    if rows is None:rows=[{'id':'TEST','instance':'9007199254740995','owner_handle':owner,'type':'BOOST','active':True,'lifetime':{'ok':True,'result':{'component_present':True,'raw_value':-1,'units':'unqualified'}}}]
    return {'ok':True,'result':{'rows':rows,'count':len(rows),'owner_uuid':uuid,'owner_handle':owner,'begin_ms':begin,'end_ms':end,'source':'StatusContainer.Statuses + ServerStatus + ServerStatusOwnership.Owner','coverage':'present-container-entries-only','global_scan_performed':False,'absence_proven':False,'lifecycle_semantics_qualified':False}}

class StatusFacetUnit(unittest.TestCase):
    def read(self,value):
        s=snapshot();s['native']['actor']['status_container_entries']=value
        return r.fresh_status_entries(s,'actor')
    def test_absent_only_returns_none(self):
        self.assertIsNone(r.fresh_status_entries(snapshot(),'actor'))
        for v in (None,False,{}, {'ok':False,'error':'missing container'}, {'ok':True,'result':None}):
            with self.subTest(value=v),self.assertRaises(r.Refusal):self.read(v)
    def test_exact_handles_false_and_raw_lifetime_preserved(self):
        v=facet();v['result']['rows'][0]['active']=False
        rows,receipt=self.read(v)
        self.assertEqual(rows[0]['instance'],'9007199254740995')
        self.assertEqual(rows[0]['owner_handle'],'9007199254740993')
        self.assertIs(rows[0]['active'],False)
        self.assertEqual(rows[0]['lifetime']['result']['raw_value'],-1)
        self.assertFalse(receipt['absenceProven'])
        self.assertEqual(receipt['globalOwnershipCompleteness'],'unproven')
    def test_malformed_decimal_handles_rejected(self):
        for h in (9007199254740993,9007199254740993.0,'+12','01','0','1.0','NaN',str(1<<63)):
            with self.subTest(handle=h),self.assertRaises(r.Refusal):r.decimal_handle(h)
        self.assertEqual(r.decimal_handle('-9223372036854775808'),'-9223372036854775808')
    def test_shape_count_and_coverage_refuse(self):
        for key,value in (('rows',{}),('count',True),('count',0),('owner_uuid','wrong'),('global_scan_performed',True),('absence_proven',True),('lifecycle_semantics_qualified',True),('coverage','all-statuses')):
            v=facet();v['result'][key]=value
            with self.subTest(key=key),self.assertRaises(r.Refusal):self.read(v)
        v=facet([]);v['result']['rows']={}
        with self.assertRaises(r.Refusal):self.read(v)
        self.assertEqual(self.read(facet([]))[0],[])
    def test_timing_inside_outer_callback(self):
        for begin,end in ((99,150),(150,201),(180,170),(True,180),(110,None)):
            with self.subTest(begin=begin,end=end),self.assertRaises(r.Refusal):self.read(facet(begin=begin,end=end))
    def test_row_ownership_identity_and_active_validated(self):
        for key,value in (('owner_handle','9007199254740994'),('id',''),('type',''),('active',1),('instance',None)):
            v=facet();v['result']['rows'][0][key]=value
            with self.subTest(key=key),self.assertRaises(r.Refusal):self.read(v)
        v=facet();v['result']['rows']*=2;v['result']['count']=2
        with self.assertRaisesRegex(r.Refusal,'Duplicate'):self.read(v)
    def test_duplicate_ids_distinct_instances_are_preserved(self):
        v=facet();second=copy.deepcopy(v['result']['rows'][0]);second['instance']='9007199254740996';v['result']['rows'].append(second);v['result']['count']=2
        self.assertEqual(len(self.read(v)[0]),2)
    def test_optional_lifetime_failure_is_not_status_failure(self):
        v=facet();v['result']['rows'][0]['lifetime']={'ok':False,'error':'unknown'}
        self.assertEqual(len(self.read(v)[0]),1)
        for bad in (float('inf'),float('nan')):
            v=facet();v['result']['rows'][0]['lifetime']['result']['raw_value']=bad
            with self.assertRaises(r.Refusal):self.read(v)

@unittest.skipUnless(TRIAL and PROFILE,'Private integration fixtures explicitly required')
class SyntheticFacetIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.out=Path(self.tmp.name)
    def intake(self):
        i=r.Intake(TRIAL,r.load_profile(PROFILE));i.verify();i.profile['controlled']['acceptContainerListedStatusProjection']=True
        return i
    def add_facets(self,i,snapshot):
        for n,role in enumerate(('actor','target')):
            cp,_=i.resolve_checkpoint(snapshot['native'][role]['uuid'],snapshot['finished_ms'] if snapshot is not i.before else snapshot['started_ms'])
            owner=str(9007199254740993+n)
            rows=[{'id':x['id'],'instance':str(x['instance']),'owner_handle':owner,'type':'TEST_SYNTHETIC','active':True} for x in cp['statuses']]
            snapshot['native'][role]['status_container_entries']=facet(rows,owner,snapshot['native'][role]['uuid'],snapshot['started_ms'],snapshot['finished_ms'])
    def test_fresh_before_prevents_probe_reads_and_uses_target_inventory(self):
        i=self.intake();self.add_facets(i,i.before)
        i.before['native']['target']['status_container_entries']['result']['rows'][0]['active']=False
        with patch.object(r,'status_probe',side_effect=AssertionError('unused supplement must not be read')):
            payload,q=r.request(i,i.before,i.profile)
        self.assertEqual(len(payload['before']['units'][0]['statuses']),4)
        self.assertFalse(q['nativeTargetStatusesRetainedButUnmodeled'][0]['active'])
        self.assertEqual(q['targetStatusEvidence']['globalOwnershipCompleteness'],'unproven')
    def test_fresh_target_inventory_overrides_legacy_projection_ids(self):
        i=self.intake();self.add_facets(i,i.before)
        target=i.before['native']['target']['uuid']
        next(x for x in i.before['turn_order'] if x['uuid']==target)['statuses']=[{'id':'STALE_UNRELATED'}]
        i.profile['controlled']['acceptStaleStatusProbe']=False
        with patch.object(r,'status_probe',side_effect=AssertionError('unused supplement')):
            _,q=r.request(i,i.before,i.profile)
        self.assertEqual(sorted(x['id'] for x in q['nativeTargetStatusesRetainedButUnmodeled']),i.profile['controlled']['excludedTargetStatusMechanics'])
    def test_missing_opt_in_refuses_no_probe_fallback(self):
        i=self.intake();self.add_facets(i,i.before);del i.profile['controlled']['acceptContainerListedStatusProjection']
        with patch.object(r,'status_probe',side_effect=AssertionError('no fallback')),self.assertRaisesRegex(r.Refusal,'explicit conditional'):r.request(i,i.before,i.profile)
    def test_failed_target_facet_refuses_before_api(self):
        i=self.intake();self.add_facets(i,i.before);i.before['native']['target']['status_container_entries']=None
        with patch.object(r.subprocess,'run',side_effect=AssertionError('must not execute')),self.assertRaises(r.Refusal):r.request(i,i.before,i.profile)
    def test_inactive_actor_or_changed_identity_refuses(self):
        for key,value in (('active',False),('id','OTHER')):
            i=self.intake();self.add_facets(i,i.before);i.before['native']['actor']['status_container_entries']['result']['rows'][0][key]=value
            with self.subTest(key=key),self.assertRaises(r.Refusal):r.request(i,i.before,i.profile)
    def test_mixed_phase_after_fallback_requires_its_own_opt_in_after_actual_api(self):
        original_verify=r.Intake.verify;original_profile=r.load_profile
        for allow in (False,True):
            output=self.out/('mixed-allowed' if allow else 'mixed-refused')
            def profile(path):
                p=original_profile(path);p['controlled']['acceptContainerListedStatusProjection']=True
                p['controlled']['acceptStaleStatusProbe']=allow
                p['statusBefore']['path']='unused-before-probe'
                return p
            def verify(i):
                result=original_verify(i);self.add_facets(i,i.before)
                return i.before,result[1]
            with self.subTest(allow=allow),patch.object(r,'load_profile',profile),patch.object(r.Intake,'verify',verify):
                if allow:
                    report=r.run(TRIAL,PROFILE,output)
                    self.assertEqual(report['mismatches'],[])
                    self.assertEqual(len(report['knownProjectionExclusions']),2)
                else:
                    with self.assertRaisesRegex(r.Refusal,'Legacy after actor status evidence requires explicit'):
                        r.run(TRIAL,PROFILE,output)
                    self.assertTrue((output/'adapter.stdout.json').is_file())
                    receipt=json.loads((output/'adapter.stdout.json').read_text())
                    self.assertEqual(receipt['api'],'BattleEngine.ExecuteObservedAction')
                    self.assertFalse((output/'report.json').exists())
    def test_synthetic_fresh_facets_actual_api_and_postoracle_isolation(self):
        # In-memory injection is deliberately synthetic, never a rewritten capture.
        original_verify=r.Intake.verify;original_load=r.Intake.load;original_profile=r.load_profile
        current={}
        def profile(path):
            p=original_profile(path);p['controlled']['acceptContainerListedStatusProjection']=True
            p['controlled']['acceptStaleStatusProbe']=False
            p['statusBefore']['path']='unused-probe-before';p['statusAfter']['path']='unused-probe-after'
            return p
        def verify(i):
            result=original_verify(i);self.add_facets(i,i.before);current['i']=i
            return i.before,result[1]
        def load(i,path,expected=None):
            value=original_load(i,path,expected)
            if path==i.trial/'after.json':
                self.assertTrue((output/'adapter.stdout.json').exists(),'AFTER facets must be read after API')
                self.add_facets(i,value)
                row=value['native']['target']['status_container_entries']['result']['rows'][0]
                row['active']=not mutate_after
                row['lifetime']={'ok':True,'result':{'component_present':True,'raw_value':123.5,'units':'unqualified'}}
            return value
        reports=[]
        for mutate_after in (False,True):
            output=self.out/('actual-inactive-after' if mutate_after else 'actual-active-after')
            with patch.object(r,'load_profile',profile),patch.object(r.Intake,'verify',verify),patch.object(r.Intake,'load',load),patch.object(r,'status_probe',side_effect=AssertionError('no unused external probes')):
                reports.append(r.run(TRIAL,PROFILE,output))
        self.assertEqual(reports[0]['operandSha256'],reports[1]['operandSha256'])
        report=reports[1]
        self.assertEqual(report['api'],'BattleEngine.ExecuteObservedAction');self.assertEqual(report['mismatches'],[])
        self.assertEqual(len(report['knownProjectionExclusions']),2)
        self.assertEqual(sum(x['matched'] for x in report['comparison'] if x['kind']!='coverage-exclusion'),27)
        self.assertTrue(report['fullSceneAdmissionBlocked'])
        self.assertEqual(report['postRawCheckpoints']['targetStatusEvidence']['source'],'native.target.status_container_entries')
        retained=report['postRawCheckpoints']['targetStatusEvidence']['rows'][0]
        self.assertIs(retained['active'],False)
        self.assertIsInstance(retained['instance'],str)
        self.assertEqual(retained['lifetime']['result']['raw_value'],123.5)
        self.assertEqual(retained['lifetime']['result']['units'],'unqualified')

if __name__=='__main__':unittest.main()
