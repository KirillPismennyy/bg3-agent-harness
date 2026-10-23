#!/usr/bin/env python3
"""Tests for fightbot/fightbot_mcp.py with a fake game.  Run: python3 -m unittest fightbot/tests/test_fightbot.py"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import fightbot_mcp as F  # noqa: E402
from bg3ai.game import GameError, JobResult  # noqa: E402

P1, P2, IMP1, IMP2 = "u-p1", "u-p2", "u-i1", "u-i2"


class FakeGame:
    def __init__(self):
        self.calls: list[tuple] = []
        self.combat = [{"active": True, "round": 1, "current": IMP1, "order": self.order()}]
        self.rolls = []
        self.jobs: list[tuple] = []

    @staticmethod
    def order(can_act=False):
        return [{"uuid": P1, "name": "Lae'zel", "relation": "party", "is_current": can_act},
                {"uuid": IMP1, "name": "Imp", "relation": "hostile", "initiative": 14},
                {"uuid": IMP2, "name": "Imp", "relation": "hostile"},
                {"uuid": P2, "name": "Gale", "relation": "party"}]

    def rpc(self, op, args=None, context="server"):
        self.calls.append((op, args))
        if op == "dev.omniscient":
            return {"on": True}
        if op == "omni.rolls_enable":
            return {"on": True, "seq": len(self.rolls), "hooks": {}}
        if op == "omni.rolls":
            rows = [dict(r) for r in self.rolls if r["seq"] > args["since"]]
            return {"latest": len(self.rolls), "rows": rows}
        if op == "state.status":
            return {"party": [{"uuid": P1, "name": "Lae'zel", "hp": 12, "max_hp": 12, "pos": [1, 0, 2]},
                              {"uuid": P2, "name": "Gale", "hp": 8, "max_hp": 8}]}
        if op == "state.character":
            return {"ac": 16, "abilities": {"Strength": 17}, "resources": {"action": 1}}
        if op == "state.combat":
            return self.combat.pop(0) if len(self.combat) > 1 else self.combat[0]
        if op == "state.entity":
            if args["uuid"] == IMP2:
                raise GameError("unknown entity")
            return {"hp": 7, "max_hp": 7, "ac": 7, "statuses": [{"name": "Temporarily Hostile"}], "secret": 1}
        if op == "state.actions":
            return {"resources": {"action": 1, "movement": 9}, "actions": [
                {"spell": "Target_MainHandAttack", "name": "Main Hand Attack", "cost": {"action": 1},
                 "available": True, "internal": "x"}]}
        raise AssertionError(op)

    def run_job(self, op, args, context="server", wait_s=25.0):
        self.jobs.append((op, args))
        self.rolls.append({"seq": len(self.rolls) + 1, "t": 5, "kind": "hit",
                           "attacker": {"uuid": P1, "name": "Lae'zel"}, "target": {"uuid": IMP1, "name": "Imp"},
                           "rolls": [{"natural": 12, "total": 17, "vs": 7}]})
        return JobResult(status="done", result={"damage": 10})


class BotTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.g = FakeGame()
        self.bot = F.Bot(self.g, Path(self.tmp.name) / "log.jsonl")
        sleep = mock.patch.object(F.time, "sleep", lambda s: None)
        sleep.start()
        self.addCleanup(sleep.stop)

    def test_state_is_unfiltered_and_uses_short_ids(self):
        s = self.bot.fight_state()
        self.assertEqual(self.g.calls[0][0], "dev.omniscient")
        self.assertEqual([p["id"] for p in s["party"]], ["c1", "c2"])
        self.assertEqual(s["party"][0]["ac"], 16)
        imps = [o for o in s["turn_order"] if o["name"] == "Imp"]
        self.assertEqual([i["id"] for i in imps], ["c3", "c4"])
        self.assertEqual((imps[0]["hp"], imps[0]["ac"]), (7, 7))
        self.assertNotIn("secret", imps[0])                        # only the listed fields
        self.assertIn("examine_error", imps[1])
        self.assertEqual(s["current"], {"id": "c3", "name": "Imp"})
        self.assertNotIn("uuid", json.dumps(s))

    def test_names_resolve_unless_ambiguous(self):
        self.bot.fight_state()
        self.assertEqual(self.bot.resolve("lae'zel"), P1)
        self.assertEqual(self.bot.resolve("c3"), IMP1)
        with self.assertRaisesRegex(GameError, "2 characters are called 'Imp'.*c3, c4"):
            self.bot.resolve("Imp")
        with self.assertRaisesRegex(GameError, "unknown character"):
            self.bot.resolve("Shadowheart")

    def test_cast_sends_uuids_and_returns_its_rolls(self):
        self.bot.fight_state()
        r = self.bot.cast("c1", "Target_MainHandAttack", target="c3")
        self.assertEqual(self.g.jobs[-1], ("act.cast", {"char": P1, "spell": "Target_MainHandAttack", "target": IMP1}))
        self.assertEqual(r["status"], "done")
        self.assertEqual(r["rolls"][0]["attacker"], {"id": "c1", "name": "Lae'zel"})
        self.assertEqual(r["rolls"][0]["rolls"][0]["natural"], 12)
        self.assertEqual(self.bot.rolls()["rows"][0]["kind"], "hit")

    def test_move_needs_a_target_or_pos(self):
        self.bot.fight_state()
        self.bot.move("c1", pos=[1, 0, 2])
        self.assertEqual(self.g.jobs[-1], ("act.move_to", {"char": P1, "pos": [1, 0, 2]}))
        with self.assertRaisesRegex(GameError, "needs a target"):
            self.bot.move("c1")

    def test_actions_keep_the_useful_fields(self):
        self.bot.fight_state()
        a = self.bot.actions("c1")
        self.assertEqual(a["actions"][0], {"spell": "Target_MainHandAttack", "name": "Main Hand Attack",
                                           "cost": {"action": 1}, "available": True})

    def test_wait_for_turn_waits_for_a_fight_then_for_our_turn_then_reports_its_end(self):
        self.g.combat = [{"active": False}, {"active": True, "order": FakeGame.order()},
                         {"active": True, "party_can_act": [P1], "order": FakeGame.order(True)},
                         {"active": True, "party_can_act": [P1], "order": FakeGame.order(True)}]
        r = self.bot.wait_for_turn(timeout_s=60)
        self.assertTrue(r["your_turn"])
        self.assertEqual(r["state"]["party_can_act"], [{"id": "c1", "name": "Lae'zel"}])
        self.g.combat = [{"active": False}]
        self.assertTrue(self.bot.wait_for_turn(timeout_s=60)["fight_over"])

    def test_no_fight_yet_is_not_fight_over(self):
        self.g.combat = [{"active": False}]
        with mock.patch.object(F.time, "time", side_effect=[0, 0, 1, 2, 999, 999]):
            r = self.bot.wait_for_turn(timeout_s=10)
        self.assertTrue(r.get("timeout"))

    def test_every_tool_call_is_logged(self):
        import asyncio
        srv = F.build_server(self.bot)
        asyncio.run(srv.call_tool("fight_state", {}))
        asyncio.run(srv.call_tool("actions", {"char": "nobody"}))
        rows = [json.loads(x) for x in (Path(self.tmp.name) / "log.jsonl").read_text().splitlines()]
        self.assertEqual([r["tool"] for r in rows], ["fight_state", "actions"])
        self.assertIn("unknown character", rows[1]["result"]["error"])


if __name__ == "__main__":
    unittest.main()
