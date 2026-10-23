"""Read-only evidence intake. No debugger, game, network, or latest-stream lookup."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
from typing import Any

NULL_GUID = "00000000-0000-0000-0000-000000000000"
PREFIX = re.compile(r"^(.+)-server-fight\d+(?:-c\d+)?$")
MAX_FILE_BYTES = 64 << 20


def scalar(value):
    if isinstance(value, dict):
        if "label" in value and set(value) <= {"label", "value"}:
            return value["label"]
        if "text" in value and set(value) <= {"text", "numeric"}:
            return value["text"]
    return value


def values(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        if "values" in value:
            return values(value["values"])
        if value and all(str(k).isdigit() for k in value):
            return [value[k] for k in sorted(value, key=lambda k: int(k))]
    return []


def loss_flags(value, path=""):
    found = []
    if isinstance(value, dict):
        if value and all(str(k).isdigit() for k in value):
            if sorted(int(k) for k in value) != list(range(1, len(value) + 1)):
                found.append(path + ": sparse numeric indexes")
        for key, item in value.items():
            here = path + "." + str(key)
            if key in {"cut", "depth_cut", "_cut", "_omitted", "truncated"} and item is True:
                found.append(here)
            found.extend(loss_flags(item, here))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(loss_flags(item, f"{path}[{index}]"))
    elif value in ("<omitted>", "<budget>"):
        found.append(path)
    return found


def uuid_of(value):
    return value.get("uuid") if isinstance(value, dict) else None


def real_guid(value):
    return isinstance(value, str) and value != NULL_GUID and bool(re.fullmatch(
        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value))


def normalize_rows(hit):
    rows = []
    for condition in values(hit.get("ConditionRolls")):
        if not isinstance(condition, dict):
            continue
        stats = condition.get("Roll") if isinstance(condition.get("Roll"), dict) else {}
        result = stats.get("Result") if isinstance(stats.get("Result"), dict) else {}
        rows.append({"type": scalar(condition.get("RollType")),
                     "natural": result.get("NaturalRoll"), "total": result.get("Total"),
                     "difficulty": condition.get("Difficulty"), "roll_uuid": condition.get("RollUuid"),
                     "raw": condition})
    return rows


def freeze_trial(before: dict, after: dict, action_result: dict, *, recorder_dir: Path,
                 probe_dirs: list[Path], destination: Path) -> dict:
    """Freeze into destination/evidence (exclusive creation), returning report.

    before/after use recording={session_id,combat_id,file_prefix}; optional
    client_session or owner_binding.client_session selects that exact client.
    Probe paths MUST be supplied explicitly. No source file is ever modified.
    The report qualifies joins, not simulator or gameplay acceptance.
    """
    destination = Path(destination)
    output = destination / "evidence"
    output.mkdir(parents=True, exist_ok=False)
    raw = output / "raw"
    raw.mkdir()
    report: dict[str, Any] = {"schema": 1, "acceptance": "not_assessed",
        "scope": "Frozen bound-stream candidate joins; no full replay or RNG qualification",
        "errors": [], "files": [], "candidates": [], "client_evidence": [],
        "unknowns": [], "job_status": action_result.get("status"),
        "stream_finalized": False}
    errors = report["errors"]

    def document(name, value):
        (output / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    document("before.json", before)
    document("after.json", after)
    document("action-result.json", action_result)
    binding = before.get("recording") or {}
    report["binding"] = binding
    prefix, session, combat = (binding.get(k) for k in ("file_prefix", "session_id", "combat_id"))
    valid_prefix = isinstance(prefix, str) and not any(c in prefix for c in "/\\:") and PREFIX.fullmatch(prefix)
    valid = bool(valid_prefix and session and combat and prefix.startswith(session + "-server-"))
    if not valid:
        errors.append("before: explicit valid server session/combat/file_prefix binding required; no fallback")
    after_binding = after.get("recording") or {}
    if any(after_binding.get(k) != binding.get(k) for k in ("session_id", "combat_id", "file_prefix")):
        errors.append("before/after recorder binding differs; action cannot be qualified across generations")
    if not binding.get("recorder_active") or not after_binding.get("recorder_active"):
        errors.append("before/after active recorder not confirmed")
    client_session = before.get("client_session") or (before.get("owner_binding") or {}).get("client_session")
    after_client = after.get("client_session") or (after.get("owner_binding") or {}).get("client_session")
    if client_session != after_client:
        errors.append("before/after client session differs")
    if not client_session:
        report["unknowns"].append("client session not supplied; no client files selected")
    elif not isinstance(client_session, str) or any(c in client_session for c in "/\\:"):
        errors.append("invalid explicit client session")
        client_session = None

    records, probes = [], []

    def snapshot(path, relative):
        try:
            initial = path.stat()
            if initial.st_size > MAX_FILE_BYTES:
                raise ValueError("input exceeds 64 MiB limit")
            data = path.read_bytes()
            final = path.stat()
            stable = (initial.st_size, initial.st_mtime_ns) == (final.st_size, final.st_mtime_ns)
            target = raw / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as handle:
                handle.write(data)
            meta = {"source": str(path), "file": str(target.relative_to(output)), "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(), "stable_during_read": stable}
            report["files"].append(meta)
            if not stable:
                errors.append(str(relative) + ": source changed during read; frozen bytes retained, no retry")
            return data, meta
        except (OSError, ValueError) as exc:
            errors.append(str(path) + ": " + str(exc))
            return None, None

    folder = Path(recorder_dir)
    if valid:
        server_pattern = re.compile(re.escape(prefix) + r"-p(\d{5})\.jsonl$")
        client_pattern = re.compile(re.escape(client_session) + r"-client-combatlog-p(\d{5})\.jsonl$") if client_session else None
        try:
            paths = sorted(path for path in folder.iterdir() if path.is_file() and
                           (server_pattern.fullmatch(path.name) or (client_pattern and client_pattern.fullmatch(path.name))))
        except OSError as exc:
            errors.append("recorder directory unreadable: " + str(exc))
            paths = []
        if not any(server_pattern.fullmatch(path.name) for path in paths):
            errors.append("bound server stream missing; no latest or previous-stream fallback")
        if len(paths) > 512:
            errors.append("bound stream exceeds 512-part freeze limit")
            paths = []
        for path in paths:
            data, meta = snapshot(path, Path("recorder") / path.name)
            if data is None:
                continue
            parsed = []
            for line, text in enumerate(data.splitlines(), 1):
                try:
                    row = json.loads(text)
                    if not isinstance(row, dict):
                        raise ValueError("record is not object")
                    parsed.append((line, row))
                except (ValueError, UnicodeError) as exc:
                    errors.append(f"{path.name}:{line}: malformed/torn record: {exc}")
            header = parsed[0][1] if parsed and parsed[0][0] == 1 else {}
            is_server = bool(server_pattern.fullmatch(path.name))
            expected_session = session if is_server else client_session
            if (header.get("kind") != "part_header" or header.get("session_id") != expected_session
                    or header.get("context") != ("server" if is_server else "client")
                    or (is_server and header.get("combat_id") != combat)):
                errors.append(path.name + ": header identity mismatch; records excluded")
                continue
            for line, row in parsed:
                item = {"file": meta["file"], "line": line, "seq": row.get("seq"), "record": row,
                        "loss_flags": loss_flags(row)}
                if is_server:
                    records.append(item)
                    if row.get("kind") == "end":
                        report["stream_finalized"] = True
                elif row.get("kind") == "entry":
                    report["client_evidence"].append(item)
        numbers = sorted(int(server_pattern.fullmatch(path.name)[1]) for path in paths if server_pattern.fullmatch(path.name))
        if numbers and numbers != list(range(1, max(numbers) + 1)):
            errors.append("missing server stream part(s)")
    for index, folder in enumerate(probe_dirs):
        try:
            if not Path(folder).is_dir():
                raise ValueError("explicit probe directory missing")
            paths = sorted(Path(folder).glob("*.json"))
            if len(paths) > 256:
                raise ValueError("probe directory exceeds 256 files")
            for path in paths:
                data, meta = snapshot(path, Path("probes") / str(index) / path.name)
                if data is None:
                    continue
                try:
                    value = json.loads(data)
                    if not isinstance(value, dict):
                        raise ValueError("probe is not object")
                    probes.append((value, meta))
                except (ValueError, UnicodeError) as exc:
                    errors.append(str(path) + ": " + str(exc))
        except (OSError, ValueError) as exc:
            errors.append(str(folder) + ": " + str(exc))

    # Only explicit GUIDs join records. Actor/target direct UUIDs are evidence,
    # never inferred from a shared timestamp, prototype, display name or result.
    result = action_result.get("result") or {}
    route = result.get("experimental_source") or {}
    requested_guid = route.get("cast_guid") or action_result.get("cast_guid")
    report["requested_cast_guid"] = requested_guid
    requested_target = route.get("expected_target") or uuid_of(result.get("target"))
    report["requested_target_uuid"] = requested_target
    grouped = {}

    def add(guid, evidence):
        if real_guid(guid):
            grouped.setdefault(guid, []).append(evidence)

    for item in records:
        data = item["record"].get("data") or {}
        if not isinstance(data, dict):
            errors.append(str(item["location"] if "location" in item else item["file"]) + ": non-object data")
            continue
        hit = data.get("hit") or {}
        if not isinstance(hit, dict):
            errors.append(item["file"] + ": non-object hit")
            continue
        add(hit.get("SpellCastGuid"), {"kind": item["record"].get("kind"), "location": {k: item[k] for k in ("file", "line", "seq")},
            "story_action_id": hit.get("StoryActionId", data.get("story_action_id")),
            "caster": uuid_of(data.get("caster")) or uuid_of(hit.get("Inflicter")),
            "target": uuid_of(data.get("target")), "spell": hit.get("SpellId"),
            "attack_rolls": normalize_rows(hit), "damage": hit.get("Damage"),
            "resolved_result": data.get("result"), "loss_flags": item["loss_flags"]})
    for probe, meta in probes:
        hit = probe.get("Hit")
        if isinstance(hit, dict):
            add(hit.get("SpellCastGuid"), {"kind": probe.get("component"), "location": {"file": meta["file"]},
                "story_action_id": hit.get("StoryActionId"), "caster": uuid_of(probe.get("caster")),
                "target": uuid_of(probe.get("target")), "spell": hit.get("SpellId"),
                "attack_rolls": normalize_rows(hit), "effective_attack_ability": scalar(hit.get("AttackRollAbility")),
                "cast_state": probe.get("CastState"), "cast_cache": probe.get("CastCache"),
                "capture_complete": probe.get("complete"), "capture_errors": probe.get("errors"),
                "loss_flags": loss_flags(probe)})
        for read in probe.get("reads") or []:
            if not isinstance(read, dict):
                errors.append(meta["file"] + ": non-object lifecycle read")
                continue
            components = read.get("components") or {}
            if not isinstance(components, dict):
                errors.append(meta["file"] + ": non-object lifecycle components")
                continue
            state = components.get("SpellCastState") or {}
            if not isinstance(state, dict):
                continue
            add(state.get("SpellCastGuid"), {"kind": "cast_lifecycle", "location": {"file": meta["file"], "stage": read.get("tick")},
                "story_action_id": (components.get("ServerSpellCastState") or {}).get("StoryActionId"),
                "caster": probe.get("caster"), "target": None, "target_note": "entity handle is not an independently resolved UUID",
                "source": state.get("SpellId"), "cast_cache": components.get("SpellCastCache"),
                "attack_rolls": [], "loss_flags": loss_flags(read)})
    for guid, evidence in sorted(grouped.items()):
        stories = sorted({e["story_action_id"] for e in evidence if type(e.get("story_action_id")) is int and e["story_action_id"] > 0})
        direct = [e for e in evidence if e.get("target") and e.get("caster")]
        pairs = sorted({(e["caster"], e["target"]) for e in direct})
        candidate = {"cast_guid": guid, "requested_guid_match": guid == requested_guid if requested_guid else None,
            "story_action_ids": stories, "story_consistent": len(stories) == 1,
            "direct_actor_target_pairs": [{"caster": a, "target": t} for a, t in pairs],
            "target_confirmed_directly": bool(direct), "target_conflict": len(pairs) > 1,
            "requested_target_match": all(t == requested_target for a, t in pairs) if requested_target and pairs else None,
            "numerical_attack_available": any(isinstance(r.get("natural"), (int, float)) and not isinstance(r.get("natural"), bool)
                                                for e in evidence for r in e.get("attack_rolls", [])),
            "evidence": evidence, "acceptance": "not_assessed"}
        report["candidates"].append(candidate)
    if not requested_guid:
        report["unknowns"].append("action result supplies no cast GUID; candidates are not automatically assigned to the requested action")
    elif requested_guid not in grouped:
        errors.append("requested cast GUID not present in frozen evidence")
    if not any(c["numerical_attack_available"] for c in report["candidates"]):
        report["unknowns"].append("numerical attack roll unavailable; zero damage/job done does not establish a miss or bonus")
    if not report["stream_finalized"]:
        report["unknowns"].append("bound server stream is active/partial; this freeze does not finalize recorder or fight")
    report["qualified_capture"] = False  # Requires caller-specific essential-field/intent admission.
    document("report.json", report)
    manifest = []
    for path in sorted(output.rglob("*")):
        if path.is_file():
            data = path.read_bytes()
            manifest.append({"file": str(path.relative_to(output)), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    document("hash-manifest.json", {"files": manifest})
    return report
