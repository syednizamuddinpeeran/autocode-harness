# HUMAN-ONLY: create a GitHub issue from a reviewed draft. PowerShell counterpart of create-issue.sh.
#   pwsh scripts/factory/create-issue.ps1 .agent-work/drafts/<id>.md [-Yes]
# Refuses a draft that is not ready (check-ready.ps1). Runs `gh issue create` with your credentials.
param([Parameter(Mandatory, Position = 0)][string]$Draft, [switch]$Yes)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Draft)) { throw "not found: $Draft" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Missing: gh' }
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-ready.ps1') $Draft
if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('Fix the draft, then run again.'); exit 4 }

$lines = Get-Content -LiteralPath $Draft
$idx = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^# (.*\S)\s*$') { $idx = $i; $title = $Matches[1]; break } }
if ($idx -lt 0 -or $title -match '<') { [Console]::Error.WriteLine("The draft needs a title line: '# <short imperative title>'"); exit 4 }
$body = New-TemporaryFile
try {
  ($lines | Select-Object -Skip ($idx + 1)) | Set-Content -LiteralPath $body -Encoding utf8
  Write-Output "──────── Title: $title"
  Get-Content -LiteralPath $body
  Write-Output '────────'
  if (-not $Yes) {
    if ([Console]::IsInputRedirected) { [Console]::Error.WriteLine('Not a terminal: pass -Yes after reviewing the draft.'); exit 1 }
    $ans = Read-Host 'Create this issue? [y/N]'
    if ($ans -notin 'y', 'Y') { Write-Output 'Not created.'; exit 0 }
  }
  $url = gh issue create --title $title --body-file $body --label agent-ready 2>$null
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("(label 'agent-ready' not found; creating without it)")
    $url = gh issue create --title $title --body-file $body
    if ($LASTEXITCODE -ne 0) { throw 'gh issue create failed' }
  }
} finally { Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue }
Write-Output "Created: $url"
Write-Output "Run it locally with:  pwsh scripts/factory/run-issue.ps1 $(($url -split '/')[-1])   (or assign it to the cloud agent)"
