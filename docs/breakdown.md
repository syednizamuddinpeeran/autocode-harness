# Breaking down large issues and tasks

The factory refuses work that is too big for one run. After planning, it measures the plan against limits you set. If any limit is exceeded, it writes no code. The planner proposes a breakdown into smaller items instead, and **you** create them as sub-issues (GitHub) or sub-tasks (local). Each item then runs as its own factory run.

## What "too complex" means: `scripts/factory/complexity.env`

| Setting | Default | Measured from |
|---|---|---|
| `MAX_ACCEPTANCE_CRITERIA` | 5 | `- AC<n>` lines in the brief |
| `MAX_PLAN_TASKS` | 6 | `### T<n>` tasks in the plan (one commit each) |
| `MAX_FILES` | 15 | distinct backticked paths on the plan's `Files:` / `Tests:` lines |
| `MAX_EST_LINES` | 400 | `Estimated lines changed:` in the plan's `## Size` section |
| `AREAS`, `MAX_AREAS` | off, 1 | `name=prefix` pairs, e.g. `"web=web/ android=android/"`. A plan touching more areas than allowed is split per area |
| `SPLIT_ON_RISK` | `high` | the brief's Risk. A plan at one of these risk levels must be split until each item has a single task |
| `MAX_SUBITEMS` | 8 | the most items one breakdown may propose |
| `MAX_PARALLEL` | 3 | the most items `run-batch` runs at once |

Agents cannot edit `complexity.env` or the check scripts (guard `deny-paths`). Change the limits on the base branch yourself.

## Flow

1. The planner writes the plan with a `## Size` estimate. It must list every file it will touch and must not squeeze a plan to fit the limits.
2. The factory runs `check-complexity.sh plan.md brief.md` (`.ps1` on Windows): exit 0 continue, 6 too complex, 4 plan malformed (the planner fixes it).
3. On exit 6, the planner writes `breakdown.md` in the `breakdown` skill format: `## Item <n>: <title>` sections, each a ready issue/task (Goal, Acceptance criteria, Out of scope, Risk) plus `Depends on: none | Item k, …` and `Covers: AC…`.
4. The factory runs `check-breakdown.sh`. It checks that every item is ready, that dependencies exist and have no cycles, and that the items together cover every parent acceptance criterion, with at most 2 fix rounds. Then it stops with status `BREAKDOWN`.
5. You review the breakdown, edit it if needed, and create the items:

| Where it ran | You get | You run |
|---|---|---|
| `run-issue.sh` (local) | exit 6; `.agent-work/breakdowns/issue-<N>.md` (+ `.brief.md`) | `scripts/factory/create-issues.sh .agent-work/breakdowns/issue-<N>.md` |
| Copilot cloud agent | a draft PR titled `Breakdown: …` | `scripts/factory/create-issues.sh --from-pr <PR>` (then close the PR) |
| Claude GitHub Action | a comment on the issue | `scripts/factory/create-issues.sh --from-issue <N>` |
| `run-task.sh` (local repo) | exit 6; `.agent-work/breakdowns/<id>.md` (+ `.brief.md`) | `scripts/factory/create-tasks.sh .agent-work/breakdowns/<id>.md` |

`create-issues` validates again, previews every item and asks for confirmation (`--yes` skips the prompt). Using your `gh` credentials, it then:
- creates the issues in dependency order. Only items with no dependencies get the `agent-ready` label, because that label starts the Claude GitHub Action. Add it to the others when their blockers are merged;
- adds them to the parent as native [sub-issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues);
- records native [blocked-by dependencies](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-issue-dependencies);
- comments the plan on the parent.

`--from-pr` only accepts PRs on `copilot/*` or `agent/*` branches. `--from-issue` only reads comments by the `claude` / `github-actions` bots.

`create-tasks` writes `tasks/<parent>.<n>.md`, with `Parent:` and `Depends on:` naming task ids. It appends `## Broken down into` to the parent task and commits everything in one commit on the base branch.

Agents are denied `create-issues`, `create-tasks` and `gh issue` writes. Only a human creates work items.

## Backstops

The agent runs `check-complexity` itself, so a misbehaving agent could skip it. The real diff is checked again with the **base branch's** script and limits:
- GitHub: the `size` job in `ci.yml` runs on agent branches (`copilot/*`, `agent/*`, `claude/*`) and fails when the PR exceeds `MAX_FILES` / `MAX_EST_LINES` / `MAX_AREAS`.
- Local: `accept.sh` refuses to merge an oversized branch unless you pass `--allow-large` (`-AllowLarge` in `accept.ps1`).

## Running the items: `run-batch`

An item is **ready** when everything it depends on is merged:
- GitHub: the sub-issue is open and every issue it is blocked by is closed. Its PR closes it with `Closes #N`.
- Local: every task on its `Depends on:` line was merged with `accept.sh`.

```bash
scripts/factory/run-batch.sh <parent> --list            # state of each item: ready, blocked by …, running, review, merged
scripts/factory/run-batch.sh <parent>                   # run every ready item, up to MAX_PARALLEL at once
scripts/factory/run-batch.sh <parent> --auto-continue   # …and keep starting items as you merge their blockers
```
`<parent>` is the parent issue number (GitHub) or task id (local). On Windows use `pwsh scripts/factory/run-batch.ps1 <parent> [-List] [-AutoContinue] [-Parallel <n>]`.

- Each item runs as its own `run-issue.sh` / `run-task.sh` (autonomous), with its own agent, worktree and branch. Output goes to `.agent-logs/batch/<item>.log`. `--parallel <n>` overrides `MAX_PARALLEL`.
- Without `--auto-continue`, the batch ends when the runs it could start have finished. Review and merge them, then run it again.
- With `--auto-continue`, it checks every `BATCH_POLL_SECONDS` (default 60) for your merges and starts the items they unblock. It stops when every item is merged, or when nothing can move without you: an item stopped with questions, a breakdown or a failure.
- Merging is never automatic. On GitHub each item is a normal PR; locally you run `accept.sh <parent>.<n>` (which also checks the size).
- An item that already has a branch or worktree is not started again. Delete it to retry, or run `run-issue.sh` / `run-task.sh` for that item yourself. A later batch shows such an item as `review` only if its branch has an open PR. If its branch has commits but no open PR, it shows `needs you: commits but no PR, run open-pr or delete the worktree` and `--auto-continue` does not wait for it. An item with no commits (the earlier run stopped) also shows as `needs you`, so `--auto-continue` does not wait for a PR that will never come.
- GitHub: a GitHub API call that fails (e.g. a network timeout) is retried up to `BATCH_GH_RETRIES` times (default 3), `BATCH_GH_RETRY_SECONDS` apart (default 5), before the batch gives up.
- Exit codes: 0 every run it started finished, 1 a run failed or stopped (questions, breakdown, unpushed work, no result) or a GitHub API call kept failing, 2 no items found.
- Agents are denied `run-batch` (it starts more agents).

**Cloud agent:** run `run-batch.sh <parent> --list` and assign the `ready` sub-issues to Copilot, or add the `agent-ready` label to start the Claude action on them. When their PRs are merged, run `--list` again.
