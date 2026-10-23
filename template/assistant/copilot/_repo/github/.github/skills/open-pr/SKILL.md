---
name: open-pr
description: Push the branch and open or update the pull request with the standard body, linked issue, and evidence. Use as the final step of an issue run.
---

# Open the pull request

## Work folder
Read the files this skill uses (`questions.md`, `breakdown.md`, `pr-body.md`) from, and write them to, the
work folder named by the `Work folder: <path>` line in your prompt. If the prompt has no such line,
stop with an error and do nothing; never fall back to a literal path.

## NEEDS-INPUT mode (intake wrote `questions.md`)
Nothing was planned or changed, so there is nothing to push.
- **Local CLI**: stop. Do not push or open a PR. `run-issue.sh` shows `questions.md` from the work folder
  to the human and offers to post it on the issue.
- **Cloud agent**: do not commit code. Put the contents of `questions.md` in your final message (the PR
  description of your draft PR), titled `Questions: <issue title>`, and stop.

## BREAKDOWN mode (the work exceeded the complexity limits)
Nothing was implemented. The deliverable is `breakdown.md` in the work folder.
- **Local CLI**: stop. Do not push or open a PR. `run-issue.sh` shows the breakdown and tells the human
  how to create the sub-issues (`create-issues.sh`).
- **Cloud agent**: do not commit code. Put the contents of `breakdown.md` in your final message (the PR
  description of your draft PR), titled `Breakdown: <issue title>`. The human creates the sub-issues with
  `create-issues.sh --from-pr <PR number>`, and stop.

## Preconditions
- `verify-changes` passed in this session (unless opening a draft for a blocked run).
- Branch is `agent/issue-N-*` (local) or `copilot/*` (cloud). Never `main`.

## Where you are running
- **Cloud agent** (`/workspace` exists, branch `copilot/*`): the platform creates the PR.
  Push your commits and put the body below into the PR description using your progress/PR update tool.
- **Local CLI**: run
  ```bash
  git push -u origin HEAD
  gh pr create --base "${BASE_BRANCH:-main}" --title "<type>(<scope>): <summary> (#N)" \
    --body-file <work folder>/pr-body.md [--draft]
  ```
  Use `--draft` when risk is high, verification failed, or blocking questions remain.

## PR body (write to `pr-body.md` in the work folder)
```markdown
Closes #N

## Summary
<2–4 sentences>

## Acceptance criteria
- [x] AC1 — <test name that proves it>
- [ ] AC2 — <why not met, if any>

## Verification
`scripts/factory/check.sh` — passed | failed (<which check>)

## Decisions
- <implementation choices made from the code base (not requirements); see decisions.md>

## Risks / follow-ups
- ...

## Agent run
Plan, review, and decisions: the work folder (local only). Action log: `.agent-logs/<UTC-timestamp>-<session>/<session>.jsonl`.
```

## Rules
- Never run `gh pr merge` or enable auto-merge. A human merges.
- Never request reviewers who are bots unless the repo already does so.
