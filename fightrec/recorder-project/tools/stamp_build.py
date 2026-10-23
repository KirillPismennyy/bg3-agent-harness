"""Stamp a deployable copy of recorder/FightRec.lua with its build content identity (offline; never deploys).

usage:
  python tools/stamp_build.py OUT_FILE [--src recorder/FightRec.lua] [--overwrite]
  python tools/stamp_build.py --verify STAMPED_FILE

Two different hashes (IR-05):
  content sha256  = sha256 of the UNSTAMPED source bytes; written into the copy as SOURCE_CONTENT_SHA256. The
                    recorder reports it as a build-time CLAIM ("claimed_by_build_stamp_unverified_at_runtime").
  artifact sha256 = sha256 of the stamped file itself; it cannot be embedded in that file. Record it next to any
                    deployment and compare it with the deployed file; this tool prints both.
--verify restores the single stamp line and checks the content hash, detecting edits made after stamping.
OUT_FILE must not exist (unless --overwrite) and may never be the source, the baseline or the repository recorder.
"""
import argparse
import hashlib
import os
import re
import sys

STAMP_NIL = b"local SOURCE_CONTENT_SHA256 = nil -- FR2-BUILD-STAMP"
STAMP_RE = re.compile(rb'local SOURCE_CONTENT_SHA256 = "([0-9a-f]{64})" -- FR2-BUILD-STAMP')
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTECTED = [os.path.join(REPO, "baseline", "FightRec.lua"), os.path.join(REPO, "recorder", "FightRec.lua")]


def _same(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))


def stamp(src, out, overwrite=False):
    for p in [src] + PROTECTED:
        if (os.path.exists(out) and os.path.exists(p) and _same(out, p)) or \
                os.path.normcase(os.path.realpath(out)) == os.path.normcase(os.path.realpath(p)):
            raise SystemExit("refusing to write %s: it is the source or a protected file" % out)
    if os.path.exists(out) and not overwrite:
        raise SystemExit("refusing to overwrite existing %s (use --overwrite)" % out)
    with open(src, "rb") as fh:
        raw = fh.read()
    if raw.count(STAMP_NIL) != 1:
        raise SystemExit("source must contain exactly one unstamped marker: %r" % STAMP_NIL)
    content = hashlib.sha256(raw).hexdigest()
    stamped = raw.replace(STAMP_NIL, b'local SOURCE_CONTENT_SHA256 = "%s" -- FR2-BUILD-STAMP' % content.encode())
    with open(out, "wb") as fh:
        fh.write(stamped)
    return content, hashlib.sha256(stamped).hexdigest()


def verify(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    found = STAMP_RE.findall(raw)
    if len(found) != 1:
        raise SystemExit("no single stamp in %s" % path)
    m = STAMP_RE.search(raw)
    restored = raw[: m.start()] + STAMP_NIL + raw[m.end():]
    content = hashlib.sha256(restored).hexdigest()
    if content != m.group(1).decode():
        raise SystemExit("stamp mismatch: claims %s, unstamped bytes hash %s (edited after stamping?)"
                         % (m.group(1).decode(), content))
    return content, hashlib.sha256(raw).hexdigest()


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", nargs="?")
    ap.add_argument("--src", default=os.path.join(REPO, "recorder", "FightRec.lua"))
    ap.add_argument("--verify")
    ap.add_argument("--overwrite", action="store_true")
    a = ap.parse_args(argv)
    if a.verify:
        content, artifact = verify(a.verify)
        print("content_sha256 %s\nartifact_sha256 %s" % (content, artifact))
        return 0
    if not a.out:
        ap.print_usage()
        return 2
    content, artifact = stamp(a.src, a.out, a.overwrite)
    print("content_sha256 %s\nartifact_sha256 %s" % (content, artifact))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
