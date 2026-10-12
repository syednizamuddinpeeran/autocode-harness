# Run the sub-issues of a broken-down issue (create-issues.ps1), in dependency order, several at a
# time, locally. PowerShell counterpart of run-batch.sh.
#
#   pwsh scripts/factory/run-batch.ps1 <parent-issue>                 # run every sub-issue that is unblocked now
#   pwsh scripts/factory/run-batch.ps1 <parent-issue> -AutoContinue   # …then keep going as their PRs are merged
#   pwsh scripts/factory/run-batch.ps1 <parent-issue> -List           # show the state of each sub-issue only
#   options: -Parallel <n> (default: MAX_PARALLEL in complexity.env)
#
# A sub-issue is ready when it is open and every issue it is "blocked by" is closed. Each runs as its
# own run-issue.ps1 in its own worktree; output goes to .agent-logs/batch/issue-<N>.log.
# -AutoContinue waits for the merges (every BATCH_POLL_SECONDS, default 60) and starts what they
# unblock. Merging stays a human step. Cloud agent instead: -List, then assign the ready ones.
# Exit codes: 0 every run it started finished, 1 a run failed or stopped, 2 no sub-issues found.
param([Parameter(Position = 0)][int]$Parent, [switch]$AutoContinue, [switch]$List, [int]$Parallel)
$ErrorActionPreference = 'Stop'
if (-not $Parent) { [Console]::Error.WriteLine('usage: run-batch.ps1 <parent-issue> [-AutoContinue] [-List] [-Parallel <n>]'); exit 2 }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Missing: gh' }
$root = (git rev-parse --show-toplevel)
Set-Location -LiteralPath $root
. (Join-Path $root '.github/hooks/scripts/common.ps1')
$limits = Read-FactoryEnvFile (Join-Path $root 'scripts/factory/complexity.env')
if (-not $Parallel) { $Parallel = if ($limits['MAX_PARALLEL']) { [int]($limits['MAX_PARALLEL']) } else { 3 } }
if ($Parallel -lt 1) { throw '-Parallel must be a positive number' }
$poll = if ($env:BATCH_POLL_SECONDS) { [int]$env:BATCH_POLL_SECONDS } else { 60 }
$stagger = if ($null -ne $env:BATCH_STAGGER_SECONDS) { [int]$env:BATCH_STAGGER_SECONDS } else { 2 }
$logs = Join-Path $root '.agent-logs/batch'; New-Item -ItemType Directory -Force -Path $logs | Out-Null
$wtRoot = if ($env:FACTORY_WORKTREE_ROOT) { $env:FACTORY_WORKTREE_ROOT } else { Join-Path (Split-Path -Parent $root) "$(Split-Path -Leaf $root)-worktrees" }

$subs = @(); $st = @{}; $blockers = @{}
function Update-Issues {
  $script:subs = @(); $script:st = @{}; $script:blockers = @{}
  foreach ($row in @(gh api "repos/{owner}/{repo}/issues/$Parent/sub_issues" --paginate --jq '.[] | "\(.number) \(.state)"')) {
    if (-not $row) { continue }
    $n, $s = $row -split ' ', 2
    $script:subs += $n; $script:st[$n] = $s
    if ($s -eq 'open') {
      $script:blockers[$n] = (@(gh api "repos/{owner}/{repo}/issues/$n/dependencies/blocked_by" --paginate --jq '.[] | select(.state == "open") | "#\(.number)"') -join ' ')
    }
  }
}
$procs = @{}; $rc = @{}
function Get-State([string]$n) {
  if ($st[$n] -ne 'open') { return 'done' }
  if ($procs.ContainsKey($n)) { return 'running' }
  if ($rc.ContainsKey($n) -and $rc[$n] -ne 0) { return 'stopped' }
  if ($rc.ContainsKey($n) -or (Test-Path -LiteralPath (Join-Path $wtRoot "issue-$n"))) { return 'review' }
  if (-not $blockers[$n].Trim()) { return 'ready' }
  'blocked'
}
function Show-State {
  Write-Output "Sub-issues of #${Parent}:"
  foreach ($n in $subs) {
    $text = switch (Get-State $n) {
      'done'    { 'closed' }
      'running' { "running (log: .agent-logs/batch/issue-$n.log)" }
      'review'  { "started: review and merge its PR (worktree $(Join-Path $wtRoot "issue-$n"))" }
      'stopped' { "needs you: see .agent-logs/batch/issue-$n.log (questions, breakdown or failure)" }
      'blocked' { "blocked by: $($blockers[$n])" }
      'ready'   { 'ready' }
    }
    Write-Output ('  #{0,-6} {1}' -f $n, $text)
  }
}

Update-Issues
if (-not $subs) { [Console]::Error.WriteLine("Issue #$Parent has no sub-issues. Create them with create-issues.ps1."); exit 2 }
if ($List) { Show-State; exit 0 }

$failed = 0
while ($true) {
  foreach ($n in @($procs.Keys)) {
    $p = $procs[$n]
    if ($p.HasExited) {
      $p.WaitForExit(); $rc[$n] = $p.ExitCode; $procs.Remove($n)
      if ($rc[$n] -ne 0) { $failed = 1 }
      Write-Output "finished #$n (exit $($rc[$n]))"
    }
  }
  foreach ($n in $subs) {
    if ($procs.Count -ge $Parallel) { break }
    if ((Get-State $n) -ne 'ready') { continue }
    Write-Output "start    #$n"
    $log = Join-Path $logs "issue-$n.log"
    $p = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList @('-NoProfile', '-Command',
      "& pwsh -NoProfile -File scripts/factory/run-issue.ps1 $n *> '$log'; exit `$LASTEXITCODE")
    $null = $p.Handle   # keep the handle so ExitCode is available after exit
    $procs[$n] = $p
    Start-Sleep -Seconds $stagger   # let each run create its worktree before the next starts
  }
  if ($procs.Count -gt 0) { Start-Sleep -Seconds 2; continue }

  $states = @($subs | ForEach-Object { Get-State $_ })
  if (-not ($states | Where-Object { $_ -ne 'done' })) { Write-Output "All sub-issues of #$Parent are closed."; break }
  if (-not $AutoContinue -or -not ($states | Where-Object { $_ -in 'review', 'ready' })) { break }
  Start-Sleep -Seconds $poll
  Update-Issues
}
Write-Output ''
Show-State
if (-not $AutoContinue) {
  Write-Output ''
  Write-Output 'Review and merge the PRs, then run the batch again (or use -AutoContinue to start the next'
  Write-Output 'ones as their blockers are merged).'
}
exit $failed
