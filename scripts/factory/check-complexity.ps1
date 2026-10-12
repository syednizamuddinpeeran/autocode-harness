# Measure a plan + brief against scripts/factory/complexity.env. PowerShell counterpart of
# check-complexity.sh (same counts, output and exit codes).
#   pwsh scripts/factory/check-complexity.ps1 <plan.md> <brief.md>     # 0 within limits, 6 too complex, 4 malformed
#   pwsh scripts/factory/check-complexity.ps1 --diff <base> [<head>]   # real diff vs limits: 0 or 6
. (Join-Path $PSScriptRoot '../../.github/hooks/scripts/common.ps1')
$Limits = Read-FactoryEnvFile (Join-Path $PSScriptRoot 'complexity.env')
function N([string]$k) { [int]($Limits[$k]) }
$problems = @()
function Report([string]$label, $value, $limit) { Write-Output ('  {0,-24} {1,6}   (limit {2})' -f $label, $value, $limit) }
function Get-AreaCount([string[]]$files) {
  $seen = @{}
  foreach ($f in $files) {
    foreach ($pair in @($Limits['AREAS'] -split '\s+' | Where-Object { $_ })) {
      $name, $prefix = $pair -split '=', 2
      if ($f.StartsWith($prefix)) { $seen[$name] = 1 }
    }
  }
  $seen.Count
}

if ($args.Count -ge 1 -and $args[0] -eq '--diff') {
  $base = $args[1]; $head = if ($args.Count -ge 3) { $args[2] } else { 'HEAD' }
  $ref = $base
  git rev-parse --verify --quiet "refs/heads/$base" | Out-Null
  if ($LASTEXITCODE -ne 0) { git rev-parse --verify --quiet "origin/$base" | Out-Null; if ($LASTEXITCODE -eq 0) { $ref = "origin/$base" } }
  $files = @(git diff --name-only "$ref...$head" | Where-Object { $_ })
  $lines = 0
  foreach ($row in @(git diff --numstat "$ref...$head")) {
    $a, $d, $null = $row -split '\s+', 3
    if ($a -ne '-') { $lines += [int]$a }; if ($d -ne '-') { $lines += [int]$d }
  }
  Write-Output 'Actual change vs limits:'
  Report 'files changed' $files.Count (N MAX_FILES); if ($files.Count -gt (N MAX_FILES)) { $problems += "files changed $($files.Count) > $(N MAX_FILES)" }
  Report 'lines changed' $lines (N MAX_EST_LINES); if ($lines -gt (N MAX_EST_LINES)) { $problems += "lines changed $lines > $(N MAX_EST_LINES)" }
  if ($Limits['AREAS']) { $n = Get-AreaCount $files; Report 'areas' $n (N MAX_AREAS); if ($n -gt (N MAX_AREAS)) { $problems += "areas $n > $(N MAX_AREAS)" } }
} else {
  if ($args.Count -lt 2) { Write-Output 'usage: check-complexity.ps1 <plan.md> <brief.md> | --diff <base> [<head>]'; exit 4 }
  $plan, $brief = $args[0], $args[1]
  if (-not (Test-Path -LiteralPath $plan) -or -not (Test-Path -LiteralPath $brief)) { Write-Output "not found: $plan or $brief"; exit 4 }
  $p = Get-Content -LiteralPath $plan; $b = Get-Content -LiteralPath $brief
  $acs = @($b | Where-Object { $_ -match '^\s*-\s*AC[0-9]+' }).Count
  $tasks = @($p | Where-Object { $_ -match '^###\s+T[0-9]+' }).Count
  $files = @($p | Where-Object { $_ -match '^\s*-\s*(Files|Tests):' } | ForEach-Object { [regex]::Matches($_, '`([^`]+)`') | ForEach-Object { ($_.Groups[1].Value -replace '\s*\(new\)$', '') -replace '::.*$', '' } } | Sort-Object -Unique)
  $est = ($p | ForEach-Object { if ($_ -match '^\s*(-\s*)?Estimated lines changed:\s*~?([0-9]+)') { $Matches[2] } } | Select-Object -First 1)
  $risk = ''; $on = $false
  foreach ($l in $b) { if ($l -match '^##[ \t]+Risk') { $on = $true; continue }; if ($l -match '^#') { $on = $false }; if ($on -and $l.Trim()) { $risk = (($l.Trim() -split '\s+')[0].ToLowerInvariant() -replace '[^a-z]', ''); break } }
  if ($tasks -eq 0) { Write-Output "plan has no '### T<n>' tasks: $plan"; exit 4 }
  if ($acs -eq 0) { Write-Output "brief has no '- AC<n>' acceptance criteria: $brief"; exit 4 }
  if (-not $est) { Write-Output "plan has no 'Estimated lines changed: <n>' line: $plan"; exit 4 }
  $est = [int]$est
  Write-Output 'Plan vs limits (scripts/factory/complexity.env):'
  Report 'acceptance criteria' $acs (N MAX_ACCEPTANCE_CRITERIA); if ($acs -gt (N MAX_ACCEPTANCE_CRITERIA)) { $problems += "acceptance criteria $acs > $(N MAX_ACCEPTANCE_CRITERIA)" }
  Report 'plan tasks' $tasks (N MAX_PLAN_TASKS); if ($tasks -gt (N MAX_PLAN_TASKS)) { $problems += "plan tasks $tasks > $(N MAX_PLAN_TASKS)" }
  Report 'files' $files.Count (N MAX_FILES); if ($files.Count -gt (N MAX_FILES)) { $problems += "files $($files.Count) > $(N MAX_FILES)" }
  Report 'estimated lines' $est (N MAX_EST_LINES); if ($est -gt (N MAX_EST_LINES)) { $problems += "estimated lines $est > $(N MAX_EST_LINES)" }
  if ($Limits['AREAS']) { $n = Get-AreaCount $files; Report 'areas' $n (N MAX_AREAS); if ($n -gt (N MAX_AREAS)) { $problems += "areas $n > $(N MAX_AREAS)" } }
  Write-Output ('  {0,-24} {1,6}' -f 'risk', $(if ($risk) { $risk } else { '?' }))
  foreach ($r in @($Limits['SPLIT_ON_RISK'] -split '\s+' | Where-Object { $_ })) {
    if ($risk -eq $r -and $tasks -gt 1) { $problems += "risk '$risk' must be split into single-task items ($tasks tasks)" }
  }
}
if ($problems.Count -eq 0) { Write-Output 'RESULT: within limits'; exit 0 }
Write-Output 'RESULT: too complex — break it down:'
$problems | ForEach-Object { Write-Output "  - $_" }
exit 6
