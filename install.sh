#!/usr/bin/env bash
# Install the agent factory into an existing git repository.
#
#   ./install.sh <target-repo> [--repo github|local] [--os linux|wsl|windows]
#                [--assistant copilot|claude-code] [--cloud none|aws] [--force] [--keep-harness]
#
#   --repo   repository type                                            [default: github]
#              github  GitHub issue → pull request (cloud agent or local CLI, CI, branch protection)
#              local   task file → reviewed local branch, merged with accept.sh (no remote needed)
#   --os     where agents run locally                                   [default: linux]
#              linux, wsl  bash hooks and scripts (also what the cloud agent uses)
#              windows     adds PowerShell 7 hooks and scripts (*.ps1); bash ones stay for the cloud agent
#   --assistant  coding assistant that runs the agents                  [default: copilot]
#              copilot      GitHub Copilot (cloud agent + Copilot CLI): .github/agents, skills, hooks
#              claude-code  Claude Code (CLI + GitHub Action): .claude/agents, skills, settings.json
#   --cloud  where the project deploys                                  [default: none]
#              aws   deny AWS credential use and deploys; deploy-from-CI workflow (GitHub repos)
#   --force  overwrite files that already exist in the target
#   --keep-harness  the target already has its own agent harness (e.g. this template repo): install
#            the factory but never write .github/hooks/, .github/workflows/, .claude/settings.json,
#            AGENTS.md, CLAUDE.md or the hook self-test (test-hooks, hook-cases.txt), not even with
#            --force. The template's versions that are new or differ go to .agent-work/harness/
#            for a person to review and merge by hand.
#
# The template is built from layers under template/, applied in order:
#   core → repo/<type> → os/<os> → assistant/<assistant> → cloud/<cloud>
# A later layer's file replaces an earlier one at the same path, except files ending in
# ".append", which are appended to the file of the same name without the suffix.
# A layer's _repo/<type>/ and _os/<os>/ folders are applied right after it, only for that repo type / OS.
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

dst="" repo="github" os="linux" assistant="copilot" cloud="none" force=0 keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   repo="${2:?--repo needs a value}"; shift 2 ;;
    --repo=*) repo="${1#*=}"; shift ;;
    --os)     os="${2:?--os needs a value}"; shift 2 ;;
    --os=*)   os="${1#*=}"; shift ;;
    --assistant)   assistant="${2:?--assistant needs a value}"; shift 2 ;;
    --assistant=*) assistant="${1#*=}"; shift ;;
    --cloud)   cloud="${2:?--cloud needs a value}"; shift 2 ;;
    --cloud=*) cloud="${1#*=}"; shift ;;
    --force)  force=1; shift ;;
    --keep-harness) keep=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *)  [[ -z "$dst" ]] || { echo "Only one target allowed" >&2; usage 1; }; dst="$1"; shift ;;
  esac
done
[[ -n "$dst" ]] || usage 1
[[ -d "$dst/.git" ]] || { echo "$dst is not a git repository" >&2; exit 1; }

case "$os" in linux|wsl|windows) ;; *) echo "Unknown --os: $os (linux, wsl, windows)" >&2; exit 1 ;; esac
[[ -d "$src/template/repo/$repo" && "$repo" != _* ]] || { echo "Unknown --repo: $repo ($(ls "$src/template/repo" | tr '\n' ' '))" >&2; exit 1; }
[[ "$cloud" == none || ( -d "$src/template/cloud/$cloud" && "$cloud" != _* ) ]] || { echo "Unknown --cloud: $cloud (none $(ls "$src/template/cloud" | tr '\n' ' '))" >&2; exit 1; }
[[ -d "$src/template/assistant/$assistant" && "$assistant" != _* ]] || { echo "Unknown --assistant: $assistant ($(ls "$src/template/assistant" | tr '\n' ' '))" >&2; exit 1; }

# Layers in order; missing optional layers (e.g. os/linux) are skipped.
layers=()
for l in core "repo/$repo" "os/$os" "assistant/$assistant" "cloud/$cloud"; do
  [[ -d "$src/template/$l" ]] || continue
  layers+=("$l")
  for sub in "_repo/$repo" "_os/$os"; do
    [[ -d "$src/template/$l/$sub" ]] && layers+=("$l/$sub")
  done
done

# Compose the layers into a staging tree.
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
for l in "${layers[@]}"; do
  (cd "$src/template/$l" && find . -path './_*' -prune -o -type f -print0) | while IFS= read -r -d '' f; do
    f="${f#./}"
    if [[ "$f" == *.append ]]; then
      t="${f%.append}"
      [[ -f "$stage/$t" ]] || { echo "template/$l/$f has no base file $t" >&2; exit 1; }
      cat "$src/template/$l/$f" >> "$stage/$t"
    else
      mkdir -p "$stage/$(dirname "$f")"
      cp "$src/template/$l/$f" "$stage/$f"
    fi
  done
done

# The target's own harness, which --keep-harness never writes.
is_harness() {
  case "$1" in
    .github/hooks/*|.github/workflows/*|.claude/settings.json|AGENTS.md|CLAUDE.md) return 0 ;;
    scripts/factory/test-hooks.sh|scripts/factory/test-hooks.ps1|scripts/factory/hook-cases.txt) return 0 ;;
  esac
  return 1
}

# Copy into the target.
kept=0
while IFS= read -r f; do
  f="${f#./}"
  if [[ $keep -eq 1 ]] && is_harness "$f"; then
    [[ -e "$dst/$f" ]] && cmp -s "$stage/$f" "$dst/$f" && continue
    state="new"; [[ -e "$dst/$f" ]] && state="differs"
    mkdir -p "$dst/.agent-work/harness/$(dirname "$f")"
    cp "$stage/$f" "$dst/.agent-work/harness/$f"
    echo "kept harness ($state): $f"; kept=$((kept + 1)); continue
  fi
  if [[ -e "$dst/$f" && $force -eq 0 ]]; then
    echo "skip (exists): $f"; continue
  fi
  mkdir -p "$dst/$(dirname "$f")"
  cp "$stage/$f" "$dst/$f"
  echo "added: $f"
done < <(cd "$stage" && find . -type f -print | sort)

gi="$dst/.gitignore"
# Make sure the last existing line ends with a newline before appending.
[[ -s "$gi" && -n "$(tail -c1 "$gi")" ]] && echo >> "$gi"
for line in ".agent-logs/" ".agent-work/"; do
  grep -qxF "$line" "$gi" 2>/dev/null || echo "$line" >> "$gi"
done
chmod +x "$dst"/.github/hooks/scripts/*.sh "$dst"/scripts/factory/*.sh 2>/dev/null || true

echo
echo "Installed: repo=$repo os=$os assistant=$assistant cloud=$cloud"
if [[ $keep -eq 1 ]]; then
  echo "Kept your harness: $kept template file(s) not installed; they are under $dst/.agent-work/harness/."
  echo "A person reviews them and merges what the factory needs by hand, in particular:"
  echo "  - the stop gate: .github/hooks/scripts/stop-gate.* and its Stop / agentStop hook entry"
  echo "  - the factory's policy lines (protect scripts/factory/check*, commands.env, complexity.env;"
  echo "    deny new-draft / create-issues / run-batch) in .github/hooks/policy/"
  echo "  - the Project section of AGENTS.md, and any workflows you want"
  echo "Then edit $dst/scripts/factory/commands.env and run your own hook tests and scripts/factory/check.*"
else
  echo "Next: edit $dst/scripts/factory/commands.env and the Project section of $dst/AGENTS.md,"
  if [[ "$os" == "windows" ]]; then
    echo "then run: (cd $dst; pwsh scripts/factory/test-hooks.ps1; pwsh scripts/factory/check.ps1)"
  else
    echo "then run: (cd $dst && bash scripts/factory/test-hooks.sh && bash scripts/factory/check.sh)"
  fi
fi
if [[ "$repo" == "local" ]]; then
  echo "Then commit, write a task from tasks/_template.md, commit it, and run scripts/factory/run-task.sh <id>."
fi
