# Self-test for the PowerShell guard and stop-gate hooks. Runs in a throwaway git repo.
# Uses the same cases as test-hooks.sh (scripts/factory/hook-cases.txt).
#   pwsh scripts/factory/test-hooks.ps1
$src = git rev-parse --show-toplevel 2>$null
if (-not $src) { $src = (Get-Location).Path }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("factory-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$global:pass = 0; $global:fail = 0
try {
  Set-Location -LiteralPath $tmp
  git init -q -b main . ; git config user.email t@t ; git config user.name t
  New-Item -ItemType Directory -Force -Path .github, scripts | Out-Null
  Copy-Item -Recurse (Join-Path $src '.github/hooks') .github/
  Copy-Item -Recurse (Join-Path $src 'scripts/factory') scripts/
  Set-Content .gitignore ".agent-logs/`n.agent-work/" -Encoding utf8
  # Neutral config: the self-test must not run the project's real checks in this throwaway repo.
  Set-Content scripts/factory/commands.env "BASE_BRANCH=`"main`"`nSETUP_CMD=`"`"`nFORMAT_CHECK_CMD=`"`"`nLINT_CMD=`"`"`nTYPECHECK_CMD=`"`"`nTEST_CMD=`"`"`nBUILD_CMD=`"`"`nALLOW_NO_CHECKS=0" -Encoding utf8
  git add -A ; git commit -qm init
  git checkout -qb agent/test-1
  $agentBranch = 'agent/test-1'
  $worktree = ''

  function Invoke-Hook([string]$Script, [string]$Json, [string[]]$HookArgs = @()) {
    $out = $Json | & pwsh -NoProfile -File ".github/hooks/scripts/$Script" @HookArgs 2>$null
    return @{ out = ($out | Out-String).Trim(); rc = $LASTEXITCODE }
  }
  function Expect([string]$Want, [string]$Desc, $Payload) {
    $json = if ($Payload -is [string]) { $Payload } else { $Payload | ConvertTo-Json -Compress -Depth 20 }
    $r = Invoke-Hook 'guard.ps1' $json
    $got = 'allow'
    if ($r.rc -ne 0) { $got = 'deny' }
    elseif ($r.out) {
      try {
        $j = $r.out | ConvertFrom-Json
        $d = if ($j.PSObject.Properties['permissionDecision']) { $j.permissionDecision } elseif ($j.PSObject.Properties['hookSpecificOutput']) { $j.hookSpecificOutput.permissionDecision } else { '' }
        if ($d -eq 'deny') { $got = 'deny' }
      } catch { $got = 'deny' }
    }
    if ($got -eq $Want) { $global:pass++ } else { $global:fail++; Write-Output "FAIL: $Desc (want $Want, got $got) $($r.out)" }
  }
  # Payloads in Copilot (camelCase) or Claude Code (snake_case) shape; $format picks one.
  function Sh([string]$c) {
    if ($format -eq 'claude') { [ordered]@{ session_id = 'test'; cwd = '.'; hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'; tool_input = @{ command = $c } } }
    else { [ordered]@{ sessionId = 'test'; timestamp = 0; cwd = '.'; toolName = 'powershell'; toolArgs = @{ command = $c } } }
  }
  function Ed([string]$t, [string]$p) {
    if ($format -eq 'claude') {
      $ct = switch ($t) { 'view' { 'Read' } 'create' { 'Write' } default { 'Edit' } }
      [ordered]@{ session_id = 'test'; cwd = '.'; hook_event_name = 'PreToolUse'; tool_name = $ct; tool_input = @{ file_path = $p } }
    } else { [ordered]@{ sessionId = 'test'; timestamp = 0; cwd = '.'; toolName = $t; toolArgs = @{ path = $p } } }
  }

  # guard cases from hook-cases.txt (core + repo type + other layers), in both payload shapes
  foreach ($format in 'copilot', 'claude') {
  foreach ($line in Get-Content scripts/factory/hook-cases.txt) {
    if ($line -match '^\s*(#|$)') { continue }
    if ($line -match '^@checkout\s+(.+)$') {
      $b = $Matches[1].Trim(); if ($b -eq '-') { $b = $agentBranch }
      git checkout -q $b; continue
    }
    if ($line -match '^@worktree\s+(.+)$') {
      $b = $Matches[1].Trim(); $worktree = ".agent-work/wt-$($b.Replace('/', '-'))"
      if (-not (Test-Path -LiteralPath $worktree)) {
        git rev-parse -q --verify "refs/heads/$b" *> $null
        if ($LASTEXITCODE -ne 0) { git branch -q $b }
        git worktree add -q $worktree $b
      }
      continue
    }
    if ($line -notmatch '^\s*(allow|deny)\s+([a-z]+)\s+(.*?)\s*::\s(.*)$') { $global:fail++; Write-Output "FAIL: bad case line: $line"; continue }
    $want = $Matches[1]; $kind = $Matches[2]; $desc = $Matches[3]
    $arg = $Matches[4].Replace('{branch}', $agentBranch).Replace('{worktree}', [string]$worktree).Replace('\n', "`n")
    if ($kind -eq 'sh') { Expect $want "$desc [$format]" (Sh $arg) } else { Expect $want "$desc [$format]" (Ed $kind $arg) }
  }
  git checkout -q $agentBranch
  }
  $format = 'copilot'

  # payload shapes
  Expect 'deny' 'apply_patch hook' ([ordered]@{ sessionId = 'test'; toolName = 'apply_patch'; toolArgs = @{ input = "*** Begin Patch`n*** Update File: .github/hooks/factory.json`n@@" } })
  Expect 'deny' 'string toolArgs' ([ordered]@{ sessionId = 'test'; toolName = 'powershell'; toolArgs = '{"command":"sudo ls"}' })
  Expect 'deny' 'backslash path' (Ed 'edit' '.github\hooks\factory.json')
  $r = Invoke-Hook 'guard.ps1' '{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"sudo ls"}}'
  if ($r.rc -eq 2 -and ($r.out | ConvertFrom-Json).hookSpecificOutput.permissionDecision -eq 'deny') { $global:pass++ } else { $global:fail++; Write-Output "FAIL: claude deny must exit 2 with hookSpecificOutput (rc=$($r.rc))" }
  Expect 'deny' 'malformed payload' 'not json'

  # stop gate
  $stopJson = '{"sessionId":"test","stop_hook_active":false}'
  function Stop-Decision { $r = Invoke-Hook 'stop-gate.ps1' $stopJson; if ($r.out) { return ($r.out | ConvertFrom-Json).decision } else { return '' } }
  if ((Stop-Decision) -eq '') { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: stop gate should pass with no changes' }
  Set-Content new.txt 'x'
  if ((Stop-Decision) -eq 'block') { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: stop gate should block unverified changes' }
  (Get-Content scripts/factory/commands.env) -replace '^ALLOW_NO_CHECKS=0', 'ALLOW_NO_CHECKS=1' | Set-Content scripts/factory/commands.env
  & pwsh -NoProfile -File scripts/factory/check.ps1 | Out-Null
  if ((Stop-Decision) -eq '') { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: stop gate should pass after check.ps1' }
  Add-Content new.txt 'y'
  if ((Stop-Decision) -eq 'block') { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: stop gate should block after a new edit' }

  # logging
  $folders = @(Get-ChildItem '.agent-logs' -Directory -Filter '*Z-test')
  $log = if ($folders.Count -eq 1) { Join-Path $folders[0].FullName 'test.jsonl' } else { '' }
  $valid = $log -and (Test-Path $log) -and ((Get-Item $log).Length -gt 0) -and @(Get-Content $log | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json | Out-Null; $true } catch { $false } }) -notcontains $false
  if ($valid -and $folders[0].Name -match '^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-test$') { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: expected one UTC-timestamped session folder with a valid test.jsonl' }
  $linesBefore = if ($log -and (Test-Path $log)) { @(Get-Content $log).Count } else { 0 }
  Invoke-Hook 'log.ps1' '{"sessionId":"test","toolName":"bash","toolArgs":{"command":"echo ghp_abcdefghijklmnopqrstuvwxyz0123"}}' @('postToolUse') | Out-Null
  $folders = @(Get-ChildItem '.agent-logs' -Directory -Filter '*Z-test')
  $log = if ($folders.Count -eq 1) { Join-Path $folders[0].FullName 'test.jsonl' } else { '' }
  if ($log -and (Test-Path $log) -and (@(Get-Content $log).Count -gt $linesBefore)) { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: same-session event should append to the existing folder' }
  if ($log -and (Test-Path $log) -and -not (Select-String -Path $log -SimpleMatch 'ghp_abcdefghij' -Quiet)) { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: token not redacted' }
  Invoke-Hook 'log.ps1' '{"sessionId":"other","toolName":"bash","toolArgs":{"command":"true"}}' @('postToolUse') | Out-Null
  $others = @(Get-ChildItem '.agent-logs' -Directory -Filter '*Z-other')
  if ($others.Count -eq 1 -and (Test-Path (Join-Path $others[0].FullName 'other.jsonl')) -and ((Get-Item (Join-Path $others[0].FullName 'other.jsonl')).Length -gt 0)) { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: a different session should get its own folder' }
  $flat = @(Get-ChildItem '.agent-logs' -File -Filter '*.jsonl' | Where-Object { $_.Name -ne 'index.jsonl' })
  if ($flat.Count -eq 0 -and -not (Test-Path '.agent-logs/test.jsonl')) { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: no flat session .jsonl should exist directly under .agent-logs' }
  $stray = @(Get-ChildItem '.agent-logs' -Directory | ForEach-Object { Get-ChildItem $_.FullName -File -Filter 'index.jsonl' })
  if ($stray.Count -eq 0) { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: index.jsonl must stay directly under .agent-logs' }
  Invoke-Hook 'log.ps1' '{"sessionId":"test","source":"startup"}' @('sessionStart') | Out-Null
  $idxOk = (Test-Path '.agent-logs/index.jsonl') -and ((Get-Item '.agent-logs/index.jsonl').Length -gt 0) -and @(Get-Content '.agent-logs/index.jsonl' | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json | Out-Null; $true } catch { $false } }) -notcontains $false
  if ($idxOk) { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: sessionStart should write valid JSONL to .agent-logs/index.jsonl' }
  $stray = @(Get-ChildItem '.agent-logs' -Directory | ForEach-Object { Get-ChildItem $_.FullName -File -Filter 'index.jsonl' })
  if ($stray.Count -eq 0) { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: index.jsonl must not be written inside a session folder' }
  foreach ($f in 'deny-paths.txt', 'deny-commands.txt') {
    if ((Get-FileHash ".github/hooks/policy/$f").Hash -eq (Get-FileHash (Join-Path $src ".github/hooks/policy/$f")).Hash) { $global:pass++ } else { $global:fail++; Write-Output "FAIL: $f differs from source" }
  }
} finally {
  Set-Location -LiteralPath $src
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
Write-Output "hooks self-test (PowerShell): $global:pass passed, $global:fail failed"
exit ([int]($global:fail -ne 0))
