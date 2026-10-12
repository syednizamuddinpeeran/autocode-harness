# Install the agent factory into an existing git repository (Windows / PowerShell 7+).
# PowerShell counterpart of install.sh; produces the same files for the same options.
#
#   pwsh ./install.ps1 <target-repo> [-Repo github|local] [-Os windows|linux|wsl]
#                      [-Assistant copilot|claude-code] [-Cloud none|aws] [-Force] [-KeepHarness]
#
#   -Repo   repository type                                            [default: github]
#             github  GitHub issue → pull request (cloud agent or local CLI, CI, branch protection)
#             local   task file → reviewed local branch, merged with accept (no remote needed)
#   -Os     where agents run locally                                   [default: windows]
#             windows     adds PowerShell 7 hooks and scripts (*.ps1); bash ones stay for the cloud agent
#             linux, wsl  bash hooks and scripts only
#   -Assistant  coding assistant that runs the agents                  [default: copilot]
#             copilot      GitHub Copilot (cloud agent + Copilot CLI): .github/agents, skills, hooks
#             claude-code  Claude Code (CLI + GitHub Action): .claude/agents, skills, settings.json
#   -Cloud  where the project deploys                                  [default: none]
#             aws   deny AWS credential use and deploys; deploy-from-CI workflow (GitHub repos)
#   -Force  overwrite files that already exist in the target
#   -KeepHarness  the target already has its own agent harness (e.g. this template repo): install
#           the factory but never write .github/hooks/, .github/workflows/, .claude/settings.json,
#           AGENTS.md, CLAUDE.md or the hook self-test (test-hooks, hook-cases.txt), not even with
#           -Force. The template's versions that are new or differ go to .agent-work/harness/
#           for a person to review and merge by hand.
#
# Layers under template/ are applied in order: core → repo/<type> → os/<os> → assistant/<assistant>
# → cloud/<cloud>.
# A later layer's file replaces an earlier one at the same path, except files ending in ".append",
# which are appended to the file of the same name without the suffix. A layer's _repo/<type>/ and
# _os/<os>/ folders are applied right after it, only for that repo type / OS.
param(
  [Parameter(Mandatory, Position = 0)][string]$Target,
  [string]$Repo = 'github',
  [ValidateSet('linux', 'wsl', 'windows')][string]$Os = 'windows',
  [string]$Assistant = 'copilot',
  [string]$Cloud = 'none',
  [switch]$Force,
  [switch]$KeepHarness
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$tpl = Join-Path $src 'template'

if (-not (Test-Path -LiteralPath (Join-Path $Target '.git'))) { throw "$Target is not a git repository" }
$repoDir = Join-Path $tpl "repo/$Repo"
if ($Repo.StartsWith('_') -or -not (Test-Path -LiteralPath $repoDir -PathType Container)) {
  throw "Unknown -Repo: $Repo ($((Get-ChildItem (Join-Path $tpl 'repo') -Directory).Name -join ', '))"
}

$assistantDir = Join-Path $tpl "assistant/$Assistant"
if ($Assistant.StartsWith('_') -or -not (Test-Path -LiteralPath $assistantDir -PathType Container)) {
  throw "Unknown -Assistant: $Assistant ($((Get-ChildItem (Join-Path $tpl 'assistant') -Directory).Name -join ', '))"
}

if ($Cloud -ne 'none' -and ($Cloud.StartsWith('_') -or -not (Test-Path -LiteralPath (Join-Path $tpl "cloud/$Cloud") -PathType Container))) {
  throw "Unknown -Cloud: $Cloud (none, $((Get-ChildItem (Join-Path $tpl 'cloud') -Directory).Name -join ', '))"
}

# Layers in order; missing optional layers (e.g. os/linux) are skipped.
$layers = @()
foreach ($l in 'core', "repo/$Repo", "os/$Os", "assistant/$Assistant", "cloud/$Cloud") {
  if (-not (Test-Path -LiteralPath (Join-Path $tpl $l) -PathType Container)) { continue }
  $layers += $l
  foreach ($sub in "_repo/$Repo", "_os/$Os") {
    if (Test-Path -LiteralPath (Join-Path $tpl "$l/$sub") -PathType Container) { $layers += "$l/$sub" }
  }
}

# Relative file paths (forward slashes) in a layer, skipping its _* sub-layers.
function Get-LayerFiles([string]$Dir) {
  Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | ForEach-Object {
    $rel = [System.IO.Path]::GetRelativePath($Dir, $_.FullName) -replace '\\', '/'
    if ($rel -notmatch '^_') { $rel }
  }
}

# Compose the layers into a staging tree.
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("factory-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
try {
  foreach ($l in $layers) {
    $dir = Join-Path $tpl $l
    foreach ($f in Get-LayerFiles $dir) {
      $from = Join-Path $dir $f
      if ($f.EndsWith('.append')) {
        $t = $f.Substring(0, $f.Length - 7)
        $to = Join-Path $stage $t
        if (-not (Test-Path -LiteralPath $to)) { throw "template/$l/$f has no base file $t" }
        [System.IO.File]::AppendAllText($to, [System.IO.File]::ReadAllText($from))
      } else {
        $to = Join-Path $stage $f
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        Copy-Item -LiteralPath $from -Destination $to -Force
      }
    }
  }

  # The target's own harness, which -KeepHarness never writes.
  $harness = '^(\.github/(hooks|workflows)/|\.claude/settings\.json$|AGENTS\.md$|CLAUDE\.md$|scripts/factory/(test-hooks\.(sh|ps1)|hook-cases\.txt)$)'

  # Copy into the target.
  $kept = 0
  foreach ($f in (Get-LayerFiles $stage | Sort-Object)) {
    $to = Join-Path $Target $f
    if ($KeepHarness -and $f -cmatch $harness) {
      $from = Join-Path $stage $f
      $exists = Test-Path -LiteralPath $to
      if ($exists -and (Get-FileHash -LiteralPath $from).Hash -eq (Get-FileHash -LiteralPath $to).Hash) { continue }
      $state = if ($exists) { 'differs' } else { 'new' }
      $keepTo = Join-Path $Target ".agent-work/harness/$f"
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $keepTo) | Out-Null
      Copy-Item -LiteralPath $from -Destination $keepTo -Force
      Write-Output "kept harness ($state): $f"; $kept++; continue
    }
    if ((Test-Path -LiteralPath $to) -and -not $Force) { Write-Output "skip (exists): $f"; continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath (Join-Path $stage $f) -Destination $to -Force
    Write-Output "added: $f"
  }
} finally {
  Remove-Item -Recurse -Force -LiteralPath $stage -ErrorAction SilentlyContinue
}

$gi = Join-Path $Target '.gitignore'
$existing = if (Test-Path -LiteralPath $gi) { [System.IO.File]::ReadAllText($gi) } else { '' }
$add = ''
if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $add += "`n" }
foreach ($line in '.agent-logs/', '.agent-work/') {
  if (($existing -split "`r?`n") -notcontains $line) { $add += "$line`n" }
}
if ($add.Trim()) { [System.IO.File]::AppendAllText($gi, $add) }

# Keep the bash scripts executable on Linux/macOS. (Hooks call them as "bash x.sh", so the
# executable bit does not matter on the cloud agent or when committed from Windows.)
if (-not $IsWindows) {
  Get-ChildItem (Join-Path $Target '.github/hooks/scripts/*.sh'), (Join-Path $Target 'scripts/factory/*.sh') -ErrorAction SilentlyContinue |
    ForEach-Object { & chmod +x $_.FullName }
}

Write-Output ''
Write-Output "Installed: repo=$Repo os=$Os assistant=$Assistant cloud=$Cloud"
if ($KeepHarness) {
  Write-Output "Kept your harness: $kept template file(s) not installed; they are under $Target/.agent-work/harness/."
  Write-Output "A person reviews them and merges what the factory needs by hand, in particular:"
  Write-Output "  - the stop gate: .github/hooks/scripts/stop-gate.* and its Stop / agentStop hook entry"
  Write-Output "  - the factory's policy lines (protect scripts/factory/check*, commands.env, complexity.env;"
  Write-Output "    deny new-draft / create-issues / run-batch) in .github/hooks/policy/"
  Write-Output "  - the Project section of AGENTS.md, and any workflows you want"
  Write-Output "Then edit $Target/scripts/factory/commands.env and run your own hook tests and scripts/factory/check.*"
} else {
  Write-Output "Next: edit $Target/scripts/factory/commands.env and the Project section of $Target/AGENTS.md,"
  if ($Os -eq 'windows') { Write-Output "then run: cd $Target; pwsh scripts/factory/test-hooks.ps1; pwsh scripts/factory/check.ps1" }
  else { Write-Output "then run: (cd $Target && bash scripts/factory/test-hooks.sh && bash scripts/factory/check.sh)" }
}
