#!/usr/bin/env bash
# HUMAN-ONLY: create a GitHub issue from a reviewed draft (from new-draft.sh, or written by hand).
#
#   scripts/factory/create-issue.sh .agent-work/drafts/<id>.md          # preview, confirm, create
#   scripts/factory/create-issue.sh .agent-work/drafts/<id>.md --yes    # no prompt (you reviewed it)
#
# Refuses a draft that is not ready (check-ready.sh): missing sections, placeholders, OPEN items.
# Runs `gh issue create` with your credentials; agents are denied this script by the guard.
set -euo pipefail
draft="${1:?usage: create-issue.sh <draft.md> [--yes]}"
yes="${2:-}"
[[ -f "$draft" ]] || { echo "not found: $draft" >&2; exit 1; }
command -v gh >/dev/null || { echo "Missing: gh" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$here/check-ready.sh" "$draft" || { echo "Fix the draft, then run again." >&2; exit 4; }

title="$(sed -n 's/^# \(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$draft" | head -1)"
[[ -n "$title" && "$title" != *"<"* ]] || { echo "The draft needs a title line: '# <short imperative title>'" >&2; exit 4; }
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
# Body = everything after the title line.
awk 'found { print } /^# / && !found { found = 1 }' "$draft" > "$body"

echo "──────── Title: $title"
cat "$body"
echo "────────"
if [[ "$yes" != "--yes" ]]; then
  [[ -t 0 ]] || { echo "Not a terminal: pass --yes after reviewing the draft." >&2; exit 1; }
  read -r -p "Create this issue? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Not created."; exit 0; }
fi

if ! url="$(gh issue create --title "$title" --body-file "$body" --label agent-ready 2>/dev/null)"; then
  echo "(label 'agent-ready' not found; creating without it)" >&2
  url="$(gh issue create --title "$title" --body-file "$body")"
fi
echo "Created: $url"
echo "Run it locally with:  scripts/factory/run-issue.sh ${url##*/}   (or assign it to the cloud agent)"
