#!/usr/bin/env python3
"""Record fights a human plays: party state, preparation, every combat event, and the game's combat log.

No agent and no runner: start the game the usual way (runner/launch_game.sh), load the save, start this, then play.
It polls the mod every --poll seconds and appends to one JSONL file (and a readable .txt beside it):

    snapshot    party sheets (level, classes, abilities, saves, AC, resources, statuses, equipment, XP), state.status,
                the turn order and the party inventory: at the start, at each combat start and at each combat end
    event       the fair event stream the agent gets (combat_started, damage, cast, status_applied, ...)
    raw         the dev recorder's unfiltered facts (Server/Recorder.lua): engine spell and status ids, enemy
                casts and rolls, unseen attackers, status durations, and the Script Extender's damage events
                (their hit and attack descriptions) where the extender has them
    combatlog   each new combat log entry as its view model holds it (Client/CombatLog.lua), with its text
    meta        what the recorder found: hooks that subscribed, where the combat log is and what it holds

Start it before you buff, so the preparation is in the record. It stops after --fights fights (0: on Ctrl-C).
See tools/README-record-fight.md.

    uv run --project bridge python tools/record_fight.py [--out DIR] [--fights 1] [--poll 0.25]
"""
from __future__ import annotations

import argparse
import json
import re
import signal
import sys
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bridge" / "src"))
sys.path.insert(0, str(HERE))

import repo_paths  # noqa: E402

TAIL = 5          # combat log entries re-read each poll to check the log still lines up
_MARKUP = re.compile(r"<[^>]*>")
_SPACES = re.compile(r"\s+")


def entry_text(d: Any) -> str:
    """The readable text of a dumped log entry: its strings, markup stripped, in order, without repeats."""
    parts: list[str] = []

    def walk(x: Any, key: str = "") -> None:
        if isinstance(x, str):
            if key.startswith("_") and key != "_text":
                return
            s = _SPACES.sub(" ", _MARKUP.sub("", x)).strip()
            if s and s not in parts and not s.startswith("ls::"):
                parts.append(s)
        elif isinstance(x, dict):
            for k in sorted(x, key=lambda k: (k == "_items", str(k))):
                walk(x[k], str(k))
        elif isinstance(x, list):
            for v in x:
                walk(v, key)
    walk(d)
    return " | ".join(parts)


def sig(d: Any) -> str:
    return json.dumps(d, sort_keys=True, separators=(",", ":"))


class LogTail:
    """Which combat log entries are new. Entries are read by index; the log can drop old ones or be rebuilt (a load),
    so each poll re-reads the last TAIL known entries and checks they still sit where they were."""

    def __init__(self, tail: int = TAIL):
        self.tail_n = tail
        self.count = 0
        self.tail: list[str] = []      # signatures of the last known entries, oldest first
        self.started = False

    def window(self) -> int:
        """The first index to read (1-based); the read runs to the end of the log."""
        return 1 if not self.started else max(1, self.count - len(self.tail) + 1)

    def _remember(self, entries: list[dict]) -> None:
        self.tail = (self.tail + [sig(e.get("d")) for e in entries])[-self.tail_n:]

    def take(self, count: int, entries: list[dict]) -> tuple[list[dict], str] | None:
        """New entries and how they were found ("backlog", "new", "resync"); None: read the whole log and call
        take_full (the known tail is no longer where it was)."""
        if not self.started:
            self.started, self.count = True, count
            self._remember(entries)
            return entries, "backlog"
        if self.tail:
            got = [sig(e.get("d")) for e in entries[:len(self.tail)]]
            if got != self.tail or count < self.count:
                return None
        new = [e for e in entries if e.get("i", 0) > self.count]
        self.count = count
        self._remember(new)
        return new, "new"

    def take_full(self, count: int, entries: list[dict]) -> tuple[list[dict], str]:
        sigs = [sig(e.get("d")) for e in entries]
        k = len(self.tail)
        at = next((j + k for j in range(len(sigs) - k, -1, -1) if k and sigs[j:j + k] == self.tail), None)
        new = entries[at:] if at is not None else entries
        self.count = count
        self.tail = []
        self._remember(entries)
        return new, ("new" if at is not None else "resync")


class Recorder:
    def __init__(self, game, out: Path, fights: int, inventory: bool, combatlog: bool, depth: int):
        self.g = game
        self.fights_max = fights
        self.inventory = inventory
        self.combatlog = combatlog
        self.depth = depth
        self.jsonl = out.with_suffix(".jsonl").open("a", encoding="utf-8")
        self.txt = out.with_suffix(".txt").open("a", encoding="utf-8")
        self.ev_seq = 0
        self.rec_seq = 0
        self.log = LogTail()
        self.fights_started = 0
        self.fights_done = 0
        self.stop_at: float | None = None

    # ---- output ----

    def write(self, src: str, **rec: Any) -> None:
        rec = {"wall": time.strftime("%Y-%m-%dT%H:%M:%S"), "src": src, **rec}
        self.jsonl.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
        self.jsonl.flush()

    def say(self, line: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} {line}"
        print(line, flush=True)
        self.txt.write(line + "\n")
        self.txt.flush()

    # ---- reads ----

    def _try(self, op: str, args: dict | None = None, context: str = "server") -> Any:
        from bg3ai.game import GameError, NotReady
        try:
            return self.g.rpc(op, args or {}, context)
        except (GameError, NotReady) as e:
            return {"error": str(e)}

    def snapshot(self, why: str) -> None:
        status = self._try("state.status")
        party = status.get("party") or [] if isinstance(status, dict) else []
        sheets = [self._try("state.character", {"uuid": p.get("uuid")}) for p in party if p.get("uuid")]
        snap: dict[str, Any] = {"why": why, "status": status, "party": sheets}
        if isinstance(status, dict) and status.get("in_combat"):
            snap["combat"] = self._try("state.combat")
        if self.inventory:
            snap["inventory"] = self._try("state.inventory")
        self.write("snapshot", **snap)
        names = ", ".join(f"{s.get('name')} L{s.get('level')} {s.get('hp')}/{s.get('max_hp')}"
                          for s in sheets if isinstance(s, dict) and "name" in s)
        self.say(f"[snapshot {why}] {names or status}")

    def start(self) -> None:
        self.g.sync_events()   # the ring's old events (an earlier session's) are not this record's
        self.ev_seq = self.g.event_seq["server"]
        on = self._try("rec.enable", {"on": True})
        self.rec_seq = on.get("seq", 0) if isinstance(on, dict) else 0
        probe = self._try("combatlog.probe", {"depth": 2}, "client") if self.combatlog else None
        info = self._try("sys.info")
        self.write("meta", info=info, recorder=on, combatlog_probe=probe)
        hooks = (on or {}).get("hooks") or {}
        bad = {k: v for k, v in hooks.items() if v != "ok"}
        self.say(f"[meta] recorder hooks: {len(hooks) - len(bad)} ok" + (f", not available: {sorted(bad)}" if bad else ""))
        if probe is not None:
            found = isinstance(probe, dict) and probe.get("found")
            self.say(f"[meta] combat log: {'found (' + str(probe.get('how')) + '), entries in ' + str(probe.get('chosen')) if found else 'NOT found: open the combat log panel'}")
        self.snapshot("start")

    # ---- polling ----

    def poll_events(self) -> None:
        res = self.g.rpc("events.since", {"seq": self.ev_seq, "limit": 300})
        if int(res.get("latest") or 0) < self.ev_seq:   # the mod reloaded (a save load): its ring starts over
            self.ev_seq = 0
            return
        for ev in res.get("events") or []:
            self.ev_seq = max(self.ev_seq, int(ev.get("seq") or 0))
            self.write("event", kind=ev.get("kind"), t=ev.get("t"), data=ev.get("data"))
            kind = ev.get("kind")
            if kind == "combat_started":
                self.fights_started += 1
                self.say(f"[fight {self.fights_started}] combat started")
                self.snapshot("combat_start")
            elif kind == "combat_ended":
                self.fights_done += 1
                self.say(f"[fight {self.fights_done}] combat ended")
                self.snapshot("combat_end")
                if self.fights_max and self.fights_done >= self.fights_max and self.stop_at is None:
                    self.stop_at = time.time() + 2.0   # the last log lines land after the event
            elif kind in ("died", "downed", "round_started"):
                self.say(f"[{kind}] {json.dumps(ev.get('data'), ensure_ascii=False)}")

    def poll_raw(self) -> None:
        res = self.g.rpc("rec.since", {"seq": self.rec_seq, "limit": 300})
        if not res.get("on") or int(res.get("latest") or 0) < self.rec_seq:   # reloaded: switch it back on
            on = self._try("rec.enable", {"on": True})
            self.rec_seq = on.get("seq", 0) if isinstance(on, dict) else 0
            return
        for r in res.get("records") or []:
            self.rec_seq = max(self.rec_seq, int(r.get("seq") or 0))
            self.write("raw", kind=r.get("kind"), t=r.get("t"), data=r.get("data"))

    def poll_log(self) -> None:
        res = self.g.rpc("combatlog.read", {"first": self.log.window(), "depth": self.depth}, "client")
        if not res.get("found") or "entries" not in res:
            return
        got = self.log.take(int(res.get("count") or 0), res["entries"])
        if got is None:
            full = self.g.rpc("combatlog.read", {"first": 1, "depth": self.depth}, "client")
            got = self.log.take_full(int(full.get("count") or 0), full.get("entries") or [])
        new, how = got
        for e in new:
            text = entry_text(e.get("d"))
            self.write("combatlog", how=how, i=e.get("i"), text=text, entry=e.get("d"))
            if how != "backlog":
                self.say(f"[log] {text}")

    def run(self, poll_s: float) -> None:
        from bg3ai.game import GameError, NotReady
        self.start()
        while self.stop_at is None or time.time() < self.stop_at:
            t0 = time.time()
            for step in (self.poll_events, self.poll_raw) + ((self.poll_log,) if self.combatlog else ()):
                try:
                    step()
                except NotReady:
                    time.sleep(1.0)   # loading or at the main menu
                    break
                except GameError as e:
                    self.write("error", step=step.__name__, error=str(e))
            time.sleep(max(0.0, poll_s - (time.time() - t0)))
        self.stop()

    def stop(self) -> None:
        if self.jsonl.closed:
            return
        self._try("rec.enable", {"on": False})
        self.say(f"[done] {self.fights_done} fight(s) recorded")
        self.jsonl.close()
        self.txt.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", type=Path, default=repo_paths.runtime_dir() / "recordings",
                    help="folder for the record (default: runtime/recordings)")
    ap.add_argument("--fights", type=int, default=1, help="stop after this many fights end (0: run until Ctrl-C)")
    ap.add_argument("--poll", type=float, default=0.25, help="seconds between polls")
    ap.add_argument("--depth", type=int, default=3, help="how deep combat log entries are read")
    ap.add_argument("--no-inventory", action="store_true", help="leave the party inventory out of snapshots")
    ap.add_argument("--no-combatlog", action="store_true", help="don't read the combat log panel")
    ap.add_argument("--port", type=int, default=9998)
    a = ap.parse_args(argv)

    from bg3ai.game import Game
    a.out.mkdir(parents=True, exist_ok=True)
    out = a.out / time.strftime("fight-%Y%m%d-%H%M%S")
    rec = Recorder(Game(port=a.port), out, a.fights, not a.no_inventory, not a.no_combatlog, a.depth)

    def on_term(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, on_term)
    print(f"recording to {out}.jsonl (Ctrl-C stops)", flush=True)
    try:
        rec.run(a.poll)
    except KeyboardInterrupt:
        rec.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
