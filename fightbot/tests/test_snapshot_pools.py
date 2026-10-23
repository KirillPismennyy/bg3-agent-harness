"""Execute generated snapshot Lua offline; no debugger or game connection."""
from pathlib import Path
import sys
import unittest
try:
    from lupa.lua54 import LuaRuntime
except ImportError:
    LuaRuntime = None
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE if (HERE / "trial_capture.py").is_file() else HERE.parent))
from trial_capture import snapshot_code


@unittest.skipIf(LuaRuntime is None, "Optional lupa Lua 5.4 runtime is required for generated-Lua execution")
class SnapshotPoolChecks(unittest.TestCase):
    def snapshot(self, mutation=""):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''
entities={}
local function entity(hp,amount)
 return {Transform={Transform={Translate={1,2,3}}},Health={Hp=hp,MaxHp=hp,TemporaryHp=0},
  Stats={SpellCastingAbility="Wisdom",ProficiencyBonus=2},SpellBook={Spells={}},
  ActionResources={Resources={movement={{Level=0,Amount=amount,MaxAmount=9}},
   spellslot={{Level=1,Amount=0,MaxAmount=3},{Level=2,Amount=1,MaxAmount=2}}}}}
end
entities.actor=entity(17,5.549888997280449)
entities.target=entity(19,2.25)
calls={}
Ext={Utils={MonotonicTime=function()return 100 end},
 Entity={Get=function(id)return entities[id]end},Json={
 Parse=function(value)if type(value)=="string" then return {actor="actor",target="target",spell="Projectile_FireBolt"}else return value end end,
 Stringify=function(value)return value end}}
BG3AI={Guard={resources=function(id)return {Movement={[0]=entities[id].ActionResources.Resources.movement[1].Amount}}end},
 rpc=function(request)calls[#calls+1]=request.op;return {ok=true,result={}}end}
FightRecV2={source_content_sha256="test-recorder"}
''')
        lua.execute(mutation)
        result = lua.execute(snapshot_code("actor", "target", "Projectile_FireBolt"))
        self.assertEqual(list(lua.globals().calls.values()), ["fightbot.identity", "state.combat", "state.character", "state.entity", "state.actions", "fightbot.identity"])
        self.assertFalse(result["validated_status_inventory"]["ok"], "Incomplete mock identity must fail the independent inventory facet")
        return result, lua

    def rows(self, result, who):
        native = result["native_" + who]
        self.assertTrue(native["ok"])
        read = native["result"]["raw_resource_entries"]
        self.assertTrue(read["ok"], read["error"])
        pools = read["result"]
        self.assertEqual(pools["count"], 3)
        self.assertEqual(pools["precision"], "unrounded")
        return {(row["resource_uuid"], row["level"]): row for row in pools["rows"].values()}

    def test_both_native_pool_sets_preserve_precision_levels_and_zero(self):
        result, lua = self.snapshot()
        actor, target = self.rows(result, "actor"), self.rows(result, "target")
        self.assertEqual(actor["movement", 0]["amount"], 5.549888997280449)
        self.assertEqual(target["movement", 0]["amount"], 2.25)
        self.assertEqual(target["movement", 0]["max_amount"], 9)
        self.assertEqual(actor["spellslot", 1]["amount"], 0)
        self.assertEqual(actor["spellslot", 2]["amount"], 1)
        self.assertEqual(lua.globals().entities.actor.ActionResources.Resources.movement[1].Amount, 5.549888997280449)

    def test_missing_component_is_unknown_without_erasing_hp_snapshot(self):
        result, _ = self.snapshot("entities.target.ActionResources=nil")
        target = result["native_target"]["result"]
        self.assertEqual(target["hp"], 19)
        read = target["raw_resource_entries"]
        self.assertFalse(read["ok"])
        self.assertIsNone(read["result"])
        self.assertIn("component unavailable", read["error"])

    def test_incomplete_row_never_publishes_partial_pool_result(self):
        result, _ = self.snapshot("entities.target.ActionResources.Resources.spellslot[2].MaxAmount=nil")
        read = result["native_target"]["result"]["raw_resource_entries"]
        self.assertFalse(read["ok"])
        self.assertIsNone(read["result"])
        self.assertIn("pool fields unavailable", read["error"])
        self.rows(result, "actor")

    def test_nonfinite_pools_are_unknown_and_cannot_poison_snapshot(self):
        for field in ("Amount", "MaxAmount"):
            for value in ("0/0", "math.huge", "-math.huge"):
                with self.subTest(field=field, value=value):
                    result, _ = self.snapshot(f"entities.target.ActionResources.Resources.movement[1].{field}={value}")
                    target = result["native_target"]["result"]
                    self.assertEqual(target["hp"], 19)
                    self.assertFalse(target["raw_resource_entries"]["ok"])
                    self.assertIsNone(target["raw_resource_entries"]["result"])
                    self.rows(result, "actor")

    def test_noninteger_resource_level_is_unknown(self):
        for value in ("0/0", "math.huge", "-math.huge", "1.5", '"1"'):
            with self.subTest(value=value):
                result, _ = self.snapshot(f"entities.target.ActionResources.Resources.movement[1].Level={value}")
                self.assertFalse(result["native_target"]["result"]["raw_resource_entries"]["ok"])


if __name__ == "__main__":
    unittest.main()
