# Bounded miss-roll diagnostic

`miss_roll_probe.lua` is a server-only read-only observer. It writes probe files and Lua bookkeeping only: no component writes, engine commands, RNG draws, recorder edits or next-tick engine-reference retention. Its unique default directory combines monotonic time with a Lua load counter; production experiments should explicitly provide a fresh unique directory.

Live owner only, after copying the script to Script Extender:

```lua
MissRollProbeConfig={dir='FightBotProbe/miss-UNIQUE-TRIAL/',max_records=48,max_callbacks=192,max_ticks=3600}
assert(Ext.Utils.LoadString(assert(Ext.IO.LoadFile('FightBotProbe/miss_roll_probe.lua'))))()
```

Optional `party_guids={'exact-guid',...}` filters by copied caster or target UUID. Without this filter all events are bounded by record/callback/tick limits. Parent does not need to ask the user to load anything if its existing live connection can evaluate these commands.

Stop and flush manifest with `MissRollProbe.stop('trial_complete')`. Per-event files are written synchronously from callback snapshots; their path uses the local immutable directory even if `MissRollProbe.dir` or global config changes. No delayed global-DIR dependency exists. `manifest.json` retains registrations, failures and limits; per-event records retain unavailable data/read errors and numerical-roll-seen separately. A readable empty roll array is not evidence that an attack never rolled. Registration success is not proof of event delivery or component lifetime support.

## API evidence

The cached official `Lua/Libs/Entity.inl` defines OnCreate, OnCreateDeferred, and OnDestroy as wrappers around EntityEventHelpers::Subscribe. More decisive local official source is `D:/MyCode/bg3 item mods/combat-sim/reference/bg3se/BG3Extender/Lua/Shared/EntityEventHelpers.inl`, checkout commit `45f32c1a1fc10b08a962f0463bb5f2cd0cb9cc76`, lines29–38: one-frame components reject destroy subscriptions and automatically turn immediate create into deferred create. Therefore the probe subscribes only `OnCreateDeferred`; adding OnDestroy or immediate OnCreate cannot gain an earlier one-frame snapshot through this API.

`EntityComponentEvents.inl` lines27–54 shows deferred dispatch re-fetches the raw component at callback time. Lines177–195 builds `tuple<EntityHandle, ExtComponentType, RawComponentRef>` for the Lua callback. The probe uses this third argument immediately, with an entity-component lookup fallback if absent. It copies nested numeric roll/result/metadata fields before returning. If the event has already expired, its record stays incomplete/unknown; this observer cannot guarantee a numerical miss roll will still be present.

The helper checkout differs from the recorder's pinned af85 header source; runtime mapping and callback delivery remain live qualifications, not a claimed exact runtime build match.

Pinned cached `BG3Extender_GameDefinitions_Components_SpellCast.h` declarations:

- lines167–174 SpellCastSpellRollAbortEvent: Hit, Target, TargetProxy.
- lines176–185 SpellCastTargetHitEvent: Hit, Attack, Target, TargetProxy, SpellCast, TargetPosition.
- lines135–143 SpellCastEvent: Hit, Target, TargetProxy; despite OneFrame type-name this declaration uses DEFINE_COMPONENT, so do not infer its actual registration behavior from its name.
- lines187–198 SpellCastTargetHitInterruptEvent: Hit, Attack, Target, Source, positions, Spell.
- lines201–210 SpellCastTargetReactionEvent: Hit, Target, TargetProxy, CastEntity.

Hit.h lines30–118 defines Roll, StatsRollResult, StatsRollMetadata, StatsRoll and ConditionRoll variants. The probe copies actual Hit.ConditionRolls, Result natural/total/discarded/critical, dice descriptor, advantage/disadvantage, reroll arrays, ability/proficiency/modifier metadata, GUID/story IDs and available native cast source/cache. The event-specific cast field is used only where declared; otherwise a read-only caster.SpellCastIsCasting.Cast or event-entity-state relation may provide source state. Missing relations remain unavailable, not fabricated from spell prototype.

## Offline verification

Run `test_miss_roll_probe.lua` through the existing local Lua5.4/lupa host. Passed 1246 plain-data/lifecycle assertions, including recursive snapshot invariants and direct behaviors: raw third-argument usage, zero Intelligence modifier, false flag preservation, deep-copy survival after source mutation/deletion, immutable directory, unsubscribe/stop, known-party filtering, record/callback/tick caps, unavailable expired event, nested read errors, failed SaveFile reporting, and unsupported hook registration. Native-like strict five-field SpellId objects reject any unknown property; both TargetHit and Interrupt callback snapshots pass complete=true without querying the unsupported SpellCastSource alias. These tests validate observer behavior, not native event timing or live numerical availability.

Live owner reported initial one-frame delivery of a cust ranged miss: natural8, total12, AC13, Dexterity2/proficiency2, plus retained roll history8/18. The original event record remains qualified partial because the first observer queried an unsupported SpellId.SpellCastSource alias. This revision removes that alias from both source lists; it does not edit the original record or reinterpret the ambiguous roll history as a complete engine-face tape.

Source hashes at delivery:

- probe: `ab5d0fcac8722a75e81717181db1c5890808cbb95d2db856d48e6c6ccbe0b124`
- helper: `e673ee6cea9673f301a443e94b5140344356d43f84568b377cf9642a588a4bea`
- event dispatcher: `c92bf5676a995ff6ec9478e2dca02ae9f532d0bb65823473687dd16845bb9e35`
- pinned SpellCast header: `f1cef95bc5fca05b69f4fc7c06400b5d14ab08ebf48ad0383a330336cc15165d`
- pinned Hit header: `f61be312eaa0801e2603934b4fa43c6d68113c811af54ccfc59449d97becd345`

Live follow-up with this corrected probe captured Shadowheart's Fire Bolt against Taman (cast 78507c4e-b32a-d461-ff0a-9b724a91f13d, StoryActionId415). TargetHit was complete=true, errors empty, and directly reported Intelligence, natural14, total16, AC13. An independently joined server damage event supplied one d10 face4. Source/cache intervention remains experimental; this does not establish native RNG or player-request equivalence.
