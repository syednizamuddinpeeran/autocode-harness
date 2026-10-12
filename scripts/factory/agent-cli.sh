#!/usr/bin/env bash
# Starts the coding assistant this repo was installed for (ASSISTANT in commands.env).
# Sourced by run-issue.sh / run-task.sh / new-draft.sh.
#
#   agent_cli <auto|--watch> <prompt> <shell command to deny>...     # factory agent; returns the exit code
#   agent_chat <agent> <prompt>                                      # interactive session with another agent
#
# The deny list is an extra CLI-level layer; the preToolUse guard hook enforces the full policy.
# Flag names can change between CLI versions: check `copilot help permissions` / `claude --help`.
# Credentials an agent must never inherit (FORBIDDEN_ENV in commands.env, e.g. set by --cloud aws).
agent_preflight() {
  local v
  for v in ${FORBIDDEN_ENV:-}; do
    if [[ -n "${!v:-}" ]]; then
      echo "Refusing to start the agent: $v is set. Agents must not inherit cloud credentials; unset it" >&2
      echo "(or start from a clean shell) and run again." >&2
      exit 1
    fi
  done
  if [[ -n "${FORBIDDEN_ENV:-}" && -e "$HOME/.aws/credentials" ]]; then
    echo "Note: $HOME/.aws/credentials exists. Make sure the CLI sandbox denies ~/.aws (docs/sandboxing.md)." >&2
  fi
}

agent_chat() {
  local agent="$1" prompt="$2"
  agent_preflight
  case "${ASSISTANT:-copilot}" in
    copilot)
      command -v copilot >/dev/null || { echo "Missing: copilot" >&2; exit 1; }
      copilot --agent "$agent" -i "$prompt"
      ;;
    claude-code)
      command -v claude >/dev/null || { echo "Missing: claude" >&2; exit 1; }
      claude --agent "$agent" "$prompt"
      ;;
    *) echo "Unknown ASSISTANT in commands.env: ${ASSISTANT}" >&2; exit 1 ;;
  esac
}

agent_cli() {
  local mode="$1" prompt="$2" c
  shift 2
  local flags=()
  agent_preflight
  case "${ASSISTANT:-copilot}" in
    copilot)
      command -v copilot >/dev/null || { echo "Missing: copilot" >&2; exit 1; }
      # In prompt mode (-p) the CLI loads repository hooks only for trusted folders. The worktree is
      # new, so opt in explicitly; without this the guard, logging and stop-gate hooks would not run.
      export GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true
      for c in "$@"; do flags+=(--deny-tool "shell($c)"); done
      if [[ "$mode" == "--watch" ]]; then
        echo "Starting interactive session. Paste this, then switch to autopilot (Shift+Tab or /autopilot):"
        echo "----"; echo "$prompt"; echo "----"
        copilot --agent factory "${flags[@]}"; return
      fi
      # shellcheck disable=SC2086  # COPILOT_EXTRA_FLAGS is a list of flags
      copilot --agent factory -p "$prompt" --allow-all-tools "${flags[@]}" ${COPILOT_EXTRA_FLAGS:-}
      ;;
    claude-code)
      command -v claude >/dev/null || { echo "Missing: claude" >&2; exit 1; }
      # claude -p runs the project's .claude/settings.json hooks even in an untrusted folder.
      for c in "$@"; do flags+=("Bash($c *)" "Bash($c)"); done
      if [[ "$mode" == "--watch" ]]; then
        echo "Starting interactive session. Paste this, then pick a permission mode (Shift+Tab):"
        echo "----"; echo "$prompt"; echo "----"
        claude --agent factory --disallowedTools "${flags[@]}"; return
      fi
      # shellcheck disable=SC2086  # CLAUDE_EXTRA_FLAGS is a list of flags
      claude --agent factory --permission-mode bypassPermissions --disallowedTools "${flags[@]}" \
        ${CLAUDE_EXTRA_FLAGS:-} -p "$prompt"
      ;;
    *) echo "Unknown ASSISTANT in commands.env: ${ASSISTANT}" >&2; exit 1 ;;
  esac
}
