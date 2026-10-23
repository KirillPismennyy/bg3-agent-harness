import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import re
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE if (HERE / "trial_capture.py").is_file() else HERE.parent))
import trial_capture

from trial_capture import capture_trial, summarize_trial


class FakeOwner:
    def __init__(self):
        self.state = dict(ready=True,ready_token="token",server_session="server",client_session="client",
            combat_id="combat",server_recorder_hash="hash",client_recorder_hash="hash",expected_recorder_hash="hash",
            probe={"dir":"FightBotProbe/lifecycle/"})
        self.snapshots = 0
        self.read_fail = False
        self.change_before = False
        self.change_after = False
        self.calls = []
        self.probe_dir = None
        self.probe_stops = 0
        self.partial_probe = False
    def poll(self):
        result=copy.deepcopy(self.state)
        if self.change_after and self.snapshots:
            result["server_session"]="new-server"
        return result
    def evaluate(self,code,**kwargs):
        self.calls.append(code)
        if "trial-capture:snapshot" in code:
            self.snapshots+=1
            def row(result):return dict(ok=True,result=result)
            raw=dict(identity=row(dict(session_id="server",combat_id="combat",file_prefix="server-server-fight01",
                party_combats=["combat"],recorder_active=True)),combat=row(dict(round=1)),
                actor=row(dict(hp=17,resources={"ActionPoint":[1,1]})),target=row(dict(hp=16,ac=10)),actions=row(dict(actions=[])),
                native_actor=row(dict(hp=17,pos=[283,18.9,331],vertical_y=18.9,proficiency_bonus=2)),
                native_target=row(dict(hp=16,pos=[293,21.3,342],vertical_y=21.3)),recorder_hash="hash",
                started_ms=100,finished_ms=101)
            if self.read_fail:raw["actor"]=dict(ok=False,error="read unavailable")
            return json.dumps(raw)
        if "trial-capture:arm-probe" in code:
            if self.probe_dir:raise RuntimeError("existing numerical probe active")
            self.probe_dir=re.search(r'dir=\[=\[(.*?)\]=\]',code).group(1)
            if self.partial_probe:raise RuntimeError("registration failed after arm")
            return json.dumps(dict(probe_relative_dir=self.probe_dir,registrations=[dict(ok=True)]*5))
        if "trial-capture:stop-probe" in code:
            self.probe_stops+=1
            self.probe_dir=None
            return json.dumps(dict(active=False))
        return "{}"
    def run_action(self,token,callback):
        if self.change_before or token!=self.state["ready_token"]:
            raise RuntimeError("fresh token required")
        return callback()


class FakeBot:
    def __init__(self):self.orders=[];self.result={"status":"done","result":{"experimental_source":{"cast_guid":"cast"}}};self.fail=False
    def resolve(self,ref):return ref
    def cast(self,**kwargs):
        self.orders.append(kwargs)
        if self.fail:raise TimeoutError("outcome unknown")
        return self.result


class CaptureTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.owner,self.bot=FakeOwner(),FakeBot()
        self.freezes=[]
    def freeze(self,before,after,action,**kwargs):
        self.freezes.append((before,after,action,kwargs))
        return {"qualified_capture":False,"candidates":[{"cast_guid":"cast","acceptance":"not_assessed"}]}
    def run_trial(self,**kwargs):
        params=dict(actor="actor",target="target",spell="Projectile_FireBolt",ready_token="token",
            destination=self.root/"trials",recorder_dir=self.root/"FightRec2",freeze_fn=self.freeze,flush_timeout_s=0)
        params.update(kwargs)
        return capture_trial(self.owner,self.bot,**params)
    def test_bounded_success_retains_raw_boundaries_and_never_claims_full_scene(self):
        report=self.run_trial()
        self.assertEqual(len(self.bot.orders),1)
        self.assertEqual(report["action_attempts"],1)
        self.assertTrue(report["control_window_qualified"])
        self.assertFalse(report["qualifications"]["simulator_scene_complete"])
        self.assertFalse(report["numerical_roll_proven"])
        before=self.freezes[0][0]
        self.assertEqual(before["party"][0]["resources"]["ActionPoint"][0],1)
        self.assertEqual(before["native"]["target"]["vertical_y"],21.3)
        self.assertEqual(before["started_ms"],100)
        self.assertTrue(Path(report["files"]["before"]["path"]).is_file())
        self.assertEqual(len(report["files"]["before"]["sha256"]),64)
        self.assertEqual(self.freezes[0][3]["probe_dirs"],[self.root/"FightBotProbe"/"lifecycle"])
    def test_client_reset_after_post_snapshot_is_still_disqualified(self):
        original_poll = self.owner.poll
        def final_changed():
            state = original_poll()
            if self.owner.snapshots >= 2:
                state["client_session"] = "new-client-after-post"
            return state
        self.owner.poll = final_changed
        report = self.run_trial()
        self.assertEqual(len(self.bot.orders), 1)
        self.assertFalse(report["qualifications"]["generation_unchanged"])
        self.assertFalse(report["control_window_qualified"])
        self.assertTrue(Path(report["files"]["post_readiness"]["path"]).is_file())
    def test_required_before_read_failure_prevents_action_and_retains_unknown(self):
        self.owner.read_fail=True
        report=self.run_trial()
        self.assertEqual(self.bot.orders,[])
        self.assertFalse(report["control_window_qualified"])
        before=json.loads(Path(report["files"]["before"]["path"]).read_text())
        self.assertEqual(before["snapshot_reads"]["actor"]["error"],"read unavailable")
    def test_generation_token_change_before_callback_issues_nothing(self):
        self.owner.change_before=True
        report=self.run_trial()
        self.assertEqual(self.bot.orders,[])
        self.assertEqual(report["action_attempts"],0)
        self.assertFalse(report["qualifications"]["action_done"])
    def test_uncertain_action_is_never_retried(self):
        self.bot.fail=True
        report=self.run_trial()
        self.assertEqual(len(self.bot.orders),1)
        self.assertEqual(report["action_attempts"],1)
        self.assertFalse(report["control_window_qualified"])
        self.assertEqual(self.freezes[0][2]["status"],"unknown")
    def test_post_generation_change_disqualifies(self):
        self.owner.change_after=True
        report=self.run_trial()
        self.assertEqual(len(self.bot.orders),1)
        self.assertFalse(report["qualifications"]["generation_unchanged"])
        self.assertFalse(report["control_window_qualified"])
    def test_refusal_kept_without_reissuing(self):
        self.bot.result={"status":"failed","error":"source selector required"}
        report=self.run_trial()
        self.assertEqual(len(self.bot.orders),1)
        self.assertFalse(report["qualifications"]["action_done"])
        self.assertEqual(self.freezes[0][2]["error"],"source selector required")
    def test_invalid_flush_timeout_cannot_issue_or_arm(self):
        for timeout in (float("nan"),float("inf"),-1,"invalid"):
            report=self.run_trial(flush_timeout_s=timeout)
            self.assertEqual(report["action_attempts"],0)
            self.assertTrue(Path(report["report_path"]).is_file())
        self.assertEqual(self.bot.orders,[])
        self.assertEqual(self.owner.calls,[])
    def test_trial_directories_are_unique_and_never_overwrite(self):
        first,second=self.run_trial(),self.run_trial()
        self.assertNotEqual(first["trial_dir"],second["trial_dir"])
        self.assertTrue(Path(first["report_path"]).is_file())
    def test_numerical_probe_arm_stop_and_both_evidence_directories(self):
        report=self.run_trial(numerical_probe=True)
        self.assertEqual(len(self.bot.orders),1)
        self.assertEqual(self.owner.probe_stops,1)
        self.assertFalse(report["probe_cleanup"]["active"])
        dirs=self.freezes[0][3]["probe_dirs"]
        self.assertEqual(len(dirs),2)
        self.assertEqual(dirs[0],self.root/"FightBotProbe"/"lifecycle")
        self.assertEqual(dirs[1].parent,self.root/"FightBotProbe")
    def test_persistent_write_failure_after_arm_still_stops_probe(self):
        original=trial_capture._write
        def failing_write(path,value):
            if self.owner.probe_dir is not None or self.owner.probe_stops:
                raise OSError("disk unavailable")
            return original(path,value)
        with mock.patch.object(trial_capture,"_write",failing_write):
            report=self.run_trial(numerical_probe=True)
        self.assertEqual(self.bot.orders,[])
        self.assertEqual(self.owner.probe_stops,1)
        self.assertIn("report_write_error",report)
        self.assertFalse(report["control_window_qualified"])
    def test_partial_arm_failure_cleans_owned_probe_without_cast(self):
        self.owner.partial_probe=True
        report=self.run_trial(numerical_probe=True)
        self.assertEqual(self.bot.orders,[])
        self.assertEqual(self.owner.probe_stops,1)
        self.assertFalse(report["control_window_qualified"])


class TrialIndexTests(unittest.TestCase):
    def test_stdout_index_never_embeds_raw_evidence_or_claims_acceptance(self):
        raw = {"requested_guid_match": True, "cast_guid": "observed-guid", "acceptance": "not_assessed",
               "evidence": [{"native": "sensitive-local-payload" * 10000}]}
        report = {"action_status": "failed", "action_error": "no line of sight", "report_path": "report.json",
                  "evidence": {"candidates": [raw], "files": [{"path": "raw.json"}], "acceptance": "not_assessed"}}
        index = summarize_trial(report)
        self.assertEqual(index["action_error"], "no line of sight")
        self.assertEqual(index["evidence_index"]["candidate_count"], 1)
        self.assertEqual(index["evidence_index"]["acceptance"], "not_assessed")
        self.assertNotIn("sensitive-local-payload", json.dumps(index))
        self.assertLess(len(json.dumps(index)), 3000)


if __name__=="__main__":unittest.main()
