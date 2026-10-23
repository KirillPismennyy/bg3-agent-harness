"""The live state contract keeps list compatibility and unknown/empty distinct."""
import tempfile
import unittest
from pathlib import Path
from test_fightbot import F, FakeGame, P1, IMP1
from fightrec_reader import FightRecReader


class StatusGame(FakeGame):
    def _op(self, op, args):
        row = super()._op(op, args)
        if op == "state.status":
            # A brief can already contain an observation, which must survive
            # when the optional detailed conditions section is absent.
            row["party"][1].update(statuses=[], status_observation={
                "available": False, "source": "StatusContainer.Statuses",
                "scope": "visible", "reason": "component_absent_or_unavailable"})
        if op == "state.character" and args["uuid"] == P1:
            row.update(statuses=[], status_observation={
                "available": False, "source": "StatusContainer.Statuses",
                "scope": "visible", "reason": "enumeration_failed"})
        if op == "state.entity" and args["uuid"] == IMP1:
            row.update(statuses=[], status_observation={
                "available": True, "source": "StatusContainer.Statuses", "scope": "visible"})
        return row


class StatusAvailabilityTest(unittest.TestCase):
    def test_unknown_and_known_empty_remain_distinct_through_state(self):
        with tempfile.TemporaryDirectory() as folder:
            state = F.Bot(StatusGame(), Path(folder) / "trace.jsonl",
                          FightRecReader(Path(folder) / "none")).fight_state()
        party = state["party"]
        enemy = next(row for row in state["turn_order"] if row["id"] == "c3")
        self.assertEqual(party[0]["statuses"], [])
        self.assertEqual(enemy["statuses"], [])
        self.assertFalse(party[0]["status_observation"]["available"])
        self.assertTrue(enemy["status_observation"]["available"])
        self.assertEqual(party[0]["status_observation"]["reason"], "enumeration_failed")
        self.assertEqual(party[1]["status_observation"]["reason"], "component_absent_or_unavailable")
        self.assertEqual(enemy["status_observation"]["source"], "StatusContainer.Statuses")
        self.assertEqual(enemy["status_observation"]["scope"], "visible")

    def test_omniscient_hidden_marker_is_not_lost(self):
        class OmniscientGame(StatusGame):
            def _op(self, op, args):
                row = super()._op(op, args)
                if op == "state.entity" and args["uuid"] == IMP1:
                    row.update(statuses=[{"id": "ENGINE_ONLY", "name": "ENGINE_ONLY", "hidden": True}],
                               status_observation={"available": True, "raw_enumeration_available": True,
                                                   "source": "StatusContainer.Statuses", "scope": "omniscient"})
                return row
        with tempfile.TemporaryDirectory() as folder:
            state = F.Bot(OmniscientGame(), Path(folder) / "trace.jsonl",
                          FightRecReader(Path(folder) / "none")).fight_state()
        enemy = next(row for row in state["turn_order"] if row["id"] == "c3")
        self.assertTrue(enemy["statuses"][0]["hidden"])
        self.assertEqual(enemy["status_observation"]["scope"], "omniscient")
        self.assertTrue(enemy["status_observation"]["raw_enumeration_available"])


if __name__ == "__main__":
    unittest.main()
