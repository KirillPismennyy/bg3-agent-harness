# Windows fightbot review — 2026-10-23

## Confirmed follow-up: Osiris cast suppresses spell rolls

The corrected live probe captured cust's Projectile_MainHandAttack at Taman with:
`SpellCastOptions(IgnoreSpellRolls,AvoidDangerousAuras,IgnoreCastChecks,IgnoreTargetChecks,NoMovement,IgnoreHasSpell)`.
These flags were present at the actor's IsCasting creation, direct deferred cast-state creation,
ticks 2/10/30, and cast-state destruction. The cast dealt 5 piercing damage; the resource guard
charged one action. **Charging resources does not restore normal attack-roll resolution.**
The cast path remains unfixed and must not be treated as player-equivalent combat.

Two probe defects were corrected locally: native bitfield serialization produced *RECURSION*,
so CastOptions is now also captured directly with tostring; watching only the actor's IsCasting
creation captured manual targeting previews, so direct cast-state lifecycle hooks were added.
Regression tests cover both. The corrected probe uses four subscriptions, all retired after capture.
No cast flags, engine queues or other engine fields were written during this investigation.

The available manual files contain IsPreview/IsHoverPreview casts, not an executed manual baseline.
They are not used as proof of executed-manual options. The decisive result is the bot's explicit
IgnoreSpellRolls flag on an executed cast through destruction, corroborated by absent attack rolls.
Raw bot-probe SHA256: 4ee7d2cdb7531557751da697e12b082dc94e09776269cc0053a3dd5aab22d9e7.
Raw probes remain outside Git. The prior observations below are retained as investigation history;
their uncertainty about the bot's actual flags is superseded by this capture.

Verdict: installation and connection defects were corrected, and one supervised action ran.
**Unattended/player-equivalent fighting is not validated.** The bot's ranged attack produced
damage without a captured attack d20 or a visible attack-roll log entry. The Osiris cast path
needs comparison with player input before proceeding. No second bot action or end-turn was issued.

Follow-up comparison: the user manually cast Gale's Fire Bolt at Taman and missed. Server seq 194
records the targeted cast, seq 199 reports zero attack damage, and seq 200 records cast completion.
The client log contains a VMHitFailedEntry with an Attack Roll tooltip and Taman's AC 13. In contrast,
the bot attack has a VMHitDamagedEntry with a Damage Roll tooltip and no attack-roll entry. The UI's
numeric d20 remains opaque in this capture. This strengthens the concern about the Osiris cast route;
it does not yet establish its exact engine flags or prove normal attack resolution is bypassed.
The runtime enum exposes IgnoreSpellRolls, but no surviving cast-state entity remained to inspect.

The user authorized local fixes and declined sending this harness to Claude. Codex authored these
changes locally. No Claude API review or Claude gameplay session was started for this test.

## Corrected findings

- Installer removed the old BG3AI directory. It now preserves the directory, loader, and settings
  in a unique backup, validates JSON first, preserves nested settings, rejects reparse points, hashes
  copied files, and writes a receipt. No recorder or save overwrite is part of installation.
- Launcher permissions were broader than the intended seven tools. It now disables built-ins,
  uses strict isolated MCP configuration and an exact allowlist, and supports hard read-only mode.
  The optional product launcher still invokes Claude Code; it was not invoked during this review.
- Native BG3SE serves one debugger socket at a time. The Windows wrapper forces pool size one
  and disables the second job-push socket.
- Native protocol negotiation omits the connect reply number, resets request sequencing per socket,
  requires sequence numbers on settings, and requires frame -1 for global evaluation. The bridge
  now handles these, serializing sequence allocation and sending together. Batched RPC chunks
  now select statement compilation. All were exercised against the actual native runtime.
- BG3SE replaces standard Lua `load`; the loader now uses `Ext.Utils.LoadString`.
- An old stream could be mistaken for current rolls. The reader now binds to the live recorder's
  exact session/combat/file prefix and reports read issues. Wrapper actions require active party
  combat, a party actor able to act, and a matching active recorder.
- Position input rejects nonfinite numbers. Legacy boolean strings are handled explicitly. Cut,
  omitted and sparse evidence is surfaced. Ambiguous damage joins are left unresolved; unique joins
  remain explicitly unverified for independent target identity.

## Validation

- 25 fightbot Python tests pass, including a strict socket-level native protocol regression.
- 8 Lua loader checks pass.
- 4 applicable shared bridge connection/lifetime tests pass after the batch change.
- The full connection suite also ran: its separate Linux fake's bare-connect leak reproduction
  failed on Windows (`leaked=4`, expected >10). This test uses bare sockets and does not exercise
  the modified LuaDebug client. It remains a recorded failure, not an all-tests-pass claim.
- `git diff --check` passes (Git reports normal LF/CRLF conversion warnings).
- Actual MCP server read-only inventory: fight_state, actions, wait_for_turn, rolls; no action tools.
- Live BG3SE reports version 33. Verified listener is 127.0.0.1:9998, owned by BG3 PID 59592.
- QuickSave 4 in latest `cust` campaign was backed up and loaded. Party: cust, Shadowheart,
  Astarion, Gale; WLD_Main_A. Recorder dev.3 loaded in both contexts with source hash
  8ec6f5c36bc6d3b468a444e0a83069985b9eb7262be165aa0da6ea09460e6e3e.
- One MCP cast: Astarion, Projectile_MainHandAttack, Taman. Returned done, 4 piercing damage,
  ActionPoint 1 -> 0, bonus and movement unchanged. Guard charged one action. Raw seq 64/65
  contains damage d6 natural 1 + 3 = 4 and empty ConditionRolls. The UI log shows the attack and
  4 damage, without an attack-roll entry. SourceType is Osiris; ordinary attack parity unresolved.

## Preserved operational evidence

Installation backup/receipt:
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\FightBotBackups\20261023T154011Z-9aeafd2d7a294b679032a456c44cf10c`

The later loader compiler correction is backed up there as
`FightBotLoad.before-native-compiler-fix.lua`. The initial receipt predates that amendment;
the final installed hash is recorded separately in the local evidence directory.

Save backup and local evidence: `D:\MyCode\BG3 control bot\work\fightbot-install-2026-10-23`.
Raw captures, save data, MCP logs, dependency environments and runtime configurations stay outside Git.
The live combat stream is still open; its snapshot is partial, not a finalized full-fight capture.

The first startup crashed before any bot Lua loaded or debugger query succeeded: Windows event
reported ucrtbase.dll / 0xc0000409. Relaunch with the game bin as working directory stayed running;
that does not prove the crash's root cause. No crash dump was uploaded.

## Primary protocol evidence

Pinned Norbyte/bg3se commit af85fd2bd2be28646539060d45df487f4d3314b9:
BG3Extender/Lua/Debugger/LuaDebugMessages.cpp and LuaDebugger.cpp,
BG3Extender/Osiris/Debugger/DebugInterface.cpp. These establish protocol, framing, global-frame
and loopback/serial-socket behavior. Official modding UseSpell documentation states Osiris bypasses
preconditions, hence the explicit guard and the need for native outcome parity verification:
https://docs.baldursgate3.game/index.php?title=UseSpell

## Remaining limits

No broad guarantee against defects or malicious dependencies is made. No obvious exfiltration path
was identified in the reviewed wrapper/installer/Lua path; the optional Claude launcher deliberately
sends game observations to Claude. The Lua debugger gives local processes arbitrary game Lua access.
No firewall or global execution policy was changed.

Windows movement, multiple targets, reaction prompts, turn ending, full-fight operation and normal
attack/save resolution remain unverified. Some Linux UI routes are unavailable. Empty status arrays
and `evidence_complete` concern the available component/serialization evidence; they do not prove
complete game state or RNG coverage. Keep the current test held while the missing d20 is investigated.
