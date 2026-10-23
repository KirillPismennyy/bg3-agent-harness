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

  The loader also turns on two things the harness keeps off:
  - **omniscient mode** (`dev.omniscient`): no visibility filtering;
  - the **roll log** (`Server/Omni.lua`): every attack roll (d20 natural and total, AC, advantage) and every damage
    die in the party's fight.
- **On your PC**, `fightbot_mcp.py`: a small MCP server with 7 tools: `fight_state`, `actions`, `cast`, `move`,
  `end_turn`, `wait_for_turn` and `rolls`. It talks to the game over the Script Extender's Lua debugger port (9998).
- **The agent**: Claude Code started in this folder. It reads `CLAUDE.md`, and its only game access is the
  `fightbot` tools.
- **Recording**:
  - your FightRec keeps recording in the game, as before;
  - the agent's calls and their results go to `fightbot/logs/fightbot-<time>.jsonl`;
  - the `rolls` tool shows the roll log.

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
2. In the Script Extender console, load the recorder and the bot in the server context:
   ```
   server
   load(Ext.IO.LoadFile("FightRec.lua"))()
   load(Ext.IO.LoadFile("FightBotLoad.lua"))()
   client
   load(Ext.IO.LoadFile("FightRec.lua"))()
   ```
   Expect `[FightBot] ready: BG3AI 0.1.0-fightbot, omniscient, roll log on`.
3. Start the agent:
   ```powershell
   powershell -ExecutionPolicy Bypass -File fightbot\run.ps1
   ```
   It waits for the fight to start, so you can trigger the fight after it is running. It then plays every party
   turn until the fight ends and finishes with a summary.

After loading another save, run the console lines again. A load resets the Lua state.

## What is not covered

- **Misses and passed saves have no numbers.** The game fires no damage event for them. They show up as rows
  without numbers in the roll log, and in FightRec's combat log.
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
| `CLAUDE.md` | the agent's instructions: the turn loop, tactics, rules |
| `.mcp.json`, `.claude/settings.json` | the MCP server for Claude Code; only `fightbot` tools allowed, shell and file edits denied |
| `install.ps1`, `run.ps1` | Windows install and start |
| `tests/` | offline tests: `python3 -m unittest fightbot/tests/test_fightbot.py`; `lua fightbot/tests/test_omni.lua mod/Mods/BG3AI/ScriptExtender/Lua` |

`mod/Mods/BG3AI/ScriptExtender/Lua/Server/Omni.lua` is the roll log. The omniscient switch is `V.OMNISCIENT` in
`Server/Visibility.lua`. Both are off unless the fightbot turns them on, so the harness's fair agent never gets
them.
