"""Tests of tools/reassemble.py on parts produced by the Lua suite (tests/test_recorder.lua --dump DIR).

Run through tests/run_all.py, which dumps a fresh set first. FR2_DUMP_DIR overrides the dump location.
The optional external-evidence test reads the retained legacy capture read-only and only if its pinned hash matches.
"""
import glob
import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
if os.environ.get("FR2_REASSEMBLE"):  # tests/mutation_check.py points this at a mutated copy
    import importlib.util
    _spec = importlib.util.spec_from_file_location("reassemble", os.environ["FR2_REASSEMBLE"])
    reassemble = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(reassemble)
else:
    import reassemble  # noqa: E402

LF = bytes([10])
DUMP = os.environ.get("FR2_DUMP_DIR", os.path.join(REPO, "work", "test-out", "lua"))
LEGACY_FIGHT04 = r"D:\MyCode\bg3 item mods\combat-sim\evidence\chapel-runtime-intake-v150\raw\1792664924-fight04.jsonl"
LEGACY_FIGHT04_SHA256 = "d8dfe3ac074f250895c4398ff6f276e3f54b3e6daa3d5a2ed8bd38bc641626a5"


def fight_prefix(directory):
    names = [n for n in os.listdir(directory) if "-server-fight01-p" in n]
    return sorted(names)[0].rsplit("-p", 1)[0]


class Case(unittest.TestCase):
    def stage(self, case):
        src = os.path.join(DUMP, case, "FightRec2")
        if not os.path.isdir(src):
            self.fail("missing Lua dump %s; run tests/run_all.py" % src)
        d = tempfile.mkdtemp(prefix="fr2-")
        self.addCleanup(shutil.rmtree, d)
        for p in glob.glob(os.path.join(src, "*")):
            shutil.copy(p, d)
        return d, fight_prefix(d)

    def check(self, d, prefix):
        streams = reassemble.discover(d)
        rep, ordered, _, _ = reassemble.check_stream(d, prefix, streams[prefix])
        return rep, ordered

    def part(self, d, prefix, n):
        return os.path.join(d, "%s-p%05d.jsonl" % (prefix, n))

    def multi_record_part(self, d, prefix, skip=()):
        """(part number, lines) of the first part holding >= 2 records (small caps put the big meta alone)."""
        for n in reassemble.discover(d)[prefix]:
            if n in skip:
                continue
            with open(self.part(d, prefix, n), "rb") as fh:
                lines = fh.read().split(LF)
            if sum(1 for ln in lines if ln.startswith(b'{"') and b'"seq":' in ln) >= 2:
                return n, lines
        self.fail("no part with two records")


class CleanStreams(Case):
    def test_many_parts_complete(self):
        d, p = self.stage("many_parts")
        rep, ordered = self.check(d, p)
        self.assertTrue(rep["complete"], rep["issues"])
        self.assertGreaterEqual(len(rep["parts"]), 6)
        self.assertEqual([r["seq"] for r in ordered], list(range(1, rep["records"] + 1)))
        self.assertEqual(rep["kinds"]["CastedSpell"], 60)
        self.assertTrue(rep["manifest"]["present"])
        self.assertEqual(rep["manifest"]["mismatches"], [])
        self.assertFalse(rep["manifest"]["trusted"])

    def test_end_only_complete(self):
        d, p = self.stage("end_only")
        rep, _ = self.check(d, p)
        self.assertTrue(rep["complete"], rep["issues"])
        self.assertEqual(rep["kinds"].get("end"), 1)

    def test_oversized_part(self):
        d, p = self.stage("oversized")
        rep, _ = self.check(d, p)
        self.assertTrue(rep["complete"], rep["issues"])
        self.assertTrue(any(x["oversized"] for x in rep["parts"]))

    def test_checksum_validated(self):
        d, p = self.stage("checksum")
        rep, _ = self.check(d, p)
        self.assertTrue(rep["complete"], rep["issues"])
        self.assertTrue(all(x.get("checksum_ok") for x in rep["parts"]))

    def test_checksum_detects_byte_change(self):
        d, p = self.stage("checksum")
        n, lines = self.multi_record_part(d, p)
        i = next(i for i, ln in enumerate(lines) if b"STATUS_" in ln)
        lines[i] = lines[i].replace(b"STATUS_", b"STATUZ_", 1)
        with open(self.part(d, p, n), "wb") as fh:
            fh.write(LF.join(lines))
        rep, _ = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertTrue(any("checksum mismatch" in i for i in rep["issues"]))


class Corruption(Case):
    def test_missing_part(self):
        d, p = self.stage("many_parts")
        os.remove(self.part(d, p, 2))
        rep, _ = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertEqual(rep["missing_parts"], [2])
        self.assertTrue(rep["gaps"])

    def test_reordered_parts(self):
        d, p = self.stage("many_parts")
        a, b, tmp = self.part(d, p, 2), self.part(d, p, 3), self.part(d, p, 99)
        os.rename(a, tmp)
        os.rename(b, a)
        os.rename(tmp, b)
        rep, ordered = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertTrue(any("renamed/reordered" in i for i in rep["issues"]))
        self.assertEqual([r["seq"] for r in ordered], sorted(r["seq"] for r in ordered), "output still in seq order")

    def test_truncated_last_part(self):
        d, p = self.stage("many_parts")
        n = max(reassemble.discover(d)[p])
        path = self.part(d, p, n)
        with open(path, "rb") as fh:
            raw = fh.read()
        with open(path, "wb") as fh:
            fh.write(raw[: len(raw) - 40])
        rep, _ = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertTrue(any("torn tail" in i for i in rep["issues"]))
        self.assertFalse(rep["final_trailer"])

    def test_identical_duplicate_reported(self):
        d, p = self.stage("many_parts")
        n1, src = self.multi_record_part(d, p)
        rec_line = src[1]
        n2, lines = self.multi_record_part(d, p, skip=(n1,))
        lines.insert(1, rec_line)
        with open(self.part(d, p, n2), "wb") as fh:
            fh.write(LF.join(lines))
        rep, ordered = self.check(d, p)
        self.assertEqual(rep["duplicates_identical"], 1)
        self.assertEqual(len(ordered), len({r["seq"] for r in ordered}))
        self.assertFalse(rep["complete"])

    def test_conflicting_duplicate_rejected(self):
        d, p = self.stage("many_parts")
        n1, src = self.multi_record_part(d, p)
        rec = json.loads(src[1])
        rec["data"] = {"forged": True}
        n2, lines = self.multi_record_part(d, p, skip=(n1,))
        lines.insert(1, json.dumps(rec).encode())
        with open(self.part(d, p, n2), "wb") as fh:
            fh.write(LF.join(lines))
        rep, ordered = self.check(d, p)
        self.assertEqual(rep["conflicts"], [rec["seq"]])
        self.assertNotIn(rec["seq"], [r["seq"] for r in ordered])
        self.assertIn([rec["seq"], rec["seq"]], rep["gaps"])
        self.assertFalse(rep["complete"])

    def test_delta_base_missing_detected(self):
        d, p = self.stage("delta")
        rep, _ = self.check(d, p)
        self.assertEqual(rep["delta_bases_missing"], 0, rep["issues"])
        self.assertEqual(rep["terminal_errors"], 1, "the deliberately unencodable checkpoint")
        target = None
        for n in reassemble.discover(d)[p]:
            path = self.part(d, p, n)
            with open(path, "rb") as fh:
                lines = fh.read().split(b"\n")
            for i, line in enumerate(lines[1:-2], start=1):
                rec = json.loads(line)
                if rec.get("kind") == "checkpoint" and rec["data"]["actors"][0].get("full"):
                    target = (path, lines, i)
                    break
            if target:
                break
        path, lines, i = target
        del lines[i]
        with open(path, "wb") as fh:
            fh.write(b"\n".join(lines))
        rep, _ = self.check(d, p)
        self.assertGreater(rep["delta_bases_missing"], 0)
        self.assertTrue(any("missing base_seq" in i for i in rep["issues"]))

    def test_trailer_count_mismatch(self):
        d, p = self.stage("many_parts")
        n, lines = self.multi_record_part(d, p)
        del lines[2]
        with open(self.part(d, p, n), "wb") as fh:
            fh.write(LF.join(lines))
        rep, _ = self.check(d, p)
        self.assertTrue(any("trailer count" in i for i in rep["issues"]))
        self.assertTrue(rep["gaps"])

    def test_bad_manifest_not_trusted(self):
        d, p = self.stage("many_parts")
        with open(os.path.join(d, p + "-manifest.json"), "w") as fh:
            fh.write("{not json")
        rep, _ = self.check(d, p)
        self.assertIn("unparsable", rep["manifest"]["error"])
        self.assertTrue(rep["complete"], "parts alone suffice")

    def test_missing_manifest(self):
        d, p = self.stage("many_parts")
        os.remove(os.path.join(d, p + "-manifest.json"))
        rep, _ = self.check(d, p)
        self.assertFalse(rep["manifest"]["present"])
        self.assertTrue(rep["complete"])

    def test_stale_manifest_mismatch_reported(self):
        d, p = self.stage("many_parts")
        mp = os.path.join(d, p + "-manifest.json")
        with open(mp) as fh:
            m = json.load(fh)
        m["last_seq"] = 3
        m["parts"][0]["count"] = 999
        with open(mp, "w") as fh:
            json.dump(m, fh)
        rep, _ = self.check(d, p)
        self.assertGreaterEqual(len(rep["manifest"]["mismatches"]), 2)

    def test_open_stream_without_final_trailer(self):
        d, p = self.stage("many_parts")
        n = max(reassemble.discover(d)[p])
        path = self.part(d, p, n)
        with open(path, "rb") as fh:
            lines = fh.read().split(b"\n")
        with open(path, "wb") as fh:
            fh.write(b"\n".join(lines[:-2] + [b""]))  # drop trailer line, keep LF termination
        rep, _ = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertIn("no final trailer (stream still open, crashed or reset)", rep["incomplete_reasons"])


class IntegrityStreams(Case):
    def test_append_recovery_duplicates(self):
        d, p = self.stage("append_partial")
        rep, ordered = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertGreaterEqual(rep["duplicates_identical"], 1)
        self.assertEqual(rep["conflicts"], [])
        self.assertEqual(rep["gaps"], [])
        self.assertTrue(any(x["recovery_of"] == 1 for x in rep["parts"]))

    def test_saturation_reports_loss(self):
        d, p = self.stage("saturation")
        rep, _ = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertGreater(rep["capture_gaps"]["lost_required"], 0)
        self.assertEqual(rep["final_capture"], "incomplete")
        self.assertEqual(rep["gaps"], [], "losses have no seq: storage stays contiguous")

    def test_merged_output_has_envelope(self):
        d, p = self.stage("many_parts")
        out = os.path.join(d, "merged.jsonl")
        rc = reassemble.main([d, "--stream", p, "--out", out, "--report", os.path.join(d, "r.json")])
        self.assertEqual(rc, 0)
        with open(out) as fh:
            first = json.loads(fh.readline())
        for k in ("session_id", "context", "stream_id", "schema_version", "recorder_version",
                  "source_content_sha256", "seq", "obs", "t", "kind", "part"):
            self.assertIn(k, first)
        self.assertEqual(first["source_content_sha256"], "unknown")


class Legacy(Case):
    def test_legacy_import_preserves_ambiguity(self):
        src = os.path.join(DUMP, "legacy_workload_baseline", "FightRec")
        path = glob.glob(os.path.join(src, "*-fight01.jsonl"))[0]
        rep, out = reassemble.legacy_import(path)
        self.assertEqual(rep["schema_version"], 1)
        self.assertFalse(rep["complete"])
        self.assertGreater(rep["positions"]["x_only"], 0)
        self.assertEqual(rep["positions"]["xyz"], 0)
        pre = [r for r in out if r["prehistory"]]
        self.assertTrue(pre and pre[0]["kind"] == "StatusApplied")
        self.assertTrue(all(r["seq"] is None for r in out))
        snap = next(r for r in out if r["kind"] == "snapshot")
        self.assertEqual(snap["data"]["characters"][0]["pos"]["y"], None)
        self.assertTrue(snap["data"]["characters"][0]["pos"]["legacy_xyz_ambiguous"])

    @unittest.skipUnless(os.path.exists(LEGACY_FIGHT04), "external retained evidence not present")
    def test_external_fight04_counts_read_only(self):
        rep, out = reassemble.legacy_import(LEGACY_FIGHT04, LEGACY_FIGHT04_SHA256)
        self.assertTrue(rep["sha256_matches"], "pinned evidence hash")
        k = rep["kinds_raw"]
        self.assertEqual(rep["records"], 637)
        for kind, n in {"TurnStarted": 42, "TurnEnded": 42, "CastedSpell": 45, "UsingSpellOnTarget": 35,
                        "BeforeDealDamage": 26, "DealDamage": 26, "DealtDamage": 26, "StatusApplied": 114,
                        "StatusRemoved": 93, "RollResult": 9, "snapshot": 2}.items():
            self.assertEqual(k.get(kind), n, kind)
        self.assertEqual(rep["positions"]["xyz"], 0)
        self.assertGreater(rep["positions"]["x_only"], 0)


class StampTool(unittest.TestCase):
    def setUp(self):
        import stamp_build
        self.sb = stamp_build
        self.d = tempfile.mkdtemp(prefix="fr2-stamp-")
        self.addCleanup(shutil.rmtree, self.d)
        self.src = os.path.join(REPO, "recorder", "FightRec.lua")

    def test_stamp_and_verify(self):
        out = os.path.join(self.d, "FightRec.lua")
        content, artifact = self.sb.stamp(self.src, out)
        with open(self.src, "rb") as fh:
            self.assertEqual(content, hashlib.sha256(fh.read()).hexdigest())
        with open(out, "rb") as fh:
            raw = fh.read()
        self.assertEqual(artifact, hashlib.sha256(raw).hexdigest())
        self.assertNotEqual(content, artifact, "content claim and artifact hash are different things (IR-05)")
        self.assertEqual(self.sb.verify(out), (content, artifact))
        self.assertIn(('local SOURCE_CONTENT_SHA256 = "%s"' % content).encode(), raw)

    def test_edit_after_stamp_detected(self):
        out = os.path.join(self.d, "FightRec.lua")
        self.sb.stamp(self.src, out)
        with open(out, "rb") as fh:
            raw = fh.read()
        with open(out, "wb") as fh:
            fh.write(raw.replace(b"FightRec v2:", b"FightRec v2 (edited):", 1))
        with self.assertRaises(SystemExit) as cm:
            self.sb.verify(out)
        self.assertIn("edited after stamping", str(cm.exception))

    def test_refuses_protected_and_existing_outputs(self):
        with open(self.src, "rb") as fh:
            before = hashlib.sha256(fh.read()).hexdigest()
        for target in (self.src, os.path.join(REPO, "baseline", "FightRec.lua")):
            with self.assertRaises(SystemExit):
                self.sb.stamp(self.src, target, overwrite=True)
        out = os.path.join(self.d, "exists.lua")
        with open(out, "wb") as fh:
            fh.write(b"keep")
        with self.assertRaises(SystemExit):
            self.sb.stamp(self.src, out)
        with open(out, "rb") as fh:
            self.assertEqual(fh.read(), b"keep")
        with open(self.src, "rb") as fh:
            self.assertEqual(hashlib.sha256(fh.read()).hexdigest(), before)
        with open(os.path.join(REPO, "baseline", "FightRec.lua"), "rb") as fh:
            self.assertEqual(hashlib.sha256(fh.read()).hexdigest(),
                             "a8a72fa165dae06df499821e04c2fc8e3199cc8f1ab96a1fbfd587fb772af4a9")


class ReviewRound1(Case):
    """Regressions for reviews/implementation-round-1.txt IR-11..IR-15."""

    def rewrite_line(self, path, index, fn):
        with open(path, "rb") as fh:
            lines = fh.read().split(LF)
        lines[index] = fn(lines[index])
        with open(path, "wb") as fh:
            fh.write(LF.join(lines))

    def test_ir11_spliced_part_from_another_stream(self):
        d, p = self.stage("many_parts")
        # run-015: splicing from the end_only dump proved nothing about identity -- the deterministic mock GUID
        # gives both dumps the same session; take a part of a genuinely different stream (session) instead
        other_dir = d
        other_p = next(x for x in reassemble.discover(d) if x.endswith("-server-session"))
        n = max(reassemble.discover(d)[p])
        last = self.part(d, p, n)
        # drop our final trailer so the splice looks like a continuation, then append a foreign part
        with open(last, "rb") as fh:
            lines = fh.read().split(LF)
        with open(last, "wb") as fh:
            fh.write(LF.join(lines[:-2] + [b""]))
        shutil.copy(self.part(other_dir, other_p, 1), self.part(d, p, n + 1))
        self.rewrite_line(self.part(d, p, n + 1), 0, lambda ln: ln.replace(b'"part":1', b'"part":%d' % (n + 1)))
        rep, _ = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertTrue(any("identity differs" in i for i in rep["issues"]), rep["issues"])
        self.assertTrue(any("does not match header identity" in i for i in rep["issues"]))

    def test_ir11_unsupported_schema(self):
        d, p = self.stage("many_parts")
        self.rewrite_line(self.part(d, p, 1), 0, lambda ln: ln.replace(b'"schema_version":2', b'"schema_version":3'))
        rep, _ = self.check(d, p)
        self.assertFalse(rep["complete"])
        self.assertTrue(any("unsupported schema_version 3" in i for i in rep["issues"]))

    def test_ir12_interior_swap_keeping_endpoints(self):
        d, p = self.stage("many_parts")
        n, lines = self.multi_record_part(d, p)
        recs = [i for i, ln in enumerate(lines) if b'"seq":' in ln and b"part_trailer" not in ln and i > 0]
        if len(recs) < 4:
            self.skipTest("need four records in one part")
        a, b = recs[1], recs[2]
        lines[a], lines[b] = lines[b], lines[a]
        with open(self.part(d, p, n), "wb") as fh:
            fh.write(LF.join(lines))
        rep, _ = self.check(d, p)
        self.assertGreater(rep["storage_order_violations"], 0)
        self.assertFalse(rep["complete"])

    def test_ir12_obs_inversion_outside_prehistory(self):
        d, p = self.stage("many_parts")
        n, lines = self.multi_record_part(d, p)
        i = next(i for i, ln in enumerate(lines) if b'"kind":"CastedSpell"' in ln)
        rec = json.loads(lines[i])
        rec["obs"] = 1
        lines[i] = json.dumps(rec, separators=(",", ":")).encode()
        with open(self.part(d, p, n), "wb") as fh:
            fh.write(LF.join(lines))
        rep, _ = self.check(d, p)
        self.assertGreater(rep["obs_order_inversions_outside_prehistory"], 0)
        self.assertFalse(rep["complete"])

    def test_ir12_final_range_undershoot(self):
        d, p = self.stage("many_parts")
        n = max(reassemble.discover(d)[p])
        path = self.part(d, p, n)
        with open(path, "rb") as fh:
            lines = fh.read().split(LF)
        tr = json.loads(lines[-2])
        tr["stream_last_seq"] -= 1
        lines[-2] = json.dumps(tr, separators=(",", ":")).encode()
        with open(path, "wb") as fh:
            fh.write(LF.join(lines))
        rep, _ = self.check(d, p)
        self.assertTrue(any("beyond final stream_last_seq" in i for i in rep["issues"]))
        self.assertFalse(rep["complete"])

    def test_ir13_malformed_shapes_reported_not_raised(self):
        for mutate in (lambda ln: b"5", lambda ln: b"[1,2]",
                       lambda ln: ln.replace(b'"part":1', b'"part":true')):
            d, p = self.stage("many_parts")
            self.rewrite_line(self.part(d, p, 1), 0, mutate)
            rep, _ = self.check(d, p)
            self.assertFalse(rep["complete"])
        d, p = self.stage("checksum")
        n, lines = self.multi_record_part(d, p)
        tr = json.loads(lines[-2])
        tr["checksum"] = "not-an-object"
        lines[-2] = json.dumps(tr).encode()
        i = next(i for i, ln in enumerate(lines) if b'"seq":' in ln and i > 0 and b"part_trailer" not in ln)
        rec = json.loads(lines[i])
        rec["seq"] = True
        lines[i] = json.dumps(rec).encode()
        lines.insert(2, b'"a bare string line"')
        with open(self.part(d, p, n), "wb") as fh:
            fh.write(LF.join(lines))
        rep, _ = self.check(d, p)
        self.assertTrue(any("malformed checksum" in x for x in rep["issues"]))
        self.assertTrue(any("invalid seq True" in x for x in rep["issues"]))
        self.assertTrue(any("non-object lines" in x for x in rep["issues"]))

    def test_ir14_outputs_never_overwrite_inputs(self):
        d, p = self.stage("many_parts")
        victim = self.part(d, p, 1)
        with open(victim, "rb") as fh:
            before = fh.read()
        self.assertEqual(reassemble.main([d, "--out", victim]), 2)
        self.assertEqual(reassemble.main([d, "--report", victim, "--overwrite"]), 2)
        same = os.path.join(d, "x.json")
        self.assertEqual(reassemble.main([d, "--out", same, "--report", same]), 2)
        self.assertEqual(reassemble.main([d, "--out", os.path.join(REPO, "baseline", "FightRec.lua"), "--overwrite"]), 2)
        legacy = glob.glob(os.path.join(DUMP, "legacy_workload_baseline", "FightRec", "*-fight01.jsonl"))[0]
        tmp_legacy = os.path.join(tempfile.mkdtemp(prefix="fr2-leg-"), "legacy.jsonl")
        self.addCleanup(shutil.rmtree, os.path.dirname(tmp_legacy))
        shutil.copy(legacy, tmp_legacy)
        with open(tmp_legacy, "rb") as fh:
            lbefore = fh.read()
        self.assertEqual(reassemble.main(["--legacy", tmp_legacy, "--out", tmp_legacy, "--overwrite"]), 2)
        with open(tmp_legacy, "rb") as fh:
            self.assertEqual(fh.read(), lbefore)
        with open(victim, "rb") as fh:
            self.assertEqual(fh.read(), before)
        existing = os.path.join(d, "existing-report.json")
        with open(existing, "w") as fh:
            fh.write("keep")
        self.assertEqual(reassemble.main([d, "--stream", p, "--report", existing]), 2)
        with open(existing) as fh:
            self.assertEqual(fh.read(), "keep")
        try:
            os.link(victim, os.path.join(d, "hardlink.json"))
        except OSError:
            return
        self.assertEqual(reassemble.main([d, "--stream", p, "--report", os.path.join(d, "hardlink.json"),
                                          "--overwrite"]), 2)
        with open(victim, "rb") as fh:
            self.assertEqual(fh.read(), before)

    def test_ir15_input_limit_reported(self):
        d, p = self.stage("many_parts")
        streams = reassemble.discover(d)
        rep, _, _, _ = reassemble.check_stream(d, p, streams[p], max_input=1000)
        self.assertFalse(rep["complete"])
        self.assertFalse(rep["validated"])
        self.assertIn("not validated", rep["incomplete_reasons"][0])


class ReviewRound2(Case):
    """Regressions for reviews/implementation-round-2.txt (IR-11, IR-13, IR-15, IR-20). Each test rewrites the
    target and then repairs the trailer's record_bytes/checksum so only the intended defect remains."""

    def edit_record(self, d, p, pred, fn):
        """Apply fn(record dict) -> record dict to the first record matching pred; fix that part's trailer."""
        for n in reassemble.discover(d)[p]:
            path = self.part(d, p, n)
            with open(path, "rb") as fh:
                lines = fh.read().split(LF)
            for i in range(1, len(lines)):
                if not lines[i] or b"part_trailer" in lines[i]:
                    continue
                rec = json.loads(lines[i])
                if pred(rec):
                    lines[i] = json.dumps(fn(rec), separators=(",", ":")).encode()
                    self.fix_trailer(lines)
                    with open(path, "wb") as fh:
                        fh.write(LF.join(lines))
                    return rec
        self.fail("no record matched")

    def fix_trailer(self, lines):
        ti = next((i for i in range(len(lines) - 1, 0, -1) if b"part_trailer" in lines[i]), None)
        if ti is None:
            return
        tr = json.loads(lines[ti])
        body = lines[1:ti]
        tr["record_bytes"] = sum(len(x) + 1 for x in body)
        if isinstance(tr.get("checksum"), dict):
            h = 2166136261
            for x in body:
                h = reassemble.fnv1a32(x + LF, h)
            tr["checksum"]["value"] = "%08x" % h
        lines[ti] = json.dumps(tr, separators=(",", ":")).encode()

    def assert_isolated(self, rep, needle):
        self.assertFalse(rep["complete"])
        self.assertTrue(any(needle in i for i in rep["issues"]), rep["issues"])
        self.assertFalse(any("trailer bytes" in i or "checksum mismatch" in i or "trailer count" in i
                             for i in rep["issues"]), "only the intended defect: %s" % rep["issues"])

    def test_ir11_record_cannot_override_envelope(self):
        d, p = self.stage("checksum")
        self.edit_record(d, p, lambda r: r.get("kind") == "StatusApplied",
                         lambda r: dict(r, session_id="forged-session", schema_version=9))
        rep, _ = self.check(d, p)
        self.assert_isolated(rep, "conflicts with the envelope")
        self.assertEqual(rep["envelope_overrides"], 2)
        out = os.path.join(d, "merged.jsonl")
        reassemble.main([d, "--stream", p, "--out", out, "--report", os.path.join(d, "r.json")])
        with open(out) as fh:
            merged = [json.loads(x) for x in fh]
        self.assertFalse(any(m.get("session_id") == "forged-session" for m in merged))
        self.assertTrue(all(m["schema_version"] == 2 for m in merged))

    def test_ir11_header_identity_types(self):
        cases = [(b'"session_id":"', b'"session_id":5,"x":"', "session_id missing or not a non-empty string"),
                 (b'"context":"server"', b'"context":"elsewhere"', "context must be server|client"),
                 (b'"source_content_sha256":"unknown"', b'"source_content_sha256":"ABC"', "must be 64 hex"),
                 (b'"fight":1', b'"fight":"one"', "fight must be a positive integer")]
        for old, new, needle in cases:
            d, p = self.stage("many_parts")
            path = self.part(d, p, 1)
            with open(path, "rb") as fh:
                lines = fh.read().split(LF)
            self.assertIn(old, lines[0], needle)
            lines[0] = lines[0].replace(old, new, 1)
            with open(path, "wb") as fh:
                fh.write(LF.join(lines))
            rep, _ = self.check(d, p)
            self.assert_isolated(rep, needle)

    def test_ir13_nested_shapes_never_raise(self):
        # run-019: many_parts holds CastedSpell records, not StatusApplied (the first version matched nothing)
        mutations = [
            ("kind list", lambda r: r.get("kind") == "CastedSpell", lambda r: dict(r, kind=[]), "kind is not a string"),
            ("obs str", lambda r: r.get("kind") == "CastedSpell", lambda r: dict(r, obs="7"), "obs is not an integer"),
            ("prehistory str", lambda r: r.get("kind") == "CastedSpell", lambda r: dict(r, prehistory="yes"),
             "prehistory is not a boolean"),
        ]
        for name, pred, fn, needle in mutations:
            d, p = self.stage("many_parts")
            self.edit_record(d, p, pred, fn)
            rep, _ = self.check(d, p)
            self.assert_isolated(rep, needle)
        for name, fn, needle in [
            ("base list", lambda r: self._set_actor(r, base_seq=[]), "delta chain bad_base"),
            ("actors str", lambda r: dict(r, data=dict(r["data"], actors="x")), "without an actors list"),
            ("actor int", lambda r: dict(r, data=dict(r["data"], actors=[5])), "malformed checkpoint actor"),
            ("data list", lambda r: dict(r, data=[]), "without an actors list"),
        ]:
            d, p = self.stage("delta")
            self.edit_record(d, p, lambda r: r.get("kind") == "checkpoint" and r.get("phase") == "action", fn)
            rep, _ = self.check(d, p)
            self.assertTrue(rep["validated"], name)
            self.assert_isolated(rep, needle)
        d, p = self.stage("saturation")
        self.edit_record(d, p, lambda r: r.get("kind") == "capture_gap", lambda r: dict(r, data="x"))
        rep, _ = self.check(d, p)
        self.assertTrue(any("malformed capture_gap data" in i for i in rep["issues"]))
        d, p = self.stage("many_parts")
        mp = os.path.join(d, p + "-manifest.json")
        with open(mp) as fh:
            m = json.load(fh)
        m["parts"] = [5, {"part": [1]}, {"part": True}]
        with open(mp, "w") as fh:
            json.dump(m, fh)
        rep, _ = self.check(d, p)
        self.assertGreaterEqual(len([x for x in rep["manifest"]["mismatches"] if "malformed manifest part" in x]), 3)
        with open(mp, "w") as fh:
            json.dump(dict(m, parts="nope"), fh)
        rep, _ = self.check(d, p)
        self.assertIn("manifest parts is not a list", rep["manifest"]["mismatches"])

    def _set_actor(self, r, **kv):
        a = dict(r["data"]["actors"][0], **kv)
        return dict(r, data=dict(r["data"], actors=[a] + r["data"]["actors"][1:]))

    def _checkpoints(self, d, p):
        rep, ordered = self.check(d, p)
        return rep, [r for r in ordered if r.get("kind") == "checkpoint"]

    def test_ir20_valid_multistep_chain(self):
        d, p = self.stage("delta")
        rep, cps = self._checkpoints(d, p)
        self.assertEqual(rep["delta_invalid"], 0, rep["issues"])
        self.assertEqual(rep["delta_bases_missing"], 0)
        self.assertGreaterEqual(rep["delta_max_chain"], 2, "full anchor -> delta -> delta chain followed")
        self.assertEqual(rep["terminal_errors"], 1, "failed-anchor case of the Lua suite kept")

    def _edit_delta(self, fn_from_cps):
        d, p = self.stage("delta")
        _, cps = self._checkpoints(d, p)
        target_seq, fn = fn_from_cps(cps)
        self.edit_record(d, p, lambda r: r.get("seq") == target_seq, fn)
        return self.check(d, p)[0]

    def test_ir20_self_reference(self):
        rep = self._edit_delta(lambda cps: (cps[2]["seq"], lambda r: self._set_actor(r, base_seq=r["seq"])))
        self.assert_isolated(rep, "delta chain bad_base")

    def test_ir20_future_reference(self):
        rep = self._edit_delta(lambda cps: (cps[1]["seq"], lambda r: self._set_actor(r, base_seq=cps[3]["seq"])))
        self.assert_isolated(rep, "delta chain bad_base")

    def test_ir20_cycle(self):
        d, p = self.stage("delta")
        _, cps = self._checkpoints(d, p)
        a, b = cps[1]["seq"], cps[2]["seq"]
        self.edit_record(d, p, lambda r: r.get("seq") == a, lambda r: self._set_actor(r, base_seq=b))
        self.edit_record(d, p, lambda r: r.get("seq") == b, lambda r: self._set_actor(r, base_seq=a))
        rep, _ = self.check(d, p)
        self.assert_isolated(rep, "delta chain bad_base")

    def test_ir20_actor_absent_at_base(self):
        d, p = self.stage("delta")
        _, ordered = self.check(d, p)
        non_cp = next(r["seq"] for r in ordered if r.get("kind") == "StatusApplied" or r.get("kind") == "TurnStarted")
        _, cps = self._checkpoints(d, p)
        later = next(c for c in cps if c["seq"] > non_cp and c["data"]["actors"][0].get("base_seq"))
        self.edit_record(d, p, lambda r: r.get("seq") == later["seq"], lambda r: self._set_actor(r, base_seq=non_cp))
        rep, _ = self.check(d, p)
        self.assert_isolated(rep, "missing or lacks this actor")
        self.assertGreater(rep["delta_bases_missing"], 0)

    def test_ir20_full_sample_with_base_is_contradictory(self):
        rep = self._edit_delta(lambda cps: (cps[0]["seq"], lambda r: self._set_actor(r, base_seq=1)))
        self.assert_isolated(rep, "delta chain contradictory")

    def test_ir20_unrooted_chain(self):
        rep = self._edit_delta(lambda cps: (cps[0]["seq"], lambda r: self._set_actor(r, full=False)))
        self.assert_isolated(rep, "delta chain unanchored")

    def test_ir13_round3_legacy_non_list_characters(self):
        d = tempfile.mkdtemp(prefix="fr2-leg3-")
        self.addCleanup(shutil.rmtree, d)
        path = os.path.join(d, "legacy.jsonl")
        with open(path, "wb") as fh:
            fh.write(b'{"t":1,"kind":"meta","data":{}}\n{"t":2,"kind":"snapshot","data":{"characters":1}}\n'
                     b'{"t":3,"kind":"snapshot","data":{"characters":{"a":1}}}\n')
        rep, out = reassemble.legacy_import(path)
        self.assertEqual(rep["malformed_snapshot_lines"], [2, 3])
        self.assertFalse(rep["complete"])
        self.assertEqual(len(out), 3)
        rc = reassemble.main(["--legacy", path, "--report", os.path.join(d, "r.json")])
        self.assertEqual(rc, 1, "structured incomplete report via the CLI path, not a traceback")

    def test_ir15_legacy_input_limit_and_streamed_output(self):
        legacy = glob.glob(os.path.join(DUMP, "legacy_workload_baseline", "FightRec", "*-fight01.jsonl"))[0]
        rep, out = reassemble.legacy_import(legacy, max_input=10)
        self.assertFalse(rep["validated"])
        self.assertEqual(out, [])
        d, p = self.stage("many_parts")
        out = os.path.join(d, "all.jsonl")
        rc = reassemble.main([d, "--out", out, "--report", os.path.join(d, "r.json")])
        self.assertEqual(rc, 1, "session stream is open, so not every stream is complete")
        with open(out) as fh:
            streams = {json.loads(x)["stream_id"] for x in fh}
        self.assertEqual(streams, {"fight01", "session"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
