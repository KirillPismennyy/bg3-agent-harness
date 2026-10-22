# FightRec

Records Baldur's Gate 3 fights to JSONL for analysis. It needs only Norbyte's Script Extender (bg3se) and is one Lua
file, `mod/Mods/FightRec/ScriptExtender/Lua/FightRec.lua`. It doesn't use the rest of this repo.

It only reads: no saves, no actions, no changes to the game. It has been tested against a mocked Script Extender
only, not yet in the game.

## What it writes

Files go to the Script Extender's data folder (Windows: `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\FightRec\`):

- **`<stamp>-fight01.jsonl`, `-fight02`, ...: one file per fight.** One JSON object per line, `{t, kind, data}`, where
  `t` is milliseconds on the game's monotonic clock.
  - `meta`: game version, region, and which hooks registered.
  - `prep`: what the party did in the 10 minutes before the fight (casts, statuses, equip changes, items used).
  - `snapshot` at the start and at the end, for the party and everyone in the fight:
    - HP, level, classes, the `Stats` component (abilities, AC, saves, skills), action resources and spell slots,
      XP, resistances and prepared spells;
    - statuses with their turns left;
    - equipment by slot;
    - position, and whether the character is hostile to the party.
  - Every event that involves the party or its fight, unfiltered:
    - `CombatRoundStarted`, `TurnStarted`/`TurnEnded`;
    - `UsingSpellOnTarget`, `CastedSpell`;
    - `AttackedBy` (damage: amount, type, cause);
    - `RollResult`;
    - `StatusApplied`/`StatusRemoved`, `HitpointsChanged`, `DownedChanged`, `Died`;
    - `Equipped`/`Unequipped`, `UseFinished`.
  - **The Script Extender's damage events** (`BeforeDealDamage`, `DealDamage`, `DealtDamage`): the engine's own hit and
    attack descriptions, as deep as they dump. This is the best place for roll data on the server side.
- **`<stamp>-combatlog.jsonl`: every combat log entry while the game runs.** The first line is a `probe` that shows
  what the log panel holds; each `entry` is a log line as its view model holds it, roll breakdowns included if the
  entry has them. The panel has to exist, so open the combat log at least once.

## Install: as a mod (recommended)

1. Pack the folder `fightrec/mod` (it contains `Mods/FightRec/...`) into `FightRec.pak` with LSLib:
   `Divine.exe -g bg3 -a create-package -s fightrec\mod -d FightRec.pak`. The ConverterApp GUI's package tab
   works too.
2. Import `FightRec.pak` into BG3 Mod Manager, activate it, and export the load order.
3. Play. The Script Extender console or log shows `[FightRec] server ready` and `client ready`, and each fight prints
   its file name when it starts and when it is saved.

## Install: no mod, from the console (try it, unverified)

1. In `ScriptExtenderSettings.json` next to `bg3.exe`, set `"CreateConsole": true`.
2. Copy `FightRec.lua` into the Script Extender data folder (the one above, not `FightRec\`).
3. Load a save. In the console window, press Enter, type `server`, then:
   `load(Ext.IO.LoadFile("FightRec.lua"))()`
   Then type `client` and run the same line again.
4. Do this again after every save load: loading resets Lua.

If `load` is missing, or the `meta` line shows the Osiris hooks failing because they were registered after the story
loaded, use the mod.

## What the first real fight will show

- **Whether the dice are there.** Look at the `DealtDamage` records (`hit`, `attack`) and the combat log `entry` lines
  for d20 results, modifiers, AC and DCs. If the log entries hold no rolls, send the `probe` line: it lists the
  panel's properties, and the reader's guess (`FR.COLLECTIONS`) can be pointed at the right one.
- **Field names.** Component and event field names come from the Script Extender's own reflection, so whatever the
  game holds is dumped as is. Dumps are cut at 50,000 characters each (`FR.DUMP_MAX`).

## Honour mode

Test on a throwaway Honour save first. A mod or extender crash can cost a single-save run. The recorder writes only
its own files.

## Test

`lua fightrec/tests/test_fightrec.lua fightrec/mod/Mods/FightRec/ScriptExtender/Lua/FightRec.lua` (Lua 5.3 or 5.4) runs it
against a mocked Script Extender.
