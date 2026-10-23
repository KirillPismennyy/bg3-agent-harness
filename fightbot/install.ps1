# FightBot install (Windows, bg3se): copies the BG3AI mod's Lua and the loader into the Script Extender folder.
#   powershell -ExecutionPolicy Bypass -File fightbot\install.ps1 [-GameBin "C:\...\Baldur's Gate 3\bin"]
# With -GameBin it also turns on the Script Extender's Lua debugger (the port the fightbot talks to) in
# ScriptExtenderSettings.json next to bg3.exe, after backing the file up. Nothing else is changed.
param([string]$GameBin = "")
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$se = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender"
if (-not (Test-Path $se)) { throw "No Script Extender folder at ${se}: run the game once with bg3se installed." }

$src = Join-Path $repo "mod\Mods\BG3AI\ScriptExtender\Lua"
$dst = Join-Path $se "BG3AI"
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Copy-Item -Recurse $src $dst
Copy-Item (Join-Path $PSScriptRoot "FightBotLoad.lua") (Join-Path $se "FightBotLoad.lua") -Force
Write-Host "Copied the mod's Lua to $dst and FightBotLoad.lua to $se"

if ($GameBin -ne "") {
    $cfg = Join-Path $GameBin "ScriptExtenderSettings.json"
    $settings = New-Object PSObject
    if (Test-Path $cfg) {
        Copy-Item $cfg "$cfg.bak-$(Get-Date -Format yyyyMMddHHmmss)"
        $settings = Get-Content $cfg -Raw | ConvertFrom-Json   # Windows PowerShell 5.1: no -AsHashtable
    }
    $settings | Add-Member -NotePropertyName EnableLuaDebugger -NotePropertyValue $true -Force
    $settings | Add-Member -NotePropertyName CreateConsole -NotePropertyValue $true -Force
    $settings | ConvertTo-Json | Set-Content $cfg -Encoding UTF8
    Write-Host "Set EnableLuaDebugger and CreateConsole in $cfg (backup beside it). Restart the game for it to apply."
} else {
    Write-Host "Make sure ScriptExtenderSettings.json next to bg3.exe has `"EnableLuaDebugger`": true (or rerun with -GameBin)."
}
