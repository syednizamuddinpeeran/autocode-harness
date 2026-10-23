# Self-test for template/os/windows/scripts/factory/migrate-paths.ps1 (twin of tests/migrate-paths.sh).
# Runs in throwaway git repos under the temp folder. Run with: pwsh -NoProfile -File tests/migrate-paths.ps1
#   (a) old flat drafts, issue work and session logs move to the stamped names; the rest stays; each move printed
#   (b) a pre-existing destination refuses the run: tree byte-identical, nothing overwritten, no .layout
#   (c) a changed DRAFTS_DIR / WORK_DIR in paths.env moves stamped folders from the recorded location;
#       a new location inside the old one is refused with nothing moved
#   (d) a second run on a migrated tree exits 0, moves nothing and leaves .agent-work/.layout unchanged
#   parity (AC1): when bash is on PATH, the same fixture through the .sh and the .ps1 gives the same tree and moves
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$coreSrc = Join-Path $root 'template/core/scripts/factory'
$winSrc = Join-Path $root 'template/os/windows/scripts/factory'
$script:fail = 0
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('migrate-paths-ps-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$T1 = [datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
$S1 = '2026-01-02T03-04-05Z'
$S2 = '2026-02-03T04-05-06Z'

function Check([string]$Desc, $Want, $Got) {
  if ([string]$Want -ceq [string]$Got) {
    Write-Output "ok   $Desc"
  } else {
    Write-Output "FAIL $Desc (want $Want, got $Got)"
    $script:fail = 1
  }
}

function Yn([bool]$Cond) { if ($Cond) { 'yes' } else { 'no' } }

function Write-File([string]$Path, [string]$Text) {
  [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
  [IO.File]::WriteAllText($Path, $Text)
}

function Read-Text([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) { return [IO.File]::ReadAllText($Path) }
  return '<missing>'
}

function Set-Mtime([string]$Path, [datetime]$When) {
  (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc = $When
}

function Copy-Factory([string]$Repo) {
  $dst = "$Repo/scripts/factory"
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  foreach ($src in @($coreSrc, $winSrc)) {
    Get-ChildItem -LiteralPath $src | Copy-Item -Destination $dst -Recurse -Force
  }
}

function New-Repo([string]$Name) { # throwaway repo with the factory scripts and the old flat layout
  $r = "$tmp/$Name"
  New-Item -ItemType Directory -Force -Path "$r/scripts" | Out-Null
  & git -C $r init -q -b main | Out-Null
  Copy-Factory $r
  Write-File "$r/.agent-work/drafts/alpha.md" 'alpha'
  Write-File "$r/.agent-work/issue-7/brief.md" 'brief'
  Write-File "$r/.agent-work/issue-7/plan.md" 'plan'
  Write-File "$r/.agent-work/drafts/$S2-beta/draft.md" 'beta'
  Write-File "$r/.agent-work/breakdowns/b.md" 'keep'
  Write-File "$r/.agent-work/harness/policy.txt" 'keep'
  Write-File "$r/.agent-logs/sess1.jsonl" '{"event":"start"}'
  Write-File "$r/.agent-logs/index.jsonl" '{"session":"x"}'
  Write-File "$r/.agent-logs/batch/issue-7.log" 'log'
  Set-Mtime "$r/.agent-work/drafts/alpha.md" $T1
  Set-Mtime "$r/.agent-work/issue-7/brief.md" $T1
  Set-Mtime "$r/.agent-work/issue-7/plan.md" $T1
  Set-Mtime "$r/.agent-work/issue-7" $T1
  Set-Mtime "$r/.agent-logs/sess1.jsonl" $T1
  return $r
}

function Invoke-Migrate([string]$Repo) { # runs the .ps1 in the repo; returns Out (merged output) and Rc (exit code)
  Push-Location -LiteralPath $Repo
  try {
    $out = (& pwsh -NoProfile -File 'scripts/factory/migrate-paths.ps1' 2>&1 | Out-String)
    $rc = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  return [pscustomobject]@{ Out = $out; Rc = $rc }
}

function Invoke-MigrateBash([string]$Repo) { # same fixture through the reference bash script
  Push-Location -LiteralPath $Repo
  try {
    $out = (& bash scripts/factory/migrate-paths.sh 2>&1 | Out-String)
    $rc = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  return [pscustomobject]@{ Out = $out; Rc = $rc }
}

function Get-Manifest([string]$Repo, [string]$SkipPrefix = '.git/') {
  # every path and every file's SHA-256, so any change shows; .git is never part of it
  $lines = New-Object System.Collections.Generic.List[string]
  Get-ChildItem -LiteralPath $Repo -Recurse -Force | ForEach-Object {
    $rel = $_.FullName.Substring($Repo.Length + 1).Replace('\', '/')
    if ($rel -eq '.git' -or $rel.StartsWith('.git/') -or ($SkipPrefix -and $rel.StartsWith($SkipPrefix))) { return }
    if ($_.PSIsContainer) {
      $lines.Add("d $rel")
    } else {
      $lines.Add("f $rel " + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)
    }
  }
  $arr = [string[]]$lines.ToArray()
  [Array]::Sort($arr, [StringComparer]::Ordinal)
  return ($arr -join "`n")
}

function Get-MoveLines([string]$Out) { # the "from -> to" lines, sorted, so order does not matter
  $moves = [string[]]@($Out -split "`r?`n" | Where-Object { $_.Contains(' -> ') })
  [Array]::Sort($moves, [StringComparer]::Ordinal)
  return ($moves -join "`n")
}

function Set-PathsEnv([string]$Repo, [string]$Key, [string]$Value) {
  $p = "$Repo/scripts/factory/paths.env"
  $text = [IO.File]::ReadAllText($p)
  $updated = [regex]::Replace($text, "(?m)^$Key=.*$", "$Key=$Value")
  [IO.File]::WriteAllText($p, $updated)
}

# (a) flat layout moves to the timestamped layout; everything else stays
$a = New-Repo 'a'
$ra = Invoke-Migrate $a
Check 'a: exit 0' 0 $ra.Rc
Check 'a: flat draft moved' 'yes' (Yn (Test-Path -LiteralPath "$a/.agent-work/drafts/$S1-alpha/draft.md" -PathType Leaf))
Check 'a: flat draft content kept' 'alpha' (Read-Text "$a/.agent-work/drafts/$S1-alpha/draft.md")
Check 'a: flat draft gone' 'no' (Yn (Test-Path -LiteralPath "$a/.agent-work/drafts/alpha.md"))
Check 'a: flat issue work moved' 'brief' (Read-Text "$a/.agent-work/$S1-issue-7/brief.md")
Check 'a: flat issue folder gone' 'no' (Yn (Test-Path -LiteralPath "$a/.agent-work/issue-7"))
Check 'a: session log moved into its folder' 'yes' (Yn (Test-Path -LiteralPath "$a/.agent-logs/$S1-sess1/sess1.jsonl" -PathType Leaf))
Check 'a: flat session log gone' 'no' (Yn (Test-Path -LiteralPath "$a/.agent-logs/sess1.jsonl"))
Check 'a: index.jsonl stays' 'yes' (Yn (Test-Path -LiteralPath "$a/.agent-logs/index.jsonl" -PathType Leaf))
Check 'a: batch logs stay' 'yes' (Yn (Test-Path -LiteralPath "$a/.agent-logs/batch/issue-7.log" -PathType Leaf))
Check 'a: breakdowns and harness untouched' 'keep:keep' ((Read-Text "$a/.agent-work/breakdowns/b.md") + ':' + (Read-Text "$a/.agent-work/harness/policy.txt"))
Check 'a: stamped draft untouched' 'beta' (Read-Text "$a/.agent-work/drafts/$S2-beta/draft.md")
Check 'a: output lists draft move' 'yes' (Yn ($ra.Out.Contains(".agent-work/drafts/alpha.md -> .agent-work/drafts/$S1-alpha/draft.md")))
Check 'a: output lists issue move' 'yes' (Yn ($ra.Out.Contains(".agent-work/issue-7 -> .agent-work/$S1-issue-7")))
Check 'a: output lists session move' 'yes' (Yn ($ra.Out.Contains(".agent-logs/sess1.jsonl -> .agent-logs/$S1-sess1/sess1.jsonl")))
Check 'a: layout is LF and records the applied locations' "DRAFTS_DIR=.agent-work/drafts`nWORK_DIR=.agent-work`n" (Read-Text "$a/.agent-work/.layout")

# (d) rerun on the migrated tree changes nothing
$mA = Get-Manifest $a
$rd = Invoke-Migrate $a
Check 'd: rerun exit 0' 0 $rd.Rc
Check 'd: rerun changes nothing' $mA (Get-Manifest $a)
Check 'd: rerun prints no moves' 0 $((Get-MoveLines $rd.Out).Length)

# (b) a pre-existing destination refuses the whole run
$b = New-Repo 'b'
Write-File "$b/.agent-work/drafts/$S1-alpha/draft.md" 'keep'
$mB = Get-Manifest $b
$rb = Invoke-Migrate $b
Check 'b: exit non-zero' 'yes' (Yn ($rb.Rc -ne 0))
Check 'b: tree byte-identical' $mB (Get-Manifest $b)
Check 'b: existing draft not overwritten' 'keep' (Read-Text "$b/.agent-work/drafts/$S1-alpha/draft.md")
Check 'b: no layout written' 'no' (Yn (Test-Path -LiteralPath "$b/.agent-work/.layout"))

# (c) changed locations in paths.env move stamped folders from the recorded location
$c = New-Repo 'c'
$rc0 = Invoke-Migrate $c
Check 'c: first run exit 0' 0 $rc0.Rc
Set-PathsEnv $c 'DRAFTS_DIR' 'elsewhere/drafts'
$rc1 = Invoke-Migrate $c
Check 'c: DRAFTS_DIR change exit 0' 0 $rc1.Rc
Check 'c: stamped draft moved to new DRAFTS_DIR' 'yes' (Yn (Test-Path -LiteralPath "$c/elsewhere/drafts/$S1-alpha/draft.md" -PathType Leaf))
Check 'c: old draft folder gone' 'no' (Yn (Test-Path -LiteralPath "$c/.agent-work/drafts/$S1-alpha"))
Check 'c: issue work stays while WORK_DIR is unchanged' 'yes' (Yn (Test-Path -LiteralPath "$c/.agent-work/$S1-issue-7/brief.md" -PathType Leaf))
Check 'c: layout records new DRAFTS_DIR' 'yes' (Yn ((Read-Text "$c/.agent-work/.layout").Contains("DRAFTS_DIR=elsewhere/drafts`n")))
Set-PathsEnv $c 'WORK_DIR' 'elsewhere/work'
$rc2 = Invoke-Migrate $c
Check 'c: WORK_DIR change exit 0' 0 $rc2.Rc
Check 'c: issue work moved to new WORK_DIR' 'yes' (Yn (Test-Path -LiteralPath "$c/elsewhere/work/$S1-issue-7/brief.md" -PathType Leaf))
New-Item -ItemType Directory -Force -Path "$c/elsewhere/drafts/$S2-delta" | Out-Null
Set-PathsEnv $c 'DRAFTS_DIR' 'elsewhere/drafts/inner'
$mC = Get-Manifest $c
$rc3 = Invoke-Migrate $c
Check 'c: nested new location refused' 'yes' (Yn ($rc3.Rc -ne 0))
Check 'c: nested refusal moves nothing' $mC (Get-Manifest $c)

# parity (AC1): the same fixture through bash and through the .ps1 gives the same tree and the same moves
if ($null -eq (Get-Command bash -ErrorAction SilentlyContinue)) {
  Write-Output 'skip parity: bash is not on PATH'
} else {
  $pb = New-Repo 'parity-bash'
  $pp = New-Repo 'parity-ps'
  $ob = Invoke-MigrateBash $pb
  $op = Invoke-Migrate $pp
  Check 'parity: both exit 0' '0:0' "$($ob.Rc):$($op.Rc)"
  Check 'parity: same tree (scripts/ excluded, it differs by design)' (Get-Manifest $pb 'scripts/') (Get-Manifest $pp 'scripts/')
  Check 'parity: same sorted moves' (Get-MoveLines $ob.Out) (Get-MoveLines $op.Out)
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit $script:fail
