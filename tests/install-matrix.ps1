# Windows CI: install every repo type × assistant with -Os windows via install.ps1 and run the PowerShell tests.
#   pwsh tests/install-matrix.ps1
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
# A git worktree as the target (its .git is a file, not a directory) installs like a normal checkout;
# a plain folder is refused.
Write-Output '=== install into a git worktree'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("factory-matrix-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $tmp 'main'), (Join-Path $tmp 'plain') | Out-Null
Push-Location -LiteralPath (Join-Path $tmp 'main')
try {
  git init -q -b main . ; git config user.email t@t ; git config user.name t
  Set-Content README.md '# scratch'; git add -A; git commit -qm init
  $wt = Join-Path $tmp 'wt'
  git worktree add -q -b wt $wt; if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' }
  & pwsh -NoProfile -File (Join-Path $root 'install.ps1') $wt -Repo github -Os windows | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'install into a worktree failed' }
  if (-not (Test-Path -LiteralPath (Join-Path $wt 'scripts/factory/run-issue.ps1'))) { throw 'worktree install wrote no factory scripts' }
  & pwsh -NoProfile -File (Join-Path $root 'install.ps1') (Join-Path $tmp 'plain') -Repo github *> $null
  if ($LASTEXITCODE -eq 0) { throw 'install into a plain folder succeeded' }
} catch {
  Write-Output "FAILED: install into a git worktree ($_)"; $fail = 1
} finally {
  Pop-Location
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
foreach ($repo in (Get-ChildItem (Join-Path $root 'template/repo') -Directory).Name) {
 foreach ($assistant in (Get-ChildItem (Join-Path $root 'template/assistant') -Directory).Name) {
  Write-Output "=== repo=$repo os=windows assistant=$assistant cloud=aws"
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("factory-matrix-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  Push-Location -LiteralPath $tmp
  try {
    git init -q -b main . ; git config user.email t@t ; git config user.name t
    Set-Content README.md '# scratch'; git add -A; git commit -qm init
    & pwsh -NoProfile -File (Join-Path $root 'install.ps1') $tmp -Repo $repo -Os windows -Assistant $assistant -Cloud aws | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'install failed' }
    if (& pwsh -NoProfile -File (Join-Path $root 'install.ps1') $tmp -Repo $repo -Os windows -Assistant $assistant -Cloud aws | Select-String '^added:') { throw 're-install added files' }
    git add -A; git commit -qm installed
    & pwsh -NoProfile -File scripts/factory/test-hooks.ps1; if ($LASTEXITCODE -ne 0) { throw 'test-hooks.ps1 failed' }
    $logs = Join-Path $tmp 'logs-check'
    $env:FACTORY_LOG_DIR = $logs
    try {
      . (Join-Path $tmp '.github/hooks/scripts/common.ps1')
      Write-FactoryLog 'sessionStart' '{"sessionId":"mysession"}'
      Write-FactoryLog 'preToolUse' '{"sessionId":"mysession"}'
    } finally { Remove-Item Env:FACTORY_LOG_DIR -ErrorAction SilentlyContinue }
    $sf = @(Get-ChildItem -LiteralPath $logs -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-mysession$' })
    if ($sf.Count -ne 1) { throw "want one UTC session folder, got $($sf.Count)" }
    if (@(Get-Content -LiteralPath (Join-Path $sf[0].FullName 'mysession.jsonl')).Count -ne 2) { throw 'session log should have 2 lines' }
    if (Test-Path -LiteralPath (Join-Path $logs 'mysession.jsonl')) { throw 'flat session log written' }
    if (-not (Select-String -LiteralPath (Join-Path $logs 'index.jsonl') -Pattern 'sessionStart' -Quiet)) { throw 'index.jsonl lacks sessionStart' }
    foreach ($fx in Get-ChildItem (Join-Path $root 'tests/fixtures/ready') -Filter *.md) {
      $want = if ($fx.Name -like 'bad-*') { 4 } else { 0 }
      & pwsh -NoProfile -File scripts/factory/check-ready.ps1 $fx.FullName | Out-Null
      if ($LASTEXITCODE -ne $want) { throw "check-ready.ps1 $($fx.Name): want $want, got $LASTEXITCODE" }
    }
    $okGoal = & pwsh -NoProfile -File scripts/factory/check-ready.ps1 (Join-Path $root 'tests/fixtures/ready/ok-goal-angle.md')
    if ($LASTEXITCODE -ne 0 -or (@($okGoal) -join "`n") -ne 'ready') { throw "check-ready.ps1 ok-goal-angle.md: want exit 0 and ready, got $LASTEXITCODE" }
    $badGoal = @(& pwsh -NoProfile -File scripts/factory/check-ready.ps1 (Join-Path $root 'tests/fixtures/ready/bad-goal-placeholder.md'))
    if ($LASTEXITCODE -ne 4 -or @($badGoal | Where-Object { $_ -like '  - *' }).Count -ne 1 -or -not ($badGoal | Where-Object { $_ -match 'Goal is empty' })) { throw "check-ready.ps1 bad-goal-placeholder.md: want exit 4 with only the Goal problem, got $LASTEXITCODE" }
    foreach ($d in Get-ChildItem (Join-Path $root 'tests/fixtures/complexity') -Directory) {
      $want = switch ($d.Name) { { $_ -in 'ok', 'high-risk-single', 'two-areas' } { 0 } 'no-estimate' { 4 } default { 6 } }
      & pwsh -NoProfile -File scripts/factory/check-complexity.ps1 (Join-Path $d.FullName 'plan.md') (Join-Path $d.FullName 'brief.md') | Out-Null
      if ($LASTEXITCODE -ne $want) { throw "check-complexity.ps1 $($d.Name): want $want, got $LASTEXITCODE" }
    }
    $bdDir = Join-Path $root 'tests/fixtures/breakdown'
    foreach ($fx in Get-ChildItem $bdDir -Filter *.md | Where-Object { $_.Name -ne 'brief.md' }) {
      $want = if ($fx.Name -like 'bad-*') { 4 } else { 0 }
      & pwsh -NoProfile -File scripts/factory/check-breakdown.ps1 $fx.FullName (Join-Path $bdDir 'brief.md') | Out-Null
      if ($LASTEXITCODE -ne $want) { throw "check-breakdown.ps1 $($fx.Name): want $want, got $LASTEXITCODE" }
    }
    $launcher = if ($repo -eq 'local') { 'scripts/factory/run-task.ps1' } else { 'scripts/factory/run-issue.ps1' }
    & pwsh -NoProfile -File $launcher *> $null
    if ($LASTEXITCODE -ne 2) { throw "$launcher without input: want exit 2, got $LASTEXITCODE" }
    & pwsh -NoProfile -File scripts/factory/run-batch.ps1 *> $null
    if ($LASTEXITCODE -ne 2) { throw "run-batch.ps1 without input: want exit 2, got $LASTEXITCODE" }
    & pwsh -NoProfile -File scripts/factory/check.ps1 *> $null; if ($LASTEXITCODE -ne 3) { throw 'check.ps1 should exit 3 with no checks' }
    (Get-Content scripts/factory/commands.env) -replace '^ALLOW_NO_CHECKS=0', 'ALLOW_NO_CHECKS=1' | Set-Content scripts/factory/commands.env
    & pwsh -NoProfile -File scripts/factory/setup.ps1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'setup.ps1 failed' }
    & pwsh -NoProfile -File scripts/factory/check.ps1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'check.ps1 failed' }
  } catch {
    Write-Output "FAILED: repo=$repo assistant=$assistant ($_)"; $fail = 1
  } finally {
    Pop-Location
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
 }
}
if ($fail) { Write-Output 'install matrix (PowerShell): FAILED' } else { Write-Output 'install matrix (PowerShell): all passed' }
exit $fail
