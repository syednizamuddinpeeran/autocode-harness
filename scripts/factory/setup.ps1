# Environment setup (Windows / PowerShell 7+). Counterpart of setup.sh.
#   pwsh scripts/factory/setup.ps1
$ErrorActionPreference = 'Stop'
$root = git rev-parse --show-toplevel 2>$null
if (-not $root) { $root = (Get-Location).Path }
Set-Location -LiteralPath $root
. (Join-Path $root '.github/hooks/scripts/common.ps1')
$cfg = Read-FactoryEnvFile (Join-Path $root 'scripts/factory/commands.env')

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Missing required tool: git' }
New-Item -ItemType Directory -Force -Path .agent-logs, .agent-work | Out-Null

if ($cfg['SETUP_CMD']) {
  Write-Output "── setup: $($cfg['SETUP_CMD'])"
  & pwsh -NoProfile -NonInteractive -Command $cfg['SETUP_CMD']
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  Write-Output '── setup: nothing configured (SETUP_CMD empty)'
}
