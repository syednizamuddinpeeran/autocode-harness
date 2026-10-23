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
# A rerun on the same breakdown is safe: sub-issues already there are reused by title. Each GitHub call is
# retried like run-batch.sh does (BATCH_GH_RETRIES, default 3; BATCH_GH_RETRY_SECONDS, default 5).
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
# gh with retries, like gh_api in run-batch.sh: a failed call is tried again up to BATCH_GH_RETRIES times
# (default 3), BATCH_GH_RETRY_SECONDS apart (default 5). Prints the reply. When retries run out it returns 1
# and names the call that gave up. An "already linked" / "already recorded" reply is the state we want: done.
# gh_try <recheck> <gh args…>: recheck is "-" for none. Otherwise it runs before every attempt and returns
# 0 with $found set when the item already exists (the call is not repeated), 1 when it does not, 2 when the
# lookup itself failed (no call is made on that try).
gh_try() {
  local recheck="$1" out i rc attempt tries="${BATCH_GH_RETRIES:-3}" err="$tmp/gh-err"
  shift
  for (( i = 0; ; i++ )); do
    attempt=1
    if [[ "$recheck" != - ]]; then
      rc=0; "$recheck" || rc=$?
      (( rc == 0 )) && { printf '%s\n' "$found"; return 0; }
      (( rc == 1 )) || attempt=0
    fi
    if (( attempt )); then
      if out="$(gh "$@" 2>"$err")"; then
        [[ -z "$out" ]] || printf '%s\n' "$out"
        return 0
      fi
      grep -qi already "$err" && return 0
    fi
    if (( i >= tries )); then
      echo "GitHub call failed $((i + 1)) times, giving up: gh $*" >&2
      return 1
    fi
    echo "GitHub call failed, retrying in ${BATCH_GH_RETRY_SECONDS:-5}s ($((i + 1))/$tries): gh $*" >&2
    sleep "${BATCH_GH_RETRY_SECONDS:-5}"
  done
}
# gh_try recheck for an issue create: is the title already under the parent (its sub-issues, all states), or is
# it an issue of this breakdown ("Parent: #N" as its first body line) that an earlier attempt created whose link
# never ran? A create that succeeded on the server but lost its reply is in neither list yet. Sets $found.
find_item() {
  local list search
  found=""
  list="$(gh_try - api "repos/{owner}/{repo}/issues/$parent/sub_issues" --paginate --jq '.[] | "\(.number)\t\(.title)"')" || return 2
  found="$(TITLE="$title" awk -F'\t' '$2 == ENVIRON["TITLE"] { print $1; exit }' <<<"$list")"
  if [[ -z "$found" ]]; then
    search="$(gh_try - issue list --state all --limit 100 --search "in:title \"$title\"" --json number,title,body)" || return 2
    found="$(jq -r --arg t "$title" --arg p "Parent: #$parent" \
      '[.[] | select(.title == $t and (((.body // "") | split("\n")[0]) == $p))] | .[0].number // empty' <<<"$search")"
  fi
  [[ -n "$found" ]]
}
# Nothing is lost by stopping here: a rerun on the same breakdown picks up where this one stopped.
give_up() { echo "Nothing is duplicated: run create-issues.sh again on this breakdown to continue." >&2; exit 1; }

if [[ -n "$from_pr" ]]; then
  # Copilot cloud agent: the breakdown is the description of its draft PR on a copilot/* branch.
  pr="$(gh_try - pr view "$from_pr" --json body,headRefName,author,url)" || exit 1
  head_ref="$(jq -r .headRefName <<<"$pr")"
  [[ "$head_ref" == copilot/* || "$head_ref" == agent/* ]] \
    || { echo "PR #$from_pr is on '$head_ref', not an agent branch (copilot/*, agent/*): refusing." >&2; exit 1; }
  jq -r .body <<<"$pr" | extract > "$bd"
  echo "Source: PR #$from_pr ($(jq -r .url <<<"$pr")) by $(jq -r .author.login <<<"$pr")"
elif [[ -n "$from_issue" ]]; then
  # Claude GitHub Action: the breakdown is a comment on the issue by the action's bot.
  comment="$(gh_try - issue view "$from_issue" --json comments --jq \
    '[.comments[] | select(.body | contains("# Breakdown of ")) | select(.author.login | test("^(claude|github-actions)(\\[bot\\])?$"))] | last')" || exit 1
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
# A rerun matches sub-issues by exact title, so two items with one title would be ambiguous: refuse.
dup="$(for i in "${order[@]}"; do head -1 "$items/$i.md" | sed 's/^# //'; done | sort | uniq -d | sed -n 1p)"
[[ -z "$dup" ]] || { echo "Two items of the breakdown have the title \"$dup\": rename one, then run again." >&2; exit 1; }
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
# Sub-issues already under the parent, one "<number><TAB><title>" per line (all states, as run-batch.sh lists them).
subs="$tmp/subs"
gh_try - api "repos/{owner}/{repo}/issues/$parent/sub_issues" --paginate --jq '.[] | "\(.number)\t\(.title)"' > "$subs" || exit 1
# Number of the sub-issue of the parent with exactly this title, if an earlier run created it.
existing_sub() {
  local n t
  while IFS=$'\t' read -r n t; do [[ "$t" == "$1" ]] && { echo "$n"; return 0; }; done < "$subs"
  return 0
}
for i in "${order[@]}"; do
  title="$(head -1 "$items/$i.md" | sed 's/^# //')"
  reused="$(existing_sub "$title")"
  verb=Created
  if [[ -n "$reused" ]]; then
    # An earlier run stopped after creating it: keep it, and still link it and record its dependencies.
    num[$i]="$reused" verb=Reused
  else
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
    # Every attempt first looks for the title (find_item), so a labelled create that lost its reply is not repeated
    # by the unlabelled one that follows it.
    if [[ -s "$items/$i.deps" ]] || ! url="$(gh_try find_item issue create --title "$title" --body-file "$body" --label agent-ready)"; then
      url="$(gh_try find_item issue create --title "$title" --body-file "$body")" || give_up
    fi
    num[$i]="${url##*/}"
  fi
  id[$i]="$(gh_try - api "repos/{owner}/{repo}/issues/${num[$i]}" --jq .id)" || give_up
  # "Already linked" / "already recorded" means an earlier run did this step: gh_try counts it as done.
  gh_try - api -X POST "repos/{owner}/{repo}/issues/$parent/sub_issues" -F "sub_issue_id=${id[$i]}" >/dev/null || give_up
  deps=""
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    deps+=" #${num[$d]}"
    gh_try - api -X POST "repos/{owner}/{repo}/issues/${num[$i]}/dependencies/blocked_by" -F "issue_id=${id[$d]}" >/dev/null || give_up
  done < "$items/$i.deps"
  echo "$verb #${num[$i]}: $title${deps:+  (blocked by$deps)}"
  summary+="- #${num[$i]} $title${deps:+ — after$deps}"$'\n'
done

gh_try - issue comment "$parent" --body "Broken down into ${#order[@]} sub-issues (scripts/factory/create-issues.sh):
$summary
Each runs as its own factory run once the issues it is blocked by are merged." >/dev/null || give_up
echo
echo "Done. Run them locally in dependency order:  scripts/factory/run-batch.sh $parent [--auto-continue]"
echo "or assign the unblocked ones to the cloud agent. Only unblocked sub-issues got the agent-ready label;"
echo "add it to the others when their blockers are merged."
