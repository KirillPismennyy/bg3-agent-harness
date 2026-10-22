#!/usr/bin/env python3
"""Tests for tools/record_fight.py (no game).  Run: python3 -m unittest tools/test_record_fight.py"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import record_fight as RF  # noqa: E402


def entries(texts, first=1):
    return [{"i": first + k, "d": {"_type": "ls.CombatLogEntry", "Text": t}} for k, t in enumerate(texts)]


class LogTailTest(unittest.TestCase):
    def test_first_read_is_backlog_then_appends_are_new(self):
        lt = RF.LogTail(tail=3)
        self.assertEqual(lt.window(), 1)
        new, how = lt.take(2, entries(["a", "b"]))
        self.assertEqual((len(new), how), (2, "backlog"))
        self.assertEqual(lt.window(), 1)            # count 2, tail 2: re-read from 1
        new, how = lt.take(4, entries(["a", "b", "c", "d"]))
        self.assertEqual([e["d"]["Text"] for e in new], ["c", "d"])
        self.assertEqual(how, "new")
        self.assertEqual(lt.window(), 2)            # tail is b, c, d
        new, _ = lt.take(4, entries(["b", "c", "d"], first=2))
        self.assertEqual(new, [])

    def test_identical_lines_in_a_row_are_each_kept(self):
        lt = RF.LogTail(tail=3)
        lt.take(1, entries(["hit 5"]))
        new, _ = lt.take(3, entries(["hit 5", "hit 5", "hit 5"]))
        self.assertEqual(len(new), 2)

    def test_dropped_head_resyncs_by_overlap(self):
        lt = RF.LogTail(tail=2)
        lt.take(3, entries(["a", "b", "c"]))
        # the log dropped "a": what was at 2..3 is now at 1..2, and "d" was added
        self.assertIsNone(lt.take(3, entries(["c", "d"], first=2)))
        new, how = lt.take_full(3, entries(["b", "c", "d"]))
        self.assertEqual(([e["d"]["Text"] for e in new], how), (["d"], "new"))
        self.assertEqual(lt.window(), 2)

    def test_rebuilt_log_is_a_resync(self):
        lt = RF.LogTail(tail=2)
        lt.take(2, entries(["a", "b"]))
        self.assertIsNone(lt.take(1, entries(["x"])))
        new, how = lt.take_full(1, entries(["x"]))
        self.assertEqual((len(new), how), (1, "resync"))


class EntryTextTest(unittest.TestCase):
    def test_strings_without_markup_types_or_repeats(self):
        d = {"_type": "ls.CombatLogEntry", "Title": "<LSTag Type=\"Char\">Lae'zel</LSTag> hits Goblin",
             "Details": {"_type": "Noesis::ObservableCollection", "_count": 2, "_items": [
                 {"_type": "ls::VMRoll", "Text": "Attack Roll: 17 (d20 13 + 4) vs AC 15"},
                 {"_type": "ls::VMRoll", "Text": "Damage: 9 Slashing"}]},
             "Again": "Lae'zel hits Goblin", "_cmd": "ls::Command"}
        self.assertEqual(RF.entry_text(d),
                         "Lae'zel hits Goblin | Attack Roll: 17 (d20 13 + 4) vs AC 15 | Damage: 9 Slashing")

    def test_element_text_is_kept(self):
        self.assertEqual(RF.entry_text({"_type": "TextBlock", "_text": "Saving throw: WIS 8 vs DC 13"}),
                         "Saving throw: WIS 8 vs DC 13")


class FakeGame:
    """The mod's answers for one short fight."""

    def __init__(self):
        self.event_seq = {"server": 10, "client": 0}
        self.calls = []
        self.events = [
            {"seq": 11, "t": 1, "kind": "cast", "data": {"name": "Bless"}},
            {"seq": 12, "t": 2, "kind": "combat_started", "data": {}},
            {"seq": 13, "t": 3, "kind": "damage", "data": {"amount": 9, "type": "Slashing"}},
            {"seq": 14, "t": 4, "kind": "combat_ended", "data": {}},
        ]
        self.log = ["old line"]

    def sync_events(self):
        pass

    def rpc(self, op, args=None, context="server"):
        self.calls.append(op)
        args = args or {}
        if op == "events.since":
            evs = [e for e in self.events if e["seq"] > args["seq"]][:1]   # one per poll
            if evs and evs[0]["kind"] == "damage":
                self.log.append("Lae'zel hits Goblin for 9")
            return {"latest": 14, "events": evs}
        if op == "rec.enable":
            return {"on": args.get("on", True), "seq": 0, "hooks": {"AttackedBy": "ok", "Ext.Events.DealtDamage": "nil"}}
        if op == "rec.since":
            return {"on": True, "latest": 0, "records": []}
        if op == "combatlog.probe":
            return {"found": True, "how": "widget", "chosen": "Entries"}
        if op == "combatlog.read":
            first = args.get("first", 1)
            return {"found": True, "count": len(self.log), "collection": "Entries",
                    "entries": entries(self.log[first - 1:], first)}
        if op == "state.status":
            return {"party": [{"uuid": "u1", "name": "Lae'zel"}], "in_combat": False}
        if op == "state.character":
            return {"uuid": args["uuid"], "name": "Lae'zel", "level": 3, "hp": 30, "max_hp": 34,
                    "equipment": [{"slot": "MainHand", "name": "Greatsword"}]}
        return {}


class RecorderTest(unittest.TestCase):
    def test_one_fight(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "fight"
            g = FakeGame()
            rec = RF.Recorder(g, out, fights=1, inventory=False, combatlog=True, depth=3)
            rec.say = lambda line: None
            rec.start()
            for _ in range(6):
                rec.poll_events()
                rec.poll_raw()
                rec.poll_log()
            self.assertEqual((rec.fights_started, rec.fights_done), (1, 1))
            self.assertIsNotNone(rec.stop_at)
            rec.stop()
            rows = [json.loads(x) for x in out.with_suffix(".jsonl").read_text().splitlines()]
            snaps = [r["why"] for r in rows if r["src"] == "snapshot"]
            self.assertEqual(snaps, ["start", "combat_start", "combat_end"])
            self.assertEqual(rows[1]["party"][0]["equipment"][0]["name"], "Greatsword")
            kinds = [r["kind"] for r in rows if r["src"] == "event"]
            self.assertEqual(kinds, ["cast", "combat_started", "damage", "combat_ended"])
            log = [(r["how"], r["text"]) for r in rows if r["src"] == "combatlog"]
            self.assertEqual(log, [("backlog", "old line"), ("new", "Lae'zel hits Goblin for 9")])
            self.assertEqual(g.calls[-1], "rec.enable")    # switched off at the end
            rec.stop()                                      # a second stop is harmless


if __name__ == "__main__":
    unittest.main()
