# Path helper. Dot-source it: . scripts/factory/lib-paths.ps1
#   New-Folder -Kind <drafts|work> -Slug <slug>
# prints <location>/<YYYY-MM-DDTHH-MM-SSZ>-<slug>/ (UTC stamp), where the location comes from paths.env.
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
