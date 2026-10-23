#!/usr/bin/env python3
"""FightBot: an MCP server that lets an agent fight Baldur's Gate 3 combats with nothing hidden, and records them.

It talks to the BG3AI mod's server half, loaded in the game by fightbot/FightBotLoad.lua (Windows, bg3se) or as the
mod (Linux, bg3le), over the Script Extender's Lua debugger port. The mod's guarded actions do the work: casts pay
what a UI cast pays, moves follow the engine's paths. Every tool call and its answer is appended to
fightbot/logs/fightbot-<time>.jsonl. See fightbot/README.md.

    uv run --project bridge python fightbot/fightbot_mcp.py        (Claude Code starts it from fightbot/.mcp.json)
"""
from __future__ import annotations

import functools
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bridge" / "src"))
os.environ.setdefault("BG3AI_RPC_ROOT", "BG3AI")   # FightBotLoad.lua loads the mod as console globals

from bg3ai.game import Game, GameError, NotReady  # noqa: E402

LOG_DIR = Path(os.environ.get("FIGHTBOT_LOG_DIR", HERE / "logs"))
TURN_POLL_S = 0.5


class Bot:
    """The tools' logic, without MCP (tests drive it with a fake game)."""

    def __init__(self, game, log_path: Path | None = None):
        self.g = game
        self.log_path = log_path
        self.ids: dict[str, str] = {}      # uuid -> c1, c2, ...
        self.uuids: dict[str, str] = {}    # c1 -> uuid
        self.names: dict[str, str] = {}    # uuid -> name
        self.roll_seq = 0
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
        """Once per process: everything visible and the roll log on (FightBotLoad.lua does it too)."""
        if self.ready:
            return
        self.rpc("dev.omniscient", {"on": True})
        r = self.rpc("omni.rolls_enable", {"on": True})
        self.roll_seq = int((r or {}).get("seq") or 0)
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

    def _rolls_since(self, since: int) -> list[dict]:
        r = self.rpc("omni.rolls", {"since": since, "limit": 50}) or {}
        rows = r.get("rows") or []
        for row in rows:
            for k in ("attacker", "target", "roller", "against"):
                w = row.get(k)
                if isinstance(w, dict) and w.get("uuid"):
                    row[k] = {"id": self.short(w["uuid"], w.get("name")), "name": w.get("name")}
            row.pop("t", None)
        self.roll_seq = max(self.roll_seq, int(r.get("latest") or 0))
        return rows

    # ---- tools ----

    def fight_state(self) -> dict:
        self.ensure()
        st = self.rpc("state.status") or {}
        cb = self.rpc("state.combat") or {}
        out: dict[str, Any] = {"in_combat": bool(cb.get("active")), "round": cb.get("round")}
        party = []
        for p in st.get("party") or []:
            u = p.get("uuid")
            self.short(u, p.get("name"))
            row = {"id": self.ids.get(u), **{k: v for k, v in p.items() if k != "uuid"}}
            try:
                ch = self.rpc("state.character", {"uuid": u, "sections": ["abilities", "resources", "conditions"]})
                for k in ("ac", "abilities", "saves", "resources", "statuses", "concentration"):
                    if ch.get(k) is not None:
                        row[k] = ch[k]
            except GameError as e:
                row["sheet_error"] = str(e)
            party.append(row)
        out["party"] = party
        order = []
        for o in cb.get("order") or []:
            u = o.get("uuid")
            self.short(u, o.get("name"))
            row = {"id": self.ids.get(u), **{k: v for k, v in o.items() if k != "uuid"}}
            if o.get("relation") != "party":
                try:
                    ex = self.rpc("state.entity", {"uuid": u}) or {}
                    for k in ("hp", "max_hp", "temp_hp", "ac", "abilities", "saves", "resistances", "statuses",
                              "level", "classes", "dead"):
                        if ex.get(k) is not None:
                            row[k] = ex[k]
                except GameError as e:
                    row["examine_error"] = str(e)
            order.append(row)
        out["turn_order"] = order
        cur = cb.get("current")
        out["current"] = self.ref(cur)
        out["party_can_act"] = [self.ref(u) for u in cb.get("party_can_act") or []]
        out["recent_rolls"] = self._rolls_since(max(0, self.roll_seq - 6))[-6:]
        return out

    def actions(self, char: str) -> dict:
        self.ensure()
        u = self.resolve(char)
        r = self.rpc("state.actions", {"uuid": u}) or {}
        acts = []
        for a in r.get("actions") or []:
            acts.append({k: a[k] for k in ("spell", "name", "level", "cost", "range", "target", "available", "reason")
                         if k in a})
        return {"char": self.ref(u), "resources": r.get("resources"), "actions": acts}

    def _act(self, op: str, args: dict, wait_s: float = 40.0) -> dict:
        self.ensure()
        before = self.roll_seq
        jr = self.g.run_job(op, args, "server", wait_s=wait_s)
        out = {"status": jr.status}
        if jr.result is not None:
            out["result"] = jr.result
        if jr.error:
            out["error"] = jr.error
        time.sleep(0.3)   # the damage events of the last hit land just after the cast settles
        rolls = self._rolls_since(before)
        if rolls:
            out["rolls"] = rolls
        return out

    def cast(self, char: str, spell: str, target: str | None = None, pos: list[float] | None = None) -> dict:
        args: dict[str, Any] = {"char": self.resolve(char), "spell": spell}
        if target:
            args["target"] = self.resolve(target)
        if pos:
            args["pos"] = pos
        return self._act("act.cast", args)

    def move(self, char: str, target: str | None = None, pos: list[float] | None = None) -> dict:
        args: dict[str, Any] = {"char": self.resolve(char)}
        if target:
            args["target"] = self.resolve(target)
        elif pos:
            args["pos"] = pos
        else:
            raise GameError("move needs a target id or a pos [x, y, z]")
        return self._act("act.move_to", args)

    def end_turn(self, char: str) -> dict:
        return self._act("act.end_turn", {"char": self.resolve(char)}, wait_s=15.0)

    def wait_for_turn(self, timeout_s: float = 180.0) -> dict:
        """Until a party member can act, or the fight is over. Before any fight it waits for one to start."""
        self.ensure()
        t0 = time.time()
        while time.time() - t0 < timeout_s:
            try:
                cb = self.rpc("state.combat") or {}
            except NotReady:
                time.sleep(1.0)
                continue
            if not cb.get("active"):
                if self.seen_fight:
                    self.seen_fight = False
                    return {"fight_over": True, "rolls": self._rolls_since(max(0, self.roll_seq - 6))}
                time.sleep(TURN_POLL_S)
                continue
            self.seen_fight = True
            if cb.get("party_can_act"):
                return {"your_turn": True, "state": self.fight_state()}
            time.sleep(TURN_POLL_S)
        return {"timeout": True, "waited_s": round(time.time() - t0)}

    def rolls(self, since: int = 0) -> dict:
        self.ensure()
        return {"rows": self._rolls_since(since), "latest": self.roll_seq}


def build_server(bot: Bot):
    from mcp.server.mcpserver import MCPServer

    srv = MCPServer("fightbot", instructions=(
        "You fight Baldur's Gate 3 combats for the party. Nothing is hidden: you see every combatant, their HP, AC, "
        "statuses and every roll. Loop: wait_for_turn -> plan from fight_state/actions -> cast/move -> end_turn, "
        "until wait_for_turn says fight_over. Characters are referred to by the ids fight_state gives (c1, c2, ...)."))

    def tool(fn):
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
        """Every attack and damage roll since a sequence number: d20 natural and total vs AC, advantage, damage
        dice. Misses and passed saves appear without numbers (the engine gives none)."""
        return bot.rolls(since=since)

    return srv


def main() -> None:
    game = Game(port=int(os.environ.get("FIGHTBOT_PORT", os.environ.get("BG3LE_DEBUG_PORT", "9998"))))
    bot = Bot(game, LOG_DIR / time.strftime("fightbot-%Y%m%d-%H%M%S.jsonl"))
    build_server(bot).run("stdio")


if __name__ == "__main__":
    main()
