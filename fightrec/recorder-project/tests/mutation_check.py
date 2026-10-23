"""Mutation check: re-introduce each fixed review defect into a temporary copy of the recorder (Lua suite) or of
tools/reassemble.py (Python suite) and confirm the regression test written for it FAILS (and passes on the real
file). Copies live in work/mutants (git-ignored). The Python part needs the Lua dumps (run tests/run_all.py first).

usage: python tests/mutation_check.py
"""
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "recorder", "FightRec.lua")
OUT = os.path.join(REPO, "work", "mutants")

# (finding, test-name filter, [(text in recorder, defective replacement), ...])
MUTANTS = [
    ("IR-01", "IR-01", [("if ok and slot and self.qBytes - slot.bytes + #line > CFG.Q_MAX_BYTES + CFG.RECORD_HARD_MAX then",
                         "if false then")]),
    ("IR-02", "IR-02", [("    elseif self.capture == \"ok\" then\n        self.capture = \"incomplete\"\n",
                         "    elseif false then\n")]),
    ("IR-03 index", "IR-03", [("if #self.parts > CFG.PARTS_INDEX_MAX then", "if false then")]),
    ("IR-03 jobs", "IR-03", [("                if pending then\n                    local merged, have = {}, {}",
                              "                if false then\n                    local merged, have = {}, {}"),
                             ("                if busy then\n", "                if false then\n")]),
    ("IR-04", "IR-04 stop during", [("if drains and #rt.streams > 0 then", "if false then")]),
    ("IR-06", "IR-06", [("local e = exists(CFG.DIR .. rt.session_id .. \"-\" .. CTX .. \"-session-p00001.jsonl\")",
                         "local e = false"),
                        ("if not exists(string.format(\"%s-p%05d.jsonl\", s.prefix, 1)) then break end", "break")]),
    ("IR-06 r2", "IR-06 round 2", [("    for k = 1, 10 do\n        if k == 10 then",
                                    "    for k = 1, 9 do\n        if k == 10 then")]),
    ("IR-06 r3", "IR-06 round 3", [("    if exists(path) then\n        self.unwritable = \"part path already exists: \" .. path",
                                    "    if false then\n        self.unwritable = \"part path already exists: \" .. path")]),
    # retargeted for 2.0.0-dev.3 (LV02 ownKeys): same mutation, budget check/decrement removed from the table branch
    ("IR-07", "IR-07", [("            if budget.n <= 0 then budget.cut = true omitted = true break end\n            budget.n = budget.n - 1\n            if depth > 0 then entries[#entries + 1] = { k, reflect(v, depth - 1, budget) }",
                         "            if depth > 0 then entries[#entries + 1] = { k, reflect(v, depth - 1, budget) }")]),
    ("IR-09", "IR-09", [("            if age > 3 * CFG.DEFER_STALL_MS and not L.inflight.stalled then\n                L.inflight.stalled = true",
                         "            if age > 3 * CFG.DEFER_STALL_MS and not L.inflight.stalled then\n                L.inflight = nil do return pumpAll(false) end")]),
    ("IR-10", "IR-10", [("if seq and f.stream.lastTerminalErr ~= seq then\n                        for _, m in ipairs(moved)",
                         "if true then\n                        for _, m in ipairs(moved)")]),
    ("LV01", "LV01", [("    if sc == nil then return nil, STATUS_ABSENT, true end",
                       "    if sc == nil then return {} end")]),
    ("LV02 keys", "LV02", [("    if seq then\n        for _, kv in ipairs(entries) do out[kv[1]] = kv[2] end",
                            "    if false then\n        for _, kv in ipairs(entries) do out[kv[1]] = kv[2] end")]),
    ("LV02 leaf", "LV02 UI", [("local LEAF_PAST_DEPTH = { [\"ls.VMDiceTypeSet\"] = true }",
                               "local LEAF_PAST_DEPTH = {}")]),
]


VALIDATOR = os.path.join(REPO, "tools", "reassemble.py")
DUMP = os.path.join(REPO, "work", "test-out", "lua")
# (finding, unittest test ids, [(text in reassemble.py, defective replacement), ...])
PY_MUTANTS = [
    ("IR-11 override", ["ReviewRound2.test_ir11_record_cannot_override_envelope"],
     [("                if k in rec and rec[k] != header.get(k if k != \"part\" else \"part\"):",
       "                if False:")]),
    ("IR-11 types", ["ReviewRound2.test_ir11_header_identity_types"],
     [("            for prob in header_problems(header):", "            for prob in []:")]),
    ("IR-12 order", ["ReviewRound1.test_ir12_interior_swap_keeping_endpoints"],
     [("            if seqs and s <= seqs[-1]:\n                order_violations += 1",
       "            if False:\n                order_violations += 1")]),
    ("IR-12 range", ["ReviewRound1.test_ir12_final_range_undershoot"],
     [("        elif prev > final_last:", "        elif False:")]),
    ("IR-14 alias", ["ReviewRound1.test_ir14_outputs_never_overwrite_inputs"],
     [("    err = check_outputs([a.out, a.report], inputs, a.overwrite)", "    err = None")]),
    ("IR-13 legacy", ["ReviewRound2.test_ir13_round3_legacy_non_list_characters"],
     [("        if chars is not None and not isinstance(chars, list):", "        if False:")]),
    ("IR-20 bases",["ReviewRound2.test_ir20_self_reference", "ReviewRound2.test_ir20_future_reference",
                     "ReviewRound2.test_ir20_cycle"],
     [("        elif not is_int(base) or base < 1 or base >= seq:", "        elif not is_int(base) or base < 1:")]),
    ("IR-20 rooting", ["ReviewRound2.test_ir20_unrooted_chain", "ReviewRound2.test_ir20_full_sample_with_base_is_contradictory"],
     [("        elif full and base is not None:\n            res = (\"contradictory\", 0)",
       "        elif False:\n            res = (\"contradictory\", 0)"),
      ("        elif base is None:\n            res = (\"unanchored\", 0)", "        elif base is None:\n            res = (\"ok\", 0)")]),
]


def run_py(validator, tests):
    env = dict(os.environ, FR2_REASSEMBLE=validator, FR2_DUMP_DIR=DUMP)
    r = subprocess.run([sys.executable, os.path.join(REPO, "tests", "test_reassemble.py")] + tests,
                       cwd=REPO, env=env, capture_output=True, text=True)
    tail = [ln for ln in r.stderr.splitlines() if ln.startswith(("OK", "FAILED", "Ran "))]
    return r.returncode, " ".join(tail)


def run(recorder, flt):
    env = dict(os.environ, FR2_RECORDER=recorder)
    r = subprocess.run([sys.executable, os.path.join(REPO, "tools", "lua54.py"),
                        os.path.join(REPO, "tests", "test_recorder.lua"), flt],
                       cwd=REPO, env=env, capture_output=True, text=True)
    tail = [ln for ln in r.stdout.splitlines() if " passed, " in ln]
    return r.returncode, tail[-1] if tail else r.stdout[-300:] + r.stderr[-300:]


def main():
    with open(SRC, "rb") as fh:
        src = fh.read().decode("utf-8")
    os.makedirs(OUT, exist_ok=True)
    ok = True
    for name, flt, edits in MUTANTS:
        mutated = src
        for a, b in edits:
            if mutated.count(a) != 1:
                print("SETUP-FAIL %-12s pattern not found exactly once: %r" % (name, a[:60]))
                ok = False
                break
            mutated = mutated.replace(a, b)
        else:
            path = os.path.join(OUT, name.replace(" ", "_") + ".lua")
            with open(path, "wb") as fh:
                fh.write(mutated.encode("utf-8"))
            rc_m, sum_m = run(path, flt)
            rc_o, sum_o = run(SRC, flt)
            good = rc_m != 0 and rc_o == 0
            ok = ok and good
            print("%-6s %-12s mutant: %-34s original: %s" % ("ok" if good else "MISSED", name, sum_m, sum_o))
    with open(VALIDATOR, "rb") as fh:
        vsrc = fh.read().decode("utf-8")
    for name, tests, edits in PY_MUTANTS:
        mutated = vsrc
        for a, b in edits:
            if mutated.count(a) != 1:
                print("SETUP-FAIL %-14s pattern not found exactly once: %r" % (name, a[:60]))
                ok = False
                break
            mutated = mutated.replace(a, b)
        else:
            path = os.path.join(OUT, name.replace(" ", "_") + ".py")
            with open(path, "wb") as fh:
                fh.write(mutated.encode("utf-8"))
            rc_m, sum_m = run_py(path, tests)
            rc_o, sum_o = run_py(VALIDATOR, tests)
            good = rc_m != 0 and rc_o == 0
            ok = ok and good
            print("%-6s %-14s mutant: %-34s original: %s" % ("ok" if good else "MISSED", name, sum_m, sum_o))
    print("ALL MUTANTS DETECTED" if ok else "SOME MUTANTS NOT DETECTED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
