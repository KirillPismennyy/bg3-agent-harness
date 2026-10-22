# Recording a fight you play

`tools/record_fight.py` logs a fight that a person plays. The agent and the runner aren't used. It talks to the
BG3AI mod through the same LuaDebug channel as the bridge and writes everything to one JSONL file, with a readable
`.txt` beside it.

## Run it

```bash
runner/launch_game.sh --continue          # the game with bg3le and the mod (docs/SETUP.md)
# load your save, open the combat log panel and leave it open
uv run --project bridge python tools/record_fight.py            # stops after 1 fight; --fights 0 = until Ctrl-C
```

Start it before you buff or drink potions, so the preparation is in the record. The files go to
`runtime/recordings/fight-<date>-<time>.jsonl` and `.txt`; `--out` changes the folder.

## What is in the record

Each line is `{"wall", "src", ...}`:

| `src` | When | Contents |
|---|---|---|
| `meta` | at start | `sys.info`, which recorder hooks subscribed, and `combatlog.probe` (where the log is and what it holds) |
| `snapshot` | at start, at each combat start, at each combat end | `state.status`, a full `state.character` per party member (level, classes, abilities, saves, skills, AC, resources and spell slots, statuses, concentration, passives, equipment, XP), `state.combat` (turn order) in combat, the party inventory |
| `event` | as they happen | the fair event stream the agent gets: `combat_started`, `round_started`, `turn_started`, `cast`, `damage`, `status_applied`, `downed`, `died`, ... |
| `raw` | as they happen, party and their fight only | `Server/Recorder.lua`, not fair-filtered: casts and spells on targets with engine ids (enemies' too), damage with its cause, statuses with ids and turns, roll results with the subject, HP changes, equip changes, and the Script Extender's `DealtDamage`/`BeforeDealDamage` hit and attack descriptions where the extender has them |
| `combatlog` | each new log entry | the entry's view model as plain data (`entry`) and its text (`text`); entries already in the log at start are `how: "backlog"` |

## Not verified in a live game

All of this was written and tested offline, against mocks. The first live run will show what holds:

- **The combat log's property names.** The page and its types (`gui::DCCombatLog`, `ls.CombatLogEntry`) come from
  research notes. The reader finds the entry collection by shape. If the `.txt` says the log was not found, or the
  `combatlog` rows hold no rolls, look at the `meta` row's `combatlog_probe`. It lists the DC's properties and dumps
  the first and last entry. Pass the right collection name back (`combatlog.read {collection}`) or adjust
  `CL.COLLECTIONS` in `Client/CombatLog.lua`. Whether an entry holds the roll breakdown that the expanded log shows
  is the open question. `--depth` reads deeper.
- **bg3le's `DealtDamage` and `BeforeDealDamage`.** The `meta` row says whether they subscribed. If they did not, the
  attack and save rolls can only come from the combat log.
- **Osiris arities** for `UsingSpellOnTarget` (6) and `HitpointsChanged` (2). A wrong one shows in the `meta` hooks and
  does no harm.

## Honour mode

The harness has never run in Honour mode, and `play/knowledge/setup.md` keeps the agent out of it. For recording, the
risk is the single save: a crash from the extender or the mod can cost the run. Test on a throwaway Honour save first.
The recorder only reads. It never saves, loads or acts, but it does run Lua inside the game the whole time.

## Fairness

The `rec.*` and `combatlog.*` ops are dev-only. No agent tool calls them, and the recorder keeps its own buffer, not
the event ring the agent reads (`docs/FAIRNESS.md`). Don't feed a recording to a playing agent: it holds what a player
can't see.
