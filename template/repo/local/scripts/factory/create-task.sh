#!/usr/bin/env bash
# HUMAN-ONLY: create tasks/<id>.md from a reviewed draft (from new-draft.sh, or written by hand) and
# commit it on the base branch.
#
#   scripts/factory/create-task.sh .agent-work/drafts/<id>.md                 # id from the file name
#   scripts/factory/create-task.sh .agent-work/drafts/<id>.md --id other-id
#   scripts/factory/create-task.sh .agent-work/drafts/<id>.md --yes           # no prompt
#
# Refuses a draft that is not ready (check-ready.sh): missing sections, placeholders, OPEN items.
# Agents are denied this script by the guard, and tasks/ is write-protected for them.
set -euo pipefail
draft="${1:?usage: create-task.sh <draft.md> [--id <slug>] [--yes]}"
shift
id="" yes=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) id="${2:?--id needs a value}"; shift 2 ;;
    --yes) yes=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -f "$draft" ]] || { echo "not found: $draft" >&2; exit 1; }
draft="$(cd "$(dirname "$draft")" && pwd)/$(basename "$draft")"

root="$(git rev-parse --show-toplevel)"
cd "$root"
# shellcheck disable=SC1091
source scripts/factory/commands.env
base="${BASE_BRANCH:-main}"

bash scripts/factory/check-ready.sh "$draft" || { echo "Fix the draft, then run again." >&2; exit 4; }
[[ -n "$id" ]] || id="$(basename "$draft" .md)"
[[ "$id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "task id must be a lowercase slug: $id" >&2; exit 1; }
[[ "$(git branch --show-current)" == "$base" ]] || { echo "Check out '$base' first." >&2; exit 1; }
[[ -z "$(git status --porcelain -- tasks)" ]] || { echo "tasks/ has uncommitted changes; commit or stash them first." >&2; exit 1; }
[[ ! -e "tasks/$id.md" ]] || { echo "tasks/$id.md already exists. Pick another --id." >&2; exit 1; }

echo "──────── tasks/$id.md"
cat "$draft"
echo "────────"
if [[ -z "$yes" ]]; then
  [[ -t 0 ]] || { echo "Not a terminal: pass --yes after reviewing the draft." >&2; exit 1; }
  read -r -p "Create and commit tasks/$id.md on '$base'? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Not created."; exit 0; }
fi
mkdir -p tasks
cp "$draft" "tasks/$id.md"
git add "tasks/$id.md"
git commit -q -m "task: $id" -- "tasks/$id.md"
echo "Committed tasks/$id.md on '$base'."
# Record the result beside the draft, but only for a draft.md that new-draft.sh made in its own folder.
if [[ "$(basename "$draft")" == "draft.md" ]]; then
  printf 'task=%s\npath=tasks/%s.md\n' "$id" "$id" > "$(dirname "$draft")/created.txt"
fi
echo "Run it with:  scripts/factory/run-task.sh $id"
