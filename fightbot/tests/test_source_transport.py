"""Source selector crosses the wrapper unchanged alongside ordinary cast arguments."""
import tempfile
import unittest
from pathlib import Path
from test_fightbot import F, FakeGame, P1, IMP1

class SourceTransportTest(unittest.TestCase):
    def test_source_selector_passes_unmodified_with_legacy_args_intact(self):
        source = dict(Prototype="Projectile_FireBolt", OriginatorPrototype="Projectile_FireBolt",
                      SourceType="ProgressionRace", Source="00000000-0000-0000-0000-000000000000",
                      ProgressionSource="30fafb0b-7c8b-4917-bd2a-536233b35d3c",
                      SpellCastingAbility="Intelligence")
        with tempfile.TemporaryDirectory() as folder:
            game = FakeGame()
            bot = F.Bot(game, Path(folder) / "trace.jsonl")
            bot.fight_state()
            game.combat = [{"active": True, "party_can_act": [P1]}]
            result = bot.cast(P1, "Projectile_FireBolt", target=IMP1, source=source)
        self.assertEqual(game.jobs[-1][1], {"char": P1, "spell": "Projectile_FireBolt", "target": IMP1, "source": source})
        self.assertEqual(result["status"], "done")

if __name__ == "__main__":
    unittest.main()
