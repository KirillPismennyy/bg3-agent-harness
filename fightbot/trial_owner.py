"""One persistent debugger owner. No polling thread or automatic action retries."""
from __future__ import annotations

import json
import threading
import uuid
from typing import Callable

from bg3ai.luadebug import LuaDebugClient, LuaDebugError


class ActionNotReady(RuntimeError):
    pass


class TransportUncertain(RuntimeError):
    """The request may have executed. Never retry it automatically."""


CLIENT_STATE = '''-- trial-owner:client-state
return Ext.Json.Stringify({state=tostring(Ext.Utils.GetGameState()),
 recorder_present=FightRecV2~=nil,
 recorder_active=FightRecV2 and FightRecV2.generation and FightRecV2.generation.active or false,
 recorder_hash=FightRecV2 and FightRecV2.source_content_sha256 or nil,
 session_id=FightRecV2 and FightRecV2.session_id or nil})'''

SERVER_STATE = '''-- trial-owner:server-state
local players=Osi.DB_Players:Get(nil)
local present=0
for _,row in ipairs(players) do if Ext.Entity.Get(row[1]) then present=present+1 end end
return Ext.Json.Stringify({party_count=#players,party_entities=present,
 recorder_present=FightRecV2~=nil,
 recorder_active=FightRecV2 and FightRecV2.generation and FightRecV2.generation.active or false,
 recorder_hash=FightRecV2 and FightRecV2.source_content_sha256 or nil,
 bot_present=BG3AI~=nil,bot_loaded=BG3AI and BG3AI.FightBotLoaded==true or false,
 session_id=FightRecV2 and FightRecV2.session_id or nil})'''


class TrialOwner:
    def __init__(self, *, host="127.0.0.1", port=9998, probe=False,
                 client_factory=LuaDebugClient, token_factory=lambda: uuid.uuid4().hex,
                 expected_recorder_hash=None):
        self.host, self.port, self.probe = host, port, probe
        self._factory, self._token_factory = client_factory, token_factory
        self.expected_recorder_hash = expected_recorder_hash
        self._client = None
        self._lock = threading.RLock()
        self._command_lock = threading.RLock()
        self._generation = None
        self._probe_generation = None
        self._probe_info = None
        self._needs_resolution = False
        self._blocked_server = None
        self._resolution_reason = None
        self._token = None
        self.status = {"ready": False, "reason": "not_checked"}
        self.events = []

    def invalidate(self, reason):
        self._token = None
        self.status = {"ready": False, "reason": reason, "needs_resolution": self._needs_resolution}

    def require_resolution(self, reason):
        self._needs_resolution = True
        self._blocked_server = self._generation[0] if self._generation else None
        self._resolution_reason = reason
        self.invalidate(reason)

    def acknowledge_resolution(self, note):
        """Explicit operator acknowledgement after inspecting/resolving prior action."""
        if not isinstance(note, str) or not note.strip():
            raise ValueError("inspection/resolution note required")
        with self._command_lock:
            self.events.append({"resolution_acknowledged": note})
            self._needs_resolution, self._blocked_server = False, None
            self._resolution_reason = None
            self.invalidate("resolution_acknowledged_recheck_required")
            return dict(self.status)

    def _connection(self):
        if self._client is None:
            client = self._factory(self.host, self.port, protocol_version=5, connect_timeout=3)
            try:
                client.connect()
            except BaseException:
                client.close()
                raise
            self._client = client
        return self._client

    def evaluate(self, code, context="client", timeout=5.0, statement=None):
        """Single attempt on the one owned connection. No action replay on failure."""
        with self._lock:
            try:
                return self._connection().evaluate(code, context=context, timeout=timeout, statement=statement)
            except (OSError, ConnectionError, TimeoutError) as exc:
                self.require_resolution("transport_uncertain")
                if self._client is not None:
                    self._client.close()
                self._client = None
                raise TransportUncertain("request outcome unknown; inspect or reload before retrying") from exc

    def _json(self, code, context):
        return json.loads(self.evaluate(code, context=context, statement=True))

    def _load(self, filename, context):
        code = ('-- trial-owner:load:' + filename + '\n'
                'assert(Ext.Utils.LoadString(assert(Ext.IO.LoadFile(' + json.dumps(filename) + '))))()\nreturn true')
        self.evaluate(code, context=context, statement=True)
        self.events.append({"loaded": filename, "context": context})

    def _rpc(self, op):
        payload = json.dumps({"op": op, "args": {}}, separators=(",", ":"))
        reply = self._json('return BG3AI.rpc([=[' + payload + ']=])', "server")
        if not reply.get("ok"):
            raise ActionNotReady(reply.get("error") or "readiness RPC unavailable")
        return reply.get("result") or {}

    def poll(self):
        """Call serially between commands. READY cannot cover earlier human input."""
        with self._command_lock, self._lock:
            provenance = {}
            try:
                client = self._json(CLIENT_STATE, "client")
                if client.get("state") != "Running":
                    self.invalidate("client_not_running")
                    return self.status
                server = self._json(SERVER_STATE, "server")
                if server.get("party_count", 0) < 1 or server.get("party_entities") != server.get("party_count"):
                    self.invalidate("party_not_ready")
                    return self.status
                # Existing but inactive/partial generations cannot be safely hot-loaded.
                if server.get("recorder_present") and not server.get("recorder_active"):
                    raise ActionNotReady("server recorder inactive; lifecycle reset required")
                if client.get("recorder_present") and not client.get("recorder_active"):
                    raise ActionNotReady("client recorder inactive; lifecycle reset required")
                if server.get("bot_present") and not server.get("bot_loaded"):
                    raise ActionNotReady("partial bot load; lifecycle reset required")
                if not server.get("recorder_present"):
                    self._load("FightRec.lua", "server")
                if not client.get("recorder_present"):
                    self._load("FightRec.lua", "client")
                if not server.get("bot_present"):
                    self._load("FightBotLoad.lua", "server")
                identity = self._rpc("fightbot.identity")
                combat = self._rpc("state.combat")
                # Read client again after loading; require both recorder contexts.
                client = self._json(CLIENT_STATE, "client")
                server = self._json(SERVER_STATE, "server")
                server_hash, client_hash = server.get("recorder_hash"), client.get("recorder_hash")
                provenance = {"server_recorder_hash": server_hash, "client_recorder_hash": client_hash,
                              "expected_recorder_hash": self.expected_recorder_hash}
                if not isinstance(server_hash, str) or not server_hash or not isinstance(client_hash, str) or not client_hash:
                    raise ActionNotReady("recorder source hash unavailable")
                if server_hash != client_hash:
                    raise ActionNotReady("server/client recorder source hashes differ")
                if self.expected_recorder_hash is not None and server_hash != self.expected_recorder_hash:
                    raise ActionNotReady("recorder source hash differs from expected reviewed build")
                if (client.get("state") != "Running" or not client.get("recorder_active")
                        or not client.get("session_id") or not identity.get("recorder_active")
                        or not identity.get("session_id")):
                    raise ActionNotReady("both active recorder contexts required")
                if server.get("session_id") != identity.get("session_id") or not server.get("recorder_active"):
                    raise ActionNotReady("server recorder changed during readiness checks")
                combat_id = identity.get("combat_id")
                if (not combat.get("active") or not combat_id or not identity.get("file_prefix")
                        or combat_id not in (identity.get("party_combats") or [])):
                    raise ActionNotReady("active combat recording not bound yet")
                generation = (identity["session_id"], client["session_id"], combat_id)
                if self._needs_resolution and self._blocked_server is not None and generation[0] != self._blocked_server:
                    self._needs_resolution, self._blocked_server = False, None
                    self._resolution_reason = None
                if generation != self._generation:
                    self._generation, self._token = generation, None
                if self.probe:
                    new_server = self._probe_generation != generation[0]
                    directory = ("FightBotProbe/owner-" + self._token_factory() + "/") if new_server else self._probe_info["dir"]
                    probe_code = ('-- trial-owner:probe\n'
                        'local allow_load=' + ("true" if new_server else "false") + '\n'
                        'local origin="existing"\n'
                        'if CastProbe==nil then\n'
                        ' assert(allow_load,"probe unexpectedly absent in this server generation")\n'
                        ' assert(Ext.Utils.LoadString(assert(Ext.IO.LoadFile("cast_probe.lua"))))()\n'
                        ' CastProbe.DIR=' + json.dumps(directory) + '\n origin="fresh_owner_load"\nend\n'
                        'assert(CastProbe and CastProbe.subs and #CastProbe.subs>=4,"probe lifecycle hooks unavailable")\n'
                        'assert(type(CastProbe.DIR)=="string" and CastProbe.DIR~="","probe directory unavailable")\n'
                        'return Ext.Json.Stringify({dir=CastProbe.DIR,origin=origin,subscriptions=#CastProbe.subs})')
                    info = self._json(probe_code, "server")
                    if not new_server and self._probe_info and info["dir"] != self._probe_info["dir"]:
                        raise ActionNotReady("probe directory changed unexpectedly")
                    if new_server:
                        self._probe_generation = generation[0]
                        self._probe_info = info
                        self.events.append({"probe_dir": info["dir"], "probe_origin": info["origin"],
                                            "server_session": generation[0]})
                    provenance["probe"] = dict(self._probe_info)
                if self._needs_resolution:
                    self.invalidate("needs_resolution: " + str(self._resolution_reason))
                    self.status.update(provenance)
                    self.status.update(server_session=generation[0],client_session=generation[1],combat_id=combat_id)
                    return dict(self.status)
                if self._token is None:
                    self._token = self._token_factory()
                self.status = {"ready": True, "ready_token": self._token,
                    "needs_resolution": False, **provenance,
                    "server_session": generation[0], "client_session": generation[1],
                    "combat_id": combat_id, "file_prefix": identity["file_prefix"],
                    "party_can_act": combat.get("party_can_act") or [],
                    "manual_coverage": "only after READY; polling cannot capture prior human actions"}
                return dict(self.status)
            except (LuaDebugError, ActionNotReady, ValueError, TypeError, KeyError) as exc:
                self.invalidate(str(exc))
                self.status.update(provenance)
                return self.status
            except TransportUncertain:
                return self.status

    def run_action(self, ready_token: str, action: Callable):
        with self._command_lock:
            state = self.poll()
            if not state.get("ready") or ready_token != state.get("ready_token"):
                raise ActionNotReady("fresh READY token required; action was not issued")
            if not state.get("party_can_act"):
                raise ActionNotReady("no party member can act; action was not issued")
            self.invalidate("action_in_progress")  # consume token before any mutation
            try:
                result = action()
                if isinstance(result, dict) and result.get("status") in {"still_running", "timeout"}:
                    self.require_resolution("previous_action_" + result["status"])
                return result
            except TransportUncertain:
                self.require_resolution("action_outcome_unknown_no_retry")
                raise
            except Exception:
                # The callback may already have issued an order before a Lua,
                # decoding, logging or other unexpected exception occurred.
                self.require_resolution("action_callback_exception_outcome_unknown")
                raise

    def close(self):
        with self._lock:
            self.invalidate("closed")
            if self._client is not None:
                self._client.close()
                self._client = None


def owned_game(owner):
    """Reuse Game RPC/job helpers without its connection pool/retry/push path."""
    import os
    os.environ.setdefault("BG3AI_RPC_ROOT", "BG3AI")
    from bg3ai.game import Game, RPC_ROOT
    if RPC_ROOT != "BG3AI":
        raise RuntimeError("import FightBot before Game, or configure BG3AI_RPC_ROOT=BG3AI")

    class OwnedGame(Game):
        def __init__(self):
            super().__init__(owner.host, owner.port, pool_max=1)
            self.job_push = False
            self._ev_synced = True

        def _new_client(self):
            raise RuntimeError("only TrialOwner may open a debugger connection")

        def eval(self, code, context="client", timeout=12.0):
            return owner.evaluate(code, context=context, timeout=timeout)

    return OwnedGame()
