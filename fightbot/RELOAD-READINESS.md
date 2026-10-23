# One debugger owner and reload readiness

One persistent controller owns the debugger connection and gates actions on recorder readiness.

Stop other local drivers, MCP servers, debugger scripts and watchers before starting this owner. All subsequent Lua evals and bot tools must route through its stdin; do not run live_load, MCP control or another debugger client alongside it. The helper owns one explicit-protocol-5 LuaDebugClient and serializes transport. Its reader thread is the client's normal socket reader; the driver's other thread only reads stdin. There is no second polling client. It cannot prevent an unrelated process from opening the debugger port.

```powershell
& 'D:\MyCode\BG3 control bot\bg3_agent_harness\bridge\.venv\Scripts\python.exe' 'fightbot/supervised_owner.py' --probe --expected-recorder-hash '8ec6f5c36bc6d3b468a444e0a83069985b9eb7262be165aa0da6ea09460e6e3e' --log 'work/reload-readiness/session.jsonl'
```

The main loop polls between requests every 0.5 seconds. It requires client Running and a fully present party before loading absent server/client FightRec globals and absent FightBotLoad. Existing inactive recorder generations or partial bot generations are refused rather than hot-loaded. It checks both recorder contexts, an active combat, file prefix and party-combat identity before emitting ready=true with a readiness token. Both runtime source_content_sha256 values must be nonempty and equal. With --expected-recorder-hash they must also match that reviewed recorder build. The observed values appear in readiness status; this is runtime provenance binding, not an independently verified disk-file hash.

Optional probe gets a unique directory only when the probe is absent in a newly seen server recorder generation. An existing active probe keeps its directory and is reported with origin=existing. Client-only reset/combat changes never rotate the server probe directory, so pending/destruction callbacks cannot be redirected to a new trial folder. Every readiness poll checks the probe exists, retains its observed directory, and has at least four recorded subscriptions. An unexpected missing/stopped/retargeted probe in the same server generation makes readiness false and is not automatically reloaded. Subscription count is only a basic availability guard; it does not certify successful probe output or exact capture coverage.

**Polling cannot capture a human attack made after reload but before instrumentation is loaded.** Wait for ready=true before manual input, then verify a newly written cast file/recorder event afterward. READY certifies the checks just made, not uninterrupted or immediate coverage. External reloads can occur between checks; bot actions receive another readiness gate, and actual recording must still be inspected.

Send newline-delimited JSON, one request at a time:

```json
{"kind":"poll"}
{"tool":"fight_state"}
{"tool":"actions","args":{"char":"Shadowheart"}}
{"tool":"cast","ready_token":"COPY_CURRENT_READY_TOKEN","args":{"char":"Shadowheart","spell":"Projectile_FireBolt","target":"Taman","source":{"Prototype":"Projectile_FireBolt","OriginatorPrototype":"Projectile_FireBolt","SourceType":"ProgressionRace","Source":"00000000-0000-0000-0000-000000000000","ProgressionSource":"30fafb0b-7c8b-4917-bd2a-536233b35d3c","SpellCastingAbility":"Intelligence"}}}
```

The cast above is a command schema example, not a request to issue it automatically. Use the actual current actions/source response and target identity. Actions consume the readiness token before execution. Stale tokens or a changed recorder generation refuse without issuing the callback. New bot instances discard short IDs/roll bindings when the server recorder session changes. `wait_for_turn` is capped at five seconds so it cannot suspend rearming for minutes.

Root-controlled diagnostic Lua also routes through the same owner:

```json
{"kind":"eval","context":"server","code":"return tostring(FightRecV2 and FightRecV2.session_id)"}
```

For a mutating Lua command, include mutation=true and the current ready_token. This is a trusted local control interface; it does not classify arbitrary Lua for side effects. Existing Game RPC/job helpers run on an OwnedGame whose eval uses only the owner's transport. Its pool opener is disabled and job push is disabled. In particular, the usual Game.eval ConnectionError retry loop is bypassed. A timeout/disconnection invalidates readiness, closes that connection, and reports unknown outcome. The same request is never retried. A later poll may reconnect for read-only inspection, but needs_resolution blocks further actions on that same server generation. A bot result of still_running or timeout sets the same latch. Reloading to a new server recorder session clears it; otherwise inspect and resolve the prior action, then acknowledge explicitly:

```json
{"kind":"acknowledge_resolution","note":"Inspected executed cast, resources and recording; previous action is complete."}
```

An empty note is refused. Acknowledgement does not issue an action or immediately grant READY; the next full readiness check is still required. No automatic acknowledgement or queued-action replay occurs.

Commands and full results go to the selected local JSONL log. Bot's own trace is a sibling .bot.jsonl file. Raw Lua requests may contain local paths/runtime metadata; these logs remain local and should not be committed as source.

Offline verification:

```powershell
& 'D:\MyCode\BG3 control bot\bg3_agent_harness\bridge\.venv\Scripts\python.exe' 'fightbot/tests/test_trial_owner.py'
```

Fourteen fake-client tests pass: both contexts loaded once, loading/party refusal, same-connection reload rearm, source hash availability/equality/expected-build checks, stable client-reset and preexisting probe directory behavior, every-poll probe health, bound-combat/inactive recorder gating, consumed/stale token refusal, uncertain mutation issued once with resolution latch, pending/timeout latches and explicit acknowledgement/new-server clearing, unexpected callback exception after an order, known refusal results, and disabled Game pool/push/retry paths. Unexpected callback exceptions conservatively require resolution because the action may already have been issued. Known failed/refused result dictionaries keep their existing behavior. The CLI recreates Bot/Game bindings on any server-session, client-session or combat-ID change, closing the old OwnedGame without closing the owner's socket. Live qualification: a named checkpoint reload rearmed both recorder contexts, the bot and lifecycle probe on the same debugger connection. A subsequent source-correct Fire Bolt produced native numerical attack and damage events. This qualifies that observed reload; READY still cannot guarantee recording of a human action between polls.

