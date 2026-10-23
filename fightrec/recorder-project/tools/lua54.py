"""Run a Lua file under the Lua 5.4 interpreter bundled with lupa (offline host harness; NOT the Script Extender).

usage: python tools/lua54.py <script.lua> [args...]

The script gets the standard Lua libraries, `arg` (arg[0] = script, arg[1..] = args) and a `host` table:
  host.hrtime_ns()            integer nanoseconds from time.perf_counter_ns (high-resolution host clock)
  host.write_file(path, data) write bytes, creating parent directories (used to dump mock file systems)
  host.sha256_file(path)      hex sha256 of a file (benchmarks bind results to exact sources)
  host.repo                   repository root
  host.lua_version, host.lupa_version
Lua strings cross as raw bytes (encoding=None). An integer return value becomes the exit code.
"""
import os
import sys
import time

import lupa
from lupa import lua54


def sha256_file(path):
    import hashlib
    with open(os.fsdecode(path), "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest().encode()


def write_file(path, data):
    path = os.fsdecode(path)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    return True


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    script = os.path.abspath(argv[1])
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    L = lua54.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    g = L.globals()
    sep = b";"
    g.package.path = sep.join([
        os.fsencode(os.path.join(repo, "tests", "?.lua")),
        os.fsencode(os.path.join(repo, "bench", "?.lua")),
        g.package.path,
    ])
    host = L.table_from({
        b"hrtime_ns": time.perf_counter_ns,
        b"write_file": write_file,
        b"sha256_file": sha256_file,
        b"repo": os.fsencode(repo),
        b"lupa_version": lupa.__version__.encode(),
    })
    host[b"lua_version"] = L.eval(b"_VERSION")
    g.host = host
    args = L.table_from([os.fsencode(a) for a in argv[2:]])
    args[0] = os.fsencode(script)
    g.arg = args
    with open(script, "rb") as fh:
        src = fh.read()
    loader = L.eval(b"function(src, name) local f, e = load(src, '@' .. name) if not f then error(e) end return f end")
    rc = loader(src, os.fsencode(script))()
    return rc if isinstance(rc, int) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
