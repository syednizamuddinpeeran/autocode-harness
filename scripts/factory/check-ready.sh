#!/usr/bin/env bash
# Is a task file or issue body ready for the factory? Deterministic; no agent involved.
#
#   bash scripts/factory/check-ready.sh <file.md>      # exit 0 ready, 4 not ready (reasons on stdout)
#
# Ready means every required section is filled in by a human, not left as a template placeholder:
#   Goal                 non-empty
#   Acceptance criteria  at least one bullet
#   Out of scope         non-empty ("None" is a valid answer)
#   Risk                 exactly low, medium or high
# and nothing is marked OPEN (unanswered questions from a draft).
# Works for tasks/<id>.md (## headings) and issue bodies from the Agent task form (### headings).
set -uo pipefail
file="${1:?usage: check-ready.sh <file.md>}"
[[ -f "$file" ]] || { echo "not found: $file"; exit 4; }

# Section text: lines after "## Name" / "### Name" up to the next heading, without HTML comments,
# template placeholders (<…>), "_No response_" (empty issue-form field) and blank lines.
section() {
  awk -v name="$1" '
    /^###?[ \t]+/ { h = $0; sub(/^#+[ \t]+/, "", h); sub(/[ \t]+$/, "", h); on = (tolower(h) == tolower(name)); next }
    on { print }
  ' "$file" | sed -E 's/<!--.*-->//g' | grep -Ev '<[^>]+>|^[[:space:]]*_No response_[[:space:]]*$|^[[:space:]]*$' || true
}

problems=()
[[ -n "$(section 'Goal')" ]] || problems+=("Goal is empty: describe the user-visible outcome in 1-2 sentences.")
section 'Acceptance criteria' | grep -Eq '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+[^[:space:]]' \
  || problems+=("Acceptance criteria: add at least one testable criterion (Given / when / then).")
[[ -n "$(section 'Out of scope')" ]] || problems+=("Out of scope is empty: list what must not change, or write \"None\".")
risk="$(section 'Risk' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$risk" =~ ^(low|medium|high)$ ]] || problems+=("Risk must be exactly one of: low, medium, high.")
if grep -Eq '(^|[^A-Za-z])OPEN:' "$file"; then
  problems+=("Unanswered questions are still marked OPEN: answer or remove them.")
fi

if [[ ${#problems[@]} -eq 0 ]]; then
  echo "ready"
  exit 0
fi
echo "Not ready for the factory ($file):"
printf '  - %s\n' "${problems[@]}"
exit 4
