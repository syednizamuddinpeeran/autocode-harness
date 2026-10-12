---
name: verify-changes
description: Run the project's full verification gate (format, lint, typecheck, tests, build) and interpret failures. Use before review and before the final step (PR or handoff).
---

# Verify changes

1. Run: `bash scripts/factory/check.sh 2>&1 | tee .agent-work/<id>/verify.log`
   (native Windows: `pwsh scripts/factory/check.ps1 *>&1 | Tee-Object .agent-work/<id>/verify.log`)
2. Exit code 0 → verification passed. `check.sh` / `check.ps1` records a marker the stop hook uses;
   any later file change invalidates it, so re-run after every fix.
3. Non-zero → read only the failing section of `verify.log`. Summarize each failure as
   `<check> | <file:line> | <one-line cause>` and hand that list to the implementer.

## Never
- Edit `scripts/factory/commands.env`, `check.sh` or `check.ps1` to make checks pass.
- Delete, skip, or loosen tests or lint rules.
- Claim success without a zero exit code in this session.

If a failure is clearly unrelated to this change (pre-existing on the base branch),
confirm by checking it out on the base branch with `git stash; bash scripts/factory/check.sh; git stash pop`,
then record it under "Pre-existing failures" in the PR or handoff.
