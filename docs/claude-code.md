# Claude Code (`--assistant claude-code`)

The same factory — agents, skills, guard, stop gate, logging, `check.sh` — driven by [Claude Code](https://code.claude.com/docs) instead of GitHub Copilot.

```bash
./install.sh ~/code/my-repo --repo github --assistant claude-code     # or --repo local, --os windows
```

## What changes

| | Copilot (`--assistant copilot`, default) | Claude Code (`--assistant claude-code`) |
|---|---|---|
| Agents | `.github/agents/*.agent.md` | `.claude/agents/*.md` (same bodies; Claude tool names in `tools:`) |
| Skills | `.github/skills/*/SKILL.md` | `.claude/skills/*/SKILL.md` (same files) |
| Hook wiring | `.github/hooks/factory.json` | `.claude/settings.json` → same scripts in `.github/hooks/scripts/` |
| Project instructions | `AGENTS.md` | `AGENTS.md` (Claude Code reads it when there is no `CLAUDE.md`) |
| CLI-level denies | `--deny-tool 'shell(…)'` | `permissions.deny` in `settings.json` + `--disallowedTools` |
| Local run | `copilot --agent factory -p … --allow-all-tools` | `claude --agent factory --permission-mode bypassPermissions -p …` |
| Cloud (GitHub repos) | Copilot cloud agent, `copilot/*` branch, opens the PR | `claude-factory.yml` (anthropics/claude-code-action), `claude/*` branch, posts a link to open the PR |
| Extra write-protected paths | — | `.claude/`, `CLAUDE.md` |

`run-issue.sh` / `run-task.sh` (and the `.ps1` versions) read `ASSISTANT` from `commands.env`, which the installer sets, and start the matching CLI.

## Guard behaviour under Claude Code

Claude Code differs from Copilot in ways that matter for a policy hook ([hooks reference](https://code.claude.com/docs/en/hooks)):

- **Only exit code 2 blocks.** A hook that exits 1, crashes or prints invalid JSON is a *non-blocking* error and the tool call goes ahead. The guard therefore answers Claude-shaped payloads (`tool_name`/`tool_input`) with `hookSpecificOutput.permissionDecision: "deny"`, the reason on stderr, **and exit 2**, and exits 2 on its own errors.
- **`onFailure: "block"`** is set on the `PreToolUse` hook, so a guard that cannot start or times out blocks the call instead of allowing it (Claude Code v2.1.295 or later; older versions ignore the field — keep Claude Code up to date).
- **Hooks load in `-p` mode** even in an untrusted folder, so autonomous runs in a fresh worktree are guarded without extra flags.
- **`bypassPermissions` skips permission prompts, not hooks or deny rules.** The guard and `permissions.deny` still apply.
- **Timeouts:** the hooks set their own (10–20 s); Claude Code's default would be 600 s.
- Tool names covered: `Bash`, `PowerShell` (shell); `Write`, `Edit`, `MultiEdit`, `NotebookEdit` (write); `Read`, `Glob`, `Grep` (read).

`test-hooks.sh` / `test-hooks.ps1` run every case in `hook-cases.txt` in both the Copilot and the Claude payload shape.

### Hooks on native Windows

- **`--os windows`** wires every hook as `pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PROJECT_DIR}/…"` (exec form, with `args`). Install **PowerShell 7** (`winget install Microsoft.PowerShell`) first: with `onFailure: "block"`, a missing `pwsh` blocks every tool call, and Windows PowerShell 5.1 cannot run `guard.ps1`.
- **Never wire a Windows hook as exec form with `"command": "bash"`.** Exec form looks `bash` up on the Windows `PATH`, where `C:\Windows\System32\bash.exe` (the WSL launcher) usually comes before Git Bash. WSL then either times out while starting (`timed out; blocking because onFailure is "block"`) or gets the Windows path with its backslashes stripped (`/bin/bash: E:OneDrive…/guard.sh: No such file or directory`). A bash hook that must also run on Windows uses **shell form** with the path in double quotes, `"command": "bash \"${CLAUDE_PROJECT_DIR}/.github/hooks/scripts/guard.sh\""` (no `args`). Claude Code runs shell form in Git Bash on Windows (where `bash` is Git's own) and `sh -c` on Linux and macOS. This repository's own `.claude/settings.json` does this.
- The bash hooks need **`jq`** on Windows too (`winget install jqlang.jq`, then restart the session). Without it `guard.sh` exits 2 with a message saying so, which blocks every tool call.
- Starting a process is slow on Windows (often 0.5–1 s with antivirus scanning), so the hooks keep the number of processes per call small and the `PreToolUse` timeout leaves room for it.

## GitHub repos: the Claude GitHub Action

`.github/workflows/claude-factory.yml` runs the factory with `anthropics/claude-code-action@v1` when an issue gets the `agent-ready` label (the Agent task form adds it; `create-issue.sh --draft` labels issues `agent-draft` instead, so nothing starts until you review them and add `agent-ready`) or someone with write access comments `@claude`.

One-time setup:
1. Install the Claude GitHub App on the repository (`/install-github-app` in Claude Code, or see the [GitHub Actions docs](https://code.claude.com/docs/en/github-actions)).
2. Add the `ANTHROPIC_API_KEY` repository secret (or `CLAUDE_CODE_OAUTH_TOKEN` and switch the input in the workflow).
3. Uncomment the language runtime in the workflow (keep it in step with `ci.yml`).
4. Branch protection as for Copilot; `claude/*` branches are covered by `guardrails-unchanged`.

Notes:
- The action only acts for users with write access by default; don't enable `allowed_non_write_users`.
- On pull-request events it restores `.claude/` from the base branch, so a PR cannot swap in its own hooks.
- Claude pushes to its `claude/*` branch and posts a link to open the PR; it does not merge.
- If the issue is too big ([breakdown.md](breakdown.md)), Claude posts the proposed breakdown as a comment instead of code; create the sub-issues with `scripts/factory/create-issues.sh --from-issue <N>`.
- The runner has the API key in its environment; the guard denies `printenv`/`env` and token echoes, but treat the workflow like any CI job that runs branch code.

## Sandboxing

Claude Code has its own sandbox ([sandboxing docs](https://code.claude.com/docs/en/sandboxing)); enable it for local runs the same way you would the Copilot CLI sandbox ([sandboxing.md](sandboxing.md)): writes limited to the worktree, no access to `~/.ssh` or `~/.aws`, network limited to what the task needs.

## Mixing assistants

Install one assistant per repository. Copilot CLI also reads `.claude/settings.json` hooks, so a repo with both `.github/hooks/factory.json` and `.claude/settings.json` runs every hook twice under Copilot (double log lines; decisions stay correct).
