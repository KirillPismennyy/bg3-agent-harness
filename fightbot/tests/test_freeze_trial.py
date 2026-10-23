import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE if (HERE / "freeze_trial.py").is_file() else HERE.parent))

from freeze_trial import freeze_trial

GUID = "78507c4e-b32a-d461-ff0a-9b724a91f13d"
ACTOR = "3ed74f06-3c60-42dc-83f6-f034cb47c679"
TARGET = "b5c913f9-f081-45bd-8e95-e34d0735b645"


class FreezeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.rec = self.base / "recorder"
        self.rec.mkdir()
        self.probes = self.base / "probe"
        self.probes.mkdir()
        self.state = {"recording": {"session_id": "session", "combat_id": "combat",
            "file_prefix": "session-server-fight01", "recorder_active": True}}
        self.action = {"status": "done", "result": {"experimental_source": {"cast_guid": GUID}}}

    def stream(self, *records, prefix="session-server-fight01", session="session", combat="combat", tail=""):
        header = {"kind": "part_header", "session_id": session, "combat_id": combat, "context": "server"}
        path = self.rec / (prefix + "-p00001.jsonl")
        path.write_text("\n".join(json.dumps(x) for x in [header, *records]) + "\n" + tail)
        return path

    def hit(self, *, target=TARGET, story=415, guid=GUID):
        return {"seq": 5, "kind": "DealtDamage", "data": {"caster": {"uuid": ACTOR},
            "target": {"uuid": target}, "hit": {"SpellCastGuid": guid, "StoryActionId": story,
            "ConditionRolls": [{"Difficulty": 13, "Roll": {"Result": {"NaturalRoll": 14, "Total": 16}}}]}}}

    def freeze(self, *, before=None, after=None, action=None):
        return freeze_trial(before or self.state, after or self.state, action or self.action,
            recorder_dir=self.rec, probe_dirs=[self.probes], destination=self.base / "trial")

    def test_exact_binding_never_uses_newest_other_stream(self):
        own = self.stream(self.hit())
        self.stream(self.hit(guid="22222222-2222-2222-2222-222222222222"), prefix="new-server-fight01", session="new")
        report = self.freeze()
        self.assertEqual([x["cast_guid"] for x in report["candidates"]], [GUID])
        file = report["files"][0]
        self.assertEqual(file["sha256"], hashlib.sha256(own.read_bytes()).hexdigest())
        self.assertFalse(report["qualified_capture"])

    def test_missing_bound_stream_does_not_fallback(self):
        self.stream(self.hit(), prefix="new-server-fight01", session="new")
        report = self.freeze()
        self.assertEqual(report["files"], [])
        self.assertEqual(report["candidates"], [])
        self.assertTrue(any("bound server stream missing" in x for x in report["errors"]))

    def test_header_mismatch_preserved_but_excluded(self):
        self.stream(self.hit(), combat="wrong")
        report = self.freeze()
        self.assertEqual(len(report["files"]), 1)
        self.assertEqual(report["candidates"], [])
        self.assertTrue(any("header identity mismatch" in x for x in report["errors"]))

    def test_torn_record_keeps_valid_raw_and_error(self):
        self.stream(self.hit(), tail='{"incomplete":')
        report = self.freeze()
        self.assertTrue(any("malformed/torn" in x for x in report["errors"]))
        self.assertTrue(report["candidates"][0]["numerical_attack_available"])

    def test_no_target_or_roll_inference_from_done_zero_damage(self):
        row = self.hit()
        row["data"].pop("target")
        row["data"]["hit"]["ConditionRolls"] = []
        self.stream(row)
        report = self.freeze(action={"status": "done", "result": {"total_damage": 0}})
        candidate = report["candidates"][0]
        self.assertFalse(candidate["target_confirmed_directly"])
        self.assertFalse(candidate["numerical_attack_available"])
        self.assertIsNone(candidate["requested_guid_match"])
        self.assertTrue(any("no cast GUID" in x for x in report["unknowns"]))

    def test_conflicting_story_and_target_not_silently_joined(self):
        self.stream(self.hit(), self.hit(target=ACTOR, story=416))
        report = self.freeze()
        candidate = report["candidates"][0]
        self.assertTrue(candidate["target_conflict"])
        self.assertFalse(candidate["story_consistent"])

    def test_probe_direct_target_and_damage_draw_retained(self):
        row = self.hit()
        row["kind"] = "BeforeDealDamage"
        row["data"].pop("target")
        row["data"]["hit"]["Damage"] = {"ConditionRoll": {"RollParams": [
            {"Result": {"NaturalRoll": 4}, "Roll": {"Roll": {"DiceValue": "D10", "AmountOfDices": 1}}}]}}
        self.stream(row)
        (self.probes / "002.json").write_text(json.dumps({"component": "SpellCastTargetHitEvent",
            "Hit": row["data"]["hit"], "caster": {"uuid": ACTOR}, "target": {"uuid": TARGET},
            "complete": True, "errors": []}))
        report = self.freeze()
        candidate = report["candidates"][0]
        self.assertTrue(candidate["target_confirmed_directly"])
        self.assertEqual(candidate["direct_actor_target_pairs"], [{"caster": ACTOR, "target": TARGET}])
        self.assertIsNone(candidate["evidence"][0]["target"])
        self.assertEqual(candidate["evidence"][0]["damage"]["ConditionRoll"]["RollParams"][0]["Result"]["NaturalRoll"], 4)

    def test_generation_change_and_loss_flags_retained(self):
        row = self.hit()
        row["data"]["shape"] = {"_cut": True}
        self.stream(row)
        after = {"recording": {**self.state["recording"], "session_id": "different"}}
        report = self.freeze(after=after)
        self.assertTrue(any("binding differs" in x for x in report["errors"]))
        self.assertTrue(report["candidates"][0]["evidence"][0]["loss_flags"])
        self.assertFalse(report["qualified_capture"])

    def test_existing_freeze_never_overwritten(self):
        self.stream(self.hit())
        self.freeze()
        with self.assertRaises(FileExistsError):
            self.freeze()


if __name__ == "__main__":
    unittest.main()
