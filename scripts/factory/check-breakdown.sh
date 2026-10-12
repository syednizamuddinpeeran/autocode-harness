#!/usr/bin/env bash
# Validate a breakdown proposed by the planner (format: the `breakdown` skill). Deterministic.
#
#   bash scripts/factory/check-breakdown.sh <breakdown.md> [brief.md] [--split <dir>]
#     exit 0 valid, 4 invalid (reasons on stdout)
#
# Checks: 1..MAX_SUBITEMS items numbered "## Item <n>: <title>" in order; every item is ready
# (check-ready.sh: Goal, Acceptance criteria, Out of scope, Risk; no OPEN); "Depends on:" names only
# other existing items and has no cycles; "Covers:" lists acceptance criteria ids, and — when the
# parent brief is given — every parent AC is covered by some item and no unknown AC is cited.
# --split <dir> writes <dir>/<n>.md (title line + item body), <dir>/<n>.deps (item numbers it
# depends on) and <dir>/order (items in dependency order).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/complexity.env"

bd="" brief="" split=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --split) split="${2:?--split needs a directory}"; shift 2 ;;
    *) if [[ -z "$bd" ]]; then bd="$1"; else brief="$1"; fi; shift ;;
  esac
done
[[ -f "$bd" ]] || { echo "usage: check-breakdown.sh <breakdown.md> [brief.md] [--split <dir>]"; exit 4; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
problems=()

# Split into items.
awk -v dir="$work" '
  /^## Item [0-9]+:/ { n++; f = dir "/" n ".md"; t = $0; sub(/^## Item [0-9]+:[ \t]*/, "", t)
                       num = $3; sub(/:$/, "", num); print num > (dir "/" n ".num")
                       print "# " t > f; print "" >> f; next }
  /^## / { f = "" }
  f { print >> f }
' "$bd"
n="$(find "$work" -name '*.md' | wc -l | tr -d ' ')"

if [[ "$n" -eq 0 ]]; then
  echo "No items found: expected '## Item 1: <title>' sections in $bd"
  exit 4
fi
(( n > MAX_SUBITEMS )) && problems+=("$n items > MAX_SUBITEMS $MAX_SUBITEMS: merge or drop items")

for ((i = 1; i <= n; i++)); do
  [[ "$(cat "$work/$i.num")" == "$i" ]] || problems+=("items must be numbered 1..$n in order (found Item $(cat "$work/$i.num") at position $i)")
  title="$(head -1 "$work/$i.md" | sed 's/^# //')"
  [[ -n "$title" && "$title" != *"<"* ]] || problems+=("Item $i: needs a title")
  if ! out="$(bash "$here/check-ready.sh" "$work/$i.md")"; then
    while IFS= read -r l; do problems+=("Item $i: ${l#  - }"); done < <(tail -n +2 <<<"$out")
  fi
  deps="$(sed -nE 's/^Depends on:[[:space:]]*(.*)$/\1/p' "$work/$i.md" | head -1)"
  [[ -n "$deps" ]] || problems+=("Item $i: missing 'Depends on:' line (write 'none' if independent)")
  : > "$work/$i.deps"
  if [[ -n "$deps" && ! "$deps" =~ ^[Nn]one ]]; then
    for d in $(grep -oE '[0-9]+' <<<"$deps"); do
      if (( d < 1 || d > n )); then problems+=("Item $i: depends on Item $d, which does not exist")
      elif (( d == i )); then problems+=("Item $i: depends on itself")
      else echo "$d" >> "$work/$i.deps"; fi
    done
  fi
  covers="$(sed -nE 's/^Covers:[[:space:]]*(.*)$/\1/p' "$work/$i.md" | head -1)"
  grep -qE 'AC[0-9]+' <<<"$covers" || problems+=("Item $i: missing 'Covers: AC<n>, …' line (which parent acceptance criteria it delivers)")
  grep -oE 'AC[0-9]+' <<<"$covers" >> "$work/covered"
done

# Dependency order (Kahn); leftovers mean a cycle.
order=()
declare -A placed=()
for ((round = 0; round < n; round++)); do
  progressed=0
  for ((i = 1; i <= n; i++)); do
    [[ -n "${placed[$i]:-}" ]] && continue
    ready=1
    while IFS= read -r d; do [[ -n "$d" && -z "${placed[$d]:-}" ]] && ready=0; done < "$work/$i.deps"
    if [[ $ready -eq 1 ]]; then order+=("$i"); placed[$i]=1; progressed=1; fi
  done
  [[ $progressed -eq 0 ]] && break
done
(( ${#order[@]} == n )) || problems+=("dependency cycle between items: $(for ((i = 1; i <= n; i++)); do [[ -z "${placed[$i]:-}" ]] && printf '%s ' "$i"; done)")

# Parent acceptance criteria coverage.
if [[ -n "$brief" ]]; then
  [[ -f "$brief" ]] || { echo "brief not found: $brief"; exit 4; }
  parent="$(grep -oE '^[[:space:]]*-[[:space:]]*AC[0-9]+' "$brief" | grep -oE 'AC[0-9]+' | sort -u)"
  covered="$(sort -u "$work/covered" 2>/dev/null)"
  missing="$(comm -23 <(echo "$parent") <(echo "$covered") | tr '\n' ' ')"
  unknown="$(comm -13 <(echo "$parent") <(echo "$covered") | tr '\n' ' ')"
  [[ -z "${missing// /}" ]] || problems+=("parent acceptance criteria not covered by any item: $missing")
  [[ -z "${unknown// /}" ]] || problems+=("items cite acceptance criteria the parent does not have: $unknown")
fi

if [[ ${#problems[@]} -gt 0 ]]; then
  echo "Breakdown is not valid ($bd):"
  printf '  - %s\n' "${problems[@]}"
  exit 4
fi
if [[ -n "$split" ]]; then
  mkdir -p "$split"
  for ((i = 1; i <= n; i++)); do cp "$work/$i.md" "$split/$i.md"; cp "$work/$i.deps" "$split/$i.deps"; done
  printf '%s\n' "${order[@]}" > "$split/order"
fi
echo "valid: $n items, order: ${order[*]}"
exit 0
