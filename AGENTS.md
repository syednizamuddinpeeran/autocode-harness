# AGENTS.md (this template repository)

This repo *is* the agent-factory template; it is not an installed copy.

- Template files live under `template/` in layers (`core`, `repo/<type>`, `os/<os>`, `assistant/<name>`,
  `cloud/<name>`). `install.sh` / `install.ps1` compose them. Edit the layer, never an installed copy.
  Files ending in `.append` extend the base file.
- `.github/workflows/selftest.yml` is this repo's own CI and is not installed.
- Before pushing run: `bash tests/install-matrix.sh`, `bash tests/installer-parity.sh`,
  `bash tests/launcher-flow.sh`, `bash tests/repo-harness.sh`, `bash tests/check-links.sh`,
  `bash tests/check-assistant-sync.sh`, and `shellcheck --severity=warning --shell=bash` on every `*.sh`.
  With pwsh available also `pwsh -File tests/install-matrix.ps1`.
- Keep `docs/` in step with any behaviour change, and every `.sh` script in step with its `.ps1`.

## This repo's own harness

Work on this repo runs under its own guard, independent of the one `install.sh` installs:
`.github/hooks/` (scripts, `policy/`, `hook-cases.txt`), `.github/hooks/repo-harness.json` (Copilot)
and `.claude/settings.json` (Claude Code). Tool calls are logged to `.agent-logs/` (not committed).

Requirements: `git` and `jq` everywhere. On Windows, Claude Code runs the hooks through Git Bash
(Git for Windows): `.claude/settings.json` uses shell form with a quoted path
(`bash "${CLAUDE_PROJECT_DIR}/…"`), never exec form, which would start WSL's `bash.exe`. It still
needs `jq` (`winget install jqlang.jq`), or the guard blocks every tool call with a message saying
so. Copilot uses the PowerShell 7 hooks (`guard.ps1`, `log.ps1`). Both guards share the same
policy files and are tested by `tests/repo-harness.sh`. See
[docs/claude-code.md](docs/claude-code.md#hooks-on-native-windows).

- Work on a branch (`agent/`, `copilot/`, `claude/`, `ccr-`, `part/`); never push to `main`.
  Changes reach `main` only through a reviewed PR with green CI.
- Never force-push, skip hooks (`--no-verify`), merge PRs into `main`, or change repo settings,
  secrets or rulesets.
- Humans change the harness itself: `.github/hooks/`, `.github/workflows/`, `.claude/settings.json`,
  `CLAUDE.md`, `LICENSE`. If a task needs that, stop and say so in the PR.
- Everything under `template/` stays editable: that is the product.
