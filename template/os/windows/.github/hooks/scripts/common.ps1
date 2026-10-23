# Shared helpers for factory hooks on Windows (PowerShell 7+). Dot-sourced, not executed.
# PowerShell counterpart of common.sh. Requires: pwsh, git.
Set-StrictMode -Version Latest

function Get-FactoryRoot {
  $r = git rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -eq 0 -and $r) { return ($r | Select-Object -First 1) }
  return (Get-Location).Path
}

function Get-FactoryLogDir {
  $d = if ($env:FACTORY_LOG_DIR) { $env:FACTORY_LOG_DIR } else { Join-Path (Get-FactoryRoot) '.agent-logs' }
  New-Item -ItemType Directory -Force -Path $d -ErrorAction SilentlyContinue | Out-Null
  return $d
}

# Mask common secret shapes before anything touches disk (same patterns as common.sh).
function Protect-FactoryText([string]$Text) {
  $t = $Text
  $t = $t -creplace 'gh[pousr]_[A-Za-z0-9]{20,}', '[REDACTED_GH_TOKEN]'
  $t = $t -creplace 'github_pat_[A-Za-z0-9_]{20,}', '[REDACTED_GH_TOKEN]'
  $t = $t -creplace '(A3T[A-Z0-9]|AKIA|ASIA)[A-Z0-9]{16}', '[REDACTED_AWS_KEY]'
  $t = $t -creplace 'sk-[A-Za-z0-9_-]{20,}', '[REDACTED_API_KEY]'
  $t = $t -creplace '-----BEGIN [A-Z ]*PRIVATE KEY-----[^"]*', '[REDACTED_PRIVATE_KEY]'
  $t = $t -replace '((password|passwd|secret|token|api[_-]?key)[\\"]*\s*[:=]\s*[\\"]*)[^\\",\s]+', '$1[REDACTED]'
  return $t
}

function Limit-FactoryValue($Value) {
  if ($Value -is [string]) {
    if ($Value.Length -gt 4000) { return $Value.Substring(0, 4000) + '…[truncated]' }
    return $Value
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $o = [ordered]@{}
    foreach ($k in $Value.Keys) { $o[$k] = Limit-FactoryValue $Value[$k] }
    return $o
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    return @(foreach ($v in $Value) { Limit-FactoryValue $v })
  }
  return $Value
}

function ConvertFrom-FactoryJson([string]$Json) {
  return ($Json | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Get-FactorySessionId($Payload) {
  $sid = 'unknown-session'
  if ($Payload -is [System.Collections.IDictionary]) {
    foreach ($k in 'sessionId', 'session_id') { if ($Payload.Contains($k) -and $Payload[$k]) { $sid = [string]$Payload[$k]; break } }
  }
  return ($sid -replace '[^A-Za-z0-9._-]', '_')
}

# Write-FactoryLog <event> <payload-json> [extra hashtable]
# Appends one JSON line to <logs>/<UTC-timestamp>Z-<sessionId>/<sessionId>.jsonl (the folder is created
# on the session's first event) and, for session start/end, to <logs>/index.jsonl.
function Write-FactoryLog([string]$EventName, [string]$PayloadJson, [System.Collections.IDictionary]$Extra = @{}) {
  $dir = Get-FactoryLogDir
  $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  $sid = 'unknown-session'
  try {
    $payload = ConvertFrom-FactoryJson $PayloadJson
    $sid = Get-FactorySessionId $payload
    $o = [ordered]@{ ts = $ts; event = $EventName; branch = $env:FACTORY_BRANCH; surface = $env:FACTORY_SURFACE }
    if ($payload -is [System.Collections.IDictionary]) {
      foreach ($k in $payload.Keys) { $o[$k] = Limit-FactoryValue $payload[$k] }
    }
    foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
  } catch {
    $raw = if ($PayloadJson.Length -gt 4000) { $PayloadJson.Substring(0, 4000) } else { $PayloadJson }
    $o = [ordered]@{ ts = $ts; event = $EventName; unparsed = $raw }
  }
  $line = Protect-FactoryText ($o | ConvertTo-Json -Compress -Depth 100)
  $sdir = Get-ChildItem -LiteralPath $dir -Directory -Filter "????-??-??T??-??-??Z-$sid" -ErrorAction SilentlyContinue | Select-Object -First 1
  $sdir = if ($sdir) { $sdir.FullName } else { Join-Path $dir ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss') + "Z-$sid") }
  New-Item -ItemType Directory -Force -Path $sdir -ErrorAction SilentlyContinue | Out-Null
  Add-Content -LiteralPath (Join-Path $sdir "$sid.jsonl") -Value $line -Encoding utf8
  if ($EventName -in 'sessionStart', 'sessionEnd') {
    $idx = [ordered]@{ ts = $o['ts']; event = $EventName; sessionId = $sid; branch = $o['branch']; surface = $o['surface'] }
    foreach ($k in 'reason', 'source') { $idx[$k] = if ($o.Contains($k)) { $o[$k] } else { $null } }
    Add-Content -LiteralPath (Join-Path $dir 'index.jsonl') -Value (Protect-FactoryText ($idx | ConvertTo-Json -Compress)) -Encoding utf8
  }
}

function Set-FactoryContext {
  $b = git branch --show-current 2>$null
  $env:FACTORY_BRANCH = if ($LASTEXITCODE -eq 0 -and $b) { $b } else { 'detached' }
  $env:FACTORY_SURFACE = if ($env:COPILOT_AGENT_PROMPT -or (Test-Path '/workspace/.git')) { 'cloud' } else { 'cli' }
}

# Hash of the working state (HEAD + tracked diff + untracked files). Must match between
# check.ps1 (which writes it) and stop-gate.ps1 (which compares it).
function Get-FactoryStateHash {
  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.AppendLine((git rev-parse HEAD 2>$null | Out-String))
  [void]$sb.AppendLine((git diff HEAD 2>$null | Out-String))
  $untracked = git ls-files --others --exclude-standard 2>$null
  foreach ($f in @($untracked)) {
    if ($f -and (Test-Path -LiteralPath $f -PathType Leaf)) {
      [void]$sb.AppendLine("$((Get-FileHash -LiteralPath $f -Algorithm SHA1).Hash)  $f")
    }
  }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Does the branch differ from base (commits ahead or a dirty tree)?
function Test-FactoryHasChanges {
  $base = if ($env:BASE_BRANCH) { $env:BASE_BRANCH } else { 'main' }
  if (git status --porcelain 2>$null) { return $true }
  $mb = git merge-base HEAD "origin/$base" 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $mb) { $mb = git merge-base HEAD $base 2>$null }
  if ($LASTEXITCODE -ne 0 -or -not $mb) { return $false }
  return ($mb -ne (git rev-parse HEAD 2>$null))
}

# Read KEY="value" lines (commands.env, git-rules.env) into a hashtable. Never executes the file.
function Read-FactoryEnvFile([string]$Path) {
  $h = @{}
  if (Test-Path -LiteralPath $Path) {
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
  }
  return $h
}
