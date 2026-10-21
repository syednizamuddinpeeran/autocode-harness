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
  $log = '.agent-logs/test.jsonl'
  $valid = (Test-Path $log) -and @(Get-Content $log | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json | Out-Null; $true } catch { $false } }) -notcontains $false
  if ($valid) { $global:pass++ } else { $global:fail++; Write-Output 'FAIL: log file missing or invalid JSONL' }
  Invoke-Hook 'log.ps1' '{"sessionId":"test","toolName":"bash","toolArgs":{"command":"echo ghp_abcdefghijklmnopqrstuvwxyz0123"}}' @('postToolUse') | Out-Null
  if (Select-String -Path $log -SimpleMatch 'ghp_abcdefghij' -Quiet) { $global:fail++; Write-Output 'FAIL: token not redacted' } else { $global:pass++ }
} finally {
  Set-Location -LiteralPath $src
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
Write-Output "hooks self-test (PowerShell): $global:pass passed, $global:fail failed"
exit ([int]($global:fail -ne 0))
