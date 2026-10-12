# Validate a breakdown proposed by the planner. PowerShell counterpart of check-breakdown.sh
# (same checks, output and exit codes).
#   pwsh scripts/factory/check-breakdown.ps1 <breakdown.md> [brief.md] [--split <dir>]
#     exit 0 valid, 4 invalid (reasons on stdout)
. (Join-Path $PSScriptRoot '../../.github/hooks/scripts/common.ps1')
$Limits = Read-FactoryEnvFile (Join-Path $PSScriptRoot 'complexity.env')
$maxItems = [int]($Limits['MAX_SUBITEMS'])

$bd = ''; $brief = ''; $split = ''
for ($a = 0; $a -lt $args.Count; $a++) {
  if ($args[$a] -eq '--split') { $split = $args[++$a] }
  elseif (-not $bd) { $bd = $args[$a] } else { $brief = $args[$a] }
}
if (-not $bd -or -not (Test-Path -LiteralPath $bd -PathType Leaf)) {
  Write-Output 'usage: check-breakdown.ps1 <breakdown.md> [brief.md] [--split <dir>]'; exit 4
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('breakdown-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
try {
  $problems = @()

  # Split into items: each is its title line ("# <title>"), a blank line, then its body.
  $items = @(); $cur = $null
  foreach ($line in Get-Content -LiteralPath $bd) {
    if ($line -match '^## Item ([0-9]+):[ \t]*(.*)$') {
      $cur = [pscustomobject]@{ Num = $Matches[1]; Lines = [System.Collections.Generic.List[string]]::new() }
      $cur.Lines.Add("# $($Matches[2])"); $cur.Lines.Add('')
      $items += $cur; continue
    }
    if ($line -match '^## ') { $cur = $null; continue }
    if ($cur) { $cur.Lines.Add($line) }
  }
  $n = $items.Count
  if ($n -eq 0) { Write-Output "No items found: expected '## Item 1: <title>' sections in $bd"; exit 4 }
  if ($n -gt $maxItems) { $problems += "$n items > MAX_SUBITEMS ${maxItems}: merge or drop items" }

  $deps = @{}; $covered = @()
  for ($i = 1; $i -le $n; $i++) {
    $it = $items[$i - 1]
    $file = Join-Path $work "$i.md"
    [System.IO.File]::WriteAllText($file, (($it.Lines -join "`n") + "`n"))
    if ($it.Num -ne "$i") { $problems += "items must be numbered 1..$n in order (found Item $($it.Num) at position $i)" }
    $title = $it.Lines[0] -replace '^# ', ''
    if (-not $title -or $title.Contains('<')) { $problems += "Item ${i}: needs a title" }
    $out = @(& (Join-Path $PSScriptRoot 'check-ready.ps1') $file)
    if ($LASTEXITCODE -ne 0) { $out | Select-Object -Skip 1 | ForEach-Object { $problems += "Item ${i}: $($_ -replace '^  - ', '')" } }

    $dep = ($it.Lines | Where-Object { $_ -match '^Depends on:' } | Select-Object -First 1)
    $deps[$i] = @()
    if ($null -eq $dep) { $problems += "Item ${i}: missing 'Depends on:' line (write 'none' if independent)" }
    else {
      $dep = ($dep -replace '^Depends on:\s*', '')
      if (-not $dep) { $problems += "Item ${i}: missing 'Depends on:' line (write 'none' if independent)" }
      elseif ($dep -notmatch '^[Nn]one') {
        foreach ($m in [regex]::Matches($dep, '[0-9]+')) {
          $d = [int]$m.Value
          if ($d -lt 1 -or $d -gt $n) { $problems += "Item ${i}: depends on Item $d, which does not exist" }
          elseif ($d -eq $i) { $problems += "Item ${i}: depends on itself" }
          else { $deps[$i] += $d }
        }
      }
    }
    $cov = ($it.Lines | Where-Object { $_ -match '^Covers:' } | Select-Object -First 1)
    $acs = if ($cov) { @([regex]::Matches($cov, 'AC[0-9]+') | ForEach-Object { $_.Value }) } else { @() }
    if (-not $acs) { $problems += "Item ${i}: missing 'Covers: AC<n>, …' line (which parent acceptance criteria it delivers)" }
    $covered += $acs
  }

  # Dependency order (Kahn); leftovers mean a cycle.
  $order = @(); $done = @{}
  for ($round = 0; $round -lt $n; $round++) {
    $progressed = $false
    for ($i = 1; $i -le $n; $i++) {
      if ($done[$i]) { continue }
      if (-not ($deps[$i] | Where-Object { -not $done[$_] })) { $order += $i; $done[$i] = $true; $progressed = $true }
    }
    if (-not $progressed) { break }
  }
  if ($order.Count -ne $n) {
    $left = (1..$n | Where-Object { -not $done[$_] } | ForEach-Object { "$_ " }) -join ''
    $problems += "dependency cycle between items: $left"
  }

  # Parent acceptance criteria coverage.
  if ($brief) {
    if (-not (Test-Path -LiteralPath $brief)) { Write-Output "brief not found: $brief"; exit 4 }
    $parent = @(Get-Content -LiteralPath $brief | Where-Object { $_ -match '^\s*-\s*(AC[0-9]+)' } | ForEach-Object { [regex]::Match($_, 'AC[0-9]+').Value } | Sort-Object -Unique)
    $cov = @($covered | Sort-Object -Unique)
    $missing = ($parent | Where-Object { $cov -notcontains $_ } | ForEach-Object { "$_ " }) -join ''
    $unknown = ($cov | Where-Object { $parent -notcontains $_ } | ForEach-Object { "$_ " }) -join ''
    if ($missing.Trim()) { $problems += "parent acceptance criteria not covered by any item: $missing" }
    if ($unknown.Trim()) { $problems += "items cite acceptance criteria the parent does not have: $unknown" }
  }

  if ($problems.Count -gt 0) {
    Write-Output "Breakdown is not valid ($bd):"
    $problems | ForEach-Object { Write-Output "  - $_" }
    exit 4
  }
  if ($split) {
    New-Item -ItemType Directory -Force -Path $split | Out-Null
    for ($i = 1; $i -le $n; $i++) {
      Copy-Item -LiteralPath (Join-Path $work "$i.md") -Destination (Join-Path $split "$i.md")
      [System.IO.File]::WriteAllText((Join-Path $split "$i.deps"), (($deps[$i] | ForEach-Object { "$_`n" }) -join ''))
    }
    [System.IO.File]::WriteAllText((Join-Path $split 'order'), (($order | ForEach-Object { "$_`n" }) -join ''))
  }
  Write-Output "valid: $n items, order: $($order -join ' ')"
  exit 0
} finally {
  Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
