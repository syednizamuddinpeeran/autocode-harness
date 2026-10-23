# preToolUse guard for Windows (PowerShell 7+). Same policy files, decisions and output contract
# as guard.sh (Copilot camelCase payloads and Claude Code snake_case payloads; see guard.sh).
# A crash exits 2, which denies the call. A Copilot hook timeout ALLOWS it, so keep this fast.
$ErrorActionPreference = 'Stop'
try {
  . (Join-Path $PSScriptRoot 'common.ps1')

  $root = (Get-FactoryRoot) -replace '\\', '/'
  $policyDir = if ($env:FACTORY_POLICY_DIR) { $env:FACTORY_POLICY_DIR } else { Join-Path $root '.github/hooks/policy' }

  $payloadJson = [Console]::In.ReadToEnd()
  Set-FactoryContext
  $payload = ConvertFrom-FactoryJson $payloadJson
  if ($payload -isnot [System.Collections.IDictionary]) { exit 2 }

  $format = if ($payload.Contains('toolName') -or $payload.Contains('toolArgs')) { 'copilot' }
            elseif ($payload.Contains('tool_name') -or $payload.Contains('tool_input') -or $payload.Contains('hook_event_name')) { 'claude' }
            else { 'copilot' }
  $tool = ''
  foreach ($k in 'toolName', 'tool_name') { if ($payload.Contains($k) -and $payload[$k]) { $tool = [string]$payload[$k]; break } }
  $toolArgs = @{}
  foreach ($k in 'toolArgs', 'tool_input') {
    if ($payload.Contains($k) -and $null -ne $payload[$k]) { $toolArgs = $payload[$k]; break }
  }
  if ($toolArgs -is [string]) {
    try { $toolArgs = ConvertFrom-FactoryJson $toolArgs } catch { $toolArgs = @{ raw = $toolArgs } }
    if ($toolArgs -isnot [System.Collections.IDictionary]) { $toolArgs = @{ raw = [string]$toolArgs } }
  }
  $argsJson = $toolArgs | ConvertTo-Json -Compress -Depth 100
} catch { exit 2 }

function Deny([string]$Reason) {
  try { Write-FactoryLog 'preToolUse' $payloadJson @{ decision = 'deny'; reason = $Reason } } catch { }
  $msg = "Blocked by factory guard: $Reason. Do not retry this action or work around it; choose a safe alternative or record it as a follow-up in the PR or handoff."
  if ($format -eq 'claude') {
    @{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $msg } } | ConvertTo-Json -Compress
    [Console]::Error.WriteLine($msg)
    exit 2
  }
  [ordered]@{ permissionDecision = 'deny'; permissionDecisionReason = $msg } | ConvertTo-Json -Compress
  exit 0
}

function Allow {
  try { Write-FactoryLog 'preToolUse' $payloadJson @{ decision = 'allow' } } catch { }
  exit 0
}

# Regex lines from a policy file, skipping comments/blank lines.
function Get-Patterns([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @(Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch '^\s*(#|$)' })
}

# POSIX classes used in some policy lines → .NET equivalents.
function ConvertTo-NetRegex([string]$Pattern) {
  return ($Pattern -replace '\[\[:space:\]\]', '\s' -replace '\[:space:\]', '\s')
}

# ---------- shell commands ----------
# Words that run their arguments (or set up a program that does): quoted text after them is code.
# Same list as guard.sh (exec_words).
$ExecWords = '(^|[^A-Za-z0-9_])(bash|sh|zsh|dash|ksh|pwsh|powershell|cmd|wsl|eval|exec|source|xargs|env|command|builtin|time|nohup|nice|timeout|watch|start|call|iex|invoke-expression|invoke-command|start-process|start-job|ssh|python[0-9.]*|perl|ruby|node|php|make|alias|editor|visual|pager|browser|foreach|run|-c|-x|git_[a-z_]*)'

# Test-GitOrGhSegments <code view with line breaks>: $true when there is at least one command and
# every command in it starts with git or gh. Commands are split at ; | & ( ) { } and line breaks;
# a >& or &> redirection is not a split. Same rule as starts_git_or_gh in guard.sh.
function Test-GitOrGhSegments([string]$Code) {
  $found = $false
  $t = ($Code -replace '>&', '>') -replace '&>', '>'
  foreach ($line in ($t -split '[;|&(){}\r\n]')) {
    $s = $line.Trim()
    if ($s -eq '') { continue }
    if ($s -notmatch '^(git|gh)(\s|$)') { return $false }
    $found = $true
  }
  return $found
}

# Get-CodeView <command>: the text the deny patterns are matched against first. The rules of
# code_view in guard.sh, with PowerShell escapes: a backtick escapes the next character, and a
# quote in a row ("" or '') is a fallback. The command keeps its line breaks, which end a command.
# Returns View and Fallback (the caller then matches the raw command too). A command that does not
# start with git or gh is a fallback, as is any word in $ExecWords.
function Get-CodeView([string]$Command) {
  $sb = [System.Text.StringBuilder]::new()
  $fallback = $false
  $n = $Command.Length; $i = 0
  while ($i -lt $n) {
    $c = $Command[$i]
    if ($c -eq '`') { [void]$sb.Append($Command.Substring($i, [Math]::Min(2, $n - $i))); $i += 2; continue }
    if ($c -ne "'" -and $c -ne '"') { [void]$sb.Append($c); $i++; continue }
    $j = $i + 1; $closed = $false
    while ($j -lt $n) {
      $d = $Command[$j]
      if ($c -eq '"' -and $d -eq '`') { $j += 2; continue }
      if ($d -eq $c) { $closed = $true; break }
      $j++
    }
    if (-not $closed) { $fallback = $true; [void]$sb.Append($Command.Substring($i)); break }
    $body = $Command.Substring($i + 1, $j - $i - 1)
    if ($j + 1 -lt $n -and $Command[$j + 1] -eq $c) { $fallback = $true }
    if ($body -match '[$`\\]') { [void]$sb.Append($Command.Substring($i, $j - $i + 1)) }
    elseif ($body -match '\s') { [void]$sb.Append('""') }
    else { [void]$sb.Append($body) }
    $i = $j + 1
  }
  $code = $sb.ToString()
  $view = (($code -replace '[\r\n\t]', ' ') -replace ' {2,}', ' ')
  if ($view -match '[$`]|<<|@[''"]' -or $view -match $ExecWords) { $fallback = $true }
  if (-not $fallback -and -not (Test-GitOrGhSegments $code)) { $fallback = $true }
  return @{ View = $view; Fallback = $fallback }
}

function Test-Shell {
  $cmd = ''
  foreach ($k in 'command', 'cmd', 'script', 'input', 'raw') {
    if ($toolArgs.Contains($k) -and $toolArgs[$k]) { $cmd = [string]$toolArgs[$k]; break }
  }
  if (-not $cmd) { $cmd = $argsJson }
  $norm = ($cmd -replace '[\r\n\t]', ' ') -replace ' {2,}', ' '
  $cv = Get-CodeView ($cmd -replace '\r', '')

  foreach ($pat in Get-Patterns (Join-Path $policyDir 'deny-commands.txt')) {
    $rx = ConvertTo-NetRegex $pat
    if ($cv.View -match $rx -or ($cv.Fallback -and $norm -match $rx)) { Deny "command matches denied pattern [$pat]" }
  }

  $rules = Read-FactoryEnvFile (Join-Path $policyDir 'git-rules.env')
  $prefixes = if ($env:FACTORY_BRANCH_PREFIXES) { $env:FACTORY_BRANCH_PREFIXES } elseif ($rules['BRANCH_PREFIXES']) { $rules['BRANCH_PREFIXES'] } else { 'agent/' }
  $branchOnly = [string]$rules['BRANCH_ONLY_GIT']
  $pushCurrentOnly = $rules['PUSH_CURRENT_BRANCH_ONLY'] -eq '1'

  # Branch rules for the git commands the line really runs (see Test-GitRules), from the
  # directory the tool call runs in.
  if (($branchOnly -or $pushCurrentOnly) -and $cmd -match '(^|[^A-Za-z0-9_.-])git') {
    $start = ''
    if ($payload.Contains('cwd') -and $payload['cwd']) { $start = ([string]$payload['cwd']) -replace '\\', '/' }
    if (-not $start -or -not (Test-Path -LiteralPath $start -PathType Container)) { $start = $root }
    Test-GitRules $cmd $start
  }
  Allow
}

# ---------- git branch rules ----------
# Mirrors guard.sh (see the comments there): a small shell tokenizer, just enough to find the git
# commands a command line really runs. Quoted text stays one word, redirections are dropped,
# heredoc bodies and here-strings are skipped, ; && || | & newline ( ) { } end a simple command,
# ( ) also scope a cd, and $( ) is parsed as commands of its own. Escapes follow PowerShell (a
# backtick escapes; "" inside "..." is a quote), the rest is shared with guard.sh.
# Result: $script:Toks, the words of each simple command followed by $TokSep, with $TokOpen /
# $TokClose around subshells.
$TokSep = [string][char]0x1e; $TokOpen = "$TokSep("; $TokClose = "$TokSep)"
$script:Toks = [System.Collections.Generic.List[string]]::new()
$script:S = ''; $script:I = 0; $script:N = 0
$Ordinal = [System.StringComparison]::Ordinal

function New-TokState {
  return @{ word = ''; inword = $false; redir = $false
            w = [System.Collections.Generic.List[string]]::new(); hd = [System.Collections.Generic.List[string]]::new() }
}
function Close-TokWord($st) {
  if ($st.inword) { if ($st.redir) { $st.redir = $false } else { $st.w.Add($st.word) } }
  $st.word = ''; $st.inword = $false
}
function Close-TokCommand($st) {
  Close-TokWord $st; $st.redir = $false
  if ($st.w.Count -gt 0) { $script:Toks.AddRange($st.w); $script:Toks.Add($TokSep) }
  $st.w.Clear()
}
function Get-TokChar([int]$At) { if ($At -lt $script:N) { return [string]$script:S[$At] } else { return '' } }

# Heredoc delimiter after << or <<-: one word, quotes removed. Adds "<strip-tabs><delim>" to hd.
function Read-HeredocDelim($st) {
  $strip = '0'; $d = ''
  if ((Get-TokChar $script:I) -eq '-') { $strip = '1'; $script:I++ }
  while ((Get-TokChar $script:I) -in ' ', "`t") { $script:I++ }
  while ($script:I -lt $script:N) {
    $c = Get-TokChar $script:I
    if ($c -eq "'" -or $c -eq '"') {
      $end = $script:S.IndexOf([char]$c, $script:I + 1); if ($end -lt 0) { $end = $script:N }
      $d += $script:S.Substring($script:I + 1, $end - $script:I - 1); $script:I = $end + 1
    } elseif ($c -eq '\') { $d += (Get-TokChar ($script:I + 1)); $script:I += 2 }
    elseif (" `t`r`n;&|<>()".Contains($c)) { break }
    else { $d += $c; $script:I++ }
  }
  if ($d) { $st.hd.Add("$strip$d") }
}
# At a newline: skip the bodies of the heredocs started on the line just ended.
function Skip-Heredocs($st) {
  foreach ($e in $st.hd) {
    $strip = $e.Substring(0, 1) -eq '1'; $delim = $e.Substring(1)
    while ($script:I -lt $script:N) {
      $nl = $script:S.IndexOf([char]10, $script:I)
      if ($nl -lt 0) { $line = $script:S.Substring($script:I); $script:I = $script:N }
      else { $line = $script:S.Substring($script:I, $nl - $script:I); $script:I = $nl + 1 }
      if ($line.EndsWith("`r", $Ordinal)) { $line = $line.Substring(0, $line.Length - 1) }
      if ($strip) { $line = $line.TrimStart("`t") }
      if ($line -ceq $delim) { break }
    }
  }
  $st.hd.Clear()
}
# Inside "...": PowerShell escapes; $( ) is a command of its own.
function Read-TokDQuote($st) {
  while ($script:I -lt $script:N) {
    $c = Get-TokChar $script:I; $c2 = Get-TokChar ($script:I + 1)
    if ($c -eq '"') {
      if ($c2 -eq '"') { $st.word += '"'; $script:I += 2; continue }
      $script:I++; return
    }
    if ($c -eq '`') { $st.word += $c2; $script:I += 2; continue }
    if ($c -eq '$' -and $c2 -eq '(') { $script:I += 2; $st.word += '$(...)'; Read-Tokens ')'; continue }
    $st.word += $c; $script:I++
  }
}
# Read-Tokens <closer>: parse from $script:I up to the closer (")") or the end of the input.
function Read-Tokens([string]$Closer) {
  $st = New-TokState; $depth = 0
  while ($script:I -lt $script:N) {
    $c = Get-TokChar $script:I; $c2 = Get-TokChar ($script:I + 1)
    if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r") { Close-TokWord $st; $script:I++; continue }
    if ($c -eq "`n") { Close-TokCommand $st; $script:I++; if ($st.hd.Count -gt 0) { Skip-Heredocs $st }; continue }
    if ($c -eq "'") {
      $st.inword = $true
      $end = $script:S.IndexOf([char]"'", $script:I + 1); if ($end -lt 0) { $end = $script:N }
      $st.word += $script:S.Substring($script:I + 1, $end - $script:I - 1); $script:I = $end + 1; continue
    }
    if ($c -eq '"') { $st.inword = $true; $script:I++; Read-TokDQuote $st; continue }
    if ($c -eq '`') {   # escape; before a line break it continues the line
      if ($c2 -eq "`n") { $script:I += 2; continue }
      if ($c2 -eq "`r" -and (Get-TokChar ($script:I + 2)) -eq "`n") { $script:I += 3; continue }
      $st.inword = $true; $st.word += $c2; $script:I += 2; continue
    }
    if ($c -eq '$') {
      $st.inword = $true
      if ($c2 -eq '(') { $script:I += 2; $st.word += '$(...)'; Read-Tokens ')'; continue }
      if ($c2 -eq '{') {
        $end = $script:S.IndexOf([char]'}', $script:I); if ($end -lt 0) { $end = $script:N - 1 }
        $st.word += $script:S.Substring($script:I, $end - $script:I + 1); $script:I = $end + 1; continue
      }
      $st.word += '$'; $script:I++; continue
    }
    if ($c -eq '@' -and -not $st.inword -and ($c2 -eq "'" -or $c2 -eq '"')) {
      # here-string @' … '@ / @" … "@: one word, its body skipped
      $nl = $script:S.IndexOf([char]10, $script:I + 2)
      if ($nl -ge 0 -and $script:S.Substring($script:I + 2, $nl - $script:I - 2).Trim().Length -eq 0) {
        $endm = $script:S.IndexOf("`n$c2@", $script:I + 2, $Ordinal)
        $st.inword = $true; $st.word += "@$c2...$c2@"
        $script:I = if ($endm -lt 0) { $script:N } else { $endm + 3 }
        continue
      }
    }
    if ($c -eq ';') { Close-TokCommand $st; $script:I++; continue }
    if ($c -eq '&') {
      if ($c2 -eq '>') {
        Close-TokWord $st; $script:I += 2; if ((Get-TokChar $script:I) -eq '>') { $script:I++ }
        $st.redir = $true; continue
      }
      Close-TokCommand $st; $script:I++; if ($c2 -eq '&') { $script:I++ }; continue
    }
    if ($c -eq '|') {
      Close-TokCommand $st; $script:I++
      if ((Get-TokChar $script:I) -in '|', '&') { $script:I++ }
      continue
    }
    if ($c -eq '(') { Close-TokCommand $st; $script:Toks.Add($TokOpen); $depth++; $script:I++; continue }
    if ($c -eq ')') {
      Close-TokCommand $st; $script:I++
      if ($depth -gt 0) { $depth--; $script:Toks.Add($TokClose) }
      elseif ($Closer -eq ')') { return }
      else { $script:Toks.Add($TokClose) }
      continue
    }
    if ($c -eq '{') { if ($st.inword) { $st.word += '{' } else { Close-TokCommand $st }; $script:I++; continue }
    if ($c -eq '}') { if ($st.word.Contains('{')) { $st.word += '}' } else { Close-TokCommand $st }; $script:I++; continue }
    if ($c -eq '<' -or $c -eq '>') {
      # a file-descriptor number (2>) or * (*>) belongs to the redirection
      if ($st.inword -and $st.word -match '^([0-9]+|\*)$') { $st.word = ''; $st.inword = $false } else { Close-TokWord $st }
      $three = $script:S.Substring($script:I, [Math]::Min(3, $script:N - $script:I))
      if ($three -eq '<<<') { $script:I += 3; $st.redir = $true; continue }
      if ($three.StartsWith('<<', $Ordinal)) { $script:I += 2; Read-HeredocDelim $st; continue }
      if ($c2 -eq '(') { $script:I++; continue }   # process substitution: parsed as a subshell
      $script:I++
      if ((Get-TokChar $script:I) -in '>', '|') { $script:I++ }
      if ((Get-TokChar $script:I) -eq '&') {
        $script:I++; $from = $script:I
        while ($script:I -lt $script:N -and '0123456789-'.Contains((Get-TokChar $script:I))) { $script:I++ }
        if ($script:I -eq $from) { $st.redir = $true }
      } else { $st.redir = $true }
      continue
    }
    $st.inword = $true; $st.word += $c; $script:I++
  }
  Close-TokCommand $st
}
function Get-ShellTokens([string]$Command) {
  $script:S = $Command; $script:N = $Command.Length; $script:I = 0
  $script:Toks = [System.Collections.Generic.List[string]]::new()
  Read-Tokens ''
}

# The directory a cd / git -C target names, or '' when it cannot be known (variables, globs,
# "cd -", a missing directory). An unknown directory means the repo root.
function Resolve-ShellDir([string]$Base, [string]$Target) {
  $t = $Target -replace '\\', '/'
  if ($t -eq '~') { $t = [string]$HOME } elseif ($t.StartsWith('~/', $Ordinal)) { $t = "$HOME/" + $t.Substring(2) }
  if (-not $t -or $t -eq '-' -or $t.Contains('$') -or $t.Contains('`') -or $t.Contains('*')) { return '' }
  if (-not ($t.StartsWith('/', $Ordinal) -or $t -match '^[A-Za-z]:/')) {
    if (-not $Base) { return '' }
    $t = $Base.TrimEnd('/') + '/' + $t
  }
  if (Test-Path -LiteralPath $t -PathType Container) { return $t } else { return '' }
}
function Get-BranchOf([string]$Dir) {
  if (-not $Dir) { $Dir = $root }
  $b = git -C $Dir branch --show-current 2>$null
  if ($b) { return [string]$b } else { return '' }
}
# A word's file name, lower-cased, without .exe (git.exe → git).
function Get-CmdName([string]$Word) {
  $n = ($Word -split '[\\/]')[-1]
  if ($n.Length -gt 20) { return '' }
  $n = $n.ToLowerInvariant()
  if ($n.EndsWith('.exe', $Ordinal)) { $n = $n.Substring(0, $n.Length - 4) }
  return $n
}

# Deny when a git command in the line breaks the branch rules, judged on the branch of the
# directory it runs in (after cd / pushd / Set-Location / git -C).
function Test-GitRules([string]$Command, [string]$Dir) {
  Get-ShellTokens $Command
  if ($script:Toks.Count -eq 0) { return }
  $toks = @($script:Toks)   # a nested check replaces $script:Toks
  $ctx = @{ dir = $Dir; stack = [System.Collections.Generic.List[string]]::new(); pstack = [System.Collections.Generic.List[string]]::new() }
  $words = [System.Collections.Generic.List[string]]::new()
  foreach ($t in $toks) {
    if ($t -ceq $TokOpen) { $ctx.stack.Add($ctx.dir); continue }
    if ($t -ceq $TokClose) {
      if ($ctx.stack.Count -gt 0) { $ctx.dir = $ctx.stack[$ctx.stack.Count - 1]; $ctx.stack.RemoveAt($ctx.stack.Count - 1) }
      continue
    }
    if ($t -ceq $TokSep) { if ($words.Count -gt 0) { Test-SimpleCommand $ctx $words.ToArray() }; $words.Clear(); continue }
    $words.Add($t)
  }
}
# One simple command, run in $ctx.dir (which a cd changes).
function Test-SimpleCommand($ctx, [string[]]$Words) {
  $n = $Words.Count; $i = 0
  while ($i -lt $n -and ($Words[$i] -cmatch '^[A-Za-z_][A-Za-z0-9_]*=' -or $Words[$i] -cin 'if', 'then', 'else', 'elif', 'do', 'while', 'until', '!', 'time')) { $i++ }
  if ($i -ge $n) { return }
  $name = Get-CmdName $Words[$i]
  if ($name -in 'cd', 'chdir', 'pushd', 'sl', 'set-location', 'push-location') {
    $j = $i + 1; while ($j -lt $n -and $Words[$j] -match '^-.') { $j++ }
    if ($name -in 'pushd', 'push-location') { $ctx.pstack.Add($ctx.dir) }
    $ctx.dir = if ($j -lt $n) { Resolve-ShellDir $ctx.dir $Words[$j] } else { [string]$HOME }
    return
  }
  if ($name -in 'popd', 'pop-location') {
    if ($ctx.pstack.Count -gt 0) { $ctx.dir = $ctx.pstack[$ctx.pstack.Count - 1]; $ctx.pstack.RemoveAt($ctx.pstack.Count - 1) } else { $ctx.dir = '' }
    return
  }
  if ($name -in 'eval', 'iex', 'invoke-expression') { Test-GitRules ($Words[($i + 1)..($n - 1)] -join ' ') $ctx.dir; return }
  for ($j = $i; $j -lt $n; $j++) {
    $name = Get-CmdName $Words[$j]
    if ($name -in 'bash', 'sh', 'zsh', 'dash', 'ksh', 'pwsh', 'powershell') {
      # bash -c '…', sh -lc '…', pwsh -Command '…': check the command text too
      for ($k = $j + 1; $k -lt $n; $k++) {
        if ($Words[$k] -cmatch '^-[A-Za-z]*c$' -or $Words[$k] -match '^-command$') {
          if ($k + 1 -lt $n) { Test-GitRules $Words[$k + 1] $ctx.dir }
          break
        }
      }
      continue
    }
    if ($name -ne 'git') { continue }
    $gdir = $ctx.dir; $k = $j + 1
    while ($k -lt $n) {
      $w = $Words[$k]
      if ($w -ceq '-C') { $gdir = Resolve-ShellDir $gdir $(if ($k + 1 -lt $n) { $Words[$k + 1] } else { '' }); $k += 2 }
      elseif ($w -cin '-c', '--git-dir', '--work-tree', '--namespace', '--config-env') { $k += 2 }
      elseif ($w.StartsWith('-', $Ordinal)) { $k++ }
      else { break }
    }
    $sub = if ($k -lt $n) { $Words[$k] } else { '' }
    # Some git subcommands (push, or commit/merge for local repos) only on agent branches.
    if ($branchOnly -and $sub -cmatch "^($branchOnly)([^A-Za-z0-9_]|$)") {
      $cur = Get-BranchOf $gdir
      $ok = $false
      foreach ($p in ($prefixes -split '\s+' | Where-Object { $_ })) { if ($cur.StartsWith($p, $Ordinal)) { $ok = $true } }
      if (-not $ok) { Deny "git $branchOnly is only allowed on branches starting with: $prefixes (current: $(if ($cur) { $cur } else { 'detached' }))" }
    }
    # Any explicit git push refspec must name the current branch or HEAD.
    if ($pushCurrentOnly -and $sub -ceq 'push') {
      $cur = Get-BranchOf $gdir; $remote = $false
      for ($k = $k + 1; $k -lt $n; $k++) {
        $r = $Words[$k]
        if ($r.StartsWith('-', $Ordinal)) { continue }
        if (-not $remote) { $remote = $true; continue }   # the first word is the remote
        if ($r -cin 'HEAD', $cur, "HEAD:$cur", "${cur}:$cur", "HEAD:refs/heads/$cur") { continue }
        Deny "git push refspec '$r' is not the current branch '$cur'"
      }
    }
    return   # the first git word of a simple command is the command
  }
}

# ---------- file tools ----------
function Get-PathArgs($Node) {
  if ($Node -is [System.Collections.IDictionary]) {
    foreach ($k in $Node.Keys) {
      $v = $Node[$k]
      if ($k -match 'path|file' -and $v -is [string]) { $v }
      elseif ($v -isnot [string]) { Get-PathArgs $v }
    }
  } elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
    foreach ($v in $Node) { Get-PathArgs $v }
  }
}

function Test-Paths([string]$Mode) {
  $paths = @(Get-PathArgs $toolArgs)
  # apply_patch style headers: "*** Update File: path"
  $paths += @([regex]::Matches(($toolArgs | ConvertTo-Json -Depth 100 -Compress), '\*\*\* (Add|Update|Delete) File: ([^\\"]+)') | ForEach-Object { $_.Groups[2].Value })
  $rules = Get-Patterns (Join-Path $policyDir 'deny-paths.txt')
  foreach ($path in $paths) {
    if (-not $path) { continue }
    $p = $path -replace '\\', '/'
    $rel = $p
    if ($rel.StartsWith("$root/", [System.StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($root.Length + 1) }
    if ($rel.StartsWith('/workspace/')) { $rel = $rel.Substring(11) }
    if ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }
    foreach ($rule in $rules) {
      if ($rule.StartsWith('write:')) {
        if ($Mode -ne 'write') { continue }
        $pat = $rule.Substring(6)
      } else { $pat = $rule }
      $pat = ConvertTo-NetRegex $pat
      # Windows paths are case-insensitive, so match case-insensitively (denies more, never less).
      if ($rel -match $pat -or $p -match $pat) { Deny "$Mode access to '$rel' is not allowed [$rule]" }
    }
  }
  Allow
}

try {
  if ($tool -eq 'str_replace_editor' -and $toolArgs.Contains('command') -and $toolArgs['command'] -eq 'view') { $tool = 'view' }
  switch -CaseSensitive ($tool) {
    { $_ -cin 'bash', 'powershell', 'shell', 'Bash', 'PowerShell', 'execute' } { Test-Shell }
    { $_ -cin 'edit', 'create', 'str_replace_editor', 'str_replace', 'apply_patch', 'write', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit' } { Test-Paths 'write' }
    { $_ -cin 'view', 'read', 'Read', 'Glob', 'Grep', 'NotebookRead' } { Test-Paths 'read' }
    default { Allow }
  }
} catch { exit 2 }
