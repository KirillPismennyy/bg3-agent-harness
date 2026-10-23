Read-only freeze/join helper for supervised trials. No game/debugger/network imports or source-repository edits. The only writes are a new `destination/evidence/` tree; an existing evidence tree is refused, never overwritten.

```python
from freeze_trial import freeze_trial
report = freeze_trial(before, after, action_result,
    recorder_dir=script_extender / "FightRec2",
    probe_dirs=[explicit_numerical_probe_directory, explicit_lifecycle_probe_directory],
    destination=existing_unique_trial_directory)
```

BEFORE and AFTER must contain `recording={session_id,combat_id,file_prefix,recorder_active}`. Optional `client_session` or `owner_binding.client_session` selects that exact client combat-log stream. Normalized actor/target/native snapshots and raw per-RPC failures remain untouched in before.json/after.json. Action results use normal `{status,result}`. An experimental result's `result.experimental_source.cast_guid` supplies the requested GUID; ordinary actions without it remain unassigned candidates. Expected target UUID is compared only against directly observed UUIDs, never used to fill a missing target.

This freezes once. The runner owns its bounded flush wait and probe stop. Byte stability does not establish event delivery or a completed action. Changed-during-read files are retained with an error, not silently retried. Active streams remain explicitly partial. Exact bound numbered files are selected; there is no latest, previous-session or timestamp-based fallback. Headers must agree with the requested server/client/session/combat identity. Missing parts, torn JSON, cut/truncated/sparse fields and generation changes are retained as errors or loss metadata.

Raw files and input envelopes are preserved and SHA-256 hashed. report.json groups candidate evidence only by nonzero full cast GUID and preserves positive StoryActionIds, direct caster/target UUIDs, target conflicts, numerical availability, effective attack ability, source/cache/lifecycle reads, raw roll metadata and native damage expressions/draws. A BeforeDealDamage record without a target keeps target=null even when another record directly confirms a target on that cast. CastProbe target handles are never converted into UUIDs. Client log entries remain historical/auxiliary records with their raw collection metadata.

The committed FightRec reader is useful for bound live summaries but does not ingest these one-frame probe files; its zero-damage rows cannot supply missing d20 values, damage-target joins require qualification, and unwrap can normalize sparse/cut shapes. This helper preserves original bytes, including individual draw descriptors and discarded/RollsCount information, and never claims complete native RNG chronology. Job `done`, zero damage, successful probe registration, or a unique candidate alone is not acceptance. `qualified_capture=false` and `acceptance=not_assessed` require the caller's trial-specific essential-field and intent admission before simulator comparison.

Validation: nine offline tests pass, including wrong/newest stream rejection, mismatched headers, torn records, no target/miss inference, conflicting GUID-story-target joins, direct one-frame target plus separately preserved d10 draw, generation changes, loss flags, hashes and overwrite refusal. A smoke freeze of the already saved source-correct Fire Bolt produced the exact GUID `78507c4e-b32a-d461-ff0a-9b724a91f13d`, StoryActionId415, direct Shadowheart/Taman UUIDs and numerical roll, with no errors; its only unknown was the intentionally active/partial stream. The smoke uses disk evidence, not a game connection.

Run tests from the shared workspace:

```powershell
& 'C:\Python314\python.exe' -m unittest discover -s 'work\trial-evidence' -p 'test_freeze_trial.py'
```
