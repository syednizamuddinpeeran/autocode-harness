# Is a task file or issue body ready for the factory? PowerShell counterpart of check-ready.sh.
#   pwsh scripts/factory/check-ready.ps1 <file.md>      # exit 0 ready, 4 not ready (reasons on stdout)
param([Parameter(Mandatory)][string]$File)
if (-not (Test-Path -LiteralPath $File)) { Write-Output "not found: $File"; exit 4 }
$lines = Get-Content -LiteralPath $File

# Section text: lines after "## Name" / "### Name" up to the next heading, without HTML comments,
# template placeholders (<…>), "_No response_" (empty issue-form field) and blank lines.
function Get-Section([string]$Name) {
  $on = $false
  foreach ($l in $lines) {
    if ($l -match '^###?[ \t]+(.*?)[ \t]*$') { $on = ($Matches[1] -ieq $Name); continue }
    if (-not $on) { continue }
    $t = $l -replace '<!--.*-->', ''
    if ($t -match '<[^>]+>' -or $t -match '^\s*_No response_\s*$' -or $t -match '^\s*$') { continue }
    $t
  }
}

$problems = @()
if (-not @(Get-Section 'Goal')) { $problems += 'Goal is empty: describe the user-visible outcome in 1-2 sentences.' }
if (-not (@(Get-Section 'Acceptance criteria') | Where-Object { $_ -match '^\s*([-*]|[0-9]+\.)\s+\S' })) {
  $problems += 'Acceptance criteria: add at least one testable criterion (Given / when / then).'
}
if (-not @(Get-Section 'Out of scope')) { $problems += 'Out of scope is empty: list what must not change, or write "None".' }
$risk = ((@(Get-Section 'Risk') -join '') -replace '\s', '').ToLowerInvariant()
if ($risk -notmatch '^(low|medium|high)$') { $problems += 'Risk must be exactly one of: low, medium, high.' }
if ($lines | Where-Object { $_ -cmatch '(^|[^A-Za-z])OPEN:' }) { $problems += 'Unanswered questions are still marked OPEN: answer or remove them.' }

if ($problems.Count -eq 0) { Write-Output 'ready'; exit 0 }
Write-Output "Not ready for the factory ($File):"
$problems | ForEach-Object { Write-Output "  - $_" }
exit 4
