[CmdletBinding()]
param([string]$GameBin = '', [string]$ScriptExtenderDir = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $ScriptExtenderDir) { $ScriptExtenderDir = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender" }
if (-not (Test-Path -LiteralPath $ScriptExtenderDir -PathType Container)) { throw 'Script Extender directory missing' }
$se = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ScriptExtenderDir).Path).TrimEnd('\')
$src = Join-Path $repo 'mod\Mods\BG3AI\ScriptExtender\Lua'
$loader = Join-Path $PSScriptRoot 'FightBotLoad.lua'
$dst = Join-Path $se 'BG3AI'
$loaderDst = Join-Path $se 'FightBotLoad.lua'
function Assert-PlainPath([string]$Path) {
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing reparse point: $Path" }
}
function Assert-SeChild([string]$Path) {
    if (-not [IO.Path]::GetFullPath($Path).StartsWith($se + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Target escapes Script Extender: $Path" }
    Assert-PlainPath $Path
}
function File-Hash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '')
    } finally { $stream.Dispose(); $hash.Dispose() }
}
Assert-PlainPath $se
if (-not (Test-Path -LiteralPath $src -PathType Container) -or -not (Test-Path -LiteralPath $loader -PathType Leaf)) { throw 'Keep fightbot, bridge and mod side by side' }
Assert-PlainPath $src
Assert-PlainPath $loader
foreach ($item in (Get-ChildItem -LiteralPath $src -Recurse -Force)) { Assert-PlainPath $item.FullName }
Assert-SeChild $dst
Assert-SeChild $loaderDst
if (Test-Path -LiteralPath $dst) {
    if (-not (Test-Path -LiteralPath $dst -PathType Container)) { throw 'BG3AI target is not a directory' }
    foreach ($item in (Get-ChildItem -LiteralPath $dst -Recurse -Force)) { Assert-PlainPath $item.FullName }
}
# Validate settings before modifying installation; preserve nested values, write UTF-8 without a BOM.
$cfg = $null
$settingsJson = $null
if ($GameBin) {
    if (-not (Test-Path -LiteralPath (Join-Path $GameBin 'bg3.exe') -PathType Leaf)) { throw 'GameBin must contain bg3.exe' }
    Assert-PlainPath $GameBin
    $cfg = Join-Path ([IO.Path]::GetFullPath($GameBin)) 'ScriptExtenderSettings.json'
    Assert-PlainPath $cfg
    $settings = New-Object PSObject
    if (Test-Path -LiteralPath $cfg) {
        $settings = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
        if ($null -eq $settings -or $settings -isnot [pscustomobject]) { throw 'Extender settings must be a JSON object' }
    }
    $settings | Add-Member -NotePropertyName EnableLuaDebugger -NotePropertyValue $true -Force
    $settings | Add-Member -NotePropertyName CreateConsole -NotePropertyValue $true -Force
    $settingsJson = $settings | ConvertTo-Json -Depth 100
}
$backupParent = Join-Path $se 'FightBotBackups'
Assert-SeChild $backupParent
$tag = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
$backup = Join-Path $backupParent $tag
Assert-SeChild $backup
New-Item -ItemType Directory -Path $backup | Out-Null
$receipt = [ordered]@{ prepared_utc = [DateTime]::UtcNow.ToString('o'); status = 'prepared'; script_extender = $se;
    backup_directory = $backup; previous_bg3ai = $false; previous_loader = $false; previous_settings = $false; settings_path = $cfg }
if (Test-Path -LiteralPath $dst) {
    $backupDst = Join-Path $backup 'BG3AI'
    Assert-SeChild $backupDst
    # Both absolute move targets were checked to stay inside the named Script Extender directory.
    Move-Item -LiteralPath $dst -Destination $backupDst
    $receipt.previous_bg3ai = $true
}
if (Test-Path -LiteralPath $loaderDst) { Copy-Item -LiteralPath $loaderDst -Destination (Join-Path $backup 'FightBotLoad.lua'); $receipt.previous_loader = $true }
if ($cfg -and (Test-Path -LiteralPath $cfg)) { Copy-Item -LiteralPath $cfg -Destination (Join-Path $backup 'ScriptExtenderSettings.json'); $receipt.previous_settings = $true }
$utf8 = New-Object Text.UTF8Encoding($false)
$receiptPath = Join-Path $backup 'install-receipt.json'
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 100), $utf8)
try {
    Copy-Item -LiteralPath $src -Destination $dst -Recurse
    Copy-Item -LiteralPath $loader -Destination $loaderDst -Force
    foreach ($item in (Get-ChildItem -LiteralPath $src -File -Recurse)) {
        $relative = $item.FullName.Substring($src.Length).TrimStart('\')
        if ((File-Hash $item.FullName) -ne (File-Hash (Join-Path $dst $relative))) { throw "Lua hash mismatch: $relative" }
    }
    if ((File-Hash $loader) -ne (File-Hash $loaderDst)) { throw 'Loader hash mismatch' }
    if ($cfg) { [IO.File]::WriteAllText($cfg, $settingsJson, $utf8) }
    $receipt.status = 'installed'
    $receipt.installed_utc = [DateTime]::UtcNow.ToString('o')
    Write-Host "Installed BG3AI and loader. Backup and receipt: $backup"
    if ($cfg) { Write-Host 'Lua debugger enabled. Restart the game. FightRec.lua and captures were preserved.' }
} catch { $receipt.status = 'failed'; $receipt.error = $_.Exception.Message; throw
} finally { [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 100), $utf8) }
