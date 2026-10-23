# Use FightBot as a simulator experiment controller

The objective is to close a specific control, capture, or simulation discrepancy per trial. Winning
a fight is separate. Prefer one action from a preserved checkpoint, inspect the result, then reload
when another controlled trial requires it. A full fight with uncertain control semantics is not a
player-behavior reference.

## Live findings, 2026-10-23

The CastRolls fix in 2f68e5e clears IgnoreSpellRolls on armed Osiris casts. A live Shadowheart Fire Bolt
produced natural 11 + 5 = 16 against AC 13, nonempty ConditionRolls, and an Attack Roll tooltip. A later
bot Fire Bolt missed Taman; the client recorded that miss. This closes the suppression diagnosis,
not full control equivalence. Eight casts reported cleared, zero failed/reapplied in that run.

**Next control blocker: spell source selection.** Shadowheart's native spellbook Fire Bolt entry is
ProgressionRace, progression 30fafb0b-7c8b-4917-bd2a-536233b35d3c, SpellCastingAbility Intelligence.
The bot's Fire Bolt roll used Wisdom +3, matching the actor's default Wisdom casting ability. Its
prototype-only Osiris route does not preserve that racial source. Do not validate simulator racial
Fire Bolt against those bot outcomes.

The `actions` response now preserves all prepared sources of an action prototype, including
Prototype, OriginatorPrototype, SourceType, Source, ProgressionSource and SpellCastingAbility.
Duplicate prototypes remain one menu action with multiple sources. This exposes the mismatch; it
does not add source selection to `cast` or repair the engine's source routing.

## Small next trials

1. Restore a checkpoint and compare the same source-aware spell via UI and bot. Verify source,
   ability/bonus/DC and costs before using the result as player ground truth.
2. Bracket one ordinary weapon attack with pre/post state and native cast/action IDs. Feed only
   initial state, intent and qualified observed dice into the simulator; compare calculated outcomes.
   Never overwrite the simulator with observed HP/status/resource results to force agreement.
3. Verify Shove on a sleeping ally: bonus-action cost, resolution, Sleep removal, displacement and
   timing. The user's tactical correction becomes a bounded rule experiment.

The wrapper does not yet implement an exact pre/post trial snapshot contract. Recorder deferred
checkpoints are not precise action boundaries. Engine/guard costs, unavailable fields, failed casts,
cuts, timing uncertainty, ambiguous joins, session resets and control interventions must be retained.
Resolve a control/capture defect before attributing a discrepancy to simulator rules. Unqualified
or missing essential inputs yield inconclusive, never a passing replay.

The current run is partial and crosses server reset boundaries. It is not a finalized full-fight
parity fixture. The simulator repository was inspected read-only and was not modified.

Validation for source observations: 225 Lua action tests, 26 fightbot Python tests, live MCP
actions response retaining the racial Intelligence source. A controlled manual-versus-bot source
selection acceptance test is still pending. No native RNG stream, AI or Act 1 parity is claimed.
