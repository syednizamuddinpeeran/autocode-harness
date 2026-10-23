# Reference

## Scripts (`scripts/factory/`)

| Script | Who runs it | Purpose |
|---|---|---|
| `commands.env` | human edits | `BASE_BRANCH`, `SETUP_CMD`, `FORMAT_CHECK_CMD`, `LINT_CMD`, `TYPECHECK_CMD`, `TEST_CMD`, `BUILD_CMD`, `ALLOW_NO_CHECKS`, `ASSISTANT` (set by the installer), `FORBIDDEN_ENV` (set by `--cloud aws`: variables that stop `run-issue`/`run-task` from starting) |
| `agent-cli.sh` / `.ps1` | run-issue, run-task | Starts `copilot` or `claude` with the factory agent and CLI-level denies, per `ASSISTANT` |
| `setup.sh` | run-issue, setup job, CI, agents | Requires `git`, `jq`; `chmod +x` scripts; creates `.agent-logs`, `.agent-work`; runs `SETUP_CMD` |
| `check.sh` | agents, humans, CI | Runs format → lint → typecheck → test → build; skips empty; writes `.agent-logs/.verified` hash on success. Exit 0 pass, 1 fail, 3 nothing configured |
| `run-issue.sh <N> [--watch]` | human (local) | Fetches the issue with `gh`; runs `check-ready.sh`; creates worktree + `agent/issue-N-<slug>` from `origin/<base>` (a leftover branch of that name without a worktree is reused: restarted from `origin/<base>` if it has no commits of its own, kept as it is if it has some); launches the assistant with the factory agent; shows `questions.md` if the agent stopped at intake, or saves the proposed breakdown to `.agent-work/breakdowns/`; reports work that was committed but has no open PR, and a run that produced nothing. Exit 0 done, 2 no issue, 4 not ready, 5 needs answers, 6 breakdown proposed, 7 committed but not pushed (no open PR for the branch), 8 no result (no commits, no open PR, no questions, no breakdown) |
| `new-draft.sh [--id <slug>] "<brief>"` | human (interactive) | Analyst session in a throwaway worktree; writes `.agent-work/drafts/<id>.md` from your answers only (unanswered → `OPEN:`). Continues an existing draft |
| `create-issue.sh [--draft] [--yes] <draft>...` | human only (github) | `check-ready` on all, preview, confirm, `gh issue create --label agent-ready`. `--draft`: no prompt, label `agent-draft`; you add `agent-ready` on GitHub after review |
| `create-task.sh <draft> [--id <slug>] [--yes]` | human only (local) | `check-ready`, preview, confirm, commit `tasks/<id>.md` on the base branch |
| `create-issues.sh <breakdown> \| --from-pr <N> \| --from-issue <N> [--parent <N>] [--yes]` | human only (github) | `check-breakdown`, preview, confirm; creates the sub-issues in dependency order, links them as native sub-issues with blocked-by dependencies between the items, records the parent as blocked by each new sub-issue, comments on the parent. See [breakdown.md](breakdown.md) |
| `create-tasks.sh <breakdown> [--yes]` | human only (local) | `check-breakdown`, preview, confirm; commits `tasks/<parent>.<n>.md` and a "Broken down into" list in the parent task |
| `run-batch.sh <parent> [--auto-continue] [--list] [--parallel <n>]` | human | Runs the ready sub-issues / sub-tasks of a breakdown in dependency order, up to `MAX_PARALLEL` at once, each as its own `run-issue` / `run-task`; `--auto-continue` starts the next ones as you merge. See [breakdown.md](breakdown.md#running-the-items-run-batch) |
| `complexity.env` | human edits | Limits that make an issue too big for one run. See [breakdown.md](breakdown.md) |
| `check-complexity.sh <plan> <brief>` / `--diff <base> [<head>]` | factory agent, CI `size` job, `accept.sh` | Measures a plan (or a real diff) against `complexity.env`. Exit 0 within limits, 6 too complex, 4 plan malformed |
| `check-breakdown.sh <breakdown> [brief] [--split <dir>]` | factory agent, create-issues, create-tasks | Items ready, numbered, dependencies valid and acyclic, parent ACs covered. Exit 0 valid, 4 invalid |
| `check-ready.sh <file>` | run-issue, run-task, human | Deterministic readiness gate: Goal, ≥1 acceptance criterion, Out of scope, Risk (low/medium/high) filled in, nothing marked `OPEN:`. A Goal may contain `<…>` words such as "Ship <name> to <env>"; it counts as empty only if blank once unfilled `<…>` template text is removed (blank means ASCII space or tab only). Exit 0 ready, 4 not ready |
| `migrate-paths.sh` | human (bash only, no session active) | Moves old flat drafts, issue work and session logs into the `<UTC-stamp>-<name>` folders, and moves stamped drafts and issue work when `DRAFTS_DIR` or `WORK_DIR` changed in `paths.env` (from the locations recorded in `.agent-work/.layout`). Prints each move as `from -> to`. Refuses the whole run (exit 1, nothing moved) if a destination exists or a new location is inside the old one; a second run moves nothing. See [usage-guide.md](usage-guide.md#move-files-to-the-timestamped-layout) |
| `test-hooks.sh` | human, CI | Runs every case in `hook-cases.txt` plus payload-shape, stop-gate, logging and redaction checks in a throwaway repo; it reports the number of cases run and failed |
| `hook-cases.txt` | human edits | Guard test cases: `<allow\|deny> <sh\|view\|edit\|create> <description> :: <argument>`, `@checkout <branch>` |

`install.sh <target> [--repo github|local] [--os linux|wsl|windows] [--assistant copilot|claude-code] [--cloud none|aws] [--force] [--keep-harness]` (or `pwsh install.ps1 <target> [-Repo …] [-Os …] [-Assistant …] [-Cloud …] [-Force] [-KeepHarness]`, same output) (template repo root) builds the template from `template/core` + `template/repo/<type>` and copies it into another repo. `--keep-harness` / `-KeepHarness` installs the factory into a repo that already has its own hooks and policy without touching them; see [install.md](install.md#repos-that-already-have-their-own-harness---keep-harness).

Repo-type and OS pieces in the installed tree: `.github/hooks/policy/git-rules.env` (which branches agents may use, which git subcommands are limited to them, whether push refspecs must be the current branch), the sections appended to each `policy/*.txt`, and the cases appended to `scripts/factory/hook-cases.txt` (run by both `test-hooks.sh` and `test-hooks.ps1`).

## Workflows (`.github/workflows/`)

| File | Purpose |
|---|---|
| `copilot-setup-steps.yml` | Prepares the cloud agent environment. Single job named `copilot-setup-steps`; only `steps`, `permissions`, `runs-on`, `services`, `snapshot`, `timeout-minutes` (≤ 59) are honoured; used only from the default branch. Runs `setup.sh` |
| `ci.yml` | Jobs `verify` (setup + `check.sh`), `hooks-selftest`, `guardrails-unchanged` and `size` (agent branches only; `size` runs the base branch's `check-complexity.sh --diff`) |

## Hook events (`.github/hooks/factory.json`)

| Event | Script | Timeout | Notes |
|---|---|---|---|
| `sessionStart`, `sessionEnd` | `log.sh` | 10s | Also written to `index.jsonl` |
| `userPromptSubmitted` | `log.sh` | 10s | |
| `preToolUse` | `guard.sh` | 15s | Logs + allow/deny |
| `postToolUse`, `postToolUseFailure` | `log.sh` | 10s | |
| `subagentStart`, `subagentStop` | `log.sh` | 10s | |
| `preCompact`, `errorOccurred` | `log.sh` | 10s | |
| `agentStop` | `stop-gate.sh` | 20s | Blocks once if unverified |

On the cloud agent all of these fire except that `preCompact` fires only for automatic compaction and `userPromptSubmitted` at most once; only the `bash` field is used. The CLI default timeout is 30s; this repo sets its own.

`common.sh` provides `factory_log`, `factory_redact`, `factory_state_hash`, `factory_has_changes`, `factory_context`.

## Policy files (`.github/hooks/policy/`)

- `deny-commands.txt` — case-insensitive extended regexes against shell commands.
- `deny-paths.txt` — regexes against file paths; `write:` prefix = writes only.
Lines starting with `#` are comments. Humans edit; agents cannot.

## Environment variables

| Variable | Used by | Effect |
|---|---|---|
| `FACTORY_STOP_GATE=off` | stop-gate | Disable the stop gate for a session |
| `FACTORY_LOG_DIR` | common.sh | Override log directory |
| `FACTORY_POLICY_DIR` | guard.sh | Override policy directory |
| `FACTORY_BRANCH_PREFIXES` | guard.sh | Branch prefixes allowed to `git push` (default from `git-rules.env`: `agent/ copilot/ claude/` for github, `agent/` for local) |
| `FACTORY_WORKTREE_ROOT` | run-issue | Worktree parent (default `../<repo>-worktrees`) |
| `COPILOT_EXTRA_FLAGS` | run-issue/run-task | Extra Copilot CLI flags for autonomous runs (e.g. `--sandbox`) |
| `CLAUDE_EXTRA_FLAGS` | run-issue/run-task | Extra Claude Code flags for autonomous runs (e.g. `--max-turns 200`) |
| `CLAUDE_REMOTE` | run-issue/run-task | Set to `1` (Claude Code) to run autonomous sessions interactively with `--remote-control`, so they show on claude.ai/code and the mobile app. `-p` runs never register. The session stays open until `/exit`; `--max-turns` and other `-p`-only flags in `CLAUDE_EXTRA_FLAGS` do not apply |
| `BATCH_GH_RETRIES` / `BATCH_GH_RETRY_SECONDS` | run-batch (GitHub) | How often a failed GitHub API call is retried (default 3) and the pause between tries in seconds (default 5) before the batch gives up with exit 1 |
| `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` | Claude Code CLI (set by run-issue/run-task) | Autonomous `claude -p` runs do not stop background sub-agents 10 minutes after the last turn |
| `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true` | Copilot CLI (set by run-issue) | Load repository hooks in `-p` mode in an untrusted folder |

## Log format

One JSON line per event in `.agent-logs/<YYYY-MM-DDTHH-MM-SSZ>-<session>/<session>.jsonl` (the folder name is the UTC start time of the session; later events of the same session append to the same file): `ts`, `event`, `branch`, `surface` (`cloud` or `cli`), the hook payload (strings clipped to 4000 chars), and for `preToolUse` `decision` (`allow`/`deny`) and `reason`. `index.jsonl` (directly under `.agent-logs/`) records session start/end. The location is still `.agent-logs/`, and the deny policy files in `.github/hooks/policy/` are unchanged. Useful queries are in [usage-guide.md](usage-guide.md#logs).

## Guard decision contract

Print `{"permissionDecision":"deny","permissionDecisionReason":"…"}` to deny; print nothing to allow. Non-zero exit = deny; timeout = allow. (`allow` and `ask` also exist; on the cloud agent `ask` is treated as deny.)
