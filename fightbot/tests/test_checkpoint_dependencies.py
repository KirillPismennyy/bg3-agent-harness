"""Field-driven checkpoint admission; private native files are immutable inputs."""
import copy,json,os,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import replay_trial as r
FIXTURE_ENV={
 'hit_trial':'BG3_CHECKPOINT_TEST_HIT_TRIAL',
 'hit_profile':'BG3_CHECKPOINT_TEST_HIT_PROFILE',
 'miss_trial':'BG3_CHECKPOINT_TEST_MISS_TRIAL',
 'miss_profile':'BG3_CHECKPOINT_TEST_MISS_PROFILE',
}
CONFIGURED=any(name in os.environ for name in FIXTURE_ENV.values())
TRIALS={role:Path(os.environ[FIXTURE_ENV[role+'_trial']]) for role in ['hit','miss'] if os.environ.get(FIXTURE_ENV[role+'_trial'])}
PROFILES={role:Path(os.environ[FIXTURE_ENV[role+'_profile']]) for role in ['hit','miss'] if os.environ.get(FIXTURE_ENV[role+'_profile'])}
ADAPTER=Path(os.environ['BG3_REPLAY_TEST_V206_ADAPTER']) if os.environ.get('BG3_REPLAY_TEST_V206_ADAPTER') else None
SHA='c7e3e92494402b4a86f705cf6525d8cf53c4e77384db1027d741d5b47adcf054'
@unittest.skipUnless(CONFIGURED,'Set all four BG3_CHECKPOINT_TEST_HIT_TRIAL/HIT_PROFILE/MISS_TRIAL/MISS_PROFILE paths for native dependency controls')
class CheckpointDependencies(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  missing=[name for name in FIXTURE_ENV.values() if not os.environ.get(name)]
  if missing:raise AssertionError('Incomplete explicit checkpoint fixture configuration: '+', '.join(missing))
  for role in ['hit','miss']:
   if not TRIALS[role].is_dir():raise AssertionError('Configured checkpoint trial is not a directory: '+str(TRIALS[role]))
   if not PROFILES[role].is_file():raise AssertionError('Configured checkpoint profile is not a file: '+str(PROFILES[role]))
 def intake(self,name='miss'):
  i=r.Intake(TRIALS[name],r.load_profile(PROFILES[name]));i.verify();return i
 def snapshot(self,i,phase):return copy.deepcopy(i.before) if phase=='before' else i.load(i.trial/'after.json')
 def allow(self,i):
  i.profile['controlled']['acceptDeferredCheckpoint']=True
  i.profile['timingLimits'].update(maxPreCheckpointAgeMs=1000000,maxPostCheckpointAgeMs=1000000)
 def test_exact_per_role_phase_never_resolves_or_invents_checkpoint(self):
  for name in TRIALS:
   i=self.intake(name)
   with patch.object(i,'resolve_checkpoint',side_effect=AssertionError('No native checkpoint dependency')):
    for phase in ['before','after']:
     s=self.snapshot(i,phase)
     for role in ['actor','target']:
      cp,receipt=r.checkpoint_inputs(i,s,role,phase,i.profile)
      self.assertEqual(cp,{});self.assertTrue(receipt['noCheckpointConsumed']);self.assertEqual(receipt['consumedFields'],[])
      self.assertNotIn('ageMs',receipt);self.assertNotIn('atomic',receipt);self.assertEqual(receipt['snapshotEvidence']['sha256'],i.report['files'][phase]['sha256'])
    payload,q=r.request(i,i.before,i.profile);self.assertFalse(i.expected_loaded)
    self.assertTrue(q['rawCheckpoint']['noCheckpointConsumed']);self.assertTrue(q['targetRawCheckpoint']['noCheckpointConsumed'])
 def test_native_status_evidence_reference_uses_snapshot_not_checkpoint(self):
  i=self.intake();p,q=r.request(i,i.before,i.profile)
  # Empty native actor here: directly require its full proof receipt to reference snapshot.
  self.assertIn('snapshotEvidence',q['rawCheckpoint']);self.assertNotIn('evidence',q['rawCheckpoint'])
 def test_complete_owned_status_reference_does_not_borrow_resource_checkpoint(self):
  from test_ownership_intake import add_synthetic
  trial=os.environ.get('BG3_REPLAY_TEST_TRIAL');profile=os.environ.get('BG3_REPLAY_TEST_PROFILE')
  if not trial or not profile:self.skipTest('Explicit historical fixture required')
  i=r.Intake(Path(trial),r.load_profile(Path(profile)));i.verify()
  add_synthetic(i,i.before);i.profile['controlled']['acceptValidatedOwnershipInventory']=True
  payload,q=r.request(i,i.before,i.profile)
  self.assertEqual(q['rawCheckpoint']['consumedFields'],['resources'])
  statuses=payload['before']['units'][0]['statuses'];self.assertTrue(statuses)
  for status in statuses:
   self.assertEqual(json.loads(status['evidenceReference'].split('; status evidence ',1)[0])['path'],str(i.trial/'before.json'))
   self.assertNotIn('; checkpoint ',status['evidenceReference'])
 def test_absent_resources_require_only_selected_role_phase_and_enforce_optin(self):
  for phase in ['before','after']:
   for role in ['actor','target']:
    with self.subTest(phase=phase,role=role):
     i=self.intake();s=self.snapshot(i,phase);del s['native'][role]['raw_resource_entries']
     original=i.resolve_checkpoint
     with patch.object(i,'resolve_checkpoint',wraps=original) as resolver,self.assertRaisesRegex(r.Refusal,'Stale checkpoint'):r.checkpoint_inputs(i,s,role,phase,i.profile)
     self.assertEqual(resolver.call_args.args[0],s['native'][role]['uuid'])
     self.allow(i)
     with patch.object(i,'resolve_checkpoint',wraps=original) as resolver:
      cp,receipt=r.checkpoint_inputs(i,s,role,phase,i.profile)
      other='target' if role=='actor' else 'actor';r.checkpoint_inputs(i,s,other,phase,i.profile)
     self.assertEqual(resolver.call_count,1);self.assertEqual(receipt['consumedFields'],['resources']);self.assertFalse(receipt['noCheckpointConsumed'])
     self.assertEqual(r.resource_rows(s['native'][role],cp)[1],'deferred-checkpoint')
 def test_consumed_checkpoint_age_is_not_bypassed_by_other_exact_fields(self):
  for phase in ['before','after']:
   for role in ['actor','target']:
    i=self.intake();s=self.snapshot(i,phase);del s['native'][role]['raw_resource_entries'];i.profile['controlled']['acceptDeferredCheckpoint']=True
    with self.subTest(phase=phase,role=role),self.assertRaisesRegex(r.Refusal,'staleness bound'):r.checkpoint_inputs(i,s,role,phase,i.profile)
 def test_mixed_before_resource_field_age_zero_still_refuses_consumed_legacy(self):
  for role in ['actor','target']:
   i=self.intake();del i.before['native'][role]['raw_resource_entries'];self.allow(i)
   with self.subTest(role=role),self.assertRaisesRegex(r.Refusal,'consumed resource field source'):r.request(i,i.before,i.profile)
 def test_actor_status_fallback_only_actor_requires_checkpoint(self):
  for phase in ['before','after']:
   i=self.intake();s=self.snapshot(i,phase);del s['native']['validated_status_inventory'];del s['native']['actor']['status_container_entries'];self.allow(i)
   original=i.resolve_checkpoint
   with patch.object(i,'resolve_checkpoint',wraps=original) as resolver:
    _,actor=r.checkpoint_inputs(i,s,'actor',phase,i.profile);_,target=r.checkpoint_inputs(i,s,'target',phase,i.profile)
   self.assertEqual(resolver.call_count,1);self.assertEqual(actor['consumedFields'],['statuses']);self.assertTrue(target['noCheckpointConsumed'])
 def test_actor_direct_status_crosscheck_still_requires_checkpoint(self):
  i=self.intake();s=self.snapshot(i,'before');del s['native']['validated_status_inventory'];a=s['native']['actor']
  a['status_container_entries']={'ok':True,'result':{'rows':[],'count':0,'owner_uuid':a['uuid'],'owner_handle':'123','begin_ms':s['started_ms'],'end_ms':s['finished_ms'],'source':'StatusContainer.Statuses + ServerStatus + ServerStatusOwnership.Owner','coverage':'present-container-entries-only','global_scan_performed':False,'absence_proven':False,'lifecycle_semantics_qualified':False}}
  self.allow(i)
  with patch.object(i,'resolve_checkpoint',wraps=i.resolve_checkpoint) as resolver:
   cp,receipt=r.checkpoint_inputs(i,s,'actor','before',i.profile)
  self.assertEqual(resolver.call_count,1);self.assertEqual(receipt['consumedFields'],['statuses'])
  i.profile['controlled']['acceptContainerListedStatusProjection']=True
  cp['statuses']=[{'id':'SYNTHETIC_WRONG','instance':'123'}]
  with self.assertRaisesRegex(r.Refusal,'identity mismatch'):r.status_evidence(i,s,'actor',cp,'before',i.profile)
 def test_present_failed_facets_never_choose_historical_fallback(self):
  for phase in ['before','after']:
   for role in ['actor','target']:
    for facet in [None,{}, {'ok':False,'error':'fault'}]:
     i=self.intake();s=self.snapshot(i,phase);s['native'][role]['raw_resource_entries']=facet
     with self.subTest(phase=phase,role=role,facet=facet),patch.object(i,'resolve_checkpoint',side_effect=AssertionError('no fallback')),self.assertRaises(r.Refusal):r.checkpoint_inputs(i,s,role,phase,i.profile)
    i=self.intake();s=self.snapshot(i,phase);s['native']['validated_status_inventory']=None
    with patch.object(i,'resolve_checkpoint',side_effect=AssertionError('no fallback')),self.assertRaises(r.Refusal):r.checkpoint_inputs(i,s,role,phase,i.profile)
 def test_post_consumed_checkpoint_must_be_after_action(self):
  i=self.intake();s=self.snapshot(i,'after');del s['native']['target']['raw_resource_entries'];self.allow(i)
  cp,receipt=i.resolve_checkpoint(s['native']['target']['uuid'],s['finished_ms']);receipt['t']=i.before['finished_ms']-1
  with patch.object(i,'resolve_checkpoint',return_value=(cp,receipt)),self.assertRaisesRegex(r.Refusal,'No post-action'):r.checkpoint_inputs(i,s,'target','after',i.profile)
 def test_exact_callbacks_strict_mode_still_refuses_real_gaps(self):
  i=self.intake();i.profile=None
  with patch.object(i,'resolve_checkpoint',side_effect=AssertionError('no checkpoint')),patch.object(r.subprocess,'run',side_effect=AssertionError('no engine')):
   payload,q=r.request(i,i.before,None)
  self.assertIsNone(payload);self.assertFalse(q['engineInvoked']);self.assertIn('full-build-and-reaction-state',q['missingInputs'])
 @unittest.skipUnless(ADAPTER,'Explicit pinned adapter required')
 def test_actual_hit_miss_api_with_zero_cp_limits_false_optin_and_poisoned_resolver(self):
  with tempfile.TemporaryDirectory() as tmp:
   for name,trial in TRIALS.items():
    with self.subTest(name=name),patch.object(r.Intake,'resolve_checkpoint',side_effect=AssertionError('No checkpoint allowed')):
     report=r.run(trial,PROFILES[name],Path(tmp)/name,adapter_path=ADAPTER,simulator_sha256=SHA)
    self.assertEqual(report['mismatches'],[]);self.assertTrue(report['expectedOutcomesLoadedAfterEngine'])
    # Each AFTER role independently regains legacy resource-age gates if its
    # exact facet is absent; the other role remains fully native.
    for role in ['actor','target']:
     i=self.intake(name);self.allow(i);payload,_=r.request(i,i.before,i.profile)
     actual=json.loads((Path(tmp)/name/'adapter.stdout.json').read_text());original=i.load
     def mixed_load(path,expected=None):
      d=original(path,expected)
      if path==i.trial/'after.json':del d['native'][role]['raw_resource_entries']
      return d
     with self.subTest(name=name,afterRole=role),patch.object(i,'load',side_effect=mixed_load),self.assertRaisesRegex(r.Refusal,'consumed resource field source'):r.compare(i,payload,actual,i.profile)
    for phase in [report['qualification'],report['postRawCheckpoints']]:
     keys=['rawCheckpoint','targetRawCheckpoint'] if 'rawCheckpoint' in phase else ['actor','target']
     for key in keys:self.assertTrue(phase[key]['noCheckpointConsumed'])
if __name__=='__main__':unittest.main()
