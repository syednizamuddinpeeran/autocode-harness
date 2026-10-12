---
name: open-pr
description: Push the branch and open or update the pull request with the standard body, linked issue, and evidence. Use as the final step of an issue run.
---

# Open the pull request

## NEEDS-INPUT mode (intake wrote `questions.md`)
Nothing was planned or changed, so there is nothing to push.
- **Local CLI**: stop. Do not push or open a PR. `run-issue.sh` shows `.agent-work/issue-N/questions.md`
  to the human and offers to post it on the issue.
- **GitHub Action**: do not commit code. Put the contents of `questions.md` in your final message (the action
  posts it as a comment on the issue), and stop.

## BREAKDOWN mode (the work exceeded the complexity limits)
Nothing was implemented. The deliverable is `.agent-work/issue-N/breakdown.md`.
- **Local CLI**: stop. Do not push or open a PR. `run-issue.sh` shows the breakdown and tells the human
  how to create the sub-issues (`create-issues.sh`).
- **GitHub Action**: do not commit code. Put the contents of `breakdown.md` in your final message (the action
  posts it as a comment on the issue). The human creates the sub-issues with
  `create-issues.sh --from-issue <N>`, and stop.

## Preconditions
- `verify-changes` passed in this session (unless opening a draft for a blocked run).
- Branch is `agent/issue-N-*` (local) or `claude/*` (GitHub Action). Never `main`.

## Where you are running
- **GitHub Action** (`GITHUB_ACTIONS=true`, branch `claude/*`): commit and push to your branch as the
  action allows. The action does not open PRs itself; end your final comment with the PR body below
  so the human can open the PR from the link the action posts.
- **Local CLI**: run
  ```bash
  git push -u origin HEAD
  gh pr create --base "${BASE_BRANCH:-main}" --title "<type>(<scope>): <summary> (#N)" \
    --body-file .agent-work/issue-N/pr-body.md [--draft]
  ```
  Use `--draft` when risk is high, verification failed, or blocking questions remain.

## PR body (write to `.agent-work/issue-N/pr-body.md`)
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
Plan, review, and decisions: `.agent-work/issue-N/` (local only). Action log: `.agent-logs/<session>.jsonl`.
```

## Rules
- Never run `gh pr merge` or enable auto-merge. A human merges.
- Never request reviewers who are bots unless the repo already does so.
