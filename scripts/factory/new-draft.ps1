# Turn a short brief into a complete issue / task draft, with you in control (Windows / PowerShell 7+).
# PowerShell counterpart of new-draft.sh.
#
#   pwsh scripts/factory/new-draft.ps1 "add CSV export to the reports page"
#   pwsh scripts/factory/new-draft.ps1 -Id csv-export "add CSV export to the reports page"
#
# Starts an interactive session with the `analyst` agent, which asks you questions and writes only
# what you answer (unanswered items are marked OPEN). Result: .agent-work/drafts/<id>.md. Review it,
# then run create-issue.ps1 (GitHub) or create-task.ps1 (local). Runs in a throwaway worktree.
param([Parameter(Position = 0)][string]$Brief, [string]$Id)
$ErrorActionPreference = 'Stop'
if (-not $Brief) { [Console]::Error.WriteLine('usage: new-draft.ps1 [-Id <slug>] "<short brief of what you want>"'); exit 2 }
if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { [Console]::Error.WriteLine('new-draft.ps1 is interactive: run it in a terminal.'); exit 2 }

$root = (git rev-parse --show-toplevel)
Set-Location -LiteralPath $root
. (Join-Path $root '.github/hooks/scripts/common.ps1')
$cfg = Read-FactoryEnvFile (Join-Path $root 'scripts/factory/commands.env')
$base = if ($cfg['BASE_BRANCH']) { $cfg['BASE_BRANCH'] } else { 'main' }
$repoName = Split-Path -Leaf $root

if (-not $Id) {
  $Id = ($Brief.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
  if ($Id.Length -gt 40) { $Id = $Id.Substring(0, 40).TrimEnd('-') }
}
if ($Id -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { throw "draft id must be a lowercase slug: $Id" }
$outDir = Join-Path $root '.agent-work/drafts'
$out = Join-Path $outDir "$Id.md"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$existing = Test-Path -LiteralPath $out
if ($existing) { Write-Output "A draft already exists: $out — the analyst will continue from it." }

$wtRoot = if ($env:FACTORY_WORKTREE_ROOT) { $env:FACTORY_WORKTREE_ROOT } else { Join-Path (Split-Path -Parent $root) "$repoName-worktrees" }
$wt = Join-Path $wtRoot "draft-$Id"
$ref = $base
git rev-parse --verify --quiet "origin/$base" | Out-Null
if ($LASTEXITCODE -eq 0) { $ref = "origin/$base" }
if (-not (Test-Path -LiteralPath $wt)) { git worktree add --detach -q $wt $ref; if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' } }
try {
  Set-Location -LiteralPath $wt
  & pwsh -NoProfile -File scripts/factory/setup.ps1 | Out-Null
  $draft = '.agent-work/draft.md'
  if ($existing) { Copy-Item -LiteralPath $out -Destination $draft -Force }
  $cont = if ($existing) { ' (it already contains an earlier draft: continue from it, keep their answers)' } else { '' }
  $prompt = @"
Brief from the human: "$Brief"
Help them turn it into a complete issue/task by asking questions (your analyst workflow). Write the
draft to $draft$cont. Ask your first question now.
"@
  . (Join-Path $wt 'scripts/factory/agent-cli.ps1')
  Invoke-AgentChat -Assistant $cfg['ASSISTANT'] -Agent analyst -Prompt $prompt -ForbiddenEnv $cfg['FORBIDDEN_ENV']

  if (-not (Test-Path -LiteralPath $draft) -or (Get-Item -LiteralPath $draft).Length -eq 0) { [Console]::Error.WriteLine('No draft was written.'); exit 1 }
  Copy-Item -LiteralPath $draft -Destination $out -Force
} finally {
  Set-Location -LiteralPath $root
  git worktree remove --force $wt 2>$null | Out-Null
}
Write-Output ''
Write-Output "Draft saved: $out"
Write-Output ''
& pwsh -NoProfile -File scripts/factory/check-ready.ps1 $out
Write-Output ''
if (Test-Path -LiteralPath 'scripts/factory/create-issue.ps1') { Write-Output "Review and edit it, then create the issue:  pwsh scripts/factory/create-issue.ps1 $out" }
else { Write-Output "Review and edit it, then create the task:   pwsh scripts/factory/create-task.ps1 $out" }
