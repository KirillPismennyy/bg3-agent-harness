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
from fightrec_reader import FightRecReader, unwrap  # noqa: E402

FIXTURE = HERE / "fixtures" / "FightRec2"   # a slice of the 2026-10-23 chapel recapture (FightRec 2.0.0-dev.1)

P1, P2, IMP1, IMP2 = "u-p1", "u-p2", "u-i1", "u-i2"


class FakeGame:
    def __init__(self):
        self.calls: list[tuple] = []
        self.combat = [{"active": True, "round": 1, "current": IMP1, "order": self.order()}]
        self.jobs: list[tuple] = []
        self.evals = 0
        self.events: list[list[dict]] = []

    @staticmethod
    def order(can_act=False):
        return [{"uuid": P1, "name": "Lae'zel", "relation": "party", "is_current": can_act},
                {"uuid": IMP1, "name": "Imp", "relation": "hostile", "initiative": 14},
                {"uuid": IMP2, "name": "Imp", "relation": "hostile"},
                {"uuid": P2, "name": "Gale", "relation": "party"}]

    def multi(self, calls, context="server"):
        self.evals += 1
        out = []
        for op, args in calls:
            try:
                out.append(self._op(op, args))
            except GameError:
                out.append(None)
        return out

    def drain_events(self, context="server"):
        return self.events.pop(0) if self.events else []

    def rpc(self, op, args=None, context="server"):
        self.evals += 1
        return self._op(op, args)

    def _op(self, op, args):
        self.calls.append((op, args))
        if op == "dev.omniscient":
            return {"on": True}
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
        return JobResult(status="done", result={"damage": [{"target": IMP1, "amount": 10}]})


class BotTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.g = FakeGame()
        self.bot = F.Bot(self.g, Path(self.tmp.name) / "log.jsonl", FightRecReader(Path(self.tmp.name) / "none"))
        sleep = mock.patch.object(F.time, "sleep", lambda s: None)
        sleep.start()
        self.addCleanup(sleep.stop)

    def test_state_is_unfiltered_and_uses_short_ids(self):
        s = self.bot.fight_state()
        self.assertEqual(self.g.calls[0][0], "dev.omniscient")
        self.assertEqual(self.g.evals, 3, "omniscient once, then two batched evals for the whole state")
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

    def test_cast_sends_uuids_and_returns_the_outcome_at_once(self):
        self.bot.fight_state()
        r = self.bot.cast("c1", "Target_MainHandAttack", target="c3")
        self.assertEqual(self.g.jobs[-1], ("act.cast", {"char": P1, "spell": "Target_MainHandAttack", "target": IMP1}))
        self.assertEqual(r, {"status": "done", "result": {"damage": [{"target": IMP1, "amount": 10}]}})

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
        self.g.events = [[{"kind": "combat_started"}], [{"kind": "status_applied"}], [], [{"kind": "turn_started"}]]
        r = self.bot.wait_for_turn(timeout_s=60)
        reads = [c for c in self.g.calls if c[0] == "state.combat"]
        self.assertEqual(len(reads), 4, "the turn order is read only after turn events (3 + the state's own)")
        self.assertTrue(r["your_turn"])
        self.assertEqual(r["state"]["party_can_act"], [{"id": "c1", "name": "Lae'zel"}])
        self.g.combat = [{"active": False}]
        self.g.events = [[{"kind": "combat_ended"}]]
        self.assertTrue(self.bot.wait_for_turn(timeout_s=60)["fight_over"])

    def test_no_fight_yet_is_not_fight_over(self):
        self.g.combat = [{"active": False}]
        clock = iter(range(0, 10**6, 1))   # one second per look at the clock
        with mock.patch.object(F.time, "time", lambda: next(clock)):
            r = self.bot.wait_for_turn(timeout_s=10)
        self.assertTrue(r.get("timeout"))
        reads = [c for c in self.g.calls if c[0] == "state.combat"]
        self.assertLessEqual(len(reads), 3, "no events: the turn order is read only every FALLBACK_S")

    def test_every_tool_call_is_logged(self):
        import asyncio
        srv = F.build_server(self.bot)
        asyncio.run(srv.call_tool("fight_state", {}))
        asyncio.run(srv.call_tool("actions", {"char": "nobody"}))
        rows = [json.loads(x) for x in (Path(self.tmp.name) / "log.jsonl").read_text().splitlines()]
        self.assertEqual([r["tool"] for r in rows], ["fight_state", "actions"])
        self.assertIn("unknown character", rows[1]["result"]["error"])


class ReaderTest(unittest.TestCase):
    """FightRec v2 files: a sealed part and an active part with a torn last line, beside an older fight."""

    def setUp(self):
        self.r = FightRecReader(FIXTURE)

    def test_newest_fight_and_its_rolls(self):
        out = self.r.rows()
        self.assertEqual(out["stream"], "1792757830-c28a02f575fb40e0ddbb900ea4c80981-server-fight01")
        self.assertEqual([x["kind"] for x in out["rows"]], ["hit", "roll_result", "no_damage"])
        hit = out["rows"][0]
        # verified live 2026-10-23 (fightrec/chapel-capture-and-deployment.txt): cust -> Taman, 10+5=15 vs 13,
        # discarded d20 9; D12 6+3 = 9, HP 23 -> 14
        self.assertEqual((hit["attacker"]["name"], hit["target"]["name"]), ("cust", "Taman"))
        self.assertEqual(hit["rolls"], [{"type": "AttackRoll", "natural": 10, "total": 15, "vs": 13, "dice": [10, 9]}])
        self.assertEqual(hit["damage"]["total"], 9)
        self.assertEqual(hit["damage"]["by_type"], {"Slashing": 9})
        self.assertEqual(hit["damage"]["dice"][0]["die"], "D12")
        self.assertEqual((hit["damage"]["dice"][0]["natural"], hit["damage"]["dice"][0]["total"]), (6, 9))
        self.assertIn("no roll", out["rows"][2]["note"])

    def test_since_and_a_missing_folder(self):
        self.assertEqual([x["seq"] for x in self.r.rows(since=1480)["rows"]], [2013, 2017])
        self.assertEqual(FightRecReader(FIXTURE / "nope").rows(), {"stream": None, "latest": 0, "rows": []})

    def test_unwrap(self):
        self.assertEqual(unwrap({"1": {"label": "D20", "value": 5}, "2": "x"}), ["D20", "x"])
        self.assertEqual(unwrap({"value": [1, "<omitted>"], "cut": True}), [1])

    def test_the_bot_hands_out_each_roll_once(self):
        g = FakeGame()
        bot = F.Bot(g, None, FightRecReader(FIXTURE))
        first = bot.fight_state()["new_rolls"]
        self.assertEqual(len(first), 3)
        self.assertEqual(first[0]["attacker"]["id"][0], "c")
        self.assertEqual(bot.fight_state()["new_rolls"], [])
        self.assertEqual(len(bot.rolls(since=0)["rows"]), 3)


if __name__ == "__main__":
    unittest.main()
