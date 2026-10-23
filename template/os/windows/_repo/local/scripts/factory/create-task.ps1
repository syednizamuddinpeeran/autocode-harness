# HUMAN-ONLY: create tasks/<id>.md from a reviewed draft and commit it on the base branch.
# PowerShell counterpart of create-task.sh.
#   pwsh scripts/factory/create-task.ps1 .agent-work/drafts/<id>.md [-Id other-id] [-Yes]
# Refuses a draft that is not ready (check-ready.ps1).
param([Parameter(Mandatory, Position = 0)][string]$Draft, [string]$Id, [switch]$Yes)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Draft)) { throw "not found: $Draft" }
$Draft = (Resolve-Path -LiteralPath $Draft).Path
$root = (git rev-parse --show-toplevel)
Set-Location -LiteralPath $root
. (Join-Path $root '.github/hooks/scripts/common.ps1')
$cfg = Read-FactoryEnvFile (Join-Path $root 'scripts/factory/commands.env')
$base = if ($cfg['BASE_BRANCH']) { $cfg['BASE_BRANCH'] } else { 'main' }

& pwsh -NoProfile -File scripts/factory/check-ready.ps1 $Draft
if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('Fix the draft, then run again.'); exit 4 }
if (-not $Id) { $Id = [System.IO.Path]::GetFileNameWithoutExtension($Draft) }
if ($Id -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { throw "task id must be a lowercase slug: $Id" }
if ((git branch --show-current) -ne $base) { throw "Check out '$base' first." }
if (git status --porcelain -- tasks) { throw 'tasks/ has uncommitted changes; commit or stash them first.' }
if (Test-Path -LiteralPath "tasks/$Id.md") { throw "tasks/$Id.md already exists. Pick another -Id." }

Write-Output "──────── tasks/$Id.md"
Get-Content -LiteralPath $Draft
Write-Output '────────'
if (-not $Yes) {
  if ([Console]::IsInputRedirected) { [Console]::Error.WriteLine('Not a terminal: pass -Yes after reviewing the draft.'); exit 1 }
  $ans = Read-Host "Create and commit tasks/$Id.md on '$base'? [y/N]"
  if ($ans -notin 'y', 'Y') { Write-Output 'Not created.'; exit 0 }
}
New-Item -ItemType Directory -Force -Path tasks | Out-Null
Copy-Item -LiteralPath $Draft -Destination "tasks/$Id.md"
git add "tasks/$Id.md"
git commit -q -m "task: $Id" -- "tasks/$Id.md"
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
Write-Output "Committed tasks/$Id.md on '$base'."
# Record the result beside the draft, but only for a draft.md that new-draft made in its own folder.
if ((Split-Path -Leaf $Draft) -eq 'draft.md') {
  [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $Draft) 'created.txt'), "task=$Id`npath=tasks/$Id.md`n")
}
Write-Output "Run it with:  pwsh scripts/factory/run-task.ps1 $Id"
