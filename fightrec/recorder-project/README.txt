BG3 control bot: recorder foundation

Scope: recorder design and source work only. The separate combat-sim project is read-only reference material. No deployment or game launch is authorized here.

baseline/FightRec.lua is an unedited copy of the installed FightRec.lua, NOT authenticated source of the historical chapel capture. Claude Opus 5.5 must author all implementation and executable validation code. Codex owns specifications, analysis, coordination and review.

Raw captures and saves remain outside this repository. Read docs/PROVENANCE.txt, docs/DESIGN.txt and docs/HANDOFF.txt before implementation. Preserve every review finding and disposition in reviews/.

The repository is operated with explicit D:\MyCode\BG3 control bot workdirs. No app project attachment tool is available in this session.

------------------------------------------------------------------------------------------------------------
Status (2026-10-23): recorder v2 core implemented and tested OFFLINE ONLY. Not deployed, never run in the game.
Live compatibility, coverage and performance are pending docs/LIVE-CHECKLIST.txt.

Layout
  baseline/FightRec.lua      immutable baseline (sha256 a8a72fa165dae06df499821e04c2fc8e3199cc8f1ab96a1fbfd587fb772af4a9)
  recorder/FightRec.lua      v2 recorder, one file for server and client (global FightRecV2, folder FightRec2/)
  docs/SCHEMA.txt            capture schema v2, completeness rules, legacy import mapping
  docs/API-PINS.txt          SE declarations relied on, pinned at af85fd2 (cached v33), and what stays unpinned
  docs/LIVE-CHECKLIST.txt    manual live acceptance checklist (not run)
  tools/reassemble.py        validate/reassemble numbered parts; --legacy imports schema-1 files (read-only)
  tools/stamp_build.py       write a deployable copy carrying its source sha256; --verify checks it
  tools/lua54.py             run Lua 5.4 scripts offline (lupa)
  tests/                     fake SE + Lua suite, Python reassembler tests, mutation check, runner
  bench/                     old-versus-new synthetic benchmark + null control (host/mock numbers only)
  reports/                   implementation report (test history, findings), benchmark report
  reviews/                   design and independent implementation reviews (verbatim) + implementer dispositions

Offline checks
  py -3.13 -m venv work\venv ; work\venv\Scripts\python -m pip install lupa     (once; work/ is git-ignored)
  work\venv\Scripts\python tests\run_all.py           syntax, 77 Lua + 15 probe + 44 Python tests, stamp
                                                     build/verify, stamped load, 22-mutant check, baseline pin
  work\venv\Scripts\python bench\summarize.py work\bench\<results>.json     render benchmark tables
  work\venv\Scripts\python tools\lua54.py bench\bench.lua [--quick]             benchmark -> work\bench\
  The Python suite also reads the retained external fight04 capture read-only when present (hash-pinned).
  Passing these validates logic against fakes of the pinned declarations, not live SE behaviour.

What v2 does (details: docs/DESIGN.txt v1.1 and docs/SCHEMA.txt)
- Numbered, independently readable JSONL parts per session/context/stream with header and trailer; only the
  active part is rewritten (SaveFile), sealed near PART_TARGET_BYTES; an oversized record gets its own part.
- A write counts only when the call did not throw AND returned true; otherwise data stays in memory for retry
  with bounded backoff and a write_recovered record follows. Bounded queue (retained bytes <= Q_MAX_BYTES +
  RECORD_HARD_MAX; each reservation counts at least 1600 bytes): refused observations are counted in capture_gap
  records and mark the stream INCOMPLETE (one console warning); optional capture (movement, deferred
  checkpoints, UI polls) is suspended first above the high-water mark. Existing files are never overwritten
  (every new part path is probed first; single writer, not an exclusive create).
- Every admitted seq ends exactly once as its record or a terminal_error at the same seq; nested callbacks keep
  entry order; finalization never reports complete with pending reservations; a required payload replaced by
  an error marks the capture incomplete.
- Observation ids (obs) are separate from storage seq; out-of-combat party observations are kept as
  prehistory with original obs/time, eviction reported.
- Generation ownership: refuses to start beside the baseline in one Lua state; re-executing the same stamped
  build is ignored; with an unknown source identity a re-execution is recorded as unverified and not activated;
  a different build is refused (no verified unsubscribe: reset the Lua state). FightRecV2.stop() ends
  observation and keeps draining writes until every stream completes or is abandoned; FightRecV2.status().
- Source identity: tools/stamp_build.py writes the sha256 of the unstamped source into a deployable copy; the
  recorder reports it as an unverified build claim (or "unknown"); record the printed artifact hash externally.
- Positions keep x, y and z (baseline lost Y/Z); missing coordinates are explicit, never zeros.
- DealtDamage.Result copied in the callback from pinned fields, with provenance and per-field errors; no engine
  object is retained. BeforeDealDamage is never labelled party without attribution.
- Small dynamic checkpoints: full anchors at turn boundaries, deltas (changed fields + base_seq) after actions,
  event bursts (deferred, coalesced) and periodic reconciliation; status instance and turns; all labelled
  non-atomic, with timing.
- Client: at most one deferred UI poll queued or running (a stalled one keeps its slot), next poll after
  completion; no direct UI access when
  Ext.UI.Defer is missing (UI capture marked unsupported, server unaffected); backlog, rebuild generation,
  ambiguous duplicate and truncation flags. The combat log remains auxiliary.
- Legacy event names, field names and raw phases are kept.

Options: set a global table FightRecV2Config = { KEY = value } before loading (unknown keys are reported).
  FLUSH_MS 2000 | PART_TARGET_BYTES 262144 | RECORD_HARD_MAX 4194304 | Q_MAX_RECORDS 20000 | Q_MAX_BYTES 8388608
  Q_HIGH_WATER 0.75 / Q_LOW_WATER 0.5 | MAX_NEST 16 | RETRY_MIN_MS 500 / RETRY_MAX_MS 16000
  RESERVE_BYTES 1600 (never below 1600) | PARTS_INDEX_MAX 128
  FINISH_TIMEOUT_MS 30000 | FINISH_GIVEUP_MS 300000 | PREP_KEEP 300 | PREP_MS 600000
  CHECKPOINT_ON_TURN true | CHECKPOINT_ON_ACTION true | CHECKPOINT_RESOURCES true | CHECKPOINT_DELTA true
  CHECKPOINT_STATUS_TURNS true
  DIRTY_QUIET_MS 400 / DIRTY_MAX_MS 2000 | RECONCILE_MS 6000 (0 = off) | CHECKPOINT_MAX_ACTORS 4
  MOVEMENT_ENABLED false (MOVE_POLL_MS 250, MOVE_MIN_M 0.25) | CHECKSUM "none" ("fnv1a32")
  WRITE_MODE "savefile" ("append" needs APPEND_SEMANTICS_VERIFIED=true and a passing self-test)
  EXPERIMENTAL_FUNCTORS false | DAMAGE_REFLECT true, REFLECT_BUDGET 3000, REFLECT_USE_SERIALIZE true
  (Serialize's own C++ work is not bounded by the budget) | DUMP_MAX 50000 | PROFILE false
  Client: LOG_POLL_MS 500 | MAX_PER_POLL 2 | DEFER_STALL_MS 10000 | DEFER_FAIL_LIMIT 3 | SEARCH_BUDGET 40000
  A different configuration is a different generation identity.

Performance: targets versus observations
  Targets: NONE agreed. Live thresholds must be recorded with hardware/frame context before acceptance; the
  reported 35--186 ms hitches are observations, not a budget.
  Offline observations (host Lua + mocks, reports/benchmark-2026-10-23.txt): rewrite bytes grow ~E^2 for the
  baseline and ~E for v2 (slopes 2.0 vs 1.0; v2 higher at E=500, lower from E=1000; 15.7 GB vs 0.69 GB at
  E=16000); mid-fight whole-harness heap grows linearly for the baseline (6.6 MB at E=16000) and stays at a few
  hundred KB for v2 (name/stat caches still grow with distinct identities); v2 writes ~3.4x the baseline's bytes
  on disk at default checkpoint settings (+32% without checkpoints), costs more host time per event and
  allocates more at small E; on real host disk writes unexplained single-tick maxima up to 571 ms (v2, which
  creates many part files) and 101 ms (baseline) were seen -- a live gate (LIVE-CHECKLIST T-03). None of this
  predicts live frame time.

Unsupported or live-pending (explicit)
  live compatibility of every API use; append mode (off); hot unsubscribe/replacement (lifecycle reset needed);
  durability/atomic writes; final flush of session/client streams; overlapping party combats in one stream;
  complete miss/save/RNG/AI coverage; individual die values beyond what the pinned fields expose; experimental
  functor diagnostics (off); stealth (outside simulator scope); simulator replay (separate project; this
  repository never injects observed consequences).

Independent final audit (2026-10-23): complete existing suite independently passed 71 Lua + 44 Python tests and all19 selected mutation checks. See reviews/final-independent-review.txt and reports/independent-validation.txt. Final full010 synthetic measurement data (not game capture) is reports/benchmark-full-010.json; source pins match. No blocking offline findings remain; LIVE-CHECKLIST gates remain unverified.

Live validation authorization (2026-10-23, subsequent phase): user explicitly authorized backup/deployment and guided chapel recapture. Installed original is backed up; reviewed stamped v2 has been deployed and hash-verified. See reports/live-validation-2026-10-23.txt. Earlier offline-only statements describe prior delivery; runtime compatibility, live coverage and performance remain pending until observed. Code fixes remain exact Claude Opus 5.5 only.

LV01 (2026-10-23, Claude Opus 5.5, offline only, not deployed): party StatusContainer reads nil live. Pinned source shows nil = component absent on the entity, not a wrong route; whether absence means "no statuses" is unverified. Recorder 2.0.0-dev.2 labels it statuses {unavailable, component_absent=true} (snapshot no longer writes [] beside an error). Read-only live probe tools/probes/lv01_status_probe_v2.lua (v1 retained; its ServerStatus.Entity route was refuted live) (tests/test_probe.lua). See reports/lv01-diagnosis-2026-10-23.txt and docs/LIVE-CHECKLIST.txt L-09.

LV02 (2026-10-23, Claude Opus 5.5, offline only, not deployed): the roll breakdown (attack d20 natural/total/rerolls, damage dice) is captured automatically on the server in hit reflections, as historically; 2.0.0-dev.1/dev.2 encoded its Lua lists as {"1":...} objects. 2.0.0-dev.3 restores JSON lists and keeps ls.VMDiceTypeSet leaves at the client depth limit. See reports/lv02-roll-capture-2026-10-23.txt.
