import itertools
import json
import re
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
REPO = Path(os.environ["FIGHTBOT_TEST_REPO"]).resolve() if os.environ.get("FIGHTBOT_TEST_REPO") else HERE.parents[1]
sys.path[:0] = [str(HERE), str(REPO / "fightbot"), str(REPO / "bridge" / "src")]
from trial_owner import TrialOwner, ActionNotReady, TransportUncertain, owned_game
from bg3ai.luadebug import LuaDebugError


class World:
    def __init__(self):
        self.state = "Running"
        self.epoch = 1
        self.client_epoch = None
        self.server_rec = self.client_rec = self.bot = False
        self.rec_active = True
        self.party = 4
        self.entities = 4
        self.combat = True
        self.bound = True
        self.fail = None
        self.calls = []
        self.clients = []
        self.server_hash = self.client_hash = "reviewed-hash"
        self.probe_dir = None
        self.probe_subs = 0

    def factory(self, host, port, **kwargs):
        assert kwargs["protocol_version"] == 5
        client = FakeClient(self)
        self.clients.append(client)
        return client


class FakeClient:
    def __init__(self, world):
        self.world, self.connected = world, False

    def connect(self):
        assert not any(c.connected for c in self.world.clients if c is not self), "second active debugger"
        self.connected = True

    def close(self):
        self.connected = False

    def evaluate(self, code, context, **kwargs):
        w = self.world
        w.calls.append((context, code))
        if not self.connected:
            raise ConnectionError("closed")
        if w.fail and w.fail in code:
            raise TimeoutError("outcome unknown")
        if "trial-owner:client-state" in code:
            return json.dumps(dict(state=w.state,recorder_present=w.client_rec,
                recorder_active=w.client_rec and w.rec_active,recorder_hash=w.client_hash,
                session_id=f"client-{w.client_epoch or w.epoch}" if w.client_rec else None))
        if "trial-owner:server-state" in code:
            return json.dumps(dict(party_count=w.party,party_entities=w.entities,
                recorder_present=w.server_rec,recorder_active=w.server_rec and w.rec_active,
                recorder_hash=w.server_hash,
                bot_present=w.bot,bot_loaded=w.bot,session_id=f"server-{w.epoch}" if w.server_rec else None))
        if "trial-owner:load:FightRec.lua" in code:
            if context == "server": w.server_rec = True
            else: w.client_rec = True
            return "true"
        if "trial-owner:load:FightBotLoad.lua" in code:
            w.bot = True
            return "true"
        if "trial-owner:probe" in code:
            origin="existing"
            if w.probe_dir is None:
                if "local allow_load=true" not in code:
                    raise LuaDebugError("probe unexpectedly absent in this server generation")
                w.probe_dir=json.loads(re.search(r'CastProbe\.DIR=("[^"\n]+")',code).group(1))
                w.probe_subs=4
                origin="fresh_owner_load"
            if w.probe_subs<4:
                raise LuaDebugError("probe lifecycle hooks unavailable")
            return json.dumps(dict(dir=w.probe_dir,origin=origin,subscriptions=w.probe_subs))
        if '"op":"fightbot.identity"' in code:
            combat = f"combat-{w.epoch}"
            return json.dumps(dict(ok=True,result=dict(recorder_active=w.server_rec and w.rec_active,
                session_id=f"server-{w.epoch}",combat_id=combat,file_prefix=f"server-{w.epoch}-fight01",
                party_combats=[combat] if w.bound else [])))
        if '"op":"state.combat"' in code:
            return json.dumps(dict(ok=True,result=dict(active=w.combat,party_can_act=["caster"])))
        return "evaluated"


class OwnerTest(unittest.TestCase):
    def setUp(self):
        self.world = World()
        counter = itertools.count()
        self.owner = TrialOwner(client_factory=self.world.factory, token_factory=lambda:f"token-{next(counter)}", probe=True)
        self.addCleanup(self.owner.close)

    def test_missing_globals_loaded_once_both_contexts_one_connection(self):
        state = self.owner.poll()
        self.assertTrue(state["ready"])
        self.assertEqual([(x["loaded"],x["context"]) for x in self.owner.events if "loaded" in x],
            [("FightRec.lua","server"),("FightRec.lua","client"),("FightBotLoad.lua","server")])
        loads = len(self.owner.events)
        self.assertEqual(self.owner.poll()["ready_token"],state["ready_token"])
        self.assertEqual(len(self.owner.events),loads)
        self.assertEqual(len(self.world.clients),1)

    def test_loading_or_missing_party_prevents_loads_and_bot_action(self):
        self.world.state="LoadLevel"
        self.assertFalse(self.owner.poll()["ready"])
        self.assertEqual(self.owner.events,[])
        called=[]
        with self.assertRaises(ActionNotReady): self.owner.run_action("anything",lambda:called.append(True))
        self.assertEqual(called,[])
        self.world.state="Running";self.world.entities=3
        self.assertEqual(self.owner.poll()["reason"],"party_not_ready")
        self.assertEqual(self.owner.events,[])

    def test_reload_rearms_on_same_connection_new_identity_and_unique_probe(self):
        first=self.owner.poll()
        self.world.epoch+=1
        self.world.server_rec=self.world.client_rec=self.world.bot=False
        self.world.probe_dir=None
        second=self.owner.poll()
        self.assertTrue(second["ready"])
        self.assertNotEqual(first["ready_token"],second["ready_token"])
        self.assertNotEqual(first["server_session"],second["server_session"])
        dirs=[e["probe_dir"] for e in self.owner.events if "probe_dir" in e]
        self.assertEqual(len(dirs),2)
        self.assertNotEqual(*dirs)
        self.assertEqual(len(self.world.clients),1)
        with self.assertRaises(ActionNotReady): self.owner.run_action(first["ready_token"],lambda:self.fail("stale action issued"))

    def test_unbound_combat_or_inactive_recorders_do_not_qualify(self):
        self.world.bound=False
        self.assertFalse(self.owner.poll()["ready"])
        self.world.bound=True;self.world.rec_active=False
        self.assertFalse(self.owner.poll()["ready"])
        self.assertIn("inactive",self.owner.status["reason"])

    def test_action_is_single_attempt_and_consumes_ready_token(self):
        token=self.owner.poll()["ready_token"]
        calls=[]
        self.assertEqual(self.owner.run_action(token,lambda:calls.append(1) or "ok"),"ok")
        with self.assertRaises(ActionNotReady): self.owner.run_action(token,lambda:calls.append(2))
        self.assertEqual(calls,[1])

    def test_uncertain_action_never_retries_and_reconnect_only_later_poll(self):
        token=self.owner.poll()["ready_token"]
        self.world.fail="MUTATION"
        with self.assertRaises(TransportUncertain):
            self.owner.run_action(token,lambda:self.owner.evaluate("MUTATION",context="server"))
        self.assertEqual(sum(code=="MUTATION" for _,code in self.world.calls),1)
        self.assertEqual(len(self.world.clients),1)
        self.assertFalse(self.world.clients[0].connected)
        self.assertEqual(self.owner.status["reason"],"action_outcome_unknown_no_retry")
        self.world.fail=None
        state=self.owner.poll()
        self.assertFalse(state["ready"])
        self.assertTrue(state["needs_resolution"])
        self.assertEqual(len(self.world.clients),2)
        with self.assertRaises(ActionNotReady): self.owner.run_action(token,lambda:self.fail("uncertain prior action"))
        self.assertEqual(self.owner.evaluate("READ_ONLY"),"evaluated")
        self.owner.acknowledge_resolution("inspected cast and resources; prior cast resolved")
        self.assertTrue(self.owner.poll()["ready"])

    def test_hash_unknown_mismatch_and_expected_build_refuse_ready(self):
        for server,client,expected in ((None,"hash",None),("hash",None,None),("a","b",None),("a","a","reviewed")):
            self.world.server_hash,self.world.client_hash=server,client
            self.owner.expected_recorder_hash=expected
            state=self.owner.poll()
            self.assertFalse(state["ready"])
            self.assertEqual(state["server_recorder_hash"],server)
            self.assertEqual(state["client_recorder_hash"],client)
        self.world.server_hash=self.world.client_hash="reviewed"
        self.assertTrue(self.owner.poll()["ready"])

    def test_client_only_reset_retains_same_server_probe_directory(self):
        first=self.owner.poll()
        directory=first["probe"]["dir"]
        self.world.client_epoch=2
        self.world.client_rec=False
        second=self.owner.poll()
        self.assertTrue(second["ready"])
        self.assertNotEqual(first["client_session"],second["client_session"])
        self.assertEqual(second["probe"]["dir"],directory)
        self.assertEqual(len([x for x in self.owner.events if "probe_dir" in x]),1)

    def test_existing_active_probe_keeps_directory_and_discloses_origin(self):
        self.world.probe_dir="FightBotProbe/preexisting/"
        self.world.probe_subs=4
        state=self.owner.poll()
        self.assertTrue(state["ready"])
        self.assertEqual(state["probe"]["dir"],"FightBotProbe/preexisting/")
        self.assertEqual(state["probe"]["origin"],"existing")

    def test_stopped_missing_or_retargeted_probe_invalidates_same_generation(self):
        self.assertTrue(self.owner.poll()["ready"])
        original=self.world.probe_dir
        self.world.probe_subs=0
        self.assertFalse(self.owner.poll()["ready"])
        self.world.probe_subs=4;self.world.probe_dir=None
        self.assertFalse(self.owner.poll()["ready"])
        self.world.probe_dir=original+"changed/"
        self.assertFalse(self.owner.poll()["ready"])

    def test_pending_action_requires_resolution_or_new_server_generation(self):
        for status in ("still_running","timeout"):
            token=self.owner.poll()["ready_token"]
            self.assertEqual(self.owner.run_action(token,lambda:{"status":status})["status"],status)
            self.assertFalse(self.owner.poll()["ready"])
            with self.assertRaises(ActionNotReady): self.owner.run_action(token,lambda:self.fail("pending action"))
            with self.assertRaises(ValueError): self.owner.acknowledge_resolution("")
            self.owner.acknowledge_resolution("inspected completion of previous action")
        token=self.owner.poll()["ready_token"]
        self.owner.run_action(token,lambda:{"status":"still_running"})
        self.world.epoch+=1
        self.world.server_rec=self.world.client_rec=self.world.bot=False
        self.world.probe_dir=None
        self.assertTrue(self.owner.poll()["ready"])
        self.assertFalse(self.owner.status["needs_resolution"])

    def test_owned_game_never_opens_pool_or_push_connection_or_retries_eval(self):
        self.owner.poll()
        game=owned_game(self.owner)
        self.assertFalse(game.job_push)
        self.assertEqual(game.pool_max,1)
        with self.assertRaises(RuntimeError): game._new_client()
        self.world.fail="MUTATION"
        with self.assertRaises(TransportUncertain): game.eval("MUTATION","server")
        self.assertEqual(sum(code=="MUTATION" for _,code in self.world.calls),1)


    def test_callback_exception_after_order_latches_without_retry(self):
        token=self.owner.poll()["ready_token"]
        orders=[]
        def ordered_then_failed():
            orders.append("cast")
            raise LuaDebugError("error after cast order")
        with self.assertRaises(LuaDebugError): self.owner.run_action(token,ordered_then_failed)
        self.assertEqual(orders,["cast"])
        state=self.owner.poll()
        self.assertFalse(state["ready"])
        self.assertTrue(state["needs_resolution"])
        self.assertIn("action_callback_exception",state["reason"])
        with self.assertRaises(ActionNotReady): self.owner.run_action(token,ordered_then_failed)
        self.assertEqual(orders,["cast"])

    def test_known_refusal_result_does_not_latch(self):
        token=self.owner.poll()["ready_token"]
        result=self.owner.run_action(token,lambda:{"status":"failed","error":"refused before order"})
        self.assertEqual(result["status"],"failed")
        self.assertTrue(self.owner.poll()["ready"])
        self.assertFalse(self.owner.status["needs_resolution"])


if __name__ == "__main__": unittest.main()
