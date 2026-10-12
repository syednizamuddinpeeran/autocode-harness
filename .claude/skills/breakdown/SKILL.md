---
name: breakdown
description: Split an issue or task that exceeds the complexity limits into smaller, independently deliverable items with dependencies. Use when check-complexity.sh reports "too complex".
---

# Breakdown

The work is too big for one run (see the `check-complexity.sh` output). Propose smaller items a
human can review and create. You write a proposal only: no code, no issues, no task files.

## Rules
- Each item is one deliverable a reviewer can check in one sitting and must itself fit the limits
  in `scripts/factory/complexity.env` (read it). Items with `high` risk must be a single task.
- Split along natural seams: by area (`AREAS` in complexity.env), by layer (data → service → UI),
  or by acceptance criterion. Prefer items that can run in parallel; add a dependency only when an
  item really needs another one merged first.
- **No new requirements.** Every item's acceptance criteria come from the parent brief, split or
  restated without changing their meaning. Every parent AC is covered by exactly the items that
  deliver it (`Covers:`). If a split needs a decision the parent does not make (e.g. which part ships
  first behind a flag), list it under "Questions for the human" instead of deciding it.
- Keep each item's Out of scope explicit, including "the other items of this breakdown".
- At most `MAX_SUBITEMS` items. Number them 1..n.
- The factory then checks it with `scripts/factory/check-breakdown.sh <breakdown.md> <brief.md>`
  (item count, readiness of each item, dependencies and cycles, AC coverage) and sends you any errors
  to fix.

## Format — write `.agent-work/<id>/breakdown.md`
```markdown
# Breakdown of <issue #N | task <id>>: <parent title>

Limits exceeded:
- <each line from check-complexity.sh "too complex">

Questions for the human:
- <only if a split needs a decision the parent does not make; otherwise "None">

## Item 1: <short imperative title>
Depends on: none
Covers: AC1, AC2

### Goal
<1–2 sentences>

### Acceptance criteria
- Given <context>, when <action>, then <observable result>

### Out of scope
- <including the other items of this breakdown>

### Pointers
<files / modules>

### Risk
<low | medium | high>

## Item 2: <title>
Depends on: Item 1
Covers: AC3
...
```
