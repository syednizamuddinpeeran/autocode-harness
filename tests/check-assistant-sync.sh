#!/usr/bin/env bash
# Agent and skill bodies must be the same for every assistant; only the frontmatter differs.
# Lists Copilot files (.github/agents/*.agent.md, .github/skills/*/SKILL.md) and compares the body
# after the frontmatter with the Claude Code file (.claude/agents/*.md, .claude/skills/*/SKILL.md).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/template/assistant" || exit 1
# Files whose bodies are allowed to differ, with the reason.
allowed=(
  "_repo/github/.github/skills/open-pr/SKILL.md"   # Copilot cloud agent vs Claude GitHub Action PR flow
)
body() { awk 'BEGIN{n=0} /^---$/ && n<2 {n++; next} n>=2' "$1"; }
fail=0 checked=0
while IFS= read -r f; do
  rel="${f#copilot/}"
  case "$rel" in
    *.github/agents/*.agent.md) other="claude-code/${rel/.github\/agents\//.claude/agents/}"; other="${other%.agent.md}.md" ;;
    *.github/skills/*)          other="claude-code/${rel/.github\/skills\//.claude/skills/}" ;;
    *) continue ;;
  esac
  checked=$((checked + 1))
  [[ -f "$other" ]] || { echo "missing Claude counterpart: $other (for $f)"; fail=1; continue; }
  skip=0; for a in "${allowed[@]}"; do [[ "$rel" == "$a" ]] && skip=1; done
  [[ $skip -eq 1 ]] && continue
  if ! diff -q <(body "$f") <(body "$other") >/dev/null; then
    echo "body differs: $f vs $other"; diff <(body "$f") <(body "$other") | head -10; fail=1
  fi
done < <(find copilot -type f \( -name '*.agent.md' -o -name SKILL.md \) | sort)
# The repo-layer issue and task skills write into the work folder named by the prompt's
# `Work folder: <path>` line. They must not name a literal work path (.agent-work/issue-N/ or
# .agent-work/<id>/), and must stop with an error when that line is missing.
work=0
while IFS= read -r f; do
  work=$((work + 1))
  if grep -Eq '\.agent-work/(issue-|<)' "$f"; then echo "literal work path in $f (use the work folder from the prompt)"; fail=1; fi
  for phrase in 'Work folder:' 'stop with an error'; do
    grep -Fq "$phrase" "$f" || { echo "missing '$phrase' in $f"; fail=1; }
  done
done < <(find . -type f -path '*/_repo/*/*/skills/*/SKILL.md' \( -path '*/issue-intake/SKILL.md' -o -path '*/open-pr/SKILL.md' -o -path '*/task-intake/SKILL.md' -o -path '*/handoff/SKILL.md' \) | sort)
[[ $work -eq 8 ]] || { echo "expected 8 repo-layer skill files, found $work"; fail=1; }
echo "assistant sync: $checked files checked, $([[ $fail -eq 0 ]] && echo ok || echo FAILED)"
exit $fail
