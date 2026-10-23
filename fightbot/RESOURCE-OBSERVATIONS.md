# Preserve the movement pool separately from its usable projection

The additive harness observation preserves movement provenance; recorder and simulator source are unchanged.

The live owner independently read the same callback's native Guard movement pool as 5.549888997280449 while State resources displayed Movement=[0,9], MoveBlocked=Entangled. The underlying pool was not zero. State.moveView deliberately masks the displayed current amount when Guard.move_blocked reports a disabling status. Actions.summary reads Guard.resources without that mask and rounds it to one decimal, so action.result.after.movement was 5.5. These are different observations with different precision, rather than evidence of a resource charge discrepancy.

The proposal changes State.lua and Actions.lua additively:

- Existing resources.Movement and resources.MoveBlocked retain their normal behavior, including the rounded [0,9] blocked display.
- resources.MovementObservation.raw retains the observed unrounded Amount/MaxAmount as current/max, its source and availability. Missing current/max is unknown; a genuine zero stays zero.
- usable_projection identifies the exact guard projection, current/max, whether a mask was applied, and that movement_legality_verified=false. This projection is available when its raw input and helper call succeeded; that does not establish engine movement legality.
- blocker_check records the Guard.move_blocked helper outcome, reported blocker or lookup failure. A successful nil return means only no_blocker_reported. status_absence_verified=false is explicit because the existing status route can swallow absent containers and metadata failures.
- Action result after gains movement_observation with the same structure, while after.movement keeps its existing rounded raw-pool meaning. An unavailable State helper is reported as unknown without changing the legacy amount.

For the observed case this yields raw.current=5.549888997280449 and usable_projection.current=0, mask_applied=true, blocker=Entangled. The proposal does not infer a pool debit, restore movement, change movement guards/costs, or relabel 5.549888997280449 as zero.

Production placement:

```
State.lua -> mod/Mods/BG3AI/ScriptExtender/Lua/Server/State.lua
Actions.lua -> mod/Mods/BG3AI/ScriptExtender/Lua/Server/Actions.lua
test_resource_observation.lua -> fightbot/tests/test_resource_observation.lua
```

Portable test from repository root:

```text
lua fightbot/tests/test_resource_observation.lua mod/Mods/BG3AI/ScriptExtender/Lua/Server/State.lua mod/Mods/BG3AI/ScriptExtender/Lua/Server/Actions.lua
```

Staging test:

```powershell
& 'D:\MyCode\BG3 control bot\work\venv\Scripts\python.exe' 'D:\MyCode\BG3 control bot\tools\lua54.py' 'work/resource-observation/test_resource_observation.lua' 'work/resource-observation/State.lua' 'work/resource-observation/Actions.lua'
```

Thirty checks pass using the actual extracted State projection and actual Actions.summary. They cover exact precision, blocked/unblocked projections, unchanged legacy fields, no source mutation, unavailable/missing/throwing blocker helpers, missing maximum/pool, real zero and action-result provenance. They do not certify complete native status coverage or path legality.
