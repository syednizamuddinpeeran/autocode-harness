# HUMAN-ONLY: create the sub-issues of a breakdown the planner proposed, after you reviewed it.
# PowerShell counterpart of create-issues.sh.
#   pwsh scripts/factory/create-issues.ps1 .agent-work/breakdowns/issue-<N>.md    # from a local run
#   pwsh scripts/factory/create-issues.ps1 -FromPr <PR>       # Copilot cloud agent: draft PR description
#   pwsh scripts/factory/create-issues.ps1 -FromIssue <N>     # Claude GitHub Action: comment on the issue
#   options: -Parent <N> (default: from the breakdown title)   -Yes (no prompt)
# Validates the breakdown (check-breakdown.ps1), shows every item, asks for confirmation, then — with
# your gh credentials — creates the issues in dependency order, adds them to the parent as native
# sub-issues, records native "blocked by" dependencies, and comments the plan on the parent.
param([Parameter(Position = 0)][string]$Breakdown, [int]$FromPr, [int]$FromIssue, [int]$Parent, [switch]$Yes)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Missing: gh' }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('issues-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $bd = Join-Path $tmp 'breakdown.md'; $brief = ''
  # From the title line to the end.
  function Get-Breakdown([string]$Text) {
    $on = $false
    ($Text -split "`r?`n" | Where-Object { if ($_ -match '^# Breakdown of ') { $on = $true }; $on }) -join "`n"
  }

  if ($FromPr) {
    # Copilot cloud agent: the breakdown is the description of its draft PR on a copilot/* branch.
    $pr = gh pr view $FromPr --json body,headRefName,author,url | ConvertFrom-Json
    if (-not ($pr.headRefName -like 'copilot/*' -or $pr.headRefName -like 'agent/*')) {
      [Console]::Error.WriteLine("PR #$FromPr is on '$($pr.headRefName)', not an agent branch (copilot/*, agent/*): refusing."); exit 1
    }
    [System.IO.File]::WriteAllText($bd, (Get-Breakdown $pr.body))
    Write-Output "Source: PR #$FromPr ($($pr.url)) by $($pr.author.login)"
  } elseif ($FromIssue) {
    # Claude GitHub Action: the breakdown is a comment on the issue by the action's bot.
    $comments = (gh issue view $FromIssue --json comments | ConvertFrom-Json).comments
    $c = @($comments | Where-Object { $_.body.Contains('# Breakdown of ') -and $_.author.login -match '^(claude|github-actions)(\[bot\])?$' }) | Select-Object -Last 1
    if (-not $c) { [Console]::Error.WriteLine("No breakdown comment from the Claude action (claude / github-actions bot) on issue #$FromIssue."); exit 1 }
    [System.IO.File]::WriteAllText($bd, (Get-Breakdown $c.body))
    Write-Output "Source: comment by $($c.author.login) on issue #$FromIssue"
    if (-not $Parent) { $Parent = $FromIssue }
  } else {
    if (-not $Breakdown -or -not (Test-Path -LiteralPath $Breakdown -PathType Leaf)) {
      [Console]::Error.WriteLine('usage: create-issues.ps1 <breakdown.md> | -FromPr <N> | -FromIssue <N> [-Parent <N>] [-Yes]'); exit 1
    }
    Copy-Item -LiteralPath $Breakdown -Destination $bd
    $b = $Breakdown -replace '\.md$', '.brief.md'
    if (Test-Path -LiteralPath $b) { $brief = $b }
  }
  if (-not (Get-Content -LiteralPath $bd -Raw)) { [Console]::Error.WriteLine("No '# Breakdown of …' section found."); exit 1 }

  if (-not $Parent) {
    foreach ($l in (Get-Content -LiteralPath $bd -TotalCount 3)) { if ($l -match '^# Breakdown of issue #([0-9]+)') { $Parent = [int]$Matches[1]; break } }
  }
  if (-not $Parent) { [Console]::Error.WriteLine('Parent issue unknown: pass -Parent <N>.'); exit 1 }

  # Validate (with the parent brief when we have it, to check acceptance-criteria coverage).
  $items = Join-Path $tmp 'items'
  $checkArgs = @($bd) + $(if ($brief) { @($brief) } else { @() })
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-breakdown.ps1') @checkArgs --split $items
  if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('Fix the breakdown, then run again.'); exit 4 }
  if (-not $brief) { Write-Output "(No parent brief next to the breakdown: acceptance-criteria coverage was not checked — compare with issue #$Parent yourself.)" }

  $order = @(Get-Content -LiteralPath (Join-Path $items 'order') | Where-Object { $_ })
  Write-Output ''
  Write-Output "──────── Sub-issues of #$Parent (in creation order)"
  foreach ($i in $order) { Write-Output ''; Write-Output "── Item $i"; Get-Content -LiteralPath (Join-Path $items "$i.md") }
  Write-Output '────────'
  if (-not $Yes) {
    if ([Console]::IsInputRedirected) { [Console]::Error.WriteLine('Not a terminal: pass -Yes after reviewing the breakdown.'); exit 1 }
    $ans = Read-Host "Create $($order.Count) sub-issues of #$Parent? [y/N]"
    if ($ans -notin 'y', 'Y') { Write-Output 'Not created.'; exit 0 }
  }

  $num = @{}; $id = @{}; $summary = ''
  foreach ($i in $order) {
    $lines = @(Get-Content -LiteralPath (Join-Path $items "$i.md"))
    $title = $lines[0] -replace '^# ', ''
    $body = Join-Path $tmp "body-$i.md"
    # Body = item without its title; "Item k" references become issue numbers.
    $out = @("Parent: #$Parent")
    foreach ($l in ($lines | Select-Object -Skip 1)) {
      if ($l -match '^Depends on:') { $l = [regex]::Replace($l, 'Item ([0-9]+)(?![0-9])', { param($m) if ($num[[int]$m.Groups[1].Value]) { "#$($num[[int]$m.Groups[1].Value])" } else { $m.Value } }) }
      $out += $l
    }
    [System.IO.File]::WriteAllText($body, (($out -join "`n") + "`n"))
    # Only unblocked items get `agent-ready` (it starts the Claude action): label the others when their
    # blockers are merged (run-batch.ps1 -List shows which are ready).
    $blocked = [bool](Get-Content -LiteralPath (Join-Path $items "$i.deps") | Where-Object { $_ })
    if (-not $blocked) { $url = gh issue create --title $title --body-file $body --label agent-ready 2>$null }
    if ($blocked -or $LASTEXITCODE -ne 0) {
      $url = gh issue create --title $title --body-file $body
      if ($LASTEXITCODE -ne 0) { throw 'gh issue create failed' }
    }
    $num[[int]$i] = ($url -split '/')[-1]
    $id[[int]$i] = gh api "repos/{owner}/{repo}/issues/$($num[[int]$i])" --jq .id
    gh api -X POST "repos/{owner}/{repo}/issues/$Parent/sub_issues" -F "sub_issue_id=$($id[[int]$i])" | Out-Null
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("  (could not add #$($num[[int]$i]) as a sub-issue of #$Parent; link it by hand)") }
    $deps = ''
    foreach ($d in @(Get-Content -LiteralPath (Join-Path $items "$i.deps") | Where-Object { $_ })) {
      $deps += " #$($num[[int]$d])"
      gh api -X POST "repos/{owner}/{repo}/issues/$($num[[int]$i])/dependencies/blocked_by" -F "issue_id=$($id[[int]$d])" | Out-Null
      if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("  (could not record #$($num[[int]$i]) blocked by #$($num[[int]$d]); the body still says 'Depends on')") }
    }
    Write-Output "Created #$($num[[int]$i]): $title$(if ($deps) { "  (blocked by$deps)" })"
    $summary += "- #$($num[[int]$i]) $title$(if ($deps) { " — after$deps" })`n"
  }

  gh issue comment $Parent --body "Broken down into $($order.Count) sub-issues (scripts/factory/create-issues.ps1):`n$summary`nEach runs as its own factory run once the issues it is blocked by are merged." | Out-Null
  Write-Output ''
  Write-Output "Done. Run them locally in dependency order:  pwsh scripts/factory/run-batch.ps1 $Parent [-AutoContinue]"
  Write-Output 'or assign the unblocked ones to the cloud agent. Only unblocked sub-issues got the agent-ready label;'
  Write-Output 'add it to the others when their blockers are merged.'
} finally {
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
