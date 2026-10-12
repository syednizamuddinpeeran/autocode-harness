#!/usr/bin/env bash
# Turn a short brief into a complete issue / task draft, with you in control.
#
#   scripts/factory/new-draft.sh "add CSV export to the reports page"
#   scripts/factory/new-draft.sh --id csv-export "add CSV export to the reports page"
#
# Starts an interactive session with the `analyst` agent. It asks you questions — goal, testable
# acceptance criteria, edge cases, out of scope, data/security, risk — and writes only what you
# answer; anything you leave unanswered is marked OPEN. It never changes code or creates anything.
#
# Result: .agent-work/drafts/<id>.md. Review and edit it, then create it yourself:
#   GitHub repos:  scripts/factory/create-issue.sh .agent-work/drafts/<id>.md
#   Local repos:   scripts/factory/create-task.sh  .agent-work/drafts/<id>.md
#
# The session runs in a throwaway git worktree, so the agent cannot touch your checkout.
set -euo pipefail

id=""
if [[ "${1:-}" == "--id" ]]; then id="${2:?--id needs a value}"; shift 2; fi
brief="${1:-}"
if [[ -z "$brief" ]]; then
  echo "usage: new-draft.sh [--id <slug>] \"<short brief of what you want>\"" >&2
  exit 2
fi
[[ -t 0 && -t 1 ]] || { echo "new-draft.sh is interactive: run it in a terminal." >&2; exit 2; }

root="$(git rev-parse --show-toplevel)"
cd "$root"
# shellcheck disable=SC1091
source scripts/factory/commands.env
base="${BASE_BRANCH:-main}"
repo_name="$(basename "$root")"

[[ -n "$id" ]] || id="$(tr '[:upper:]' '[:lower:]' <<<"$brief" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 | sed -E 's/-+$//')"
[[ "$id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "draft id must be a lowercase slug: $id" >&2; exit 1; }
out_dir="$root/.agent-work/drafts"
out="$out_dir/$id.md"
mkdir -p "$out_dir"
if [[ -e "$out" ]]; then
  echo "A draft already exists: $out — the analyst will continue from it."
fi

# Throwaway worktree at the base branch (detached): hooks and guard apply, your checkout is untouched.
wt="${FACTORY_WORKTREE_ROOT:-$(dirname "$root")/${repo_name}-worktrees}/draft-${id}"
ref="$base"; git rev-parse --verify --quiet "origin/$base" >/dev/null && ref="origin/$base"
[[ -d "$wt" ]] || git worktree add --detach -q "$wt" "$ref"
cleanup() { git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cd "$wt"
bash scripts/factory/setup.sh >/dev/null
draft=".agent-work/draft.md"
cont=""
if [[ -e "$out" ]]; then
  cp "$out" "$draft"
  cont=" (it already contains an earlier draft: continue from it, keep their answers)"
fi

prompt="Brief from the human: \"${brief}\"
Help them turn it into a complete issue/task by asking questions (your analyst workflow). Write the
draft to ${draft}${cont}. Ask your first question now."

# shellcheck source=agent-cli.sh
source scripts/factory/agent-cli.sh
agent_chat analyst "$prompt" || true

if [[ ! -s "$draft" ]]; then
  echo "No draft was written." >&2
  exit 1
fi
cp "$draft" "$out"
echo
echo "Draft saved: $out"
echo
bash scripts/factory/check-ready.sh "$out" || true
echo
if [[ -f scripts/factory/create-issue.sh ]]; then
  echo "Review and edit it, then create the issue:  scripts/factory/create-issue.sh $out"
else
  echo "Review and edit it, then create the task:   scripts/factory/create-task.sh $out"
fi
