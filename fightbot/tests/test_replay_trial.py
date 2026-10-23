import copy
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import replay_trial as replay

HERE=Path(__file__).resolve().parent
TRIAL=Path(os.environ["BG3_REPLAY_TEST_TRIAL"]) if os.environ.get("BG3_REPLAY_TEST_TRIAL") else None
PROFILE=Path(os.environ["BG3_REPLAY_TEST_PROFILE"]) if os.environ.get("BG3_REPLAY_TEST_PROFILE") else None

@unittest.skipUnless(TRIAL is not None and PROFILE is not None,"Private integration fixtures not configured: set BG3_REPLAY_TEST_TRIAL and BG3_REPLAY_TEST_PROFILE explicitly")
class ReplayChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
    def intake(self):
        intake=replay.Intake(TRIAL,replay.load_profile(PROFILE));intake.verify();return intake
    def test_actual_api_command_and_honest_projection_exclusions(self):
        output=self.root/"actual"
        report=replay.run(TRIAL,PROFILE,output)
        self.assertTrue(report["engineInvoked"])
        self.assertEqual(report["api"],"BattleEngine.ExecuteObservedAction")
        self.assertEqual(report["mismatches"],[])
        self.assertIsNone(report["earliestDivergence"])
        self.assertEqual(len(report["knownProjectionExclusions"]),2)
        self.assertTrue(report["fullSceneAdmissionBlocked"])
        self.assertEqual(report["qualification"]["rawCheckpoint"]["ageMs"],4367)
        self.assertEqual(report["qualification"]["actorResourceFieldSourceAgeMs"],162241)
        self.assertEqual(report["qualification"]["targetResourceFieldSourceAgeMs"],209207)
        fields={x["field"]:x for x in report["comparison"]}
        self.assertEqual(fields["attack.totalUsedForComparison"]["actual"],13)
        self.assertEqual(fields["attack.armorUsedForComparison"]["actual"],13)
        self.assertEqual(fields["attack.natural"]["actual"],11)
        payload=json.loads((output/"operands.json").read_text())
        self.assertNotIn("Total",json.dumps(payload["randomInputs"]))
        self.assertEqual([x["value"] for x in payload["randomInputs"]],[11,2])
        target=payload["before"]["units"][1]
        self.assertEqual((target["actions"],target["bonusActions"],target["reactionPoints"],target["rawMovement"]),(1,1,1,9))
    def test_strict_gaps_refuse_without_invoking_bridge(self):
        with patch.object(replay.subprocess,"run",side_effect=AssertionError("must not invoke")):
            result=replay.run(TRIAL,None,self.root/"strict")
        self.assertEqual(result["status"],"refused")
        self.assertFalse(result["engineInvoked"])
        self.assertIn("individual-disadvantage-face-pair",result["missingInputs"])
    def test_cli_scalar_mismatch_has_distinct_nonzero_exit(self):
        with patch.object(replay.sys,"argv",["replay_trial.py",str(TRIAL),"--output",str(self.root/"out")]),patch.object(replay,"run",return_value={"status":"scalar_mismatch","engineInvoked":True,"mismatches":[{"field":"target.hp"}]}),patch.object(replay.sys,"stdout",new_callable=io.StringIO) as captured:
            self.assertEqual(replay.main(),3)
            self.assertEqual(json.loads(captured.getvalue())["mismatchCount"],1)
    def test_frozen_hash_corruption_refuses(self):
        trial=self.root/"trial";shutil.copytree(TRIAL,trial)
        file=next((trial/"evidence/raw/probes/1").glob("*TargetHitEvent.json"))
        file.write_bytes(file.read_bytes()+b" ")
        with self.assertRaisesRegex(replay.Refusal,"SHA256 mismatch"):
            replay.Intake(trial,replay.load_profile(PROFILE)).verify()
    def test_conflicting_actor_identity_refuses(self):
        intake=self.intake();intake.before["native"]["actor"]["uuid"]="wrong-caster"
        with self.assertRaisesRegex(replay.Refusal,"unique BEFORE caster"):
            replay.request(intake,intake.before,intake.profile)
    def test_ambiguous_direct_cast_guid_refuses(self):
        intake=self.intake();path=next(p for p in intake.verified if p.name=="002-SpellCastTargetHitEvent.json")
        row=json.loads(intake.verified[path]);row["Hit"]["SpellCastGuid"]="11111111-1111-1111-1111-111111111111"
        intake.verified[path.with_name("999-ambiguous.json")]=replay.encoded(row)
        with self.assertRaisesRegex(replay.Refusal,"unique direct caster/target native hit"):
            replay.request(intake,intake.before,intake.profile)
    def test_profile_cannot_override_observed_or_oracle_fields(self):
        profile=json.loads(PROFILE.read_text());profile["controlled"]["actorHp"]=1
        path=self.root/"bad.json";path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(replay.Refusal,"Unexpected controlled field"):
            replay.load_profile(path)
        profile=json.loads(PROFILE.read_text());profile["expectedAfter"]={"hp":2};path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(replay.Refusal,"oracle field"):
            replay.load_profile(path)
    def test_stale_evidence_cannot_exceed_explicit_limit(self):
        intake=self.intake();intake.profile["timingLimits"]["maxPreCheckpointAgeMs"]=1
        with self.assertRaisesRegex(replay.Refusal,"staleness bound"):
            replay.request(intake,intake.before,intake.profile)
    def test_failed_exact_pool_facet_never_falls_back(self):
        with self.assertRaisesRegex(replay.Refusal,"no stale fallback"):
            replay.resource_rows({"raw_resource_entries":{"ok":False}},{"resources":[]})
        rows,precision=replay.resource_rows({"raw_resource_entries":{"ok":True,"result":{"count":1,"precision":"unrounded","rows":[{"resource_uuid":replay.MOVEMENT_ID,"entry_index":1,"level":0,"amount":5.5,"max_amount":9}]}}},{})
        self.assertEqual(rows[0]["amount"],5.5);self.assertEqual(precision,"callback-exact-unrounded")
    def test_post_oracle_loaded_after_api_and_cannot_change_operands(self):
        baseline=replay.run(TRIAL,PROFILE,self.root/"baseline")
        original=replay.Intake.load;mutated_output=self.root/"changed-oracle"
        def changed(intake,path,expected=None):
            value=original(intake,path,expected)
            if path==intake.trial/"after.json":
                self.assertTrue((mutated_output/"adapter.stdout.json").exists())
                value=copy.deepcopy(value);value["native"]["target"]["hp"]=15
            return value
        with patch.object(replay.Intake,"load",changed):
            result=replay.run(TRIAL,PROFILE,mutated_output)
        self.assertEqual(result["operandSha256"],baseline["operandSha256"])
        self.assertEqual(result["status"],"scalar_mismatch")
        self.assertEqual(result["earliestDivergence"]["field"],"target.hp")
        self.assertEqual(result["earliestDivergence"]["actual"],17)
    def test_source_bonus_not_manufactured_from_hit_totals(self):
        intake=self.intake();path=next(p for p in intake.verified if p.name=="002-SpellCastTargetHitEvent.json")
        row=json.loads(intake.verified[path]);roll=row["Hit"]["ConditionRolls"]["values"][0]["Roll"]
        roll["Result"]["Total"]=999;roll["Metadata"]["ProficiencyBonus"]=999;roll["Roll"]["Roll"]["DiceAdditionalValue"]=999
        intake.verified[path]=replay.encoded(row)
        payload,_=replay.request(intake,intake.before,intake.profile)
        self.assertEqual(payload["compilerContext"],{"level":2,"proficiencyBonus":2,"spellcastingModifier":0})
    def test_damage_producer_after_upper_boundary_refuses_report(self):
        original=replay.Intake.joined_random
        def future_damage(intake,caster,target):
            for row in intake.rows:
                if row.get("kind")=="BeforeDealDamage" and row.get("data",{}).get("hit",{}).get("SpellCastGuid")==intake.report["evidence"]["requested_cast_guid"]:
                    row["t"]+=100000
            return original(intake,caster,target)
        output=self.root/"future-damage"
        with patch.object(replay.Intake,"joined_random",future_damage),patch.object(replay.subprocess,"run",side_effect=AssertionError("out-of-window damage must refuse before engine admission")),self.assertRaisesRegex(replay.Refusal,"before engine admission"):
            replay.run(TRIAL,PROFILE,output)
        self.assertFalse((output/"report.json").exists())
    def test_raw_damage_prototype_conflict_refuses(self):
        intake=self.intake()
        row=replay.one([r for r in intake.rows if r.get("kind")=="BeforeDealDamage" and r.get("data",{}).get("hit",{}).get("SpellCastGuid")==intake.report["evidence"]["requested_cast_guid"]],"fixture damage producer")
        row["data"]["hit"]["SpellId"]="Projectile_AcidSplash"
        with self.assertRaisesRegex(replay.Refusal,"prototype mismatch"):
            replay.request(intake,intake.before,intake.profile)
    def test_missing_bridge_preflight_does_not_launch_dotnet(self):
        with patch.object(replay,"HERE",self.root),patch.object(replay.subprocess,"run",side_effect=AssertionError("missing bridge must refuse before process launch")),self.assertRaisesRegex(replay.Refusal,"bridge is missing"):
            replay.run(TRIAL,PROFILE,self.root/"missing-bridge-output")
    def test_old_resource_field_rejected_despite_recent_checkpoint(self):
        intake=self.intake();intake.profile["timingLimits"]["maxBeforeActorResourceFieldSourceAgeMs"]=5000
        with self.assertRaisesRegex(replay.Refusal,"consumed resource field source"):
            replay.request(intake,intake.before,intake.profile)
    def test_future_inherited_resource_base_refuses(self):
        intake=self.intake()
        intake.by_seq[534]["t"]=intake.before["started_ms"]+100000
        with self.assertRaisesRegex(replay.Refusal,"Checkpoint parent timestamp|Checkpoint record timestamp"):
            replay.request(intake,intake.before,intake.profile)
    def test_parent_child_timestamp_inversion_refuses(self):
        intake=self.intake();caster=intake.before["native"]["actor"]["uuid"]
        child=min((r for r in intake.rows if r.get("kind")=="checkpoint" and any(a.get("uuid")==caster and a.get("base_seq")==534 for a in r["data"].get("actors",[]))),key=lambda r:r["seq"])
        intake.by_seq[534]["t"]=child["t"]+1
        self.assertLess(intake.by_seq[534]["t"],intake.before["started_ms"])
        with self.assertRaisesRegex(replay.Refusal,"Checkpoint parent timestamp"):
            replay.request(intake,intake.before,intake.profile)
    def test_future_field_metadata_refuses(self):
        intake=self.intake();caster=intake.before["native"]["actor"]["uuid"]
        actor=next(a for a in intake.by_seq[534]["data"]["actors"] if a["uuid"]==caster)
        actor["st"]=intake.before["started_ms"]+1
        with self.assertRaisesRegex(replay.Refusal,"Checkpoint field metadata timestamp"):
            replay.request(intake,intake.before,intake.profile)
    def test_required_checkpoint_interval_cannot_be_omitted(self):
        for seq in (534,639):
            for key in ("begin_t","end_t"):
                with self.subTest(seq=seq,key=key):
                    intake=self.intake();del intake.by_seq[seq]["data"][key]
                    with self.assertRaisesRegex(replay.Refusal,"explicit valid begin_t/end_t"):
                        replay.request(intake,intake.before,intake.profile)
    def test_parent_cannot_complete_during_child_capture(self):
        intake=self.intake();child=intake.by_seq[639]
        child["data"]["end_t"]=child["t"]+2
        intake.by_seq[635]["data"]["end_t"]=child["t"]+1
        with self.assertRaisesRegex(replay.Refusal,"parent read completion exceeds child start"):
            replay.request(intake,intake.before,intake.profile)
    def test_actor_stamp_between_start_and_completion_is_accepted(self):
        intake=self.intake();child=intake.by_seq[639];caster=intake.before["native"]["actor"]["uuid"]
        child["data"]["end_t"]=child["t"]+2
        actor=next(a for a in child["data"]["actors"] if a["uuid"]==caster)
        actor["st"]=child["t"]+1
        payload,qualification=replay.request(intake,intake.before,intake.profile)
        self.assertEqual(payload["before"]["activeActorId"],caster)
        self.assertEqual(qualification["rawCheckpoint"]["latestSeq"],639)
    def test_negative_resource_source_age_rejects_all_four_consumers(self):
        output=self.root/"valid-age-baseline"
        replay.run(TRIAL,PROFILE,output)
        actual=json.loads((output/"adapter.stdout.json").read_bytes())
        for phase in ("before","after"):
            for role in ("actor","target"):
                with self.subTest(phase=phase,role=role):
                    intake=self.intake();payload,_=replay.request(intake,intake.before,intake.profile)
                    selected_uuid=intake.before["native"][role]["uuid"]
                    original=intake.resolve_checkpoint
                    def negative_age(uuid,boundary):
                        value,receipt=original(uuid,boundary)
                        if uuid==selected_uuid:receipt["fieldSources"]["resources"]["ageMs"]=-1
                        return value,receipt
                    with patch.object(intake,"resolve_checkpoint",negative_age),self.assertRaisesRegex(replay.Refusal,"source age must be nonnegative"):
                        if phase=="before":replay.request(intake,intake.before,intake.profile)
                        else:replay.compare(intake,payload,actual,intake.profile)
    def test_changed_source_damage_type_is_actual_mismatch(self):
        profile=json.loads(PROFILE.read_bytes())
        source=json.loads(Path(profile["rules"]["path"]).read_bytes())
        fields=copy.deepcopy(source["stats"]["Projectile_FireBolt"]["resolved"])
        original=fields["SpellSuccess"]
        fields["SpellSuccess"]=original.replace(",Fire,",",Cold,")
        self.assertNotEqual(fields["SpellSuccess"],original)
        changed_rules=self.root/"cold-rules.json"
        changed_rules.write_bytes(replay.encoded({"stats":{"Projectile_FireBolt":{"resolved":fields}}}))
        profile["rules"]={"path":str(changed_rules),"sha256":replay.sha(changed_rules.read_bytes())}
        changed_profile=self.root/"cold-profile.json";changed_profile.write_bytes(replay.encoded(profile))
        report=replay.run(TRIAL,changed_profile,self.root/"cold-result")
        mismatch=next(x for x in report["mismatches"] if x["field"]=="damage.byType")
        self.assertEqual(mismatch["expected"],{"Fire":2})
        self.assertEqual(mismatch["actual"],{"Cold":2})
        self.assertTrue(next(x for x in report["comparison"] if x["field"]=="damage.total")["matched"])
        self.assertEqual(report["status"],"scalar_mismatch")

class FixtureIndependentChecks(unittest.TestCase):
    def test_checkpoint_interval_requires_explicit_consistent_bounds(self):
        valid={"kind":"checkpoint","t":100,"data":{"begin_t":100,"end_t":102}}
        self.assertEqual(replay.checkpoint_interval(valid,200),(100,102))
        replay.checkpoint_field_metadata({"st":101},102)
        cases=[{"kind":"checkpoint","t":100,"data":{"begin_t":100}},{"kind":"checkpoint","t":100,"data":{"end_t":102}},{"kind":"checkpoint","t":100,"data":{"begin_t":99,"end_t":102}},{"kind":"checkpoint","t":100,"data":{"begin_t":100,"end_t":99}},{"kind":"checkpoint","t":100,"data":{"begin_t":100,"end_t":201}}]
        for record in cases:
            with self.subTest(record=record),self.assertRaises(replay.Refusal):
                replay.checkpoint_interval(record,200)
    def test_resource_source_age_is_closed_interval(self):
        for phase in ("Before actor","Before target","After actor","After target"):
            replay.resource_source_age(0,100,phase);replay.resource_source_age(100,100,phase)
            for age in (-1,101):
                with self.subTest(phase=phase,age=age),self.assertRaisesRegex(replay.Refusal,"nonnegative"):
                    replay.resource_source_age(age,100,phase)
    def test_future_embedded_checkpoint_metadata_refuses(self):
        with self.assertRaisesRegex(replay.Refusal,"metadata timestamp"):
            replay.checkpoint_field_metadata({"pos":{"st":101}},100)
    def test_missing_or_wrong_simulator_refuses_prelaunch(self):
        with tempfile.TemporaryDirectory() as temporary:
            bridge=Path(temporary)/"TrialReplay.dll"
            with patch.object(replay.subprocess,"run",side_effect=AssertionError("must not launch")):
                with self.assertRaisesRegex(replay.Refusal,"bridge is missing"):replay.verify_bridge(bridge)
                bridge.write_bytes(b"exists but will not execute")
                with self.assertRaisesRegex(replay.Refusal,"simulator DLL is missing"):replay.verify_bridge(bridge)
                bridge.with_name("bg3sim.dll").write_bytes(b"incompatible assembly")
                with self.assertRaisesRegex(replay.Refusal,"hash mismatch"):replay.verify_bridge(bridge)
    def test_after_envelope_extracts_no_oracle_fields(self):
        source={"native":{"hp":999,"nested":[{"text":"escaped \\\" brace }, comma , ["}]},"started_ms":100,"snapshot_reads":{"expected_outcome":"not an operand"},"finished_ms":101,"owner_binding":{"combat_id":"explicit"}}
        self.assertEqual(replay.after_receipt_metadata(replay.encoded(source)),{"started_ms":100,"finished_ms":101,"owner_binding":{"combat_id":"explicit"}})
        with self.assertRaisesRegex(replay.Refusal,"Duplicate AFTER"):
            replay.after_receipt_metadata(b'{"started_ms":1,"started_ms":2,"finished_ms":3,"owner_binding":{}}')
    def test_cut_or_error_damage_records_refuse(self):
        for row in ({"hit":{"Damage":{"truncated":True}}},{"hit":{"errors":["unreadable"]}},{"hit":{"Damage":{"available":False}}},{"hit":{"Damage":"<budget>"}}):
            with self.subTest(row=row),self.assertRaises(replay.Refusal):
                replay.complete_damage_evidence(row)
    def test_absent_facet_allows_explicit_checkpoint_fallback(self):
        rows=[{"id":"retained-checkpoint-row"}]
        self.assertEqual(replay.resource_rows({}, {"resources":rows}),(rows,"deferred-checkpoint"))
    def test_present_null_and_wrong_type_never_fall_back(self):
        for malformed in (None,[],"unreadable",1,False):
            with self.subTest(value=malformed),self.assertRaisesRegex(replay.Refusal,"no stale fallback"):
                replay.resource_rows({"raw_resource_entries":malformed},{"resources":[{"sentinel":"must not use"}]})
    def test_failed_or_malformed_exact_facet_rejects(self):
        for facet in ({"ok":False},{"ok":True,"result":None},{"ok":True,"result":{"rows":None}},{"ok":True,"result":{"rows":{},"count":0,"precision":"unrounded"}}):
            with self.subTest(facet=facet),self.assertRaises(replay.Refusal):
                replay.resource_rows({"raw_resource_entries":facet},{"resources":[]})
    def test_valid_exact_facet_preserves_unrounded_value(self):
        facet={"ok":True,"result":{"rows":[{"resource_uuid":replay.MOVEMENT_ID,"entry_index":1,"level":0,"amount":5.549888997280449,"max_amount":9}],"count":1,"precision":"unrounded"}}
        rows,precision=replay.resource_rows({"raw_resource_entries":facet},{"resources":[]})
        self.assertEqual(rows[0]["amount"],5.549888997280449)
        self.assertEqual(precision,"callback-exact-unrounded")
    def test_evidence_paths_cannot_escape_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for relative in ("../other.json","..\\other.json",str(root.parent/"outside.json")):
                with self.subTest(path=relative),self.assertRaisesRegex(replay.Refusal,"escapes"):
                    replay.safe_file(root,relative)
            self.assertEqual(replay.safe_file(root,"raw/probe.json"),root/"raw/probe.json")
    def test_scalar_mismatch_exit_is_three(self):
        with patch.object(replay.sys,"argv",["replay_trial.py","explicit-unused-trial","--output","explicit-unused-output"]),patch.object(replay,"run",return_value={"status":"scalar_mismatch","engineInvoked":True,"mismatches":[{"field":"target.hp"}]}),patch.object(replay.sys,"stdout",new_callable=io.StringIO):
            self.assertEqual(replay.main(),3)

if __name__=="__main__":unittest.main()
