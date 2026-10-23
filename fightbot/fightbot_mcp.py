#!/usr/bin/env python3
"""FightBot: an MCP server that lets an agent fight Baldur's Gate 3 combats with nothing hidden, and records them.

It talks to the BG3AI mod's server half, loaded in the game by fightbot/FightBotLoad.lua (Windows, bg3se) or as the
mod (Linux, bg3le), over the Script Extender's Lua debugger port. The mod's guarded actions do the work: casts pay
what a UI cast pays, moves follow the engine's paths. Rolls come from FightRec v2's files (fightrec_reader.py): one
recorder in the game, not two. Every tool call and its answer is appended to fightbot/logs/fightbot-<time>.jsonl.
See fightbot/README.md.

    uv run --project bridge python fightbot/fightbot_mcp.py        (Claude Code starts it from fightbot/.mcp.json)
"""
from __future__ import annotations

import functools
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bridge" / "src"))
os.environ.setdefault("BG3AI_RPC_ROOT", "BG3AI")   # FightBotLoad.lua loads the mod as console globals
if sys.platform == "win32":
    # Native bg3se services one debugger connection at a time; the Linux pool/push listener is unsuitable.
    os.environ["BG3AI_RPC_CONNS"] = "1"
    os.environ["BG3AI_JOB_PUSH"] = "0"

from bg3ai.game import Game, GameError, NotReady  # noqa: E402

sys.path.insert(0, str(HERE))
from fightrec_reader import FightRecReader  # noqa: E402

LOG_DIR = Path(os.environ.get("FIGHTBOT_LOG_DIR", HERE / "logs"))
# wait_for_turn reads the turn order when one of these events arrives (events.since is a cheap read), and at least
# every FALLBACK_S: state.combat computes distances and line of sight per combatant, so it isn't polled.
TURN_EVENTS = {"combat_started", "combat_ended", "round_started", "turn_started", "turn_ended", "died", "downed",
               "revived"}
EVENT_POLL_S = 0.3
FALLBACK_S = 5.0
PARTY_SECTIONS = ["abilities", "resources", "conditions"]


class Bot:
    """The tools' logic, without MCP (tests drive it with a fake game and a reader of test files)."""

    def __init__(self, game, log_path: Path | None = None, reader: FightRecReader | None = None,
                 read_only: bool = False):
        self.g = game
        self.log_path = log_path
        self.reader = reader or FightRecReader()
        self.reader.require_binding()
        self.read_only = read_only
        self.recording_identity: dict = {}
        self.ids: dict[str, str] = {}      # uuid -> c1, c2, ...
        self.uuids: dict[str, str] = {}    # c1 -> uuid
        self.names: dict[str, str] = {}    # uuid -> name
        self.roll_stream: str | None = None
        self.roll_seq = 0                  # FightRec seq of the last roll row handed out
        self.ready = False
        self.seen_fight = False   # wait_for_turn reports fight_over only after a fight was seen

    # ---- plumbing ----

    def log(self, tool: str, args: dict, result: Any) -> None:
        if not self.log_path:
            return
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        with self.log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "tool": tool, "args": args,
                                "result": result}, ensure_ascii=False, default=str) + "\n")

    def rpc(self, op: str, args: dict | None = None) -> Any:
        return self.g.rpc(op, args or {}, "server")

    def ensure(self) -> None:
        """Once per process: everything visible (FightBotLoad.lua does it too)."""
        if not self.ready:
            self.rpc("dev.omniscient", {"on": True})
            self.ready = True

    def short(self, uuid: str | None, name: str | None = None) -> str | None:
        if not uuid:
            return None
        if name:
            self.names[uuid] = name
        if uuid not in self.ids:
            sid = f"c{len(self.ids) + 1}"
            self.ids[uuid], self.uuids[sid] = sid, uuid
        return self.ids[uuid]

    def resolve(self, ref: str | None) -> str | None:
        """A c-id, a uuid or a unique name -> uuid."""
        if not ref:
            return None
        ref = ref.strip()
        if ref in self.uuids:
            return self.uuids[ref]
        if ref in self.ids:
            return ref
        hits = [u for u, n in self.names.items() if n and n.lower() == ref.lower()]
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            raise GameError(f"{len(hits)} characters are called {ref!r}: use their id ("
                            + ", ".join(self.ids[u] for u in hits) + ")")
        raise GameError(f"unknown character {ref!r}: call fight_state first and use an id from it")

    def ref(self, uuid: str | None) -> dict | None:
        if not uuid:
            return None
        return {"id": self.short(uuid), "name": self.names.get(uuid)}

    def rolls_since(self, since: int | None = None) -> list[dict]:
        """Roll rows from FightRec's files with seq > since (default: those not handed out yet)."""
        try:
            r = self.reader.rows(0 if since is None else since)
        except OSError:
            return []
        if r["stream"] != self.roll_stream:   # a new fight: its seqs start over
            self.roll_stream, self.roll_seq = r["stream"], 0
        rows = [x for x in r["rows"] if since is not None or x["seq"] > self.roll_seq]
        for row in rows:
            for k in ("attacker", "target", "roller", "against"):
                w = row.get(k)
                if isinstance(w, dict) and w.get("uuid"):
                    row[k] = {"id": self.short(w["uuid"], w.get("name")), "name": w.get("name")}
        if rows:
            self.roll_seq = max(self.roll_seq, max(x["seq"] for x in rows))
        return rows

    def bind_recording(self, identity: dict | None) -> None:
        identity = identity or {}
        if identity.get("session_id") != self.recording_identity.get("session_id"):
            self.reader.bind(None)
            self.roll_stream, self.roll_seq = None, 0
        self.recording_identity = identity
        if identity.get("file_prefix") and identity.get("combat_id"):
            self.reader.bind(identity["file_prefix"], identity["combat_id"])

    @staticmethod
    def checked_pos(pos: list[float] | None) -> list[float] | None:
        if pos is not None and (len(pos) != 3 or any(isinstance(v, bool) or not isinstance(v, (int, float))
                                                   or not math.isfinite(v) for v in pos)):
            raise GameError("position must contain exactly three finite numbers [x, y, z]")
        return pos

    # ---- tools ----

    def fight_state(self) -> dict:
        """Two game calls: status + turn order, then every party sheet and enemy examine in one batch."""
        self.ensure()
        st, cb, identity = self.g.multi([("state.status", {}), ("state.combat", {}), ("fightbot.identity", {})])
        self.bind_recording(identity)
        if st is None or cb is None:
            raise GameError("the game did not answer state.status / state.combat")
        party_rows = st.get("party") or []
        others = [o for o in cb.get("order") or [] if o.get("relation") != "party"]
        calls = [("state.character", {"uuid": p.get("uuid"), "sections": PARTY_SECTIONS}) for p in party_rows]
        calls += [("state.entity", {"uuid": o.get("uuid")}) for o in others]
        details = self.g.multi(calls) if calls else []
        sheets, exams = details[:len(party_rows)], dict(zip([o.get("uuid") for o in others], details[len(party_rows):]))

        out: dict[str, Any] = {"in_combat": bool(cb.get("active")), "round": cb.get("round")}
        party = []
        for p, ch in zip(party_rows, sheets):
            u = p.get("uuid")
            self.short(u, p.get("name"))
            row = {"id": self.ids.get(u), **{k: v for k, v in p.items() if k != "uuid"}}
            if ch is None:
                row["sheet_error"] = "no answer"
            else:
                row.update({k: ch[k] for k in ("ac", "abilities", "saves", "resources", "statuses", "concentration")
                            if ch.get(k) is not None})
            party.append(row)
        out["party"] = party
        order = []
        for o in cb.get("order") or []:
            u = o.get("uuid")
            self.short(u, o.get("name"))
            row = {"id": self.ids.get(u), **{k: v for k, v in o.items() if k != "uuid"}}
            if o.get("relation") != "party":
                ex = exams.get(u)
                if ex is None:
                    row["examine_error"] = "no answer"
                else:
                    row.update({k: ex[k] for k in ("hp", "max_hp", "temp_hp", "ac", "abilities", "saves",
                                                   "resistances", "statuses", "level", "classes", "dead")
                                if ex.get(k) is not None})
            order.append(row)
        out["turn_order"] = order
        out["current"] = self.ref(cb.get("current"))
        out["party_can_act"] = [self.ref(u) for u in cb.get("party_can_act") or []]
        out["new_rolls"] = self.rolls_since()
        out["recording"] = {**self.recording_identity, "read_issues": self.reader.read_issues}
        out["read_only"] = self.read_only
        return out

    def actions(self, char: str) -> dict:
        self.ensure()
        u = self.resolve(char)
        r = self.rpc("state.actions", {"uuid": u}) or {}
        acts = []
        for a in r.get("actions") or []:
            acts.append({k: a[k] for k in ("spell", "name", "level", "cost", "range", "target", "available", "reason", "sources")
                         if k in a})
        return {"char": self.ref(u), "resources": r.get("resources"), "actions": acts}

    def _act(self, op: str, args: dict, wait_s: float = 40.0) -> dict:
        """The job's own outcome (hits and damage as the game reported them). Its rolls reach FightRec's files
        within FLUSH_MS and come with the next fight_state / wait_for_turn: no waiting here."""
        if self.read_only:
            raise GameError("actions are disabled in read-only preflight mode")
        self.ensure()
        cb, identity = self.g.multi([("state.combat", {}), ("fightbot.identity", {})])
        self.bind_recording(identity)
        if not cb or not cb.get("active"):
            raise GameError("fightbot refuses actions outside combat")
        if args.get("char") not in (cb.get("party_can_act") or []):
            raise GameError("actor is not a party member able to act this turn")
        if (not identity or not identity.get("recorder_active") or not identity.get("file_prefix")
                or identity.get("combat_id") not in (identity.get("party_combats") or [])):
            raise GameError("current combat is not bound to an active FightRec recording")
        jr = self.g.run_job(op, args, "server", wait_s=wait_s)
        out = {"status": jr.status}
        if jr.result is not None:
            out["result"] = jr.result
        if jr.error:
            out["error"] = jr.error
        return out

    def cast(self, char: str, spell: str, target: str | None = None, pos: list[float] | None = None) -> dict:
        args: dict[str, Any] = {"char": self.resolve(char), "spell": spell}
        if target:
            args["target"] = self.resolve(target)
        if pos is not None:
            args["pos"] = self.checked_pos(pos)
        return self._act("act.cast", args)

    def move(self, char: str, target: str | None = None, pos: list[float] | None = None) -> dict:
        args: dict[str, Any] = {"char": self.resolve(char)}
        if target:
            args["target"] = self.resolve(target)
        elif pos is not None:
            args["pos"] = self.checked_pos(pos)
        else:
            raise GameError("move needs a target id or a pos [x, y, z]")
        return self._act("act.move_to", args)

    def end_turn(self, char: str) -> dict:
        return self._act("act.end_turn", {"char": self.resolve(char)}, wait_s=15.0)

    def wait_for_turn(self, timeout_s: float = 180.0) -> dict:
        """Until a party member can act, or the fight is over. Before any fight it waits for one to start."""
        self.ensure()
        t0 = time.time()
        check, last_check = True, 0.0
        while time.time() - t0 < timeout_s:
            if check or time.time() - last_check >= FALLBACK_S:
                check, last_check = False, time.time()
                try:
                    cb = self.rpc("state.combat") or {}
                except NotReady:
                    time.sleep(1.0)
                    continue
                if not cb.get("active"):
                    if self.seen_fight:
                        self.seen_fight = False
                        return {"fight_over": True, "new_rolls": self.rolls_since()}
                else:
                    self.seen_fight = True
                    if cb.get("party_can_act"):
                        return {"your_turn": True, "state": self.fight_state()}
            try:
                evs = self.g.drain_events("server")
            except NotReady:
                time.sleep(1.0)
                continue
            if any(e.get("kind") in TURN_EVENTS for e in evs):
                check = True
            else:
                time.sleep(EVENT_POLL_S)
        return {"timeout": True, "waited_s": round(time.time() - t0)}

    def rolls(self, since: int = 0) -> dict:
        self.bind_recording(self.rpc("fightbot.identity"))
        rows = self.rolls_since(since)
        return {"rows": rows, "latest": self.roll_seq, "fight": self.roll_stream,
                "recording": self.recording_identity, "read_issues": self.reader.read_issues}


def build_server(bot: Bot):
    from mcp.server.mcpserver import MCPServer

    srv = MCPServer("fightbot", instructions=(
        "You fight Baldur's Gate 3 combats for the party using omniscient observations. Respect missing fields, "
        "recording.read_issues and each roll's evidence flags; do not assume complete roll/status coverage. "
        "Loop: wait_for_turn -> plan from fight_state/actions -> cast/move -> end_turn, "
        "until wait_for_turn says fight_over. Characters are referred to by the ids fight_state gives (c1, c2, ...)."))

    def tool(fn):
        if bot.read_only and fn.__name__ in {"cast", "move", "end_turn"}:
            return fn
        @functools.wraps(fn)   # the SDK reads the parameters from the wrapped signature
        def wrapper(**kw):
            try:
                res = fn(**kw)
            except (GameError, NotReady) as e:
                res = {"error": str(e)}
            bot.log(fn.__name__, kw, res)
            return res
        return srv.tool()(wrapper)

    @tool
    def fight_state() -> dict:
        """Everything about the fight: round, whose turn, the party (HP, AC, abilities, saves, resources, statuses,
        position) and every combatant in turn order (HP, AC, statuses, resistances, position, initiative), plus the
        last rolls. Nothing is filtered."""
        return bot.fight_state()

    @tool
    def actions(char: str) -> dict:
        """What a party member can do now: each action's spell id (pass it to cast), cost, range, target kind and
        whether it is available, plus the action/bonus/movement/slots left."""
        return bot.actions(char)

    @tool
    def cast(char: str, spell: str, target: str | None = None, pos: list[float] | None = None) -> dict:
        """Use an action: an attack, spell, Dash, Shove, Jump, Hide, a potion... `spell` is the id from actions,
        `target` a combatant id, or `pos` [x, y, z] for a ground target. Returns the outcome and its rolls."""
        return bot.cast(char=char, spell=spell, target=target, pos=pos)

    @tool
    def move(char: str, target: str | None = None, pos: list[float] | None = None) -> dict:
        """Walk to a combatant (next to it) or to a position [x, y, z], using the movement left this turn."""
        return bot.move(char=char, target=target, pos=pos)

    @tool
    def end_turn(char: str) -> dict:
        """End this party member's turn."""
        return bot.end_turn(char=char)

    @tool
    def wait_for_turn(timeout_s: float = 180.0) -> dict:
        """Wait while enemies act, until a party member can act (returns the fight state) or the fight is over."""
        return bot.wait_for_turn(timeout_s=timeout_s)

    @tool
    def rolls(since: int = 0) -> dict:
        """Every attack and damage roll of the current fight since a sequence number (FightRec's seq): d20 natural
        and total vs AC, advantage, damage dealt and its dice. Misses and passed saves appear without numbers
        (the engine gives none). fight_state and wait_for_turn already include the rolls you haven't seen."""
        return bot.rolls(since=since)

    return srv


def main() -> None:
    game = Game(port=int(os.environ.get("FIGHTBOT_PORT", os.environ.get("BG3LE_DEBUG_PORT", "9998"))))
    bot = Bot(game, LOG_DIR / time.strftime("fightbot-%Y%m%d-%H%M%S.jsonl"),
              read_only=os.environ.get("FIGHTBOT_READ_ONLY") == "1")
    build_server(bot).run("stdio")


if __name__ == "__main__":
    main()
