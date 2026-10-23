"""Rolls for the fightbot, read from FightRec v2's files on disk (no second recorder in the game).

FightRec v2 (fightrec/recorder-project/docs/SCHEMA.txt) writes each fight as numbered JSONL parts in the Script
Extender folder's FightRec2/: <session>-server-fightNN[-cN]-pNNNNN.jsonl, the active part rewritten every
FLUSH_MS (2 s). The newest fight stream is read; sealed parts are cached, the active part is re-read.

Rows: a hit from each DealtDamage (attacker, target, attack roll, damage dealt; damage dice from the
BeforeDealDamage of the same cast when it names one), a no_damage row for an AttackedBy of 0 from an attack (a miss
or a passed save: no numbers exist for it), and each RollResult as the engine gave it.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

_PART = re.compile(r"^(?P<stream>.+-server-fight\d+(?:-c\d)?)-p(?P<n>\d{5})\.jsonl$")
NULL_GUID = "00000000-0000-0000-0000-000000000000"


def default_dir() -> Path:
    if os.environ.get("FIGHTBOT_FIGHTREC_DIR"):
        return Path(os.environ["FIGHTBOT_FIGHTREC_DIR"])
    base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
    return Path(base) / "Larian Studios" / "Baldur's Gate 3" / "Script Extender" / "FightRec2"


def unwrap(x: Any) -> Any:
    """FightRec v2's shapes back to plain data: a cut value {value, cut...} -> value; a list written as an object
    {"1": a, "2": b} (dev.1/dev.2) -> [a, b]; enums {value, label} -> label."""
    if isinstance(x, dict):
        if "value" in x and set(x) <= {"value", "cut", "depth_cut", "serialize_unbudgeted"}:
            return unwrap(x["value"])
        if "label" in x and set(x) <= {"value", "label"}:
            return x["label"]
        if x and all(isinstance(k, str) and k.isdigit() for k in x):
            return [unwrap(x[k]) for k in sorted(x, key=int)]
        return {k: unwrap(v) for k, v in x.items()}
    if isinstance(x, list):
        return [unwrap(v) for v in x if v != "<omitted>"]
    return x


def _get(d: Any, *path: str) -> Any:
    for k in path:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def _label(x: Any) -> Any:
    if isinstance(x, str):
        m = re.match(r"^\w+\((.*)\)$", x)   # "ConditionRollType(AttackRoll)" -> "AttackRoll"
        return m.group(1) if m else x
    return x


def evidence_issues(value: Any, path: str = "", depth: int = 0) -> list[str]:
    """Keep loss metadata visible even when unwrap normalizes the value's representation."""
    if depth > 40:
        return [path + ": inspection depth exceeded"]
    issues = []
    if isinstance(value, dict):
        for k, v in value.items():
            p = f"{path}.{k}" if path else str(k)
            if k in {"cut", "depth_cut", "_cut", "_omitted", "truncated"} and v is True:
                issues.append(p)
            issues.extend(evidence_issues(v, p, depth + 1))
        if value and all(isinstance(k, str) and k.isdigit() for k in value):
            if sorted(map(int, value)) != list(range(1, len(value) + 1)):
                issues.append(path + ": sparse numeric indexes")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            issues.extend(evidence_issues(v, f"{path}[{i}]", depth + 1))
    elif value in ("<omitted>", "<budget>"):
        issues.append(path + ": " + value)
    return issues


def attack_rolls(hit: dict) -> list[dict]:
    out = []
    for c in _get(hit, "ConditionRolls") or []:
        roll, res = _get(c, "Roll", "Roll") or {}, _get(c, "Roll", "Result") or {}
        dice = [d.get("RollValue") for d in (res.get("RollsCount") or []) if isinstance(d, dict)]
        row = {"type": _label(c.get("RollType")), "natural": res.get("NaturalRoll"), "total": res.get("Total"),
               "vs": c.get("Difficulty")}
        for k, src in (("advantage", "Advantage"), ("disadvantage", "Disadvantage")):
            if roll.get(src) is True or roll.get(src) == "true":
                row[k] = True
        crit = _label(res.get("Critical"))
        if crit and crit != "None":
            row["critical"] = crit
        if dice:
            row["dice"] = dice
        out.append(row)
    return out


def damage_dice(damage: dict) -> list[dict]:
    out = []
    for dtype, rolls in (_get(damage, "DamageRolls") or {}).items() if isinstance(_get(damage, "DamageRolls"), dict) else []:
        for r in rolls or []:
            spec, res = _get(r, "Roll", "Roll") or {}, _get(r, "Result") or {}
            out.append({"type": dtype, "die": spec.get("DiceValue"), "count": spec.get("AmountOfDices"),
                        "bonus": spec.get("DiceAdditionalValue"), "natural": res.get("NaturalRoll"),
                        "total": res.get("Total")})
    return out


class FightRecReader:
    def __init__(self, folder: Path | None = None):
        self.folder = folder or default_dir()
        self._cache: dict[str, tuple[float, int, list[dict]]] = {}   # sealed part path -> (mtime, size, records)
        self.binding_required = False
        self.bound_prefix: str | None = None
        self.bound_combat: str | None = None
        self.read_issues: list[str] = []

    def require_binding(self) -> None:
        self.binding_required = True

    def bind(self, prefix: str | None, combat: str | None = None) -> None:
        if prefix is not None and (any(c in prefix for c in "/\\:") or not _PART.fullmatch(prefix + "-p00001.jsonl")):
            raise ValueError("invalid recorder stream prefix")
        if (prefix, combat) != (self.bound_prefix, self.bound_combat):
            self._cache.clear()
        self.bound_prefix, self.bound_combat = prefix, combat

    def latest_stream(self) -> list[Path]:
        if self.binding_required and not self.bound_prefix:
            return []
        if not self.folder.is_dir():
            return []
        streams: dict[str, list[tuple[int, Path]]] = {}
        for p in self.folder.glob("*-server-fight*-p*.jsonl"):
            m = _PART.match(p.name)
            if m and (self.bound_prefix is None or m["stream"] == self.bound_prefix):
                streams.setdefault(m["stream"], []).append((int(m["n"]), p))
        if not streams:
            return []
        newest = max(streams, key=lambda s: max(p.stat().st_mtime for _, p in streams[s]))
        return [p for _, p in sorted(streams[newest])]

    def _read(self, p: Path) -> list[dict]:
        st = p.stat()
        hit = self._cache.get(str(p))
        if hit and hit[0] == st.st_mtime and hit[1] == st.st_size:
            return hit[2]
        if st.st_size > 64 << 20:
            self.read_issues.append(p.name + ": input exceeds 64 MiB limit")
            return []
        recs, sealed = [], False
        lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        if self.bound_prefix:
            try:
                h = json.loads(lines[0])
            except (IndexError, ValueError):
                self.read_issues.append(p.name + ": header unavailable during flush")
                return []
            if h.get("kind") != "part_header" or h.get("context") != "server" or h.get("combat_id") != self.bound_combat:
                self.read_issues.append(p.name + ": recorder identity mismatch")
                return []
        start_issues = len(self.read_issues)
        for i, line in enumerate(lines, 1):
            try:
                r = json.loads(line)
            except ValueError:
                self.read_issues.append(f"{p.name}:{i}: malformed or torn record")
                continue   # a torn last line: the active part is being rewritten
            if not isinstance(r, dict):
                self.read_issues.append(f"{p.name}:{i}: non-object record")
                continue
            if r.get("kind") == "part_trailer":
                sealed = True
            elif r.get("kind") != "part_header":
                recs.append(r)
        if sealed and len(self.read_issues) == start_issues:
            self._cache[str(p)] = (st.st_mtime, st.st_size, recs)
        return recs

    def records(self) -> tuple[str | None, list[dict]]:
        self.read_issues = []
        parts = self.latest_stream()
        if len(parts) > 256:
            self.read_issues.append("stream exceeds 256-part live reader limit")
            return self.bound_prefix, []
        recs: list[dict] = []
        for p in parts:
            recs.extend(self._read(p))
        recs.sort(key=lambda r: r.get("seq") or 0)
        return (_PART.match(parts[-1].name)["stream"] if parts else self.bound_prefix), recs

    def rows(self, since: int = 0) -> dict:
        """{stream, latest, rows}: roll rows with seq > since, from the newest fight."""
        stream, recs = self.records()
        dice_by_cast: dict[tuple, list[dict]] = {}
        rows: list[dict] = []
        latest = 0
        for r in recs:
            seq, kind, d = r.get("seq") or 0, r.get("kind"), r.get("data") or {}
            if not isinstance(d, dict):
                self.read_issues.append(f"seq {seq}: non-object data")
                continue
            latest = max(latest, seq)
            if kind == "BeforeDealDamage":
                hit = unwrap(d.get("hit")) or {}
                guid = hit.get("SpellCastGuid")
                if guid and guid != NULL_GUID:
                    dice = damage_dice(hit.get("Damage") or {})
                    if dice:
                        key = (guid, hit.get("StoryActionId"))
                        dice_by_cast.setdefault(key, []).append({"seq": seq, "dice": dice,
                            "issues": evidence_issues(d.get("hit"), "before.hit")})
                continue
            if seq <= since:
                continue
            if kind == "DealtDamage":
                hit = unwrap(d.get("hit")) or {}
                dealt = unwrap(_get(d, "result", "Attack")) or {}
                row = {"seq": seq, "kind": "hit", "attacker": d.get("caster"), "target": d.get("target"),
                       "spell": hit.get("SpellId") or _get(unwrap(d.get("spell")) or {}, "Prototype"),
                       "rolls": attack_rolls(hit),
                       "damage": {"total": dealt.get("TotalDamageDone"),
                                  "by_type": {x.get("type"): x.get("amount") for x in dealt.get("DamageList") or []
                                              if isinstance(x, dict)}}}
                issues = evidence_issues(d.get("hit"), "hit") + evidence_issues(d.get("result"), "result")
                key = (hit.get("SpellCastGuid"), hit.get("StoryActionId"))
                candidates = dice_by_cast.get(key, [])
                if len(candidates) == 1:
                    before = candidates[0]
                    row["damage"]["dice"] = before["dice"]
                    row["damage"]["dice_provenance"] = {"before_seq": before["seq"],
                        "join": "unique preceding cast+story_action", "target_independently_verified": False}
                    issues.extend(before["issues"])
                    del dice_by_cast[key]  # never reuse one target's dice for a later hit
                elif candidates:
                    row["damage"]["dice_unavailable"] = "ambiguous multiple pre-damage records for this cast/action"
                    issues.append("damage dice target attribution ambiguous")
                row["evidence_complete"] = not issues
                if issues:
                    row["evidence_issues"] = issues
                rows.append(row)
            elif kind == "AttackedBy" and d.get("cause") == "Attack" and d.get("amount") == 0:
                rows.append({"seq": seq, "kind": "no_damage", "attacker": d.get("source"), "target": d.get("target"),
                             "note": "zero attack damage: hit/miss/save/immune/blocked is unresolved; this event has no roll numbers"})
            elif kind == "RollResult":
                rows.append({"seq": seq, "kind": "roll_result", "event": d.get("event"), "roller": d.get("roller"),
                             "against": d.get("subject"), "result": d.get("result")})
        return {"stream": stream, "latest": latest, "rows": rows}
