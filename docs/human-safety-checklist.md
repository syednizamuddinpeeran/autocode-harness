# Human Safety Checklist

The agent is guarded, not trusted. These are the things only you can do.

## One-time
- [ ] Branch protection / ruleset on the base branch: PR required, ≥1 human approval, required checks `verify`, `hooks-selftest`, `guardrails-unchanged`, force-push blocked, no bot bypass.
- [ ] CODEOWNERS covers `.github/`, `scripts/factory/`, `AGENTS.md`, with "Require review from Code Owners" (recommended).
- [ ] No AWS or production secrets in **Agents** secrets/variables or `.env` files.
- [ ] Cloud agent firewall on (Settings → Copilot → Internet access).
- [ ] (Local runs) Copilot CLI sandbox is on (`/sandbox status`), `/sandbox policy` grants no `~/.ssh` or `~/.aws`, and **Allow sandbox bypass** is off. See [sandboxing.md](sandboxing.md).

## Before a run
- [ ] You created the issue or task yourself (`create-issue` / `create-task` or by hand) and read the whole draft first, including *Decisions made while drafting*. Issues made with `create-issue --draft` are created without a prompt: read each one on GitHub before adding `agent-ready`, which is what starts an agent.
- [ ] Base branch has the guardrails (`.github/`, `scripts/factory/`, `AGENTS.md`) you reviewed.
- [ ] `bash scripts/factory/test-hooks.sh` (Windows: `pwsh scripts/factory/test-hooks.ps1`) reports 0 failed.
- [ ] No cloud/prod credentials in your shell environment or `~/.aws` (local runs).
- [ ] The issue text is trustworthy. Issues from outsiders, or pasted from email or web pages, can hide instructions; read them first.
- [ ] Risk is rated honestly (`high` for auth, payments, migrations, public APIs, infra).

## During / after a run
- [ ] (Cloud) Read the diff *before* clicking **Approve and run workflows** — CI runs branch code.
- [ ] Read the PR description: Ready vs Draft, unmet ACs, **Decisions** (implementation choices), **Risks / follow-ups**. Requirements are never assumed: if the agent asked questions, answer them in the issue.
- [ ] If the agent proposed a breakdown: read every item before `create-issues` / `create-tasks` (each becomes a work item an agent will act on), check the dependencies, and that the items together deliver the whole parent issue.
- [ ] Review denied actions — the agent was trying something:
  `jq -c 'select(.decision=="deny")' <worktree>/.agent-logs/*/*.jsonl` (local only; cloud logs are discarded).
- [ ] Skim what the agent ran:
  `jq -c 'select(.event=="preToolUse") | {tool: .toolName, args: .toolArgs}' <worktree>/.agent-logs/*/*.jsonl`

## Before merging (read the diff yourself)
- [ ] The PR touches only the files the issue needed.
- [ ] **Nothing unexpected under `.github/`, `scripts/`, `AGENTS.md`.** CI blocks hooks, workflows, `check.sh` and `commands.env`; it does *not* block agents, skills, `setup.sh`, `run-issue.sh` or `AGENTS.md`.
- [ ] No weakened tests: removed assertions, `skip`/`xfail`/`.only`, loosened lint config, changed thresholds.
- [ ] No new dependencies, lockfile changes, or install scripts you did not expect.
- [ ] No new network calls, telemetry, base64 blobs, obfuscated code, or hard-coded URLs/keys.
- [ ] Every acceptance criterion has a test that would fail without the change.
- [ ] CI is green on the latest commit; `review.md` findings (local) have no unresolved `BLOCKING:` items.
- [ ] You approve and merge yourself; the agent must not.

## Red flags — stop and investigate
- Edits to hooks, policy, workflows, `check.sh`, `commands.env` or `setup.sh`.
- Commands in the log touching `.env`, `.ssh`, `.aws`, tokens, `curl`, `base64`, `eval`.
- Many denied attempts at the same action.
- PR claims "all checks passed" but CI is red or missing.
- Changes far outside the issue scope.

## Ongoing
- Review `deny-commands.txt` / `deny-paths.txt` when your stack changes; add project-specific dangers.
- Keep the Copilot CLI and sandbox up to date; re-check flag names after upgrades (`copilot help permissions`).
- Never run `copilot -p` with `--allow-all-tools` yourself in an untrusted folder without `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true` — the hooks would not load.
- Delete old worktrees and logs; logs may contain sensitive command output despite redaction.
- Add hosts to the cloud agent firewall only when needed, and remove them afterwards.

## Variant additions
- **`--repo local`:** read `handoff.md`; merge only with `accept.sh`, and use `--allow-guardrails` only after reading each changed guardrail line ([local-repo.md](local-repo.md)).
- **`--assistant claude-code`:** keep Claude Code current (the guard relies on `onFailure: "block"`); nothing under `.claude/` should change in an agent's diff; no `allowed_non_write_users` in the Claude workflow ([claude-code.md](claude-code.md)).
- **`--os windows`:** run `pwsh scripts/factory/test-hooks.ps1`; remember sandbox host rules are weaker on Windows ([platforms.md](platforms.md)).
- **`--cloud aws`:** no AWS keys anywhere agents run; the deploy role trusts only the `production` environment; `deploy-aws.yml` is in CODEOWNERS ([aws.md](aws.md)).
