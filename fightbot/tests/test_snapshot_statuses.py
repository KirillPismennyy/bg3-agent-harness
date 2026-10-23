"""Offline execution of generated server snapshot code; never connects to BG3."""
import json
from pathlib import Path
import sys
import unittest
try:
    from lupa.lua54 import LuaRuntime
except ImportError:
    LuaRuntime = None
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE if (HERE / "trial_capture.py").exists() else HERE.parent))
from trial_capture import snapshot_code


@unittest.skipIf(LuaRuntime is None, "Optional lupa Lua 5.4 runtime required")
class SnapshotStatusChecks(unittest.TestCase):
    def snapshot(self, mutation=""):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''
entities={}; lookup_count=0; clock=100
local function entity(handle,hp)
 return {handle=handle,Transform={Transform={Translate={1,2,3}}},
  Health={Hp=hp,MaxHp=hp,TemporaryHp=0},Stats={SpellCastingAbility="Wisdom",ProficiencyBonus=2},
  SpellBook={Spells={}},ActionResources={Resources={}},StatusContainer={Statuses={}}}
end
entities.actor=entity(144115222435628104,17)
entities.target=entity(144115222435633717,19)
function add(who,handle,id,active)
 local s={handle=handle,ServerStatus={StatusId=id,Type="BOOST"},
  ServerStatusOwnership={Owner=entities[who]},StatusLifetime={Lifetime=12.5},
  HasRawComponent=function(self,name) assert(name=="esv::status::ActiveComponent"); return active end}
 entities[who].StatusContainer.Statuses[s]=id
 return s
end
a=add("actor",144115235320525612,"VINES",true)
b=add("actor",144115235320525613,"VINES",false)
t=add("target",144115222435698110,"ENABLE_AOO",true)
Ext={Utils={MonotonicTime=function()clock=clock+1;return clock end,
 HandleToInteger=function(h)assert(type(h)=="table");return h.handle end},
 Entity={Get=function(id)
  assert(type(id)~="number","numeric argument would be a NetId")
  if type(id)=="table" then lookup_count=lookup_count+1; return id end
  return entities[id]
 end},Json={Parse=function(v)if type(v)=="string" then return {actor="actor",target="target",spell="Projectile_FireBolt"}else return v end end,
 Stringify=function(v)return v end}}
BG3AI={Guard={resources=function()return {}end},rpc=function()return {ok=true,result={}}end}
FightRecV2={source_content_sha256="test"}
''')
        lua.execute(mutation)
        result=lua.execute(snapshot_code("actor","target","Projectile_FireBolt"))
        return result,lua

    def facet(self,result,who="actor"):
        native=result["native_"+who]
        self.assertTrue(native["ok"],native["error"])
        return native["result"]["status_container_entries"]

    def test_duplicate_ids_keep_distinct_exact_instances_and_active_false(self):
        result,lua=self.snapshot()
        facet=self.facet(result)
        self.assertTrue(facet["ok"],facet["error"])
        data=facet["result"]
        rows=list(data["rows"].values())
        self.assertEqual([r["instance"] for r in rows],["144115235320525612","144115235320525613"])
        self.assertEqual([r["active"] for r in rows],[True,False])
        self.assertEqual(data["owner_handle"],"144115222435628104")
        self.assertEqual(data["owner_uuid"],"actor")
        self.assertEqual(data["count"],2)
        self.assertFalse(data["absence_proven"])
        self.assertFalse(data["global_scan_performed"])
        self.assertLess(data["begin_ms"],data["end_ms"])
        self.assertEqual(lua.globals().lookup_count,3)
        self.assertEqual(rows[0]["lifetime"]["result"]["raw_value"],12.5)
        self.assertEqual(rows[0]["lifetime"]["result"]["units"],"unqualified")
        self.assertFalse(data["lifecycle_semantics_qualified"])

    def test_absent_container_is_unknown_preserving_hp_and_resources(self):
        result,_=self.snapshot("entities.target.StatusContainer=nil")
        f=self.facet(result,"target")
        self.assertFalse(f["ok"]);self.assertIsNone(f["result"])
        self.assertIn("absence not established",f["error"])
        target=result["native_target"]["result"]
        self.assertEqual(target["hp"],19)
        self.assertTrue(target["raw_resource_entries"]["ok"])
        self.assertTrue(self.facet(result)["ok"])

    def test_empty_present_container_is_zero_listed_not_global_absence(self):
        result,_=self.snapshot("entities.target.StatusContainer.Statuses={}")
        f=self.facet(result,"target")
        self.assertTrue(f["ok"]);self.assertEqual(f["result"]["count"],0)
        self.assertFalse(f["result"]["absence_proven"])

    def test_bad_identity_owner_handle_active_and_iteration_fail_whole_facet(self):
        mutations=[
            't.ServerStatus.StatusId="OTHER"',
            't.ServerStatusOwnership.Owner=entities.actor',
            't.ServerStatusOwnership=nil',
            't.ServerStatus=nil',
            't.handle=0',
            't.handle=1.5',
            't.HasRawComponent=function()return nil end',
            'entities.target.StatusContainer.Statuses=nil',
            'Ext.Entity.Get=function(id)if id==t then return a end;return entities[id]end',
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                result,_=self.snapshot(mutation)
                facet=self.facet(result,"target")
                self.assertFalse(facet["ok"]);self.assertIsNone(facet["result"])
                self.assertEqual(result["native_target"]["result"]["hp"],19)

    def test_late_failure_never_publishes_partial_statuses(self):
        result,_=self.snapshot('b.ServerStatusOwnership.Owner=entities.target')
        f=self.facet(result)
        self.assertFalse(f["ok"]);self.assertIsNone(f["result"])
        self.assertTrue(self.facet(result,"target")["ok"])

    def test_lifetime_missing_nonfinite_and_getter_error_stay_independent(self):
        for mutation in ['a.StatusLifetime=nil','a.StatusLifetime={Lifetime=0/0}',
                         'a.StatusLifetime={Lifetime=math.huge}',
                         'a.StatusLifetime=setmetatable({},{__index=function()error("lifetime fault")end})']:
            with self.subTest(mutation=mutation):
                result,_=self.snapshot(mutation)
                f=self.facet(result)
                self.assertTrue(f["ok"],f["error"])
                rows=list(f["result"]["rows"].values())
                lifetime=rows[0]["lifetime"]
                if mutation=='a.StatusLifetime=nil':
                    self.assertTrue(lifetime["ok"])
                    self.assertFalse(lifetime["result"]["component_present"])
                else:
                    self.assertFalse(lifetime["ok"]);self.assertIsNone(lifetime["result"])

    def test_strict_json_boundary_keeps_decimal_string_instances(self):
        result,_=self.snapshot()
        def convert(value):
            if hasattr(value,"items"):
                return {str(k):convert(v) for k,v in value.items()}
            return value
        encoded=json.dumps(convert(result),allow_nan=False)
        decoded=json.loads(encoded)
        instance=decoded["native_actor"]["result"]["status_container_entries"]["result"]["rows"]["1"]["instance"]
        self.assertEqual(instance,"144115235320525612")


if __name__=="__main__":unittest.main()
