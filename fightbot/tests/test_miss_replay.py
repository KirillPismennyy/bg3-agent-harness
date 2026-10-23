"""Offline retained native miss tests; set explicit private fixture/profile paths.
Fault cases mutate only decoded in-memory evidence; no game or source writes.
"""
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
TRIAL=Path(os.environ['BG3_MISS_TEST_TRIAL']) if os.environ.get('BG3_MISS_TEST_TRIAL') else None
PROFILE=Path(os.environ['BG3_MISS_TEST_PROFILE']) if os.environ.get('BG3_MISS_TEST_PROFILE') else None
ADAPTER=Path(os.environ['BG3_MISS_TEST_ADAPTER']) if os.environ.get('BG3_MISS_TEST_ADAPTER') else None
SHA=os.environ.get('BG3_MISS_TEST_SIMULATOR_SHA256')

@unittest.skipUnless(TRIAL and PROFILE,'Private native miss fixture/profile explicitly required')
class NativeMiss(unittest.TestCase):
    def intake(self):
        i=r.Intake(TRIAL,r.load_profile(PROFILE));i.verify();return i
    def event(self,i):
        p=next(p for p in i.verified if p.name=='001-SpellCastEvent.json');return p,json.loads(i.verified[p])
    def operands(self,i):return r.request(i,i.before,i.profile)[0]
    def test_native_miss_operand_tape_contains_no_fabricated_damage(self):
        i=self.intake();p=self.operands(i)
        self.assertFalse(i.expected_loaded);self.assertEqual(len(p['randomInputs']),1)
        self.assertEqual(p['randomInputs'][0]['value'],4);self.assertNotIn('Total',json.dumps(p['randomInputs']))
        self.assertEqual(i.join['route'],'executed-miss');self.assertEqual(i.join['storyActionId'],415)
        self.assertEqual(p['before']['units'][0]['rawMovement'],5.326401698635891)
        # Simultaneous unrelated global damage must remain unrelated.
        self.assertTrue(any(x.get('kind')=='BeforeDealDamage' for x in i.rows))
    def test_miss_event_faults_refuse_without_engine(self):
        changes=[('complete',False),('component_available',False),('hit_available',False),('numerical_roll_seen',False),('errors',['fault']),('at_ms',0)]
        for key,value in changes:
            with self.subTest(key=key):
                i=self.intake();p,e=self.event(i);e[key]=value;i.verified[p]=r.encoded(e)
                with patch.object(r.subprocess,'run',side_effect=AssertionError('no engine')),self.assertRaises(r.Refusal):self.operands(i)
    def test_miss_roll_source_flags_and_identity_faults(self):
        def mutate(e,path,value):
            node=e
            for k in path[:-1]:node=node[k]
            node[path[-1]]=value
        cases=[(['Hit','SpellCastGuid'],'wrong'),(['Hit','StoryActionId'],416),(['Hit','EffectFlags'],{'text':'DamageFlags(Hit)'}),(['Hit','TotalDamageDone'],1),(['Hit','TotalDamageDone'],False),(['Hit','DamageType'],{'text':'Fire'}),(['CastCache','SpellCastingAbility'],{'text':'Wisdom'}),(['target','uuid'],'wrong'),(['Hit','ConditionRolls','truncated'],True),(['Hit','ConditionRolls','values',0,'Roll','Metadata','FixedRollBonuses','truncated'],True),(['Hit','ConditionRolls','values',0,'Roll','Result','NaturalRoll'],True),(['Hit','ConditionRolls','values',0,'Roll','Roll','RerollConditions','values'],[1]),(['Hit','ConditionRolls','values',0,'SwappedSourceAndTarget'],True)]
        for path,value in cases:
            with self.subTest(path=path):
                i=self.intake();p,e=self.event(i);mutate(e,path,value);i.verified[p]=r.encoded(e)
                with self.assertRaises(r.Refusal):self.operands(i)
    def test_lifecycle_all_identity_story_and_completeness_conflicts_refuse(self):
        changes=[
            lambda d:d.update(entity='Entity (0200000b00000000)'),
            lambda d:d['reads'][0]['components']['SpellCastState'].update(Entity='Entity (0200000b00000000)'),
            lambda d:[x['components']['SpellCastState'].update(Caster='Entity (0200000a00000000)') for x in d['reads']],
            lambda d:[x['components']['SpellCastState'].update(Targets=[{'Target':'Entity (0200000800000000)','TargetingType':'Projectile'}]) for x in d['reads']],
            lambda d:d['reads'][-2]['components']['ServerSpellCastState'].update(StoryActionId=416),
            lambda d:d['reads'][0]['components']['SpellCastState'].update(available=False),
            lambda d:d['reads'][0]['components']['SpellCastState'].update(truncated=True),
            lambda d:d['reads'][0]['components']['SpellCastState'].update(SpellCastGuid='wrong'),
            lambda d:d['reads'][-2]['components']['SpellCastState']['SpellId'].update(SourceType='Osiris'),
            lambda d:d['reads'][0]['components']['SpellCastState']['SpellId'].update(ProgressionSource='wrong'),
        ]
        for n,change in enumerate(changes):
            i=self.intake();p=next(p for p in i.verified if p.parent.name=='0');d=json.loads(i.verified[p]);change(d);i.verified[p]=r.encoded(d)
            with self.subTest(case=n),self.assertRaises(r.Refusal):self.operands(i)
        # Native story0/Osiris -> requested racial source transition stays accepted.
        self.operands(self.intake())
    def test_ordered_lifecycle_cannot_regress_execution_story_or_source(self):
        for variant in ['both','story-only','source-only','source-before-execution','phase-only']:
            i=self.intake();p=next(p for p in i.verified if p.parent.name=='0');d=json.loads(i.verified[p])
            initial=d['reads'][0]['components'];last=d['reads'][-1]['components']
            if variant in ['both','story-only']:last['ServerSpellCastState']['StoryActionId']=0
            if variant in ['both','source-only']:
                last['SpellCastState']['SpellId']=copy.deepcopy(initial['SpellCastState']['SpellId'])
                last['SpellCastCache']['SpellCastingAbility']=initial['SpellCastCache']['SpellCastingAbility']
            if variant=='source-before-execution':
                middle=d['reads'][2]['components'];middle['SpellCastState']['SpellId']=copy.deepcopy(initial['SpellCastState']['SpellId']);middle['SpellCastCache']['SpellCastingAbility']=initial['SpellCastCache']['SpellCastingAbility']
            if variant=='phase-only':last['ServerSpellCastState']['Phase']='MovementSteering'
            i.verified[p]=r.encoded(d)
            with self.subTest(variant=variant),self.assertRaises(r.Refusal):self.operands(i)
        self.operands(self.intake())
    def test_synthetic_additive_metadata_does_not_change_operands(self):
        i=self.intake();baseline=self.operands(i)
        for value in [2,-2,2147483647,-2147483648]:
            modified=self.intake();p,event=self.event(modified)
            event['Hit']['ConditionRolls']['values'][0]['Roll']['Roll']['Roll']['DiceAdditionalValue']=value
            # Native totals/difficulty are not used as compiler operands either.
            event['Hit']['ConditionRolls']['values'][0]['Difficulty']=99
            event['Hit']['ConditionRolls']['values'][0]['Roll']['Result']['Total']=-100
            modified.verified[p]=r.encoded(event)
            with self.subTest(additive=value):
                self.assertEqual(self.operands(modified),baseline);self.assertFalse(modified.expected_loaded)
        for value in [True,2.0,float('nan'),'2',2147483648,-2147483649]:
            modified=self.intake();p,event=self.event(modified)
            event['Hit']['ConditionRolls']['values'][0]['Roll']['Roll']['Roll']['DiceAdditionalValue']=value
            modified.verified[p]=json.dumps(event).encode()
            with self.subTest(invalid=value),self.assertRaises(r.Refusal):self.operands(modified)
    def test_duplicate_same_guid_probe_refuses(self):
        i=self.intake();p,e=self.event(i);i.verified[p.with_name('duplicate.json')]=r.encoded(e)
        with self.assertRaises(r.Refusal):self.operands(i)
    def test_guid_bound_damage_conflict_refuses(self):
        i=self.intake();i.rows.append({'kind':'BeforeDealDamage','data':{'hit':{'SpellCastGuid':i.report['evidence']['requested_cast_guid']}}})
        with self.assertRaises(r.Refusal):self.operands(i)
    def test_raw_execution_and_lifecycle_witness_required(self):
        for kind in ['UsingSpellOnTarget','CastedSpell','lifecycle']:
            with self.subTest(kind=kind):
                i=self.intake()
                if kind=='lifecycle':i.verified={p:d for p,d in i.verified.items() if p.parent.name!='0'}
                else:i.rows=[x for x in i.rows if x.get('kind')!=kind]
                with self.assertRaises(r.Refusal):self.operands(i)
    @unittest.skipUnless(ADAPTER and SHA,'Explicit pinned runtime required')
    def test_actual_pinned_api_and_post_oracle_faults(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'native';report=r.run(TRIAL,PROFILE,out,adapter_path=ADAPTER,simulator_sha256=SHA)
            self.assertEqual(report['mismatches'],[]);self.assertEqual(len(report['knownProjectionExclusions']),2)
            self.assertEqual(len(report['comparison']),29)
            actual=json.loads((out/'adapter.stdout.json').read_text());i=self.intake();payload=self.operands(i)
            original=i.load
            for key,value in [('no_damage',False),('damage',[]),('total_damage',0)]:
                def load(path,expected=None):
                    d=original(path,expected)
                    if path==i.trial/'action.json':d['result'][key]=value
                    return d
                with self.subTest(key=key),patch.object(i,'load',side_effect=load),self.assertRaises(r.Refusal):r.compare(i,payload,actual,i.profile)
            def changed_hp(path,expected=None):
                d=original(path,expected)
                if path==i.trial/'after.json':d['native']['target']['hp']-=1
                return d
            with patch.object(i,'load',side_effect=changed_hp),self.assertRaises(r.Refusal):r.compare(i,payload,actual,i.profile)
            def changed_movement(path,expected=None):
                d=original(path,expected)
                if path==i.trial/'after.json':
                    actor=next(x for x in d['party'] if x['uuid']==payload['before']['activeActorId'])
                    actor['resources']['MovementObservation']['raw']['current']=5.31
                    actor['resources']['MovementObservation']['usable_projection']['current']=5.31
                return d
            with patch.object(i,'load',side_effect=changed_movement),self.assertRaises(r.Refusal):r.compare(i,payload,actual,i.profile)

class MovementProjection(unittest.TestCase):
    def resources(self):
        return {'Movement':[5.3,9.0],'MovementObservation':{'raw':{'available':True,'current':5.326401698635891,'max':9.0,'precision':'unrounded'},'usable_projection':{'available':True,'current':5.326401698635891,'max':9.0,'mask_applied':False}}}
    def test_exact_and_masked_projection(self):
        d=self.resources();self.assertEqual(r.usable_movement(d)[0],5.326401698635891)
        d['Movement']=[0,9];d['MovementObservation']['usable_projection'].update(current=0,mask_applied=True);self.assertEqual(r.usable_movement(d)[0],0)
        self.assertEqual(r.usable_movement({'Movement':[0,9]})[0],0)
    def test_lua_producer_midpoint_rounding_current_and_maximum(self):
        for exact,rounded in [(5.25,5.3),(5.35,5.4)]:
            d=self.resources();d['Movement']=[rounded,rounded]
            for facet in ['raw','usable_projection']:d['MovementObservation'][facet].update(current=exact,max=exact)
            with self.subTest(exact=exact):self.assertEqual(r.usable_movement(d)[0],exact)
    def test_present_invalid_projection_never_falls_back(self):
        for facet in [None,{}, {'raw':{'available':False}}, {'error':'unavailable'}]:
            with self.subTest(facet=facet),self.assertRaises(r.Refusal):r.usable_movement({'Movement':[5.3,9],'MovementObservation':facet})
        for path,value in [(('raw','current'),float('nan')),(('usable_projection','current'),True),(('usable_projection','current'),5.2),(('usable_projection','mask_applied'),True)]:
            d=self.resources();d['MovementObservation'][path[0]][path[1]]=value
            with self.subTest(path=path),self.assertRaises(r.Refusal):r.usable_movement(d)

if __name__=='__main__':unittest.main()
