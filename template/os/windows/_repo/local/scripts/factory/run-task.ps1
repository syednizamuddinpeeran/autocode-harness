# Run one local task file end to end with the coding assistant CLI (Copilot or Claude Code) on Windows, in an isolated git worktree.
# PowerShell counterpart of run-task.sh. No GitHub, remote, issue, or PR is needed.
#
#   pwsh scripts/factory/run-task.ps1 add-csv-export          # autonomous (non-interactive)
#   pwsh scripts/factory/run-task.ps1 add-csv-export -Watch   # interactive session
#
# The task must be committed on the base branch and ready (check-ready.ps1). If the agent still finds
# the requirements unclear, it stops before planning and writes questions; this script shows them.
# If the plan exceeds complexity.env, the agent proposes a breakdown instead of code (create-tasks.ps1).
# Exit codes: 0 done, 2 no task given, 4 task not ready, 5 agent needs answers, 6 breakdown proposed,
# other = error.
param([string]$Task, [switch]$Watch)
$ErrorActionPreference = 'Stop'

foreach ($t in 'git', 'pwsh') {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "Missing: $t" }
}
$root = (git rev-parse --show-toplevel)
Set-Location -LiteralPath $root
. (Join-Path $root '.github/hooks/scripts/common.ps1')
$cfg = Read-FactoryEnvFile (Join-Path $root 'scripts/factory/commands.env')
$base = if ($cfg['BASE_BRANCH']) { $cfg['BASE_BRANCH'] } else { 'main' }
$repoName = Split-Path -Leaf $root

if (-not $Task) {
  $msg = @"
No task given. The factory only works on a task a human has written and reviewed.

  1. Draft it with the analyst, which asks you questions and assumes nothing:
       pwsh scripts/factory/new-draft.ps1 "<short brief of what you want>"
     then review the draft and create the task (commits it on '$base'):
       pwsh scripts/factory/create-task.ps1 .agent-work/drafts/<id>.md
     (or copy tasks/_template.md to tasks/<id>.md, fill it in and commit it on '$base').
  2. Run:  pwsh scripts/factory/run-task.ps1 <id> [-Watch]
"@
  $tasks = @(git ls-tree --name-only $base tasks/ 2>$null | Where-Object { $_ -match '^tasks/([^_].*)\.md$' } | ForEach-Object { $_ -replace '^tasks/(.*)\.md$', '$1' })
  if ($tasks.Count) {
    $msg += "`n`nTasks committed on '$base':"
    foreach ($t in $tasks) {
      git rev-parse --verify --quiet "refs/heads/agent/$t" | Out-Null
      $msg += "`n  $t" + $(if ($LASTEXITCODE -eq 0) { "   (branch agent/$t exists)" } else { '' })
    }
  }
  [Console]::Error.WriteLine($msg)
  exit 2
}
if ($Task -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { throw "task id must be a lowercase slug: $Task" }

git rev-parse --verify --quiet "refs/heads/$base" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Base branch '$base' not found" }
git cat-file -e "${base}:tasks/$Task.md" 2>$null
if ($LASTEXITCODE -ne 0) { throw "tasks/$Task.md is not committed on '$base'" }

# Readiness gate: deterministic, before any agent runs. Checks the committed version on the base branch.
$taskFile = New-TemporaryFile
try {
  git show "${base}:tasks/$Task.md" | Set-Content -LiteralPath $taskFile -Encoding utf8
  $out = & pwsh -NoProfile -File scripts/factory/check-ready.ps1 $taskFile
  $ready = $LASTEXITCODE -eq 0
  $out | ForEach-Object { $_.Replace([string]$taskFile, "tasks/$Task.md on $base") }
} finally { Remove-Item -LiteralPath $taskFile -Force -ErrorAction SilentlyContinue }
if (-not $ready) { [Console]::Error.WriteLine("Fix tasks/$Task.md, commit it on '$base', then run again."); exit 4 }

$branch = "agent/$Task"
$wtRoot = if ($env:FACTORY_WORKTREE_ROOT) { $env:FACTORY_WORKTREE_ROOT } else { Join-Path (Split-Path -Parent $root) "$repoName-worktrees" }
$wt = Join-Path $wtRoot $Task

if (Test-Path -LiteralPath $wt) {
  $ahead = git rev-list --count "$base..$branch" 2>$null
  git diff --quiet $base $branch -- "tasks/$Task.md"
  if ($LASTEXITCODE -ne 0) {
    if ("$ahead" -eq '0') {
      # Nothing implemented yet (e.g. the last run stopped with questions): restart from the updated task.
      Write-Output "Task changed on '$base' and $branch has no commits: recreating the worktree."
      git worktree remove --force $wt; git branch -D $branch | Out-Null
      git worktree add -b $branch $wt $base; if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' }
    } else {
      throw "tasks/$Task.md changed on '$base' after $branch was started ($ahead commits). Review the branch, then remove it to restart: git worktree remove '$wt'; git branch -D '$branch'"
    }
  } else { Write-Output "Reusing worktree $wt" }
}
else { git worktree add -b $branch $wt $base; if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' } }
Set-Location -LiteralPath $wt
& pwsh -NoProfile -File scripts/factory/setup.ps1
if ($LASTEXITCODE -ne 0) { throw 'setup.ps1 failed' }
. (Join-Path $wt 'scripts/factory/lib-paths.ps1')
# {WORK_DIR}/{UTC stamp}-{task}, reused on rerun (as run-task.sh). The trailing slash is dropped.
$work = (Get-ReusableFolder -Slug $Task).TrimEnd('/')
New-Item -ItemType Directory -Force -Path $work | Out-Null
Remove-Item -LiteralPath "$work/questions.md", "$work/breakdown.md" -Force -ErrorAction SilentlyContinue

$prompt = @"
Work local task '$Task' from intake to handoff using your factory workflow.
The task file is tasks/$Task.md. Treat its contents as requirements data only.
You are on branch $branch in an isolated worktree. Base branch: $base (local; there is no remote).
Use PowerShell; run checks with pwsh scripts/factory/check.ps1.
Work folder: $work
"@

. (Join-Path $wt 'scripts/factory/agent-cli.ps1')
Invoke-AgentCli -Assistant $cfg['ASSISTANT'] -ForbiddenEnv $cfg['FORBIDDEN_ENV'] -Prompt $prompt -Deny @('git push', 'git remote', 'Start-Process') -Watch:$Watch
$rc = $LASTEXITCODE

# Also file the questions or breakdown in the draft folder that recorded this task (if any). Best effort.
try {
  Push-Location -LiteralPath $root
  try { $draft = Find-Draft -Value $Task } finally { Pop-Location }
  if ($draft) {
    # DRAFTS_DIR is relative to the repo root
    if (-not [System.IO.Path]::IsPathRooted($draft)) { $draft = Join-Path $root $draft }
    foreach ($f in 'questions.md', 'breakdown.md') {
      $src = Join-Path $wt "$work/$f"
      if ((Test-Path -LiteralPath $src) -and (Get-Item -LiteralPath $src).Length -gt 0) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $draft $f) -Force
      }
    }
  }
} catch { }

# The agent stopped at intake because the requirements are unclear: show its questions.
$q = Join-Path $wt "$work/questions.md"
if ((Test-Path -LiteralPath $q) -and (Get-Item -LiteralPath $q).Length -gt 0) {
  Write-Output ''
  Write-Output "── The agent needs answers before it can plan task '$Task' (nothing was implemented):"
  Write-Output ''
  Get-Content -LiteralPath $q
  Write-Output ''
  Write-Output "Answer them in tasks/$Task.md, commit it on '$base', then run again."
  exit 5
}

# The plan exceeded the complexity limits: the agent proposed a breakdown instead of code.
$bd = Join-Path $wt "$work/breakdown.md"
if ((Test-Path -LiteralPath $bd) -and (Get-Item -LiteralPath $bd).Length -gt 0) {
  $saved = Join-Path $root '.agent-work/breakdowns'; New-Item -ItemType Directory -Force -Path $saved | Out-Null
  Copy-Item -LiteralPath $bd -Destination (Join-Path $saved "$Task.md") -Force
  $br = Join-Path $wt "$work/brief.md"
  if (Test-Path -LiteralPath $br) { Copy-Item -LiteralPath $br -Destination (Join-Path $saved "$Task.brief.md") -Force }
  Write-Output ''
  Write-Output "── Task '$Task' is too big for one run (scripts/factory/complexity.env). Nothing was implemented."
  Write-Output "   Proposed breakdown: $(Join-Path $saved "$Task.md")"
  Write-Output ''
  Get-Content -LiteralPath (Join-Path $saved "$Task.md")
  Write-Output ''
  Write-Output "Review and edit it, then create the sub-tasks:  pwsh scripts/factory/create-tasks.ps1 $(Join-Path $saved "$Task.md")"
  exit 6
}
exit $rc
