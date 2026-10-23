# Usage Guide

## 1. Prerequisites

Cloud runs need only a GitHub repo with the Copilot cloud agent enabled. Local runs (WSL Ubuntu / macOS / Linux) also need:

```bash
sudo apt-get install -y git jq
npm install -g @github/copilot
gh auth login
copilot            # sign in; then enable the sandbox — see sandboxing.md
```
Keep repos in the WSL filesystem (`~/code/...`), not `/mnt/c/...`. For native Windows (PowerShell 7), see [platforms.md](platforms.md).

## 2. Install into a repository

```bash
./install.sh /path/to/repo --repo github           # skips files that already exist
./install.sh /path/to/repo --repo github --force   # overwrites template files
```
Requires a git repo with at least one commit. Appends `.agent-logs/` and `.agent-work/` to `.gitignore`, makes scripts executable.

## 3. Configure

1. `scripts/factory/commands.env`: `BASE_BRANCH`, `SETUP_CMD`, `FORMAT_CHECK_CMD`, `LINT_CMD`, `TYPECHECK_CMD`, `TEST_CMD`, `BUILD_CMD`. Empty = skipped. Presets for Python, TypeScript, Java, .NET and CDK are in the file. If all are empty, `check.sh` fails (exit 3) unless `ALLOW_NO_CHECKS=1`.
2. `AGENTS.md` → **Project** section: what the repo is, stack, layout, conventions.
3. `.github/workflows/copilot-setup-steps.yml` and `ci.yml`: uncomment the language runtime(s) the project needs.

Then verify and commit to the base branch *before* running agents:
```bash
bash scripts/factory/test-hooks.sh && bash scripts/factory/check.sh
git add -A && git commit -m "chore: add agent factory" && git push
```

## 4. One-time GitHub setup

1. Enable the Copilot cloud agent for the repo.
2. Merge the template into the default branch. Custom agents appear in the agent dropdown, and `copilot-setup-steps.yml` runs, only from the default branch.
3. Branch protection / ruleset on the base branch: require a PR, ≥1 human approval, required checks `verify`, `hooks-selftest`, `guardrails-unchanged`; block force-push; no bypass for bots. GitHub already stops the person who assigned the issue from approving Copilot's PR.
4. Recommended: a `CODEOWNERS` entry for `.github/`, `scripts/factory/` and `AGENTS.md` with "Require review from Code Owners", so guardrail edits need your approval even where CI does not check them.
5. Keep the cloud agent firewall on with the recommended allowlist (Settings → Copilot → Internet access); add hosts only when needed.
6. Do not add AWS or production secrets as **Agents** secrets/variables (Settings → Secrets and variables → Agents). The cloud agent cannot see Actions secrets.

## 5. Create an issue

**Recommended: draft it with the analyst.**
```bash
scripts/factory/new-draft.sh "add CSV export to the reports page"
```
This opens an interactive session with the `analyst` agent. It asks you, one topic at a time: who the user is and what they get, testable acceptance criteria with concrete values, edge cases, what is out of scope, data and security impact, risk. It writes only what you answer: anything unanswered becomes an `OPEN:` line, and it records each question with your answer under *Decisions made while drafting*, so you can see exactly what you asked for. It runs in a throwaway worktree and cannot change code or create anything.

Review and edit `.agent-work/drafts/<id>.md`, then create the issue yourself:
```bash
scripts/factory/create-issue.sh .agent-work/drafts/<id>.md      # preview → confirm → gh issue create
```
It refuses drafts that are not ready (OPEN items, missing sections, placeholders), uses your `gh` credentials, and adds the `agent-ready` label. Agents are denied `new-draft`, `create-issue` and `gh issue` writes by the guard.

**Many clear requirements at once: draft on GitHub, approve there.** Write each as a ready draft, then:
```bash
scripts/factory/create-issue.sh --draft .agent-work/drafts/*.md
```
All drafts are validated first, then created without prompts and labelled `agent-draft` (not `agent-ready`), so nothing starts. Review and edit the issues on GitHub, then add `agent-ready` to the ones you approve: that is what starts the factory.

**Or write it by hand** with the **Agent task** form: Goal, Acceptance criteria (Given/when/then — make them automatically testable), Out of scope (or "None"), Pointers, Risk. It applies the `agent-ready` label.

The factory never guesses requirements:
- `run-issue.sh` first runs `scripts/factory/check-ready.sh` on the issue body. If Goal, Acceptance criteria, Out of scope or Risk is missing or still a placeholder, it lists what to fix and exits (code 4) **before any agent starts**. Run it with no issue number and it tells you how to create one (code 2).
- If the issue is filled in but still unclear (untestable criteria, contradictions, undefined terms, unstated edge cases), the agent stops at intake, before planning, and writes `questions.md`. `run-issue.sh` shows the questions and offers to post them on the issue (code 5). Answer them in the issue and run again. On the cloud agent the questions appear as the draft PR's description.

If the agent ends with commits on its branch but no open pull request for it (its push or PR was blocked or failed), `run-issue.sh` says the work is committed but not pushed and exits with code 7, so a batch shows that issue as "needs you". If it ends with nothing at all (no commits, no open pull request, no questions, no breakdown), for example because it was cut off, `run-issue.sh` says the run produced no result and exits with code 8, which a batch also shows as "needs you".

If a branch `agent/issue-<N>-…` is left over from an earlier run whose worktree was removed, `run-issue.sh` reuses it: a branch with no commits of its own is restarted from the base branch; a branch with commits is kept as it is and the new worktree is attached to it, so no work is lost. To start over on such a branch, delete it first (`git branch -D agent/issue-<N>-…`).

Too big for one run? After planning, the factory checks the plan against `scripts/factory/complexity.env`. If it exceeds a limit, no code is written: the planner proposes a breakdown, `run-issue.sh` saves it and exits with code 6, and you create the sub-issues with `create-issues.sh`. `run-batch.sh <parent>` then runs the unblocked ones in parallel. See [breakdown.md](breakdown.md).

Tips: one outcome per issue; name real files in Pointers; mark risk `high` for auth, payments, migrations, public APIs, infra (result will be a draft PR).

## 6. Run

**Cloud:** assign the issue to Copilot and choose the **factory** agent from the dropdown. It works on a `copilot/*` branch (the only branch it can push to) and opens the PR. By default, CI does not run on Copilot's pushes until someone with write access clicks **Approve and run workflows** — read the diff first, because CI executes branch code.

**Local:**
```bash
scripts/factory/run-issue.sh 42            # autonomous
scripts/factory/run-issue.sh 42 --watch    # interactive; you switch to autopilot
```
This fetches the issue with `gh`, creates `../<repo>-worktrees/issue-42` on `agent/issue-42-<slug>` from `origin/<base>` (or reuses it), runs `setup.sh`, and starts `copilot --agent factory`. Autonomous mode sets `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true` (in `-p` mode the CLI otherwise skips repository hooks in an untrusted folder, and the new worktree is untrusted) and adds `--allow-all-tools` plus CLI-level denies for `git push --force`, `gh pr merge`, `sudo`; extra flags via `COPILOT_EXTRA_FLAGS`. Flag names can change between CLI versions — check `copilot help permissions`.

## 7. Review and merge

Use [human-safety-checklist.md](human-safety-checklist.md). Local run artifacts:
```bash
cat ../<repo>-worktrees/issue-42/.agent-work/issue-42/review.md
jq -c 'select(.decision=="deny")' ../<repo>-worktrees/issue-42/.agent-logs/*.jsonl
```
Merge the PR on GitHub once CI is green and you have approved it. Agents never merge; the cloud agent cannot mark its PR ready for review, approve it or merge it.

## 8. Clean up (local)

```bash
git worktree remove ../<repo>-worktrees/issue-42 && git branch -d agent/issue-42-<slug>
```

## Logs

- Local: `.agent-logs/<sessionId>.jsonl` and `.agent-logs/index.jsonl`.
- Cloud: the environment is destroyed after the job, so hook logs are discarded. Use the agent session log on GitHub.

```bash
jq -c 'select(.event=="preToolUse") | {ts, tool: .toolName, decision, reason}' .agent-logs/*.jsonl
jq -c 'select(.decision=="deny")' .agent-logs/*.jsonl
jq -c 'select(.event|test("subagent")) | {ts, event, agentName}' .agent-logs/*.jsonl
```
