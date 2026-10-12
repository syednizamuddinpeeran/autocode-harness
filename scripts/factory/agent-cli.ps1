# Starts the coding assistant this repo was installed for (ASSISTANT in commands.env) with the
# factory agent. Dot-sourced by run-issue.ps1 / run-task.ps1. PowerShell counterpart of agent-cli.sh.
#
#   Invoke-AgentCli  -Assistant <copilot|claude-code> -Prompt <text> -Deny <shell commands> [-Watch]   # factory; then read $LASTEXITCODE
#   Invoke-AgentChat -Assistant <copilot|claude-code> -Agent <name> -Prompt <text>                    # interactive, e.g. the analyst
#
# The deny list is an extra CLI-level layer; the preToolUse guard hook enforces the full policy.
# Flag names can change between CLI versions: check `copilot help permissions` / `claude --help`.
# Credentials an agent must never inherit (FORBIDDEN_ENV in commands.env, e.g. set by -Cloud aws).
function Test-AgentPreflight([string]$ForbiddenEnv) {
  foreach ($v in @($ForbiddenEnv -split '\s+' | Where-Object { $_ })) {
    if ([Environment]::GetEnvironmentVariable($v)) {
      throw "Refusing to start the agent: $v is set. Agents must not inherit cloud credentials; unset it (or start from a clean shell) and run again."
    }
  }
  if ($ForbiddenEnv -and (Test-Path (Join-Path $HOME '.aws/credentials'))) {
    [Console]::Error.WriteLine("Note: $(Join-Path $HOME '.aws/credentials') exists. Make sure the CLI sandbox denies ~/.aws (docs/sandboxing.md).")
  }
}

# Interactive session with a non-factory agent (e.g. the analyst used by new-draft).
function Invoke-AgentChat([string]$Assistant, [string]$Agent, [string]$Prompt, [string]$ForbiddenEnv = '') {
  if (-not $Assistant) { $Assistant = 'copilot' }
  Test-AgentPreflight $ForbiddenEnv
  switch ($Assistant) {
    'copilot' {
      if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) { throw 'Missing: copilot' }
      & copilot --agent $Agent -i $Prompt
    }
    'claude-code' {
      if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw 'Missing: claude' }
      & claude --agent $Agent $Prompt
    }
    default { throw "Unknown ASSISTANT in commands.env: $Assistant" }
  }
}

function Invoke-AgentCli([string]$Assistant, [string]$Prompt, [string[]]$Deny, [switch]$Watch, [string]$ForbiddenEnv = '') {
  if (-not $Assistant) { $Assistant = 'copilot' }
  Test-AgentPreflight $ForbiddenEnv
  switch ($Assistant) {
    'copilot' {
      if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) { throw 'Missing: copilot' }
      # In prompt mode (-p) the CLI loads repository hooks only for trusted folders. The worktree is
      # new, so opt in explicitly; without this the guard, logging and stop-gate hooks would not run.
      $env:GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS = 'true'
      $flags = @(foreach ($c in $Deny) { '--deny-tool'; "shell($c)" })
      $extra = if ($env:COPILOT_EXTRA_FLAGS) { @($env:COPILOT_EXTRA_FLAGS -split '\s+' | Where-Object { $_ }) } else { @() }
      if ($Watch) {
        Write-Output 'Starting interactive session. Paste this, then switch to autopilot (Shift+Tab or /autopilot):'
        Write-Output '----'; Write-Output $Prompt; Write-Output '----'
        & copilot --agent factory @flags
      } else {
        & copilot --agent factory -p $Prompt --allow-all-tools @flags @extra
      }
    }
    'claude-code' {
      if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw 'Missing: claude' }
      # claude -p runs the project's .claude/settings.json hooks even in an untrusted folder.
      $flags = @(foreach ($c in $Deny) { "Bash($c *)"; "Bash($c)"; "PowerShell($c *)"; "PowerShell($c)" })
      $extra = if ($env:CLAUDE_EXTRA_FLAGS) { @($env:CLAUDE_EXTRA_FLAGS -split '\s+' | Where-Object { $_ }) } else { @() }
      if ($Watch) {
        Write-Output 'Starting interactive session. Paste this, then pick a permission mode (Shift+Tab):'
        Write-Output '----'; Write-Output $Prompt; Write-Output '----'
        & claude --agent factory --disallowedTools @flags
      } else {
        & claude --agent factory --permission-mode bypassPermissions --disallowedTools @flags @extra -p $Prompt
      }
    }
    default { throw "Unknown ASSISTANT in commands.env: $Assistant" }
  }
}
