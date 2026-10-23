# FightBot

An agent fights Baldur's Gate 3 combats for your party while every fight is recorded. Nothing is hidden from
the agent. It sees every combatant's HP, AC, abilities, saves, resistances, statuses and position, and every
attack and damage roll. You watch the agent's reasoning and every action in the Claude Code window, and every tool
call is also logged to a file.

**Status: written and tested offline only, never run in the game.** It reuses the harness's combat actions, which
have played 149 fights on Linux (bg3le), but it has never run under the Windows Script Extender (bg3se). The first
live run will show what works.

## How it fits together

- **In the game**, loaded from the Script Extender console: the server half of the harness's BG3AI mod
  (`FightBotLoad.lua`). Its actions are guarded:
  - a cast is checked like the UI checks it and pays what a UI cast pays;
  - a move follows the engine's path.

  The loader also turns on **omniscient mode** (`dev.omniscient`), which the harness keeps off: no visibility
  filtering.
- **Recording is FightRec v2's job, and only its job.** Nothing in the fightbot records in the game. The agent's
  rolls come from FightRec's own files on disk (`fightrec_reader.py`): each hit's d20 natural and total vs AC,
  advantage, damage dealt and its dice. They are read outside the game, within FightRec's 2-second flush.
- **On your PC**, `fightbot_mcp.py`: a small MCP server with 7 tools: `fight_state`, `actions`, `cast`, `move`,
  `end_turn`, `wait_for_turn` and `rolls`. It talks to the game over the Script Extender's Lua debugger port (9998).
  - `fight_state` costs two game calls, each a batch.
  - `wait_for_turn` watches the cheap event stream and reads the turn order only when a turn changes, or every
    5 s.
- **The agent**: Claude Code started in this folder. It reads `CLAUDE.md`, and its only game access is the
  `fightbot` tools.
- **Logs**: the agent's calls and their results go to `fightbot/logs/fightbot-<time>.jsonl`.

## Setup (Windows, once)

1. Install [uv](https://docs.astral.sh/uv/) and [Claude Code](https://claude.com/claude-code). Get this repo, on
   this branch.
2. Install the in-game part. Use your game's `bin` folder, the one with `bg3.exe`:
   ```powershell
   powershell -ExecutionPolicy Bypass -File fightbot\install.ps1 -GameBin "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\bin"
   ```
   This copies the mod's Lua to `Script Extender\BG3AI\` and `FightBotLoad.lua` to `Script Extender\`. It also
   sets `"EnableLuaDebugger": true` and `"CreateConsole": true` in `ScriptExtenderSettings.json`, after backing
   the file up.
3. In the game's options, turn off the **reaction prompts**: every reaction set to always or never, not "ask".
   The bot doesn't answer popups.

## Each fight

1. Start the game and load a save just before the fight.
2. In the Script Extender console, load FightRec, then the bot, in the server context:
   ```
   server
   load(Ext.IO.LoadFile("FightRec.lua"))()
   load(Ext.IO.LoadFile("FightBotLoad.lua"))()
   client
   load(Ext.IO.LoadFile("FightRec.lua"))()
   ```
   Expect `[FightBot] ready: BG3AI 0.1.0-fightbot, omniscient`. If it adds "FightRec v2 is not loaded", load
   FightRec first: without it the agent gets no rolls.
3. Start the agent:
   ```powershell
   powershell -ExecutionPolicy Bypass -File fightbot\run.ps1
   ```
   It waits for the fight to start, so you can trigger the fight after it is running. It then plays every party
   turn until the fight ends and finishes with a summary.

After loading another save, run the console lines again. A load resets the Lua state.

## What is not covered

- **Misses and passed saves have no numbers.** The game fires no damage event for them. The agent sees them as
  rows without numbers; FightRec's combat log has their text.
- **Some spells need the UI.** Spells with more than 2 targets, and two-step spells (Dimension Door), use the
  harness's hotbar click route, which needs the Linux input shim. Here they fail with a reason, and the agent
  picks something else.
- **No popups.** The bot doesn't answer reaction prompts, dialogue or level-up screens.
- **Untested on Windows.** The debugger connection to bg3se, the mod's server code under bg3se, and loading it
  from the console are all untested. If `FightBotLoad.lua` errors, the console names the file and line.

## Files

| File | What it is |
|---|---|
| `FightBotLoad.lua` | the console loader (the server half of `mod/Mods/BG3AI`, plus the two switches) |
| `fightbot_mcp.py` | the MCP server: tools, short ids `c1, c2, ...`, logging |
| `fightrec_reader.py` | reads the newest fight's rolls from FightRec v2's parts (`FIGHTBOT_FIGHTREC_DIR` overrides the folder) |
| `CLAUDE.md` | the agent's instructions: the turn loop, tactics, rules |
| `.mcp.json`, `.claude/settings.json` | the MCP server for Claude Code; only `fightbot` tools allowed, shell and file edits denied |
| `install.ps1`, `run.ps1` | Windows install and start |
| `tests/` | offline tests: `python3 -m unittest fightbot/tests/test_fightbot.py` (the reader runs on a slice of the chapel recapture in `tests/fixtures/`); `lua fightbot/tests/test_loader.lua` |

The omniscient switch is `V.OMNISCIENT` in `mod/Mods/BG3AI/ScriptExtender/Lua/Server/Visibility.lua`. It is off
unless the fightbot turns it on, so the harness's fair agent never gets it.
