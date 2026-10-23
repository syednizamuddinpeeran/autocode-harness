---
name: handoff
description: Finish a task run on the local agent branch and write the handoff note a human reads before merging. Use as the final step of a task run.
---

# Handoff (local replacement for "open a PR")

There is no remote, pull request, or CI. The deliverable is the committed `agent/<id>` branch plus a handoff note.

## Work folder
Write every file this skill produces into the work folder named by the `Work folder: <path>` line in
your prompt. If the prompt has no such line, stop with an error and write nothing; never fall back to a
literal path.

## Preconditions
- `verify-changes` passed in this session (unless writing a DRAFT handoff for a blocked run).
- All work is committed on `agent/<id>`. Never commit to the base branch.

## Steps
1. Write `handoff.md` in the work folder using the body below.
2. Show the human the result: `git log --oneline <base>..HEAD` and `git diff --stat <base>...HEAD`.
3. Stop. Do not merge, push, add remotes, or switch to the base branch. A human merges with
   `scripts/factory/accept.sh <id>`.

## Handoff body
```markdown
Status: READY | DRAFT | NEEDS-INPUT | BREAKDOWN
        (DRAFT: risk is high or verification failed. NEEDS-INPUT: intake wrote questions.md; nothing was
         planned or changed — put the questions under Summary and stop. BREAKDOWN: the work exceeded the
         complexity limits; nothing was implemented — point to breakdown.md under Summary and stop;
         the human creates the tasks with create-tasks.sh.)
Task: <id>
Branch: agent/<id>

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
Plan, review, and decisions: the work folder. Action log: `.agent-logs/<UTC-timestamp>-<session>/<session>.jsonl`.
```

## Rules
- Never merge into the base branch, rebase it, or run `git push` / `git remote`.
- Guardrail edits (hooks, agents, skills, check.sh, commands.env) are proposals only: describe them under Risks / follow-ups.
