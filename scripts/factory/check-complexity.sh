#!/usr/bin/env bash
# Measure a plan + brief against scripts/factory/complexity.env. Deterministic; no agent judgement
# except the planner's line estimate.
#
#   bash scripts/factory/check-complexity.sh <plan.md> <brief.md>
#     exit 0 within limits, 6 too complex (reasons on stdout), 4 plan/brief malformed
#   bash scripts/factory/check-complexity.sh --diff <base> [<head>]
#     after implementation: compares the real diff <base>...<head> (default HEAD) to the limits; exit 0 or 6
#
# Counts: acceptance criteria = "- AC<n>" lines in the brief; tasks = "### T<n>" headings in the
# plan; files = distinct backticked paths on the plan's "- Files:" and "- Tests:" lines; estimated
# lines = "Estimated lines changed: <n>" in the plan; risk = first word under "## Risk" in the brief.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/complexity.env"

problems=()
over() { problems+=("$1"); }
report() { # report <label> <value> <limit>
  printf '  %-24s %6s   (limit %s)\n' "$1" "$2" "$3"
}

area_count() { # stdin: file paths → number of distinct configured areas touched
  local f pair name prefix
  declare -A seen=()
  while IFS= read -r f; do
    for pair in $AREAS; do
      name="${pair%%=*}"; prefix="${pair#*=}"
      [[ "$f" == "$prefix"* ]] && seen[$name]=1
    done
  done
  echo "${#seen[@]}"
}

if [[ "${1:-}" == "--diff" ]]; then
  base="${2:?usage: check-complexity.sh --diff <base> [<head>]}"
  head="${3:-HEAD}"
  ref="$base"
  if ! git rev-parse --verify --quiet "refs/heads/$base" >/dev/null && git rev-parse --verify --quiet "origin/$base" >/dev/null; then
    ref="origin/$base"
  fi
  files="$(git diff --name-only "$ref...$head")"
  nfiles="$(grep -c . <<<"$files" || true)"
  lines="$(git diff --numstat "$ref...$head" | awk '{ a += ($1 == "-" ? 0 : $1); d += ($2 == "-" ? 0 : $2) } END { print a + d + 0 }')"
  echo "Actual change vs limits:"
  report "files changed" "$nfiles" "$MAX_FILES"; (( nfiles > MAX_FILES )) && over "files changed $nfiles > $MAX_FILES"
  report "lines changed" "$lines" "$MAX_EST_LINES"; (( lines > MAX_EST_LINES )) && over "lines changed $lines > $MAX_EST_LINES"
  if [[ -n "$AREAS" ]]; then
    n="$(area_count <<<"$files")"; report "areas" "$n" "$MAX_AREAS"; (( n > MAX_AREAS )) && over "areas $n > $MAX_AREAS"
  fi
else
  plan="${1:?usage: check-complexity.sh <plan.md> <brief.md> | --diff <base>}"
  brief="${2:?usage: check-complexity.sh <plan.md> <brief.md> | --diff <base>}"
  [[ -f "$plan" && -f "$brief" ]] || { echo "not found: $plan or $brief"; exit 4; }

  acs="$(grep -cE '^[[:space:]]*-[[:space:]]*AC[0-9]+' "$brief" || true)"
  tasks="$(grep -cE '^###[[:space:]]+T[0-9]+' "$plan" || true)"
  files="$(grep -E '^[[:space:]]*-[[:space:]]*(Files|Tests):' "$plan" | grep -oE '`[^`]+`' | tr -d '`' | sed -E 's/[[:space:]]*\(new\)$//; s/::.*$//' | sort -u)"
  nfiles="$(grep -c . <<<"$files" || true)"
  est="$(sed -nE 's/^[[:space:]]*(-[[:space:]]*)?Estimated lines changed:[[:space:]]*~?([0-9]+).*/\2/p' "$plan" | head -1)"
  risk="$(awk '/^##[ \t]+Risk/ { on = 1; next } /^#/ { on = 0 } on && NF { print tolower($1); exit }' "$brief" | tr -cd 'a-z')"

  [[ "$tasks" -gt 0 ]] || { echo "plan has no '### T<n>' tasks: $plan"; exit 4; }
  [[ "$acs" -gt 0 ]] || { echo "brief has no '- AC<n>' acceptance criteria: $brief"; exit 4; }
  [[ -n "$est" ]] || { echo "plan has no 'Estimated lines changed: <n>' line: $plan"; exit 4; }

  echo "Plan vs limits (scripts/factory/complexity.env):"
  report "acceptance criteria" "$acs" "$MAX_ACCEPTANCE_CRITERIA"; (( acs > MAX_ACCEPTANCE_CRITERIA )) && over "acceptance criteria $acs > $MAX_ACCEPTANCE_CRITERIA"
  report "plan tasks" "$tasks" "$MAX_PLAN_TASKS"; (( tasks > MAX_PLAN_TASKS )) && over "plan tasks $tasks > $MAX_PLAN_TASKS"
  report "files" "$nfiles" "$MAX_FILES"; (( nfiles > MAX_FILES )) && over "files $nfiles > $MAX_FILES"
  report "estimated lines" "$est" "$MAX_EST_LINES"; (( est > MAX_EST_LINES )) && over "estimated lines $est > $MAX_EST_LINES"
  if [[ -n "$AREAS" ]]; then
    n="$(area_count <<<"$files")"; report "areas" "$n" "$MAX_AREAS"; (( n > MAX_AREAS )) && over "areas $n > $MAX_AREAS"
  fi
  printf '  %-24s %6s\n' "risk" "${risk:-?}"
  for r in $SPLIT_ON_RISK; do
    if [[ "$risk" == "$r" ]] && (( tasks > 1 )); then over "risk '$risk' must be split into single-task items ($tasks tasks)"; fi
  done
fi

if [[ ${#problems[@]} -eq 0 ]]; then
  echo "RESULT: within limits"
  exit 0
fi
echo "RESULT: too complex — break it down:"
printf '  - %s\n' "${problems[@]}"
exit 6
