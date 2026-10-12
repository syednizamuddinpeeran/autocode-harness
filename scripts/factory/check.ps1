# Verification gate (Windows / PowerShell 7+). Counterpart of check.sh; same commands.env.
# On success, records a state hash that the agentStop hook uses to know the work is verified.
#   pwsh scripts/factory/check.ps1
$root = git rev-parse --show-toplevel 2>$null
if (-not $root) { $root = (Get-Location).Path }
Set-Location -LiteralPath $root
. (Join-Path $root '.github/hooks/scripts/common.ps1')
$cfg = Read-FactoryEnvFile (Join-Path $root 'scripts/factory/commands.env')

$checks = [ordered]@{
  format = $cfg['FORMAT_CHECK_CMD']; lint = $cfg['LINT_CMD']; typecheck = $cfg['TYPECHECK_CMD']
  test = $cfg['TEST_CMD']; build = $cfg['BUILD_CMD']
}

$ran = 0; $failed = @()
foreach ($name in $checks.Keys) {
  $cmd = $checks[$name]
  if (-not $cmd) { Write-Output "── ${name}: skipped (not configured)"; continue }
  $ran++
  Write-Output "── ${name}: $cmd"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & pwsh -NoProfile -NonInteractive -Command $cmd
  $code = $LASTEXITCODE
  $secs = [int]$sw.Elapsed.TotalSeconds
  if ($code -eq 0) { Write-Output "── ${name}: PASS (${secs}s)" } else { Write-Output "── ${name}: FAIL (${secs}s)"; $failed += $name }
}

$marker = Join-Path (Get-FactoryLogDir) '.verified'
if ($ran -eq 0 -and $cfg['ALLOW_NO_CHECKS'] -ne '1') {
  [Console]::Error.WriteLine('No checks configured. Edit scripts/factory/commands.env for this project.')
  Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
  exit 3
}
if ($failed.Count -gt 0) {
  Write-Output "RESULT: FAIL ($($failed -join ' '))"
  Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
  exit 1
}
Set-Content -LiteralPath $marker -Value (Get-FactoryStateHash) -Encoding utf8 -NoNewline
Write-Output "RESULT: PASS ($ran checks)"
exit 0
