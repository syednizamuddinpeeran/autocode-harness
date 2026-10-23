---
name: implementation-plan
description: Format and rules for writing an ordered, test-first implementation plan from a brief. Use when planning code changes.
---

# Implementation plan

Write `.agent-work/<id>/plan.md` (`<id>` is `issue-N` or the task id) in this exact format:

```markdown
# Plan for <issue #N | task id>

## Approach
<3–6 sentences: the design, and why it is the smallest change that works>

## Size
- Estimated lines changed: <n>   (added + removed, all files including tests; an honest estimate)

## Tasks
### T1: <imperative title>
- Files: `path/a.ext`, `path/b.ext`
- Tests: `path/test_a.ext` — <what the test asserts>
- Covers: AC1, AC2
- Done when: <observable condition>

### T2: ...

## AC coverage
| AC | Tasks | Tests |
|----|-------|-------|
| AC1 | T1 | test_a::test_x |

## Risks and rollback
- <risk> → <mitigation>
```

## Rules
- Each task is one commit and fits comfortably in one focused session. The limits on tasks, files,
  estimated lines and areas are in `scripts/factory/complexity.env`; plan what the work really needs —
  `check-complexity.sh` decides afterwards whether it must be broken down. Never squeeze a plan to fit.
- List every file each task touches on its `Files:` / `Tests:` lines; the size check counts them.
- Order tasks so the build and tests pass after every task.
- Name real paths found by searching the repo. Mark new files as `(new)`.
- No task may say "refactor" without a concrete reason tied to an AC.
- Include a task for docs/README only if behavior visible to users changes.
