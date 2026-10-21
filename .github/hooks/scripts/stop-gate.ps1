# agentStop gate (Windows / PowerShell 7+). Counterpart of stop-gate.sh: if the agent changed code
# but has not passed scripts/factory/check.ps1 since its last change, force one more turn.
# Disable for a session with FACTORY_STOP_GATE=off.
try {
  . (Join-Path $PSScriptRoot 'common.ps1')
  $payloadJson = [Console]::In.ReadToEnd()
  Set-FactoryContext
  $root = Get-FactoryRoot
  $cfg = Read-FactoryEnvFile (Join-Path $root 'scripts/factory/commands.env')
  if ($cfg['BASE_BRANCH']) { $env:BASE_BRANCH = $cfg['BASE_BRANCH'] }

  function Pass([string]$Gate) { try { Write-FactoryLog 'agentStop' $payloadJson @{ gate = $Gate } } catch { }; exit 0 }

  if ($env:FACTORY_STOP_GATE -eq 'off') { Pass 'disabled' }
  $payload = $null
  try { $payload = ConvertFrom-FactoryJson $payloadJson } catch { }
  if ($payload -is [System.Collections.IDictionary] -and $payload.Contains('stop_hook_active') -and $payload['stop_hook_active'] -eq $true) { Pass 'already-continued' }
  if (-not (Test-FactoryHasChanges)) { Pass 'no-changes' }

  $marker = Join-Path (Get-FactoryLogDir) '.verified'
  if ((Test-Path -LiteralPath $marker) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq (Get-FactoryStateHash))) { Pass 'verified' }

  try { Write-FactoryLog 'agentStop' $payloadJson @{ gate = 'blocked-unverified' } } catch { }
  [ordered]@{
    decision = 'block'
    reason   = 'Your changes have not passed verification since the last edit. Load the verify-changes skill, run pwsh scripts/factory/check.ps1, fix any failures, and only then finish with the final step of your workflow (the open-pr or handoff skill).'
  } | ConvertTo-Json -Compress
} catch { }
exit 0
