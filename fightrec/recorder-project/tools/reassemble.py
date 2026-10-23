"""Reassemble and validate FightRec v2 numbered parts (read-only; never feeds a simulator).

usage:
  python tools/reassemble.py DIR [--stream PREFIX] [--report FILE] [--out FILE] [--overwrite]
                             [--max-input-bytes N]
  python tools/reassemble.py --legacy FILE [--sha256 HEX] [--report FILE] [--out FILE] [--overwrite]
                             [--max-input-bytes N]

DIR holds the parts (a copy of the extender's FightRec2/ folder). Every stream found there
(<session>-<context>-<stream>[-cN]-pNNNNN.jsonl) is checked, or only --stream (the file prefix without
-pNNNNN.jsonl). The numbered parts are the source of truth; a manifest is cross-checked, never trusted.

Checks: supported schema; required header identity fields with types (allowed unknowns: source content hash
"unknown", combat_id/fight absent on non-fight streams) and one consistent identity across all parts and the
file names; records may not override envelope identity fields; missing/misnumbered parts; header/trailer shape
and consistency (count, seq range, bytes, fnv1a32 checksum); storage order inside and across parts BEFORE any
sorting; torn tails, unparsable or malformed lines and nested shapes; seq gaps; identical duplicates (reported)
and conflicting duplicates (rejected); an exact final range (stream_last_seq); recovery parts;
capture_gap/terminal_error records; observation-order inversions outside prehistory; delta checkpoint chains
(each base an earlier checkpoint of the same actor, every chain rooted in a full anchor).
`complete` is true only when nothing is wrong and the final trailer says capture "ok"; parsing success alone is
never treated as event completeness. Malformed input yields a structured incomplete report, never a traceback.

Outputs (--report, --out) are never written over an existing file unless --overwrite, and never onto any input
(same path, symlink or hard link), each other, or the protected sources (baseline/ and recorder/ FightRec.lua).
Memory: one stream at a time is held decoded in memory (O(largest stream bytes)) plus the report; merged output
is written stream by stream. Nothing here is bounded-memory: inputs above --max-input-bytes (default 1 GiB per
stream or legacy file) are reported as not validated.
--legacy imports a schema-1 (baseline) file preserving its ambiguity: no seq, X-only positions flagged.
Exit status: 0 all streams complete, 1 something incomplete or invalid, 2 usage/refused output.
"""
import argparse
import hashlib
import json
import os
import re
import sys

PART_RE = re.compile(r"^(?P<prefix>.+)-p(?P<n>\d{5})\.jsonl$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SUFFIX = re.compile(r"^-c[2-9]$")
SUPPORTED_SCHEMAS = (2,)
IDENTITY_KEYS = ("schema_version", "recorder_version", "source_content_sha256", "generation", "session_id",
                 "context", "stream_id", "combat_id", "fight", "file_prefix_suffix")
ENVELOPE_KEYS = IDENTITY_KEYS + ("part",)
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTECTED = [os.path.join(REPO, "baseline", "FightRec.lua"), os.path.join(REPO, "recorder", "FightRec.lua")]
DEFAULT_MAX_INPUT = 1 << 30


def fnv1a32(data, h=2166136261):
    for b in data:
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return h


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def nonempty_str(v):
    return isinstance(v, str) and v != ""


def canonical(rec):
    return json.dumps(rec, sort_keys=True, separators=(",", ":"))


def split_lines(raw):
    """Return (complete line byte strings, torn tail bytes or None)."""
    parts = raw.split(b"\n")
    tail = parts.pop()
    return parts, (tail if tail else None)


def discover(directory):
    streams = {}
    for name in sorted(os.listdir(directory)):
        m = PART_RE.match(name)
        if m:
            streams.setdefault(m.group("prefix"), []).append(int(m.group("n")))
    return {k: sorted(v) for k, v in streams.items()}


def part_path(directory, prefix, n):
    return os.path.join(directory, "%s-p%05d.jsonl" % (prefix, n))


def _recovery_target(directory, prefix, n):
    try:
        with open(part_path(directory, prefix, n), "rb") as fh:
            first = json.loads(fh.readline().decode("utf-8"))
        return first.get("recovery_of") if isinstance(first, dict) else None
    except (OSError, ValueError, UnicodeDecodeError):
        return None


def header_problems(h):
    """Required identity fields and their types (IR-11). Returns a list of problems."""
    out = []
    if h.get("schema_version") not in SUPPORTED_SCHEMAS or not is_int(h.get("schema_version")):
        out.append("unsupported schema_version %r" % (h.get("schema_version"),))
    for k in ("recorder_version", "generation", "session_id", "stream_id"):
        if not nonempty_str(h.get(k)):
            out.append("header field %s missing or not a non-empty string: %r" % (k, h.get(k)))
    src = h.get("source_content_sha256")
    if not (src == "unknown" or (isinstance(src, str) and HEX64.match(src))):
        out.append("header field source_content_sha256 must be 64 hex or \"unknown\": %r" % (src,))
    if h.get("context") not in ("server", "client"):
        out.append("header field context must be server|client: %r" % (h.get("context"),))
    if h.get("combat_id") is not None and not nonempty_str(h.get("combat_id")):
        out.append("header field combat_id must be a string when present: %r" % (h.get("combat_id"),))
    if h.get("fight") is not None and (not is_int(h.get("fight")) or h.get("fight") < 1):
        out.append("header field fight must be a positive integer when present: %r" % (h.get("fight"),))
    sfx = h.get("file_prefix_suffix")
    if sfx is not None and not (isinstance(sfx, str) and SUFFIX.match(sfx)):
        out.append("header field file_prefix_suffix malformed: %r" % (sfx,))
    if not is_int(h.get("part")) or h.get("part") < 1:
        out.append("header field part must be a positive integer: %r" % (h.get("part"),))
    if not is_int(h.get("first_seq")) or h.get("first_seq") < 1:
        out.append("header field first_seq must be a positive integer: %r" % (h.get("first_seq"),))
    return out


def check_stream(directory, prefix, numbers, max_input=DEFAULT_MAX_INPUT):
    try:
        return _check_stream(directory, prefix, numbers, max_input)
    except Exception as e:  # safety net (IR-13): structured incomplete report instead of a traceback
        rep = {"stream": prefix, "complete": False, "validated": False, "parts": [], "issues": [],
               "incomplete_reasons": ["validator internal error on malformed input: %s: %s" % (type(e).__name__, e)]}
        return rep, [], {}, {}


def _check_stream(directory, prefix, numbers, max_input):
    rep = {"stream": prefix, "parts": [], "missing_parts": [], "issues": [], "records": 0}
    issues = rep["issues"]
    total = sum(os.path.getsize(part_path(directory, prefix, n)) for n in numbers)
    rep["input_bytes"] = total
    if total > max_input:
        rep.update({"complete": False, "validated": False,
                    "incomplete_reasons": ["input %d bytes exceeds --max-input-bytes %d; not validated" % (total, max_input)]})
        return rep, [], {}, {}
    accepted = {}  # seq -> (record, canonical, part)
    duplicates_identical, conflicts = [], set()
    expected = 1
    for n in numbers:
        while expected < n:
            rep["missing_parts"].append(expected)
            expected += 1
        expected = n + 1
    final_trailer, headers, identity = None, {}, None
    prev_part_last, order_violations, overrides, bad_fields = None, 0, 0, 0
    for n in numbers:
        with open(part_path(directory, prefix, n), "rb") as fh:
            raw = fh.read()
        lines, tail = split_lines(raw)
        prep = {"part": n, "lines": len(lines), "torn_tail_bytes": len(tail) if tail else 0}
        if tail:
            issues.append("part %d: torn tail (%d bytes without LF)" % (n, len(tail)))
        header, trailer, records, unparsable, malformed = None, None, [], [], []
        record_bytes, ck = 0, 2166136261
        for i, line in enumerate(lines):
            try:
                rec = json.loads(line.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                unparsable.append(i + 1)
                continue
            if i == 0:
                header = rec
                continue
            if not isinstance(rec, dict):
                malformed.append(i + 1)
                continue
            if rec.get("kind") == "part_trailer":
                if trailer is not None:
                    issues.append("part %d: more than one trailer" % n)
                trailer = rec
                if i != len(lines) - 1:
                    issues.append("part %d: records after trailer" % n)
                continue
            records.append(rec)
            record_bytes += len(line) + 1
            ck = fnv1a32(line + b"\n", ck)
        if unparsable:
            issues.append("part %d: unparsable lines %s" % (n, unparsable[:10]))
        if malformed:
            issues.append("part %d: non-object lines %s" % (n, malformed[:10]))
        if not isinstance(header, dict) or header.get("kind") != "part_header":
            issues.append("part %d: missing or malformed part header" % n)
            header = {}
        else:
            for prob in header_problems(header):
                issues.append("part %d: %s" % (n, prob))
            if header.get("part") != n:
                issues.append("part %d: header says part %r (renamed/reordered/spliced file?)" % (n, header.get("part")))
            ident = tuple(header.get(k) for k in IDENTITY_KEYS)
            if identity is None:
                identity = ident
            elif ident != identity:
                diff = [k for k, a, b in zip(IDENTITY_KEYS, identity, ident) if a != b]
                issues.append("part %d: identity differs from part %d in %s (spliced stream?)" % (n, numbers[0], diff))
            expect_prefix = "%s-%s-%s%s" % (header.get("session_id"), header.get("context"), header.get("stream_id"),
                                           header.get("file_prefix_suffix") or "")
            if expect_prefix != prefix:
                issues.append("part %d: file prefix %r does not match header identity %r" % (n, prefix, expect_prefix))
        headers[n] = header
        prep.update({"header_first_seq": header.get("first_seq"), "records": len(records),
                     "trailer": trailer is not None, "final": bool(isinstance(trailer, dict) and trailer.get("final") is True),
                     "recovery_of": header.get("recovery_of"), "duplicate_uncertain": header.get("duplicate_uncertain"),
                     "oversized": header.get("oversized")})
        if header.get("recovery_of") is not None:
            issues.append("part %d: recovery part for part %r (duplicate uncertainty)" % (n, header["recovery_of"]))
        # record shape and envelope: before any sorting
        seqs = []
        for rec in records:
            s = rec.get("seq")
            if not is_int(s) or s < 1:
                issues.append("part %d: record with invalid seq %r" % (n, s))
                continue
            for k in ENVELOPE_KEYS:
                if k in rec and rec[k] != header.get(k if k != "part" else "part"):
                    overrides += 1
                    issues.append("part %d seq %d: record field %r=%r conflicts with the envelope (rejected)" % (n, s, k, rec[k]))
            if not isinstance(rec.get("kind"), str):
                bad_fields += 1
                issues.append("part %d seq %d: kind is not a string: %r" % (n, s, rec.get("kind")))
            if "obs" in rec and not is_int(rec["obs"]):
                bad_fields += 1
                issues.append("part %d seq %d: obs is not an integer: %r" % (n, s, rec["obs"]))
            if "prehistory" in rec and not isinstance(rec["prehistory"], bool):
                bad_fields += 1
                issues.append("part %d seq %d: prehistory is not a boolean" % (n, s))
            if seqs and s <= seqs[-1]:
                order_violations += 1
            seqs.append(s)
        if seqs and is_int(header.get("first_seq")) and seqs[0] != header["first_seq"]:
            issues.append("part %d: first seq %s != header first_seq %s" % (n, seqs[0], header["first_seq"]))
        if seqs and prev_part_last is not None and seqs[0] <= prev_part_last and header.get("recovery_of") is None:
            order_violations += 1
        if seqs:
            prev_part_last = seqs[-1]
        if trailer is not None:
            if not is_int(trailer.get("count")) or trailer.get("count") != len(records):
                issues.append("part %d: trailer count %r != %d records" % (n, trailer.get("count"), len(records)))
            if not is_int(trailer.get("record_bytes")) or trailer.get("record_bytes") != record_bytes:
                issues.append("part %d: trailer bytes %r != %d" % (n, trailer.get("record_bytes"), record_bytes))
            if seqs and (trailer.get("first_seq") != seqs[0] or trailer.get("last_seq") != seqs[-1]):
                issues.append("part %d: trailer seq range mismatch" % n)
            cks = trailer.get("checksum")
            if cks is not None:
                if not isinstance(cks, dict) or cks.get("alg") != "fnv1a32" or not isinstance(cks.get("value"), str):
                    issues.append("part %d: unsupported or malformed checksum %r" % (n, cks))
                else:
                    prep["checksum_ok"] = cks["value"] == "%08x" % ck
                    if not prep["checksum_ok"]:
                        issues.append("part %d: checksum mismatch" % n)
            if trailer.get("final") is True:
                if final_trailer is not None:
                    issues.append("part %d: second final trailer" % n)
                final_trailer = trailer
                if n != numbers[-1]:
                    issues.append("part %d: final trailer is not on the last part" % n)
        elif n != numbers[-1] and not header.get("recovery_of"):
            nxt = numbers[numbers.index(n) + 1]
            if _recovery_target(directory, prefix, nxt) != n:
                issues.append("part %d: unsealed (no trailer) but not the last part" % n)
        for rec in records:
            s = rec.get("seq")
            if not is_int(s) or s < 1:
                continue
            c = canonical(rec)
            if s in accepted:
                if accepted[s][1] == c:
                    duplicates_identical.append(s)
                else:
                    conflicts.add(s)
            else:
                accepted[s] = (rec, c, n)
        rep["parts"].append(prep)
    if order_violations:
        issues.append("%d storage-order violations (records not increasing within/across parts)" % order_violations)
    for s in sorted(conflicts):
        accepted.pop(s, None)
    if rep["missing_parts"]:
        issues.append("missing parts %s" % rep["missing_parts"])
    if duplicates_identical:
        issues.append("identical duplicate seqs (reported, kept once): %s" % sorted(set(duplicates_identical))[:20])
    if conflicts:
        issues.append("conflicting duplicate seqs (rejected): %s" % sorted(conflicts)[:20])
    seqs = sorted(accepted)
    gaps, prev = [], 0
    for s in seqs:
        if s != prev + 1:
            gaps.append([prev + 1, s - 1])
        prev = s
    final_last = final_trailer.get("stream_last_seq") if final_trailer else None
    if final_trailer is not None:
        if not is_int(final_last) or final_last < 0:
            issues.append("final trailer stream_last_seq malformed: %r" % (final_last,))
        elif prev > final_last:
            issues.append("records beyond final stream_last_seq %d (max seq %d)" % (final_last, prev))
        elif prev < final_last:
            gaps.append([prev + 1, final_last])
    gaps.extend([[s, s] for s in sorted(conflicts) if not any(a <= s <= b for a, b in gaps)])
    if gaps:
        issues.append("seq gaps %s" % gaps[:20])
    ordered = [accepted[s][0] for s in seqs]
    kinds = {}
    for r in ordered:
        k = r.get("kind") if isinstance(r.get("kind"), str) else "<invalid kind>"
        kinds[k] = kinds.get(k, 0) + 1
    gap_records = [r for r in ordered if r.get("kind") == "capture_gap"]
    lost_required = lost_optional = 0
    for r in gap_records:
        d = r.get("data")
        if not isinstance(d, dict) or not is_int(d.get("required", 0)) or not is_int(d.get("optional", 0)):
            issues.append("seq %d: malformed capture_gap data" % r["seq"])
            lost_required += 1  # unknown amount: count as at least one lost observation
            continue
        lost_required += d.get("required", 0)
        lost_optional += d.get("optional", 0)
    terminal = [r for r in ordered if r.get("kind") == "terminal_error"]
    inversions, last_obs = 0, None
    for r in ordered:
        if r.get("prehistory") is True:
            continue
        o = r.get("obs")
        if is_int(o):
            if last_obs is not None and o < last_obs:
                inversions += 1
            last_obs = o
    if inversions:
        issues.append("%d observation-order inversions outside prehistory (callback order not preserved)" % inversions)
    delta = check_deltas(ordered, accepted, issues)
    rep.update({"validated": True, "records": len(ordered), "delta_bases_missing": delta["missing"],
                "delta_invalid": delta["invalid"], "delta_max_chain": delta["max_chain"],
                "first_seq": seqs[0] if seqs else None, "last_seq": prev or None,
                "gaps": gaps, "duplicates_identical": len(duplicates_identical), "conflicts": sorted(conflicts),
                "storage_order_violations": order_violations, "envelope_overrides": overrides,
                "malformed_fields": bad_fields, "kinds": kinds, "terminal_errors": len(terminal),
                "capture_gaps": {"records": len(gap_records), "lost_required": lost_required, "lost_optional": lost_optional},
                "late_after_end": sum(1 for r in ordered if r.get("late_after_end") is True),
                "prehistory": sum(1 for r in ordered if r.get("prehistory") is True),
                "obs_order_inversions_outside_prehistory": inversions,
                "final_trailer": final_trailer is not None,
                "final_capture": final_trailer.get("capture") if final_trailer else None,
                "end_reason": final_trailer.get("end_reason") if final_trailer else None})
    rep["manifest"] = check_manifest(directory, prefix, rep, final_trailer)
    reasons = []
    if not final_trailer:
        reasons.append("no final trailer (stream still open, crashed or reset)")
    elif final_trailer.get("capture") != "ok":
        reasons.append("final capture state %r" % (final_trailer.get("capture"),))
    if rep["missing_parts"]:
        reasons.append("missing parts")
    if gaps:
        reasons.append("seq gaps")
    if conflicts:
        reasons.append("conflicting duplicates")
    if lost_required or lost_optional:
        reasons.append("capture_gap records (lost observations)")
    if terminal:
        reasons.append("terminal_error records")
    if issues and not reasons:
        reasons.append("structural issues")
    rep["complete"] = not reasons and not issues
    rep["incomplete_reasons"] = reasons
    rep["identity"] = dict(zip(IDENTITY_KEYS, identity)) if identity else None
    return rep, ordered, headers, accepted


def check_deltas(ordered, accepted, issues):
    """IR-20: every delta sample's base_seq is an earlier accepted checkpoint holding the same actor, and following
    bases ends at a full anchor (no self/future/cyclic or unrooted ancestry; no full sample with a base)."""
    samples = {}  # (seq, uuid) -> sample dict
    malformed = 0
    for r in ordered:
        if r.get("kind") != "checkpoint":
            continue
        d = r.get("data")
        actors = d.get("actors") if isinstance(d, dict) else None
        if not isinstance(actors, list):
            malformed += 1
            issues.append("seq %d: checkpoint without an actors list" % r["seq"])
            continue
        for a in actors:
            if not isinstance(a, dict) or not nonempty_str(a.get("uuid")):
                malformed += 1
                issues.append("seq %d: malformed checkpoint actor sample %r" % (r["seq"], a if not isinstance(a, dict) else a.get("uuid")))
                continue
            samples[(r["seq"], a["uuid"])] = a
    rooted, missing, invalid, max_chain = {}, 0, malformed, 0

    def root(seq, uuid):
        """(status, steps from this sample to its full anchor). Bases strictly decrease, so no cycles recurse.
        run-019: an earlier version memoized depths relative to the first query and under-reported chains."""
        key = (seq, uuid)
        if key in rooted:
            return rooted[key]
        a = samples.get(key)
        full, base = (a.get("full") is True, a.get("base_seq")) if a is not None else (False, None)
        if a is None:
            res = ("missing", 0)
        elif full and base is not None:
            res = ("contradictory", 0)
        elif full:
            res = ("ok", 0)
        elif base is None:
            res = ("unanchored", 0)
        elif not is_int(base) or base < 1 or base >= seq:
            res = ("bad_base", 0)
        else:
            status, steps = root(base, uuid)
            res = (status, steps + 1)
        rooted[key] = res
        return res

    for (seq, uuid), a in sorted(samples.items()):
        if a.get("full") is True and a.get("base_seq") is None:
            continue
        status, depth = root(seq, uuid)
        max_chain = max(max_chain, depth)
        if status == "missing":
            missing += 1
            issues.append("seq %d actor %s: delta base_seq %r missing or lacks this actor" % (seq, uuid, a.get("base_seq")))
        elif status != "ok":
            invalid += 1
            issues.append("seq %d actor %s: delta chain %s (base_seq %r)" % (seq, uuid, status, a.get("base_seq")))
    if missing:
        issues.append("%d delta checkpoint samples reference a missing base_seq" % missing)
    return {"missing": missing, "invalid": invalid, "max_chain": max_chain}


def check_manifest(directory, prefix, rep, final_trailer):
    path = os.path.join(directory, prefix + "-manifest.json")
    out = {"present": os.path.exists(path), "trusted": False, "mismatches": []}
    if not out["present"]:
        return out
    try:
        with open(path, "rb") as fh:
            m = json.loads(fh.read().decode("utf-8"))
        if not isinstance(m, dict):
            raise ValueError("not an object")
    except (ValueError, UnicodeDecodeError) as e:
        out["error"] = "unparsable manifest: %s" % e
        return out
    if m.get("last_seq") != rep.get("last_seq"):
        out["mismatches"].append("last_seq %r != parts %r" % (m.get("last_seq"), rep.get("last_seq")))
    found = {p["part"]: p for p in rep["parts"]}
    parts = m.get("parts")
    if parts is not None and not isinstance(parts, list):
        out["mismatches"].append("manifest parts is not a list")
        parts = []
    for p in parts or []:
        if not isinstance(p, dict) or not is_int(p.get("part")):
            out["mismatches"].append("malformed manifest part entry %r" % (p,))
            continue
        if p.get("state") != "sealed":
            continue
        f = found.get(p["part"])
        if not f:
            out["mismatches"].append("manifest part %r missing on disk" % p["part"])
        elif f["records"] != p.get("count"):
            out["mismatches"].append("part %r count %r != %r on disk" % (p["part"], p.get("count"), f["records"]))
    if m.get("capture") != (final_trailer or {}).get("capture"):
        out["mismatches"].append("capture %r != final trailer %r" % (m.get("capture"), (final_trailer or {}).get("capture")))
    return out


def legacy_import(path, sha256=None, max_input=DEFAULT_MAX_INPUT):
    try:
        return _legacy_import(path, sha256, max_input)
    except Exception as e:  # safety net (IR-13): structured incomplete report instead of a traceback
        return {"file": path, "schema_version": 1, "complete": False, "validated": False,
                "incomplete_reasons": ["importer internal error on malformed input: %s: %s" % (type(e).__name__, e)]}, []


def _legacy_import(path, sha256, max_input):
    size = os.path.getsize(path)
    if size > max_input:
        return {"file": path, "schema_version": 1, "complete": False, "validated": False,
                "incomplete_reasons": ["input %d bytes exceeds --max-input-bytes %d; not imported" % (size, max_input)]}, []
    with open(path, "rb") as fh:
        raw = fh.read()
    digest = hashlib.sha256(raw).hexdigest()
    rep = {"file": path, "sha256": digest, "schema_version": 1, "sha256_matches": None if sha256 is None else digest == sha256}
    lines, tail = split_lines(raw)
    out, kinds, unparsable, malformed = [], {}, [], []
    pos = {"present": 0, "x_only": 0, "xyz": 0, "other": 0, "absent_on_character": 0}
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            rec = json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            unparsable.append(i + 1)
            continue
        if not isinstance(rec, dict):
            unparsable.append(i + 1)
            continue
        kind, data, pre = rec.get("kind"), rec.get("data"), False
        if kind == "prep" and isinstance(data, dict):
            kind, data, pre = data.get("kind"), data.get("data"), True
        chars = data.get("characters") if rec.get("kind") == "snapshot" and isinstance(data, dict) else None
        if chars is not None and not isinstance(chars, list):
            malformed.append(i + 1)  # IR-13 round 3: a non-list collection is reported, never iterated
            chars = None
        if chars is not None:
            for ch in chars:
                if not isinstance(ch, dict):
                    continue
                p = ch.get("pos")
                if p is None:
                    pos["absent_on_character"] += 1
                    continue
                pos["present"] += 1
                if isinstance(p, list) and len(p) == 1:
                    pos["x_only"] += 1
                    ch["pos"] = {"x": p[0], "y": None, "z": None, "valid": False, "legacy_xyz_ambiguous": True}
                elif isinstance(p, list) and len(p) == 3:
                    pos["xyz"] += 1
                    ch["pos"] = {"x": p[0], "y": p[1], "z": p[2], "valid": None, "legacy_unverified": True}
                else:
                    pos["other"] += 1
        k = rec.get("kind") if isinstance(rec.get("kind"), str) else "<invalid kind>"
        kinds[k] = kinds.get(k, 0) + 1
        out.append({"schema_version": 1, "storage_index": i + 1, "seq": None, "obs": None, "t": rec.get("t"),
                    "kind": kind, "data": data, "prehistory": pre or None,
                    "legacy_notes": "storage order only; no seq/obs; producer source unknown"})
    rep.update({"lines": len(lines), "torn_tail_bytes": len(tail) if tail else 0, "records": len(out),
                "unparsable": unparsable, "malformed_snapshot_lines": malformed, "kinds_raw": kinds, "positions": pos,
                "limits": ["no sequence numbers: gaps/duplicates cannot be detected",
                           "X-only positions cannot be completed (Y/Z unknown, not zero)",
                           "registration success does not establish hook coverage"],
                "complete": False})
    return rep, out


def _same(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))


def check_outputs(outputs, inputs, overwrite):
    """Return an error string if any output would overwrite an input, a protected file, another output or (without
    --overwrite) any existing file."""
    outs = [o for o in outputs if o]
    for i, o in enumerate(outs):
        for other in outs[i + 1:]:
            if os.path.normcase(os.path.realpath(o)) == os.path.normcase(os.path.realpath(other)) or (
                    os.path.exists(o) and os.path.exists(other) and _same(o, other)):
                return "output paths collide: %s" % o
        if os.path.exists(o):
            if not overwrite:
                return "refusing to overwrite existing %s (use --overwrite)" % o
            for src in list(inputs) + PROTECTED:
                if os.path.exists(src) and _same(o, src):
                    return "refusing to write %s: it is an input or protected file (%s)" % (o, src)
        else:
            real = os.path.normcase(os.path.realpath(o))
            for src in list(inputs) + PROTECTED:
                if os.path.normcase(os.path.realpath(src)) == real:
                    return "refusing to write %s: it is an input or protected file" % o
    return None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--stream")
    ap.add_argument("--report")
    ap.add_argument("--out")
    ap.add_argument("--legacy")
    ap.add_argument("--sha256")
    ap.add_argument("--overwrite", action="store_true")
    ap.add_argument("--max-input-bytes", type=int, default=DEFAULT_MAX_INPUT)
    a = ap.parse_args(argv)
    if a.legacy:
        inputs = [a.legacy]
    elif a.dir and os.path.isdir(a.dir):
        inputs = [os.path.join(a.dir, n) for n in os.listdir(a.dir)]
    else:
        ap.print_usage()
        return 2
    err = check_outputs([a.out, a.report], inputs, a.overwrite)
    if err:
        print(err, file=sys.stderr)
        return 2
    out_fh = open(a.out, "w", encoding="utf-8", newline="\n") if a.out else None
    try:
        if a.legacy:
            rep, recs = legacy_import(a.legacy, a.sha256, a.max_input_bytes)
            reports, ok = [rep], False
            if out_fh:
                for r in recs:
                    out_fh.write(json.dumps(r, sort_keys=True) + "\n")
        else:
            streams = discover(a.dir)
            if a.stream:
                streams = {a.stream: streams.get(a.stream, [])}
            reports, ok = [], bool(streams)
            for prefix, numbers in sorted(streams.items()):
                if not numbers:
                    reports.append({"stream": prefix, "complete": False, "incomplete_reasons": ["no parts"]})
                    ok = False
                    continue
                rep, ordered, headers, accepted = check_stream(a.dir, prefix, numbers, a.max_input_bytes)
                reports.append(rep)
                ok = ok and rep["complete"]
                if out_fh:
                    for r in ordered:
                        h = headers.get(accepted[r["seq"]][2], {})
                        env = dict(r)
                        for k in IDENTITY_KEYS:  # the checked header identity always wins over record fields
                            env.pop(k, None)
                            if h.get(k) is not None:
                                env[k] = h[k]
                        env["part"] = accepted[r["seq"]][2]
                        out_fh.write(json.dumps(env, sort_keys=True) + "\n")
                del ordered, headers, accepted
    finally:
        if out_fh:
            out_fh.close()
    text = json.dumps({"streams": reports}, indent=1, sort_keys=True)
    if a.report:
        with open(a.report, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text + "\n")
    else:
        print(text)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
