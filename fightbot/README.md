# FightBot

FightBot exposes seven narrow MCP tools for a BG3 combat: `fight_state`, `actions`, `cast`, `move`,
`end_turn`, `wait_for_turn`, and `rolls`. It uses the harness's guarded server actions and reads the
existing FightRec v2 recorder files. Omniscient mode removes the harness's visibility filtering.

Windows status: native BG3SE v33 connection, Lua loading, read-only MCP queries, and one ranged
attack were verified live. The attack dealt 4 piercing damage and paid one action, but its raw
records and visible log contained no attack-roll entry. Normal attack-roll behavior is unresolved;
do not treat this as validated player-equivalent combat or use unattended. Movement and full fights
remain untested on Windows.

**Follow-up confirmed:** the executed bot cast carries `IgnoreSpellRolls` (plus IgnoreCastChecks,
IgnoreTargetChecks and IgnoreHasSpell). The resource guard charged its action but the cast route
suppresses spell rolls. That route remains unfixed: do not use it for player-equivalent fighting.
The corrected read-only probe captures direct bitfield labels and cast-state lifecycle events;
see `SAFETY_REVIEW.md` for evidence and the earlier investigation history.

**Fix to test (offline-tested only):** `mod/.../Server/CastRolls.lua` removes `IgnoreSpellRolls`, and only
that option, from the cast state of each cast the guard orders. It acts when the state appears, reads the
write back, and re-checks for 30 ticks. Every cast result now has `rolls.fix`: `rolls_restored`,
`not_cleared`, `cast_state_not_seen` or `unavailable`, with the options before and after. The other Ignore*
options stay: the guard does those checks and charges the costs, so the engine doing them too could refuse
or double-charge. Live acceptance: with the cast probe loaded, a bot attack shows no `IgnoreSpellRolls` and
has a non-empty `ConditionRolls` and an Attack Roll log entry, and some bot attacks against a high AC miss.

A manual Gale Fire Bolt miss produced an Attack Roll tooltip (target AC 13), whereas the bot attack
only produced a Damage Roll tooltip. Numeric d20 capture remains incomplete; the cast-route
comparison and exact cause are still under investigation. See `SAFETY_REVIEW.md`.

## Setup on Windows

Keep `fightbot`, `bridge`, and `mod` side by side. With uv installed:

```powershell
uv sync --project bridge --frozen --no-dev
powershell -ExecutionPolicy Bypass -File fightbot\install.ps1 -GameBin "D:\SteamLibrary\steamapps\common\Baldurs Gate 3\bin"
```

The installer validates settings before replacement, moves an existing BG3AI folder into a unique
`Script Extender\FightBotBackups` directory, backs up the loader/settings, and writes an install
receipt with hashes. It enables the Lua debugger and console. It preserves `FightRec.lua` and saves.
Restart BG3 after changing debugger settings. The native debugger listens on loopback port 9998;
it allows local Lua execution, so do not expose it through port forwarding.

## Load a saved game and connect

Back up the chosen save before a first test. In the Script Extender console, run each line separately:

```lua
server
assert(Ext.Utils.LoadString(assert(Ext.IO.LoadFile("FightRec.lua"))))()
assert(Ext.Utils.LoadString(assert(Ext.IO.LoadFile("FightBotLoad.lua"))))()
client
assert(Ext.Utils.LoadString(assert(Ext.IO.LoadFile("FightRec.lua"))))()
exit
```

The loader uses `Ext.Utils.LoadString`, since native BG3SE replaces standard Lua `load`. It loads
only the server modules, not the client Tick/UI module. Loading a different recorder generation
requires a lifecycle reset. After reloading a save, verify the runtime identities and load again if absent.

Run a read-only connection check first:

```powershell
powershell -ExecutionPolicy Bypass -File fightbot\run.ps1 -ReadOnly
```

This launcher starts **Claude Code**, using exact model `claude-opus-5-5`. It sends game observations
to that service. It disables built-in tools and unrelated MCP servers; the read-only server exposes
only the four read tools and also rejects direct action requests. `-PrintOnly` shows the launch
configuration without invoking Claude. `-Headless -MaxTurns 30` bounds agent turns in print mode.

For a supervised combat run, omit `-ReadOnly`. Trigger combat yourself and watch the first action.
The wrapper refuses actions outside combat, on another actor's turn, or without an active recorder
bound to that party's current combat. Ctrl+C stops the agent/MCP process; an already accepted game
action can finish. Do not run multiple debugger clients concurrently: native BG3SE services one socket
at a time. The Windows wrapper enforces one pooled socket and disables the extra push listener.

The bot cannot answer reaction prompts, dialogue, or level-up screens. Resolve these yourself if they
block play. Some multi-target/two-step spells depend on the Linux UI route and are unsupported here.

## Recording limits

The reader binds to the recorder's live session/combat/file prefix. It does not select an older fight
when the current stream has not flushed. A flush can take a few seconds. `recording.read_issues`
reports malformed or missing evidence. Roll rows retain `evidence_complete`/`evidence_issues` flags
for cut, omitted, and sparse data. An empty issue list is not proof of full RNG coverage.

Damage association is conservative: ambiguous candidates are left unresolved. Per-target identity
is not independently verified by the GUID/action join. Miss/save/zero-damage rows can lack numerical
breakdowns. Actor sheets and statuses are limited by the harness's native component readers.
Each status projection carries `status_observation`: `available`, `raw_enumeration_available`,
`source`, `scope` (visible or omniscient), and a reason when unavailable. An empty `statuses` list
with `available=false` means unknown. Successful raw enumeration does not guarantee successful
metadata lookup; partial rows can remain alongside unavailable projection metadata. Hidden markers
are retained in omniscient mode. This does not establish a complete engine status inventory.

Tool calls/results are logged under ignored `fightbot/logs`. Runtime MCP configs are under ignored
`fightbot/.runtime`. Keep save files, raw recorder captures, and user diagnostics out of Git.

## Verification

```powershell
bridge\.venv\Scripts\python.exe -m unittest discover -s fightbot/tests -v
lua fightbot/tests/test_loader.lua
```

The strict native protocol regression checks version negotiation, the uncorrelated connect reply,
per-connection sequence reset, sequenced settings, and global-frame evaluation. The separate bridge
Linux fake has a bare-connect leak reproduction that is timing/platform sensitive on Windows; its
failure is not a native BG3SE test. See the local safety review for the recorded results.

For reproducible live experiments, use the single-connection
[supervised owner](RELOAD-READINESS.md) and wait for READY after every reload before human input.
Prototype-only Osiris casts refuse when current prepared sources are ambiguous, unreadable or use a
casting ability different from the actor default. Select the exact observed source explicitly for
the experimental source/cache intervention. It supports one entity target and remains unproven as a
complete player-request equivalent. Same-default legacy casts also disclose unproven provenance.
The [verified trial and limits](SIM-TRIALS.md#verified-source-correct-bot-case) document the native
racial Intelligence Fire Bolt and bounded simulator comparison.

Additional Lua regressions from the repository root:

```powershell
lua fightbot/tests/test_source_cast.lua mod/Mods/BG3AI/ScriptExtender/Lua/Server/CastRolls.lua
lua fightbot/tests/test_actions_source_gate.lua .
lua fightbot/tests/test_miss_roll_probe.lua fightbot/probes/miss_roll_probe.lua
```

The installer also copies the lifecycle probe to `cast_probe.lua` and the numerical event probe to
`FightBotProbe/miss_roll_probe.lua` in Script Extender. Existing copies are backed up and installed
hashes recorded in the receipt. It preserves FightRec.lua and existing probe captures. Verify the
installer in temporary fixtures with `powershell -File fightbot/tests/test_install.ps1`.

Use [`trial_cast`](TRIAL-CAPTURE.md) for a single guarded action with immutable before/after
observations and a [bound evidence freeze](TRIAL-EVIDENCE.md). Failed and uncertain attempts remain
recorded; a completed job is not replay acceptance. [Movement observations](RESOURCE-OBSERVATIONS.md)
preserve exact raw pools separately from status-masked usable amounts. Optional stat attributes are
checked against their native schema before lookup, avoiding warnings for unsupported fields.
