# Installing: choose your combination

One template, four choices (plus `--keep-harness` for repos with their own harness). `install.sh` (bash) and `install.ps1` (PowerShell 7) take the same options and produce the same files.

```bash
./install.sh <target-repo> [--repo github|local] [--os linux|wsl|windows] \
             [--assistant copilot|claude-code] [--cloud none|aws] [--force] [--keep-harness]
```
```powershell
pwsh ./install.ps1 <target-repo> [-Repo github|local] [-Os windows|linux|wsl] `
                   [-Assistant copilot|claude-code] [-Cloud none|aws] [-Force] [-KeepHarness]
```

| Option | Values | Default | Read |
|---|---|---|---|
| Repo type | `github` — issue → PR, cloud agent or local CLI, CI + branch protection<br>`local` — task file → local branch, merged with `accept`; no remote | `github` | [usage-guide.md](usage-guide.md), [local-repo.md](local-repo.md) |
| OS (where agents run locally) | `linux`, `wsl` — bash<br>`windows` — adds PowerShell 7 hooks and scripts | `linux` (`install.sh`), `windows` (`install.ps1`) | [platforms.md](platforms.md) |
| Assistant | `copilot` — GitHub Copilot cloud agent and CLI<br>`claude-code` — Claude Code CLI and GitHub Action | `copilot` | [claude-code.md](claude-code.md) |
| Keep harness | `--keep-harness` / `-KeepHarness` — the target already has its own hooks and policy: install the factory without touching them | off | [below](#repos-that-already-have-their-own-harness---keep-harness) |
| Cloud (where the project deploys) | `none`<br>`aws` — AWS guardrails, credential-free agents, OIDC deploy workflow | `none` | [aws.md](aws.md) |

The target must be a git repository with at least one commit. Existing files are skipped unless you pass `--force` (not with `--keep-harness`: harness files are never written, see [below](#repos-that-already-have-their-own-harness---keep-harness)); the installer appends `.agent-logs/` and `.agent-work/` to `.gitignore`. Re-running with the same options changes nothing.

## What each choice installs

| Choice | Adds or changes |
|---|---|
| always (core) | `.github/hooks/scripts/{guard,log,stop-gate,common}.sh`, `.github/hooks/policy/{deny-commands,deny-paths}.txt`, `scripts/factory/{check,setup,test-hooks,agent-cli}.sh`, `commands.env`, `hook-cases.txt` |
| `--repo github` | `AGENTS.md`, `run-issue.sh`, `ci.yml`, issue form, PR template, `git-rules.env` (push only from `agent/`, `copilot/`, `claude/`), `gh` deny rules |
| `--repo local` | `AGENTS.md`, `run-task.sh`, `accept.sh`, `tasks/_template.md`, `git-rules.env` (commit only on `agent/`), no-push/no-remote/no-`gh` rules, extra write-protected paths |
| `--os windows` | `*.ps1` for every hook and script, PowerShell deny patterns; with `copilot`, `factory.json` gets `powershell` commands; with `claude-code`, `settings.json` calls `pwsh` |
| `--assistant copilot` | `.github/agents/*.agent.md`, `.github/skills/`, `.github/hooks/factory.json`, `copilot-setup-steps.yml` (github) |
| `--assistant claude-code` | `.claude/agents/*.md`, `.claude/skills/`, `.claude/settings.json`, `claude-factory.yml` (github), `.claude/` write-protected |
| `--keep-harness` | Everything above except the harness: `.github/hooks/`, `.github/workflows/`, `.claude/settings.json`, `AGENTS.md`, `CLAUDE.md`, `test-hooks.*` and `hook-cases.txt` are never written, not even with `--force`; the template's versions are held in `.agent-work/harness/` for you to merge |
| `--cloud aws` | AWS deny patterns and paths, `FORBIDDEN_ENV` for AWS credentials, `deploy-aws.yml` (github) |

## After installing

1. Edit `scripts/factory/commands.env` (your build/test commands) and the **Project** section of `AGENTS.md`.
2. Run the self-tests: `bash scripts/factory/test-hooks.sh && bash scripts/factory/check.sh` (Windows: `pwsh scripts/factory/test-hooks.ps1; pwsh scripts/factory/check.ps1`).
3. Commit to the base branch before running any agent.
4. Do the one-time setup for your choices: GitHub settings ([usage-guide.md](usage-guide.md#4-one-time-github-setup)), sandbox ([sandboxing.md](sandboxing.md)), Claude GitHub App ([claude-code.md](claude-code.md)), AWS OIDC ([aws.md](aws.md)).
5. Work through [human-safety-checklist.md](human-safety-checklist.md).

## Repos that already have their own harness (`--keep-harness`)

Some repos already guard their agents with hooks and policy of their own, such as this template repo. `--keep-harness` (`-KeepHarness`) installs the factory there without touching that harness:

- **Installed as usual:** `scripts/factory/` (launchers, `check`, `setup`, the readiness, complexity and breakdown checks, `commands.env`), the agents and skills, the issue form and the PR template.
- **Never written, not even with `--force`:** `.github/hooks/`, `.github/workflows/`, `.claude/settings.json`, `AGENTS.md`, `CLAUDE.md`, and the hook self-test (`test-hooks.*`, `hook-cases.txt`, which test the template's policy, not yours).
- **Held back for review:** the template's versions of those files that are new or differ go to `.agent-work/harness/` (gitignored). The installer lists each one as `kept harness (new)` or `kept harness (differs)`.

A person then merges by hand what the factory needs from `.agent-work/harness/`:

1. **The stop gate:** `stop-gate.sh` / `.ps1` into `.github/hooks/scripts/`, plus a `Stop` hook (Claude Code) or `agentStop` hook (Copilot) that runs it.
2. **The factory's policy lines:**
   - write-protect `scripts/factory/check*`, `commands.env`, `complexity.env` and the human-only launchers;
   - deny `new-draft`, `create-issues` and `run-batch`.

   Without them an agent could weaken its own checks.
3. **The Project section of `AGENTS.md`**, and any workflows you want (`ci.yml`, `claude-factory.yml` needs a secret).

`check.sh` sources your `.github/hooks/scripts/common.sh` and needs its `factory_log_dir` and `factory_state_hash`; `check.ps1` needs `Get-FactoryLogDir` and `Get-FactoryStateHash` from `common.ps1`. Keep those functions if your harness has its own helpers. Then edit `commands.env` and run your own hook tests and `scripts/factory/check.sh`.

On this repo:

```bash
./install.sh . --repo github --os windows --assistant claude-code --keep-harness
```

## How the template is built (for maintainers)

Files live in layers under `template/`, each mirroring the installed tree, applied in order:

```
core → repo/<type> → os/<os> → assistant/<name> → cloud/<name>
```

- A later layer's file replaces an earlier one at the same path.
- `name.append` is appended to `name` instead (deny lists, `hook-cases.txt`, `commands.env`).
- A layer's `_repo/<type>/` and `_os/<os>/` folders apply only for that repo type / OS (e.g. `os/windows/_repo/local/scripts/factory/accept.ps1`).
- Missing layers are skipped (there is no `os/linux` or `cloud/none`).

This repo's own CI (`.github/workflows/selftest.yml`) installs combinations into scratch repos and runs their self-tests on Ubuntu and Windows, checks that both installers agree (`installer-parity.sh`), that agent and skill bodies match across assistants (`check-assistant-sync.sh`), shellcheck, and docs links. See [AGENTS.md](../AGENTS.md) for contributor rules.

## This repo's own harness (for maintainers)

This repo works under its own guard, separate from the one the installer writes into other repos: `.github/hooks/` (scripts, `policy/`, `hook-cases.txt`), `.github/hooks/repo-harness.json` (Copilot) and `.claude/settings.json` (Claude Code). Tool calls are logged to `.agent-logs/` (not committed). The factory is installed here with `--keep-harness`, so the installer never overwrites it. Edits to `template/` change the product; edits to the harness change only this repo.

- **Humans own it.** Agents must not change `.github/hooks/`, `.github/workflows/`, `.claude/settings.json`, `CLAUDE.md` or `LICENSE`; a task that needs that stops and says so in the PR. Work happens on `agent/`, `copilot/`, `claude/`, `ccr-` or `part/` branches, never on `main`, and reaches `main` only through a reviewed PR with green CI.
- **Requirements.** `git` and `jq`. On Windows, Claude Code runs the hooks through Git Bash, so `.claude/settings.json` uses shell form with a quoted path ([claude-code.md](claude-code.md#hooks-on-native-windows)); Copilot uses the PowerShell 7 hooks (`guard.ps1`, `log.ps1`). Both guards share the same policy files and are tested by `tests/repo-harness.sh`.
- **Before pushing**, run the checks listed in [AGENTS.md](../AGENTS.md): `bash tests/install-matrix.sh`, `bash tests/installer-parity.sh`, `bash tests/launcher-flow.sh`, `bash tests/repo-harness.sh`, `bash tests/check-links.sh`, `bash tests/check-assistant-sync.sh`, and `shellcheck --severity=warning --shell=bash` on every `*.sh`; with `pwsh` also `pwsh -File tests/install-matrix.ps1`.
- **Keep in step.** Update `docs/` with any behaviour change, and every `.sh` script with its `.ps1`. `.gitattributes` keeps scripts and policy files LF in Windows checkouts.
