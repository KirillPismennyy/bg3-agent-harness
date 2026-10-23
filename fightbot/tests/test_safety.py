"""Offline safety regression tests; never connects to a game or model API."""
import asyncio
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_fightbot import F, FakeGame, FIXTURE, PREFIX, COMBAT, P1
from fightrec_reader import FightRecReader, attack_rolls, evidence_issues

ROOT = Path(__file__).resolve().parents[2]
PS = shutil.which("powershell.exe")


class ActionSafety(unittest.TestCase):
    def setUp(self):
        self.game = FakeGame()
        self.bot = F.Bot(self.game, reader=FightRecReader(FIXTURE / "missing"))
        self.bot.fight_state()

    def test_readonly_has_no_action_tools_or_action_side_effect(self):
        bot = F.Bot(self.game, read_only=True)
        names = {t.name for t in asyncio.run(F.build_server(bot).list_tools())}
        self.assertFalse(names & {"cast", "move", "end_turn"})
        with self.assertRaisesRegex(F.GameError, "read-only"):
            bot._act("act.cast", {"char": P1})
        self.assertEqual(self.game.jobs, [])

    def test_cannot_act_outside_combat_or_on_enemy_turn(self):
        for state, message in [({"active": False}, "outside combat"),
                               ({"active": True, "party_can_act": []}, "able to act")]:
            self.game.combat = [state]
            with self.assertRaisesRegex(F.GameError, message):
                self.bot.end_turn("c1")
        self.assertEqual(self.game.jobs, [])

    def test_unbound_recording_blocks_actions(self):
        self.game.combat = [{"active": True, "party_can_act": [P1]}]
        original = self.game._op
        self.game._op = lambda op, args: ({"recorder_active": False} if op == "fightbot.identity" else original(op, args))
        with self.assertRaisesRegex(F.GameError, "active FightRec"):
            self.bot.cast("c1", "Target_MainHandAttack", "c3")
        self.assertEqual(self.game.jobs, [])

    def test_bad_positions_never_reach_game_actions(self):
        for p in ([1, 2], [1, 2, 3, 4], [float("nan"), 0, 0], [float("inf"), 0, 0], [True, 0, 0]):
            with self.assertRaisesRegex(F.GameError, "finite"):
                self.bot.move("c1", pos=p)
        self.assertEqual(self.game.jobs, [])


class RecordingSafety(unittest.TestCase):
    def test_binding_does_not_fall_back_to_old_fight(self):
        r = FightRecReader(FIXTURE)
        r.require_binding()
        self.assertEqual(r.rows()["rows"], [])
        r.bind("future-server-fight01", "future-combat")
        self.assertEqual(r.rows()["rows"], [])
        r.bind(PREFIX, COMBAT)
        self.assertTrue(r.rows()["rows"])
        r.bind(PREFIX, "other-combat")
        self.assertEqual(r.rows()["rows"], [])
        self.assertTrue(r.read_issues)

    def test_no_old_rows_without_runtime_binding(self):
        g = FakeGame()
        original = g._op
        g._op = lambda op, args: ({"session_id": "new-session"} if op == "fightbot.identity" else original(op, args))
        b = F.Bot(g, reader=FightRecReader(FIXTURE))
        self.assertEqual(b.fight_state()["new_rolls"], [])

    def test_partial_evidence_remains_visible(self):
        self.assertTrue(evidence_issues({"value": [1, "<omitted>"], "cut": True}))
        self.assertTrue(evidence_issues({"1": "a", "3": "c"}))
        self.assertEqual(evidence_issues({"1": "a", "2": "b"}), [])

    def test_legacy_false_strings_are_not_true(self):
        rows = attack_rolls({"ConditionRolls": [{"Roll": {"Roll": {"Advantage": "false", "Disadvantage": "false"}}}]})
        self.assertNotIn("advantage", rows[0])
        self.assertNotIn("disadvantage", rows[0])

    def test_ambiguous_damage_is_not_assigned_to_another_target(self):
        records = FightRecReader(FIXTURE).records()[1]
        dealt = next(copy.deepcopy(r) for r in records if r["kind"] == "DealtDamage")
        before = next(copy.deepcopy(r) for r in records if r["kind"] == "BeforeDealDamage"
                      and r["data"]["hit"].get("SpellCastGuid") == dealt["data"]["hit"]["SpellCastGuid"])
        before["seq"] = 1
        other = copy.deepcopy(before)
        other["seq"] = 2
        dealt["seq"] = 3
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / (PREFIX + "-p00001.jsonl")
            p.write_text("\n".join(json.dumps(r) for r in (before, other, dealt)), encoding="utf-8")
            hit = FightRecReader(Path(td)).rows()["rows"][0]
            self.assertNotIn("dice", hit["damage"])
            self.assertIn("ambiguous", hit["damage"]["dice_unavailable"])
            self.assertFalse(hit["evidence_complete"])


@unittest.skipUnless(PS, "Windows PowerShell integration checks")
class WindowsSetup(unittest.TestCase):
    def ps(self, *args):
        return subprocess.run([PS, "-NoProfile", "-ExecutionPolicy", "Bypass", *map(str, args)],
                              cwd=ROOT, capture_output=True, text=True, timeout=30)

    def test_installer_preserves_old_files_recorder_and_nested_settings(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            se, bin_dir = base / "Script Extender", base / "bin"
            se.mkdir()
            bin_dir.mkdir()
            (bin_dir / "bg3.exe").write_bytes(b"test-only")
            cfg = bin_dir / "ScriptExtenderSettings.json"
            old_cfg = {"Nested": {"a": {"b": {"c": "keep"}}}, "CreateConsole": False}
            cfg.write_text(json.dumps(old_cfg), encoding="utf-8")
            (se / "BG3AI").mkdir()
            (se / "BG3AI" / "old.txt").write_text("old", encoding="utf-8")
            (se / "FightBotLoad.lua").write_text("old-loader", encoding="utf-8")
            (se / "FightRec.lua").write_text("unchanged", encoding="utf-8")
            result = self.ps("-File", ROOT / "fightbot/install.ps1", "-GameBin", bin_dir, "-ScriptExtenderDir", se)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            receipt_file = next((se / "FightBotBackups").glob("*/install-receipt.json"))
            receipt = json.loads(receipt_file.read_text(encoding="utf-8-sig"))
            backup = receipt_file.parent
            self.assertEqual(receipt["status"], "installed")
            self.assertEqual((backup / "BG3AI/old.txt").read_text(), "old")
            self.assertEqual((backup / "FightBotLoad.lua").read_text(), "old-loader")
            self.assertEqual(json.loads((backup / cfg.name).read_text()), old_cfg)
            settings = json.loads(cfg.read_text())
            self.assertEqual(settings["Nested"], old_cfg["Nested"])
            self.assertTrue(settings["EnableLuaDebugger"])
            self.assertFalse(cfg.read_bytes().startswith(b"\xef\xbb\xbf"))
            self.assertEqual((se / "FightRec.lua").read_text(), "unchanged")

    def test_invalid_settings_fail_before_replacing_mod(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            se, bin_dir = base / "se", base / "bin"
            (se / "BG3AI").mkdir(parents=True)
            bin_dir.mkdir()
            (se / "BG3AI/old.txt").write_text("keep")
            (bin_dir / "bg3.exe").write_bytes(b"test-only")
            (bin_dir / "ScriptExtenderSettings.json").write_text("invalid-json")
            result = self.ps("-File", ROOT / "fightbot/install.ps1", "-GameBin", bin_dir, "-ScriptExtenderDir", se)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((se / "BG3AI/old.txt").read_text(), "keep")
            self.assertFalse((se / "FightBotBackups").exists())

    def test_launcher_has_only_scoped_tools_and_one_native_connection(self):
        result = self.ps("-File", ROOT / "fightbot/run.ps1", "-ReadOnly", "-Headless", "-PrintOnly")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout)
        args = config["args"]
        self.assertIn("--tools=", args)
        self.assertIn("--strict-mcp-config", args)
        self.assertEqual(args[args.index("--model") + 1], "claude-opus-5-5")
        mcp = config["mcp_config"]["mcpServers"]
        self.assertEqual(set(mcp), {"fightbot"})
        self.assertEqual(mcp["fightbot"]["env"]["BG3AI_RPC_CONNS"], "1")
        self.assertEqual(mcp["fightbot"]["env"]["BG3AI_JOB_PUSH"], "0")
        allowed = args[args.index("--allowedTools") + 1]
        self.assertNotIn("__cast", allowed)
        self.assertNotIn("__move", allowed)


if __name__ == "__main__":
    unittest.main()
