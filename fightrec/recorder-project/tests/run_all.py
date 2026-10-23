"""Run every offline check: Lua 5.4 syntax of recorder + baseline, the Lua suite (dumping parts), the LV01 probe tests, the Python
reassembler/stamp tests, a stamped-artifact load test, the mutation check, and the baseline hash pin.

usage: python tests/run_all.py   (needs the lupa package; see README.txt "Offline checks")
Raw outputs go under work/ (git-ignored). Exit status is non-zero if anything failed.
"""
import hashlib
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE_SHA256 = "a8a72fa165dae06df499821e04c2fc8e3199cc8f1ab96a1fbfd587fb772af4a9"


def run(name, cmd, env=None):
    print("== %s: %s" % (name, " ".join(cmd)), flush=True)
    r = subprocess.run(cmd, cwd=REPO, env=env)
    print("== %s exit %d\n" % (name, r.returncode), flush=True)
    return r.returncode == 0


def main():
    py = sys.executable
    lua = [py, os.path.join("tools", "lua54.py")]
    ok = True
    with open(os.path.join(REPO, "baseline", "FightRec.lua"), "rb") as fh:
        h = hashlib.sha256(fh.read()).hexdigest()
    print("== baseline sha256 %s %s\n" % (h, "OK" if h == BASELINE_SHA256 else "MISMATCH"))
    ok = ok and h == BASELINE_SHA256
    ok = run("syntax", lua + [os.path.join("tests", "check_syntax.lua")]) and ok
    dump = os.path.join(REPO, "work", "test-out", "lua")
    shutil.rmtree(dump, ignore_errors=True)
    ok = run("lua suite", lua + [os.path.join("tests", "test_recorder.lua"), "--dump", dump]) and ok
    ok = run("lv01 probe", lua + [os.path.join("tests", "test_probe.lua")]) and ok
    env = dict(os.environ, FR2_DUMP_DIR=dump)
    ok = run("reassembler/stamp tests", [py, os.path.join("tests", "test_reassemble.py")], env) and ok
    stamped = os.path.join(REPO, "work", "build", "FightRec.lua")
    os.makedirs(os.path.dirname(stamped), exist_ok=True)
    ok = run("stamp build", [py, os.path.join("tools", "stamp_build.py"), stamped, "--overwrite"]) and ok
    ok = run("stamp verify", [py, os.path.join("tools", "stamp_build.py"), "--verify", stamped]) and ok
    ok = run("stamped artifact loads", lua + [os.path.join("tests", "test_stamped.lua"), stamped]) and ok
    ok = run("mutation check", [py, os.path.join("tests", "mutation_check.py")]) and ok
    print("ALL OFFLINE CHECKS PASSED" if ok else "SOME OFFLINE CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
