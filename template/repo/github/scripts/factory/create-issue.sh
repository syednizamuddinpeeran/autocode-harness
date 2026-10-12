#!/usr/bin/env bash
# HUMAN-ONLY: create GitHub issues from reviewed drafts (from new-draft.sh, or written by hand).
#
#   scripts/factory/create-issue.sh .agent-work/drafts/<id>.md          # preview, confirm, create
#   scripts/factory/create-issue.sh .agent-work/drafts/<id>.md --yes    # no prompt (you reviewed it)
#   scripts/factory/create-issue.sh --draft .agent-work/drafts/*.md     # many at once, review on GitHub
#
# --draft: no prompt; each issue gets the `agent-draft` label instead of `agent-ready`. Review and edit
# the issues on GitHub, then add `agent-ready` to the ones you approve (that starts the factory).
#
# Refuses a draft that is not ready (check-ready.sh): missing sections, placeholders, OPEN items.
# Every draft is validated before any issue is created.
# Runs `gh issue create` with your credentials; agents are denied this script by the guard.
set -euo pipefail
command -v gh >/dev/null || { echo "Missing: gh" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

drafts=() yes="" as_draft=""
for a in "$@"; do
  case "$a" in
    --yes) yes=1 ;;
    --draft) as_draft=1 ;;
    -*) echo "unknown option: $a" >&2; exit 1 ;;
    *) drafts+=("$a") ;;
  esac
done
[[ ${#drafts[@]} -gt 0 ]] || { echo "usage: create-issue.sh [--draft] [--yes] <draft.md>..." >&2; exit 1; }

title_of() { sed -n 's/^# \(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$1" | head -1; }

for draft in "${drafts[@]}"; do
  [[ -f "$draft" ]] || { echo "not found: $draft" >&2; exit 1; }
  bash "$here/check-ready.sh" "$draft" || { echo "Fix $draft, then run again." >&2; exit 4; }
  title="$(title_of "$draft")"
  [[ -n "$title" && "$title" != *"<"* ]] || { echo "$draft needs a title line: '# <short imperative title>'" >&2; exit 4; }
done

label="agent-ready"
if [[ -n "$as_draft" ]]; then
  label="agent-draft"
  gh label create agent-draft --description "Drafted by the factory; review, then add agent-ready" --color FBCA04 >/dev/null 2>&1 || true
fi

body="$(mktemp)"; trap 'rm -f "$body"' EXIT
for draft in "${drafts[@]}"; do
  title="$(title_of "$draft")"
  # Body = everything after the title line.
  awk 'found { print } /^# / && !found { found = 1 }' "$draft" > "$body"

  if [[ -z "$as_draft" ]]; then
    echo "──────── Title: $title"
    cat "$body"
    echo "────────"
    if [[ -z "$yes" ]]; then
      [[ -t 0 ]] || { echo "Not a terminal: pass --yes after reviewing the draft." >&2; exit 1; }
      read -r -p "Create this issue? [y/N] " ans
      [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Not created."; continue; }
    fi
  fi

  if ! url="$(gh issue create --title "$title" --body-file "$body" --label "$label" 2>/dev/null)"; then
    echo "(label '$label' not found; creating without it)" >&2
    url="$(gh issue create --title "$title" --body-file "$body")"
  fi
  echo "Created: $url"
  [[ -n "$as_draft" ]] || echo "Run it locally with:  scripts/factory/run-issue.sh ${url##*/}   (or assign it to the cloud agent)"
done
[[ -z "$as_draft" ]] || echo "Review the issues on GitHub, then add the agent-ready label to the ones you approve."
