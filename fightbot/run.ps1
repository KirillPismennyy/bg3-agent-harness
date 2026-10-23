# Start the fight agent (Windows). The game must be in the fight's save with FightBotLoad.lua loaded.
#   powershell -ExecutionPolicy Bypass -File fightbot\run.ps1
Set-Location $PSScriptRoot
claude "Fight the current combat. If no fight has started yet, call wait_for_turn and wait for it."
