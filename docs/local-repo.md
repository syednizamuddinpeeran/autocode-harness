# Local repo variant (`--repo local`)

For repositories with **no GitHub remote**, or when you don't want agents to push. A task file goes in; a verified, reviewed local branch (`agent/<id>`) and a handoff note come out. You merge it with `accept.sh`, which takes the place of CI, branch protection and the merge button.

```
tasks/<id>.md  (committed on the base branch by a human)
      │
scripts/factory/run-task.sh <id>
      │  creates git worktree ../<repo>-worktrees/<id> on new branch agent/<id>
      │  runs setup.sh, then: copilot --agent factory -p "<prompt>" --allow-all-tools --deny-tool …
      ▼
factory agent:  task-intake → planner → implementer ×T → verify-changes → reviewer → handoff
      ▼
human: scripts/factory/accept.sh <id>
      guardrail-diff check → check.sh in the branch worktree → hook self-test → confirm → git merge --no-ff
```

## What differs from the GitHub variant

| | GitHub (`--repo github`) | Local (`--repo local`) |
|---|---|---|
| Input | Issue (Agent task form) | `tasks/<id>.md` from `tasks/_template.md`, committed on the base branch |
| Run | Cloud agent, or `run-issue.sh <N>` | `run-task.sh <id> [--watch]` |
| Branch | `copilot/*` or `agent/issue-N-<slug>` | `agent/<id>` |
| Intake / final skill | `issue-intake` / `open-pr` | `task-intake` / `handoff` → `.agent-work/<id>/handoff.md` (READY or DRAFT) |
| Git rules (guard) | push only the current `agent/*`/`copilot/*` branch; no force-push; `gh` merge/admin denied | no `git push`, no `git remote` changes, no merging `main`/`master`, no `gh`; commits only on `agent/*` |
| Extra write-protected paths | `.github/workflows/` | `.github/agents/`, `.github/skills/`, `AGENTS.md`, `tasks/`, `accept.sh`, `run-task.sh`, `setup.sh`, `test-hooks.sh`, `test-hooks.d/` |
| Verification / merge gate | CI + branch protection + human merge | `accept.sh` (human only; the guard denies it to agents) |
| Hook self-test cases | github section of `hook-cases.txt` | local section of `hook-cases.txt` |

Everything else — agents, hooks, stop gate, logging, `check.sh`, sandboxing — is shared; see the other docs.

## Usage

```bash
./install.sh ~/code/my-repo --repo local        # needs ≥1 commit; no remote required
cd ~/code/my-repo
# edit scripts/factory/commands.env and the Project section of AGENTS.md
bash scripts/factory/test-hooks.sh && bash scripts/factory/check.sh
git add -A && git commit -m "chore: add agent factory"

scripts/factory/new-draft.sh "add CSV export"   # the analyst asks you questions; draft in .agent-work/drafts/
scripts/factory/create-task.sh .agent-work/drafts/add-csv-export.md   # review → commits tasks/<id>.md
# (or: cp tasks/_template.md tasks/add-csv-export.md, fill it in, commit it on the base branch)

scripts/factory/run-task.sh add-csv-export            # autonomous
scripts/factory/run-task.sh add-csv-export --watch    # interactive

cat ../my-repo-worktrees/add-csv-export/.agent-work/add-csv-export/handoff.md
git diff main...agent/add-csv-export
scripts/factory/accept.sh add-csv-export              # from the base checkout, clean tree

git worktree remove ../my-repo-worktrees/add-csv-export && git branch -d agent/add-csv-export
```

The task id must be a lowercase slug (`^[a-z0-9][a-z0-9._-]*$`). Re-running `run-task.sh <id>` reuses the worktree.

The factory never guesses requirements:
- `run-task.sh` with no id explains how to write a task and lists the tasks committed on the base branch (exit 2).
- It runs `scripts/factory/check-ready.sh` on the committed task first; a missing or placeholder Goal, Acceptance criteria, Out of scope or Risk stops it before any agent starts (exit 4). A Goal may contain `<…>` words such as "Ship <name> to <env>"; it counts as empty only if blank once unfilled `<…>` template text is removed (blank means ASCII space or tab only).
- If the task is still unclear, the agent stops at intake and writes `questions.md` plus a NEEDS-INPUT handoff; `run-task.sh` prints the questions (exit 5). Answer them in `tasks/<id>.md`, commit on the base branch, and run again — if nothing was implemented yet, the worktree is recreated from the updated task.
- If the plan exceeds `scripts/factory/complexity.env`, nothing is implemented: `run-task.sh` saves the proposed breakdown to `.agent-work/breakdowns/<id>.md` (exit 6). Review it, then `scripts/factory/create-tasks.sh .agent-work/breakdowns/<id>.md` commits `tasks/<id>.<n>.md`. Run them with `scripts/factory/run-batch.sh <id> [--auto-continue]`. See [breakdown.md](breakdown.md).

## `accept.sh`

1. Prints the commits and diff stat.
2. Blocks if the branch changed anything under `.github/`, `scripts/factory/`, `tasks/`, `AGENTS.md` or `install.sh` — re-run with `--allow-guardrails` only after reading those changes. This matters because the next step runs the **branch's** `setup.sh` and your check commands on your machine, and shell edits can bypass the agent's path rules.
3. Blocks if the branch exceeds `scripts/factory/complexity.env` (`check-complexity.sh --diff`) — re-run with `--allow-large` to merge anyway.
4. Runs `setup.sh` + `check.sh` in the branch's worktree (or a temporary one).
5. Runs `test-hooks.sh` from the base checkout.
6. Asks `Merge … [y/N]`, then `git merge --no-ff`.

`accept.sh` is a convention: anyone with shell access can `git merge` by hand, and nothing enforces it. Never merge agent branches by hand without the same checks.

## Human checklist additions

- The task file is yours. If you pasted it from an issue, email or web page, read it for hidden instructions.
- Read `handoff.md`: Status (READY, DRAFT or NEEDS-INPUT), unmet ACs, Decisions, Risks.
- `review.md` has no unresolved `BLOCKING:` items.
- Use `--allow-guardrails` only after reading each changed guardrail line.
- Use `--allow-large` only when splitting would not make review easier.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `tasks/<id>.md is not committed on 'main'` | `git add tasks && git commit` on the base branch |
| `task id must be a lowercase slug` | Use `[a-z0-9._-]`, starting alphanumeric |
| `Branch modifies guardrail files` | Read the listed changes; if intended, `--allow-guardrails` |
| `Check out 'main' first` / `Working tree is not clean` | Switch to the base branch; commit or stash |
| `No branch agent/<id>` | The run never started or the branch was deleted; re-run `run-task.sh` |
