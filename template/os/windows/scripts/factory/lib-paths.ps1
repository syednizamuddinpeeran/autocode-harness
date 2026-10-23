# Path helper. Dot-source it: . scripts/factory/lib-paths.ps1
#   New-Folder -Kind <drafts|work> -Slug <slug>
# prints <location>/<YYYY-MM-DDTHH-MM-SSZ>-<slug>/ (UTC stamp), where the location comes from paths.env.
#   Get-ReusableFolder -Slug <slug>
# prints the newest existing <WORK_DIR>/<stamp>-<slug>/, else creates and prints a new one like New-Folder -Kind work.
#   Find-Draft -Value <value>
# prints the <DRAFTS_DIR>/<folder>/ whose created.txt has number=<value> or task=<value>; nothing if none.
# Twin of lib-paths.sh: same paths.env, same result. -At is only a test seam for a fixed time.
$script:PathsDir = $PSScriptRoot

function Read-PathsEnv([string]$Path) {
  $h = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      $key = $Matches[1]
      $v = $Matches[2].Trim()
      if ($v -match '^"(.*)"\s*(#.*)?$') { $v = $Matches[1] }
      elseif ($v -match "^'(.*)'\s*(#.*)?$") { $v = $Matches[1] }
      else { $v = ($v -replace '\s+#.*$', '') }
      $h[$key] = $v
    }
  }
  return $h
}

function New-Folder {
  param(
    [string]$Kind,
    [string]$Slug,
    [datetime]$At = [datetime]::UtcNow
  )
  $cfg = Read-PathsEnv (Join-Path $script:PathsDir 'paths.env')
  switch ($Kind) {
    'drafts' { $loc = $cfg['DRAFTS_DIR'] }
    'work' { $loc = $cfg['WORK_DIR'] }
    default { throw "New-Folder: -Kind must be 'drafts' or 'work'" }
  }
  if ([string]::IsNullOrEmpty($Slug)) { throw 'New-Folder: slug required' }
  $stamp = $At.ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss', [cultureinfo]::InvariantCulture) + 'Z'
  # Match bash ${loc%/}: drop one trailing slash.
  if ($loc.EndsWith('/')) { $loc = $loc.Substring(0, $loc.Length - 1) }
  return "$loc/$stamp-$Slug/"
}

function Get-ReusableFolder {
  param(
    [string]$Slug,
    [datetime]$At = [datetime]::UtcNow
  )
  if ([string]::IsNullOrEmpty($Slug)) { throw 'Get-ReusableFolder: slug required' }
  $cfg = Read-PathsEnv (Join-Path $script:PathsDir 'paths.env')
  $loc = $cfg['WORK_DIR']
  # Match bash ${WORK_DIR%/}: drop one trailing slash.
  if ($loc.EndsWith('/')) { $loc = $loc.Substring(0, $loc.Length - 1) }
  $pattern = '^.{4}-.{2}-.{2}T.{2}-.{2}-.{2}Z-' + [regex]::Escape($Slug) + '$'
  $best = Get-ChildItem -LiteralPath $loc -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name[0] -ne '.' -and $_.Name -cmatch $pattern } |
    Sort-Object Name |
    Select-Object -Last 1
  if ($best) { return "$loc/$($best.Name)/" }
  $path = New-Folder -Kind work -Slug $Slug -At $At
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  return $path
}

function Find-Draft {
  param([string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { throw 'Find-Draft: value required' }
  $cfg = Read-PathsEnv (Join-Path $script:PathsDir 'paths.env')
  $loc = $cfg['DRAFTS_DIR']
  # Match bash ${DRAFTS_DIR%/}: drop one trailing slash.
  if ($loc.EndsWith('/')) { $loc = $loc.Substring(0, $loc.Length - 1) }
  $dirs = Get-ChildItem -LiteralPath $loc -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name[0] -ne '.' } |
    Sort-Object Name
  foreach ($d in $dirs) {
    $file = Join-Path $d.FullName 'created.txt'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    # Split on LF only, so a CR left on a line stops it matching, as with bash grep -x.
    $text = [System.IO.File]::ReadAllText($file)
    foreach ($line in $text.Split("`n")) {
      if ([string]::Equals($line, "number=$Value", [StringComparison]::Ordinal) -or
          [string]::Equals($line, "task=$Value", [StringComparison]::Ordinal)) {
        return "$loc/$($d.Name)/"
      }
    }
  }
}
