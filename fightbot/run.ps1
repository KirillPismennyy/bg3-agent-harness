[CmdletBinding()]
param([switch]$ReadOnly, [switch]$Headless, [switch]$PrintOnly, [ValidateRange(1,200)][int]$MaxTurns = 30)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$python = Join-Path (Split-Path -Parent $PSScriptRoot) 'bridge\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Run uv sync --project bridge --frozen first.' }
$claude = (Get-Command claude -ErrorAction Stop).Source
$runtime = Join-Path $PSScriptRoot '.runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$config = Join-Path $runtime ('mcp-' + [guid]::NewGuid().ToString('N') + '.json')
$readOnlyValue = '0'
if ($ReadOnly) { $readOnlyValue = '1' }
$mcp = @{ mcpServers = @{ fightbot = @{ command = $python; args = @((Join-Path $PSScriptRoot 'fightbot_mcp.py'));
    env = @{ BG3AI_RPC_ROOT = 'BG3AI'; BG3AI_RPC_CONNS = '1'; BG3AI_JOB_PUSH = '0'; FIGHTBOT_READ_ONLY = $readOnlyValue } } } }
[IO.File]::WriteAllText($config, ($mcp | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
$tools = @('fight_state','actions','wait_for_turn','rolls')
if (-not $ReadOnly) { $tools += @('cast','move','end_turn') }
$allowed = ($tools | ForEach-Object { 'mcp__fightbot__' + $_ }) -join ','
# An explicitly empty option survives Windows PowerShell 5.1's native argument handling.
$claudeArgs = @('--model','claude-opus-5-5','--tools=','--strict-mcp-config','--mcp-config',$config,
    '--allowedTools',$allowed,'--permission-mode','dontAsk')
if ($Headless) { $claudeArgs += @('--print','--verbose','--output-format','stream-json','--max-turns',"$MaxTurns") }
$prompt = 'Fight exactly the current combat through fightbot tools only. Wait if it has not started. Stop after fight_over. Never save or load.'
if ($ReadOnly) { $prompt = 'Read fight_state once and report connection, party and recorder status. Do not wait for combat or request actions.' }
$claudeArgs += $prompt
if ($PrintOnly) { @{ command = $claude; args = $claudeArgs; mcp_config = $mcp } | ConvertTo-Json -Depth 12; return }
& $claude @claudeArgs
exit $LASTEXITCODE
