# HUMAN-ONLY: create GitHub issues from reviewed drafts. PowerShell counterpart of create-issue.sh.
#   pwsh scripts/factory/create-issue.ps1 .agent-work/drafts/<id>.md [-Yes]
#   pwsh scripts/factory/create-issue.ps1 -Draft .agent-work/drafts/*.md     # many at once, review on GitHub
# -Draft: no prompt; each issue gets the `agent-draft` label instead of `agent-ready`. Review and edit
# the issues on GitHub, then add `agent-ready` to the ones you approve (that starts the factory).
# Refuses a draft that is not ready (check-ready.ps1); every draft is validated before any issue is
# created. Runs `gh issue create` with your credentials.
param([Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)][string[]]$Drafts, [switch]$Yes, [switch]$Draft)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Missing: gh' }

function Get-Title([string]$Path) {
  foreach ($l in (Get-Content -LiteralPath $Path)) { if ($l -match '^# (.*\S)\s*$') { return $Matches[1] } }
  return $null
}

foreach ($d in $Drafts) {
  if (-not (Test-Path -LiteralPath $d)) { throw "not found: $d" }
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-ready.ps1') $d
  if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("Fix $d, then run again."); exit 4 }
  $t = Get-Title $d
  if (-not $t -or $t -match '<') { [Console]::Error.WriteLine("$d needs a title line: '# <short imperative title>'"); exit 4 }
}

$label = 'agent-ready'
if ($Draft) {
  $label = 'agent-draft'
  gh label create agent-draft --description 'Drafted by the factory; review, then add agent-ready' --color FBCA04 2>&1 | Out-Null
  $global:LASTEXITCODE = 0
}

$body = New-TemporaryFile
try {
  foreach ($d in $Drafts) {
    $lines = Get-Content -LiteralPath $d
    $idx = 0
    while ($lines[$idx] -notmatch '^# ') { $idx++ }
    $title = Get-Title $d
    ($lines | Select-Object -Skip ($idx + 1)) | Set-Content -LiteralPath $body -Encoding utf8
    if (-not $Draft) {
      Write-Output "──────── Title: $title"
      Get-Content -LiteralPath $body
      Write-Output '────────'
      if (-not $Yes) {
        if ([Console]::IsInputRedirected) { [Console]::Error.WriteLine('Not a terminal: pass -Yes after reviewing the draft.'); exit 1 }
        $ans = Read-Host 'Create this issue? [y/N]'
        if ($ans -notin 'y', 'Y') { Write-Output 'Not created.'; continue }
      }
    }
    $url = gh issue create --title $title --body-file $body --label $label 2>$null
    if ($LASTEXITCODE -ne 0) {
      [Console]::Error.WriteLine("(label '$label' not found; creating without it)")
      $url = gh issue create --title $title --body-file $body
      if ($LASTEXITCODE -ne 0) { throw 'gh issue create failed' }
    }
    Write-Output "Created: $url"
    if (-not $Draft) { Write-Output "Run it locally with:  pwsh scripts/factory/run-issue.ps1 $(($url -split '/')[-1])   (or assign it to the cloud agent)" }
  }
} finally { Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue }
if ($Draft) { Write-Output 'Review the issues on GitHub, then add the agent-ready label to the ones you approve.' }
