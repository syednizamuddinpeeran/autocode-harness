# Moves factory files into the timestamped layout. Run it with no agent session active:
#   pwsh scripts/factory/migrate-paths.ps1
# Twin of migrate-paths.sh (the reference): same move rules, same refusals, same output lines and the
# same .agent-work/.layout. See the bash script's header for the full description.
#
# What moves (each move is printed as "from -> to", paths relative to the repo root, / separators):
#   <old drafts>/<id>.md          -> <DRAFTS_DIR>/<stamp>-<id>/draft.md      old flat draft
#   <old work>/issue-N/           -> <WORK_DIR>/<stamp>-issue-N/            old flat issue work
#   .agent-logs/<session>.jsonl   -> .agent-logs/<stamp>-<session>/<session>.jsonl
#   <old drafts>/<stamp>-<slug>/  -> <DRAFTS_DIR>/<stamp>-<slug>/           DRAFTS_DIR changed
#   <old work>/<stamp>-<slug>/    -> <WORK_DIR>/<stamp>-<slug>/             WORK_DIR changed
# <stamp> is the UTC last-write time of the moved item, YYYY-MM-DDTHH-MM-SSZ. index.jsonl and batch/ stay put.
#
# Safety: every destination is checked before anything moves. If one exists, or a new location is inside
# the old one, nothing moves and the script exits 1. Each move re-checks its destination and is verified
# afterwards (source gone, destination present). .agent-work/.layout is written last.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib-paths.ps1')

function Fail([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 1
}

$root = (& git rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($root)) { Fail 'migrate-paths: not inside a git repository' }
$root = ([string]$root).Trim().Replace('\', '/')
Set-Location -LiteralPath $root

$layoutRel = '.agent-work/.layout'
$layoutPath = "$root/$layoutRel"
$cfg = Read-PathsEnv (Join-Path $PSScriptRoot 'paths.env')
foreach ($key in @('DRAFTS_DIR', 'WORK_DIR')) {
  if (-not $cfg.ContainsKey($key)) { Fail "migrate-paths: paths.env does not set $key" }
}
$oldDrafts = '.agent-work/drafts'
$oldWork = '.agent-work'
if (Test-Path -LiteralPath $layoutPath -PathType Leaf) {
  foreach ($line in [IO.File]::ReadAllLines($layoutPath)) {
    if ($line -match '^([^=]*)=(.*)$') {
      switch ($Matches[1]) {
        'DRAFTS_DIR' { $oldDrafts = $Matches[2] }
        'WORK_DIR' { $oldWork = $Matches[2] }
      }
    }
  }
}

function Get-AbsPath([string]$Path) { # absolute, forward slashes, no trailing slash
  $p = $Path.Replace('\', '/')
  if ($p.EndsWith('/')) { $p = $p.Substring(0, $p.Length - 1) }
  if (-not ($p.StartsWith('/') -or $p -match '^[A-Za-z]:/')) { $p = "$root/$p" }
  return $p
}

function Get-RelPath([string]$Path) { # relative to the repo root when inside it
  $prefix = "$root/"
  if ($Path.StartsWith($prefix, [StringComparison]::Ordinal)) { return $Path.Substring($prefix.Length) }
  return $Path
}

function Get-MtimeStamp([string]$Path) { # UTC last-write time, whole seconds, as YYYY-MM-DDTHH-MM-SSZ
  $t = (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc
  return $t.ToString('yyyy-MM-ddTHH-mm-ss', [cultureinfo]::InvariantCulture) + 'Z'
}

function Test-Exists([string]$Path) { # true for a file, folder or dangling link
  return ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue))
}

function Test-IsLink([string]$Path) { # reparse point (junction or symlink): treated as not data, as bash skips -L
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return ($null -ne $item) -and $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
}

function Get-ChildNames([string]$Dir) { # names directly under Dir, unsorted; empty when Dir is missing
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $Dir | ForEach-Object { $_.Name })
}

function Sort-Ordinal($Values) { # ordinal sort, as LC_ALL=C, so the output order does not depend on the locale
  $arr = [string[]]@($Values | Where-Object { $null -ne $_ })
  [Array]::Sort($arr, [StringComparer]::Ordinal)
  return ,$arr
}

function Test-LocationInside([string]$Old, [string]$New) {
  return ($Old -cne $New) -and $New.StartsWith("$Old/", [StringComparison]::Ordinal)
}

$oldD = Get-AbsPath $oldDrafts
$newD = Get-AbsPath $cfg['DRAFTS_DIR']
$oldW = Get-AbsPath $oldWork
$newW = Get-AbsPath $cfg['WORK_DIR']
$logs = "$root/.agent-logs"
if (Test-LocationInside $oldD $newD) {
  Fail "migrate-paths: refusing, nothing moved: drafts location $(Get-RelPath $newD) is inside the old $(Get-RelPath $oldD)"
}
if (Test-LocationInside $oldW $newW) {
  Fail "migrate-paths: refusing, nothing moved: work location $(Get-RelPath $newW) is inside the old $(Get-RelPath $oldW)"
}

$from = New-Object System.Collections.Generic.List[string]
$to = New-Object System.Collections.Generic.List[string]
function Add-Move([string]$Source, [string]$Destination) {
  $from.Add($Source)
  $to.Add($Destination)
}

# old flat drafts: <old drafts>/<id>.md (dotfiles and non-.md names are not drafts, as the bash glob)
foreach ($name in (Sort-Ordinal (Get-ChildNames $oldD))) {
  if ($name.StartsWith('.') -or -not $name.EndsWith('.md', [StringComparison]::Ordinal)) { continue }
  $f = "$oldD/$name"
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
  $id = $name.Substring(0, $name.Length - 3)
  Add-Move $f "$newD/$(Get-MtimeStamp $f)-$id/draft.md"
}
# old flat issue work: <old work>/issue-N/
foreach ($name in (Sort-Ordinal (Get-ChildNames $oldW))) {
  if ($name -cnotmatch '^issue-[0-9]+$') { continue }
  $d = "$oldW/$name"
  if (-not (Test-Path -LiteralPath $d -PathType Container) -or (Test-IsLink $d)) { continue }
  Add-Move $d "$newW/$(Get-MtimeStamp $d)-$name"
}
# old flat session logs: .agent-logs/<session>.jsonl (index.jsonl stays)
foreach ($name in (Sort-Ordinal (Get-ChildNames $logs))) {
  if ($name.StartsWith('.') -or -not $name.EndsWith('.jsonl', [StringComparison]::Ordinal) -or $name -ceq 'index.jsonl') { continue }
  $f = "$logs/$name"
  if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Test-IsLink $f)) { continue }
  $session = $name.Substring(0, $name.Length - 6)
  Add-Move $f "$logs/$(Get-MtimeStamp $f)-$session/$session.jsonl"
}
# stamped folders in a location that changed in paths.env
function Add-StampedMoves([string]$Old, [string]$New) {
  if ($Old -ceq $New) { return }
  foreach ($name in (Sort-Ordinal (Get-ChildNames $Old))) {
    if ($name -cnotmatch '^.{4}-.{2}-.{2}T.{2}-.{2}-.{2}Z-') { continue }
    $d = "$Old/$name"
    if (-not (Test-Path -LiteralPath $d -PathType Container) -or (Test-IsLink $d)) { continue }
    Add-Move $d "$New/$name"
  }
}
Add-StampedMoves $oldD $newD
Add-StampedMoves $oldW $newW

if ($from.Count -gt 0) {
  # Preflight: every destination must be free and unique, and every source unique, before any move.
  $bad = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $from.Count; $i++) {
    if (Test-Exists $to[$i]) {
      $bad.Add("exists: $(Get-RelPath $to[$i]) (for $(Get-RelPath $from[$i]))")
    }
  }
  $dupFrom = @($from | Group-Object | Where-Object { $_.Count -gt 1 })
  $dupTo = @($to | Group-Object | Where-Object { $_.Count -gt 1 })
  if ($dupFrom.Count -gt 0 -or $dupTo.Count -gt 0) { $bad.Add('two moves share a source or destination') }
  if ($bad.Count -gt 0) {
    [Console]::Error.WriteLine('migrate-paths: refusing, nothing moved:')
    foreach ($line in $bad) { [Console]::Error.WriteLine("  $line") }
    exit 1
  }

  for ($i = 0; $i -lt $from.Count; $i++) {
    $src = $from[$i]
    $dst = $to[$i]
    [IO.Directory]::CreateDirectory($dst.Substring(0, $dst.LastIndexOf('/'))) | Out-Null
    # re-check just before the move: never overwrite, never nest a folder inside an existing one
    if (Test-Exists $dst) {
      Fail "migrate-paths: move failed: $(Get-RelPath $src) -> $(Get-RelPath $dst) (destination appeared); rerun after fixing it"
    }
    try {
      if (Test-Path -LiteralPath $src -PathType Container) {
        [IO.Directory]::Move($src, $dst)
      } else {
        [IO.File]::Move($src, $dst)
      }
    } catch {
      Fail "migrate-paths: move failed: $(Get-RelPath $src) -> $(Get-RelPath $dst); rerun after fixing it"
    }
    if ((Test-Exists $src) -or -not (Test-Exists $dst)) {
      Fail "migrate-paths: move failed: $(Get-RelPath $src) -> $(Get-RelPath $dst); rerun after fixing it"
    }
    Write-Output "$(Get-RelPath $src) -> $(Get-RelPath $dst)"
  }
} else {
  Write-Output 'migrate-paths: nothing to move'
}

# Record the applied locations last, so a rerun after a failure still sees the old ones.
[IO.Directory]::CreateDirectory("$root/.agent-work") | Out-Null
$content = "DRAFTS_DIR=$($cfg['DRAFTS_DIR'])`nWORK_DIR=$($cfg['WORK_DIR'])`n"
$layoutTmp = "$layoutPath.tmp"
[IO.File]::WriteAllText($layoutTmp, $content)
$unchanged = (Test-Path -LiteralPath $layoutPath -PathType Leaf) -and ([IO.File]::ReadAllText($layoutPath) -ceq $content)
if ($unchanged) {
  Remove-Item -LiteralPath $layoutTmp -Force
} else {
  Move-Item -LiteralPath $layoutTmp -Destination $layoutPath -Force
}
