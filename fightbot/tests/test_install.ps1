param([string]$Installer = (Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'))
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('fightbot-installer-test-' + [guid]::NewGuid().ToString('N'))
$bot = Join-Path $fixture 'fightbot'
$mod = Join-Path $fixture 'mod\Mods\BG3AI\ScriptExtender\Lua\Server'
$se = Join-Path $fixture 'se'
New-Item -ItemType Directory -Path $bot,$mod,$se,(Join-Path $bot 'probes'),(Join-Path $se 'FightBotProbe') | Out-Null
Copy-Item -LiteralPath $Installer -Destination (Join-Path $bot 'install.ps1')
Set-Content (Join-Path $mod 'sample.lua') 'new module'
Set-Content (Join-Path $bot 'FightBotLoad.lua') 'new loader'
Set-Content (Join-Path $bot 'probes\cast_probe.lua') 'new cast probe'
Set-Content (Join-Path $bot 'probes\miss_roll_probe.lua') 'new numerical probe'
Set-Content (Join-Path $se 'cast_probe.lua') 'old cast probe'
Set-Content (Join-Path $se 'FightBotProbe\miss_roll_probe.lua') 'old numerical probe'
Set-Content (Join-Path $se 'FightBotProbe\retained-capture.json') 'retained capture'
Set-Content (Join-Path $se 'FightRec.lua') 'unchanged recorder'
$retained = Get-FileHash (Join-Path $se 'FightBotProbe\retained-capture.json')
$recorder = Get-FileHash (Join-Path $se 'FightRec.lua')
& (Join-Path $bot 'install.ps1') -ScriptExtenderDir $se
$backup = Get-ChildItem (Join-Path $se 'FightBotBackups') -Directory | Select-Object -First 1
$receipt = Get-Content (Join-Path $backup.FullName 'install-receipt.json') -Raw | ConvertFrom-Json
if ($receipt.status -ne 'installed' -or $receipt.probes.Count -ne 2) { throw 'probe receipt missing' }
if ((Get-Content (Join-Path $backup.FullName 'cast_probe.lua')).Trim() -ne 'old cast probe') { throw 'old cast probe not backed up' }
if ((Get-Content (Join-Path $backup.FullName 'miss_roll_probe.lua')).Trim() -ne 'old numerical probe') { throw 'old numerical probe not backed up' }
foreach ($probe in $receipt.probes) {
    if (-not $probe.previous -or (Get-FileHash $probe.path).Hash -ne $probe.sha256) { throw 'installed hash/provenance mismatch' }
}
if ((Get-FileHash $retained.Path).Hash -ne $retained.Hash -or (Get-FileHash $recorder.Path).Hash -ne $recorder.Hash) { throw 'capture/recorder changed' }
# A source validation failure must happen before the existing installation is moved.
$oldModuleHash = (Get-FileHash (Join-Path $se 'BG3AI\Server\sample.lua')).Hash
Move-Item -LiteralPath (Join-Path $bot 'probes\cast_probe.lua') -Destination (Join-Path $bot 'probes\cast_probe.saved')
$refused = $false
try { & (Join-Path $bot 'install.ps1') -ScriptExtenderDir $se } catch { $refused = $_.Exception.Message -like 'Missing probe source:*' }
if (-not $refused -or (Get-FileHash (Join-Path $se 'BG3AI\Server\sample.lua')).Hash -ne $oldModuleHash) { throw 'missing probe did not refuse before deployment' }
Write-Output 'Installer probe checks passed: backup, hashes, receipt, capture/recorder preservation and preflight refusal.'
