#!/usr/bin/env bash
# HUMAN-ONLY: create the sub-issues of a breakdown the planner proposed, after you reviewed it.
#
#   scripts/factory/create-issues.sh .agent-work/breakdowns/issue-<N>.md     # from a local run
#   scripts/factory/create-issues.sh --from-pr <PR>       # Copilot cloud agent: draft PR description
#   scripts/factory/create-issues.sh --from-issue <N>     # Claude GitHub Action: comment on the issue
#   options: --parent <N> (default: from the breakdown title)   --yes (no prompt)
#
# Validates the breakdown (check-breakdown.sh: items ready, dependencies, no cycles, parent AC
# coverage when the brief is available), shows every item, asks for confirmation, then — with your
# gh credentials — creates the issues in dependency order, adds them to the parent as native
# sub-issues, records native "blocked by" dependencies, and comments the plan on the parent.
# Agents are denied this script by the guard.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v gh >/dev/null || { echo "Missing: gh" >&2; exit 1; }
command -v jq >/dev/null || { echo "Missing: jq" >&2; exit 1; }

src="" from_pr="" from_issue="" parent="" yes=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-pr) from_pr="${2:?--from-pr needs a number}"; shift 2 ;;
    --from-issue) from_issue="${2:?--from-issue needs a number}"; shift 2 ;;
    --parent) parent="${2:?--parent needs a number}"; shift 2 ;;
    --yes) yes=1; shift ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) src="$1"; shift ;;
  esac
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bd="$tmp/breakdown.md" brief=""
extract() { awk '/^# Breakdown of / { on = 1 } on { print }'; }   # from the title line to the end

if [[ -n "$from_pr" ]]; then
  # Copilot cloud agent: the breakdown is the description of its draft PR on a copilot/* branch.
  pr="$(gh pr view "$from_pr" --json body,headRefName,author,url)"
  head_ref="$(jq -r .headRefName <<<"$pr")"
  [[ "$head_ref" == copilot/* || "$head_ref" == agent/* ]] \
    || { echo "PR #$from_pr is on '$head_ref', not an agent branch (copilot/*, agent/*): refusing." >&2; exit 1; }
  jq -r .body <<<"$pr" | extract > "$bd"
  echo "Source: PR #$from_pr ($(jq -r .url <<<"$pr")) by $(jq -r .author.login <<<"$pr")"
elif [[ -n "$from_issue" ]]; then
  # Claude GitHub Action: the breakdown is a comment on the issue by the action's bot.
  comment="$(gh issue view "$from_issue" --json comments --jq \
    '[.comments[] | select(.body | contains("# Breakdown of ")) | select(.author.login | test("^(claude|github-actions)(\\[bot\\])?$"))] | last')"
  [[ -n "$comment" && "$comment" != "null" ]] \
    || { echo "No breakdown comment from the Claude action (claude / github-actions bot) on issue #$from_issue." >&2; exit 1; }
  jq -r .body <<<"$comment" | extract > "$bd"
  echo "Source: comment by $(jq -r .author.login <<<"$comment") on issue #$from_issue"
  parent="${parent:-$from_issue}"
else
  [[ -f "$src" ]] || { echo "usage: create-issues.sh <breakdown.md> | --from-pr <N> | --from-issue <N> [--parent <N>] [--yes]" >&2; exit 1; }
  cp "$src" "$bd"
  [[ -f "${src%.md}.brief.md" ]] && brief="${src%.md}.brief.md"
fi
[[ -s "$bd" ]] || { echo "No '# Breakdown of …' section found." >&2; exit 1; }

if [[ -z "$parent" ]]; then
  parent="$(sed -nE '1,3s/^# Breakdown of issue #([0-9]+).*/\1/p' "$bd" | head -1)"
fi
[[ "$parent" =~ ^[0-9]+$ ]] || { echo "Parent issue unknown: pass --parent <N>." >&2; exit 1; }

# Validate (with the parent brief when we have it, to check acceptance-criteria coverage).
items="$tmp/items"
if ! bash "$here/check-breakdown.sh" "$bd" ${brief:+"$brief"} --split "$items"; then
  echo "Fix the breakdown, then run again." >&2
  exit 4
fi
[[ -n "$brief" ]] || echo "(No parent brief next to the breakdown: acceptance-criteria coverage was not checked — compare with issue #$parent yourself.)"

mapfile -t order < "$items/order"
echo
echo "──────── Sub-issues of #$parent (in creation order)"
for i in "${order[@]}"; do
  echo
  echo "── Item $i"
  cat "$items/$i.md"
done
echo "────────"
if [[ -z "$yes" ]]; then
  [[ -t 0 ]] || { echo "Not a terminal: pass --yes after reviewing the breakdown." >&2; exit 1; }
  read -r -p "Create ${#order[@]} sub-issues of #$parent? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Not created."; exit 0; }
fi

declare -A num=() id=()
summary=""
for i in "${order[@]}"; do
  title="$(head -1 "$items/$i.md" | sed 's/^# //')"
  body="$tmp/body-$i.md"
  {
    echo "Parent: #$parent"
    # Body = item without its title; "Item k" references become issue numbers.
    tail -n +2 "$items/$i.md" | while IFS= read -r line; do
      if [[ "$line" == "Depends on:"* ]]; then
        for k in "${!num[@]}"; do line="$(sed -E "s/Item $k([^0-9]|$)/#${num[$k]}\\1/g" <<<"$line")"; done
      fi
      printf '%s\n' "$line"
    done
  } > "$body"
  # Only unblocked items get `agent-ready` (it starts the Claude action): label the others when their
  # blockers are merged (run-batch.sh --list shows which are ready).
  if [[ -s "$items/$i.deps" ]] || ! url="$(gh issue create --title "$title" --body-file "$body" --label agent-ready 2>/dev/null)"; then
    url="$(gh issue create --title "$title" --body-file "$body")"
  fi
  num[$i]="${url##*/}"
  id[$i]="$(gh api "repos/{owner}/{repo}/issues/${num[$i]}" --jq .id)"
  gh api -X POST "repos/{owner}/{repo}/issues/$parent/sub_issues" -F "sub_issue_id=${id[$i]}" >/dev/null \
    || echo "  (could not add #${num[$i]} as a sub-issue of #$parent; link it by hand)" >&2
  deps=""
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    deps+=" #${num[$d]}"
    gh api -X POST "repos/{owner}/{repo}/issues/${num[$i]}/dependencies/blocked_by" -F "issue_id=${id[$d]}" >/dev/null \
      || echo "  (could not record #${num[$i]} blocked by #${num[$d]}; the body still says 'Depends on')" >&2
  done < "$items/$i.deps"
  echo "Created #${num[$i]}: $title${deps:+  (blocked by$deps)}"
  summary+="- #${num[$i]} $title${deps:+ — after$deps}"$'\n'
done

gh issue comment "$parent" --body "Broken down into ${#order[@]} sub-issues (scripts/factory/create-issues.sh):
$summary
Each runs as its own factory run once the issues it is blocked by are merged." >/dev/null || true
echo
echo "Done. Run them locally in dependency order:  scripts/factory/run-batch.sh $parent [--auto-continue]"
echo "or assign the unblocked ones to the cloud agent. Only unblocked sub-issues got the agent-ready label;"
echo "add it to the others when their blockers are merged."
