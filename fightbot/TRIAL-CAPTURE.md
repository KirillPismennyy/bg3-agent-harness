# Bounded one-cast trial primitive

Production placement: trial_capture.py and supervised_owner.py belong in fightbot/. The independently reviewed freeze_trial.py helper belongs beside them. Test goes in fightbot/tests/test_trial_capture.py; add the fightbot directory to Python's import path when running it, as the existing tests do. The persistent controller owns the only debugger connection.

The primitive takes the existing TrialOwner and Bot. It opens no connection, issues at most one bot.cast inside owner.run_action, and never retries an uncertain or refused action. A before snapshot uses one server Lua callback for identity, combat, actor sheet, target examination, actions, exact actor/target HP/XYZ (Y explicitly preserved), actor casting ability, current matching book sources and observed proficiency bonus or read error. started_ms/finished_ms bound that callback; this is not a lock on the whole engine. Client/server sessions, combat and reviewed recorder hashes are bound through owner readiness. Essential read/identity failure prevents the action; a changed generation before action is rejected by its readiness token; changed post identity disqualifies the trial.

Configure the persistent owner with --trial-root pointing to a local evidence folder. Optional --script-extender-dir is needed when its recorder folder is not named FightRec2. Otherwise the validated FightRec2 parent supplies the separate Script Extender root for FightBotProbe paths. Stop the old owner before starting the updated driver; all subsequent commands use this one process.

One stdin command:

```json
{"kind":"trial_cast","ready_token":"CURRENT_READY_TOKEN","directory":"lowground-firebolt","numerical_probe":true,"flush_timeout_s":2,"args":{"char":"CURRENT_ACTOR_ID","target":"CURRENT_TARGET_ID","spell":"Projectile_FireBolt","source":{"Prototype":"Projectile_FireBolt","OriginatorPrototype":"Projectile_FireBolt","SourceType":"ProgressionRace","Source":"00000000-0000-0000-0000-000000000000","ProgressionSource":"CURRENT_OBSERVED_PROGRESSION_GUID","SpellCastingAbility":"Intelligence"}}}
```

Resolve current character IDs with fight_state first. directory is an optional basename under configured trial root; absolute paths, traversal and separators are refused. Every invocation creates an exclusive time/UUID directory, never overwrites an earlier trial, and preserves intent, raw before/action/after observations, file hashes and report. Invalid flush timeout is rejected before probe setup or action. The numerical probe is optional; an existing active numerical probe is refused. Newly owned diagnostics use a unique directory, verify the five requested registrations, then stop after a bounded elapsed flush window. Registration/callback counts do not prove numerical capture. Cleanup runs even after artifact-write/flush errors; unavailable disk space is reported explicitly and does not cause a recast.

freeze_trial receives the exact recorder folder and explicit lifecycle/numerical probe folders, copies raw evidence once and retains conservative candidate joins. The fixed elapsed wait does not prove delivery, stream completeness, finalization, numerical availability or RNG ordering. No newest-file fallback or expected damage/hit calculation is performed. Failed/uncertain trials are retained. control_window_qualified is only the bounded control/identity/action-result gate; simulator_scene_complete and numerical_roll_proven remain false. Replay admission requires inspecting independently joined raw observations and all essential simulator inputs.

Offline staged tests (no game connection):

```powershell
& 'D:\MyCode\BG3 control bot\bg3_agent_harness\bridge\.venv\Scripts\python.exe' 'fightbot/tests/test_trial_capture.py'
```

Thirteen tests pass: successful bounded observation/path/hash handoff, essential read failure, token change, no retry after uncertain action, post-generation change, refusal retention, finite flush validation, immutable unique directories, numerical arm/stop and both evidence roots, persistent post-arm write failure cleanup, and partial arm failure cleanup. The command was live-qualified on both a no-line-of-sight refusal and an executed entangled Fire Bolt; complete simulator-scene admission remains unverified.

The final post-snapshot readiness check detects a client/session change after the server sample. Snapshot native.raw_resource_amounts preserves unrounded guard pool values; these are distinct from status-masked usable resources. stdout/logging returns a compact index of paths, hashes, requested candidates and errors; full native evidence stays in the immutable report on disk. A candidate index is not a replay acceptance decision.
