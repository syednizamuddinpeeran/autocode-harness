#!/usr/bin/env bash
# Self-test for this repository's own guard (.github/hooks/, not the template's).
# Runs every case in .github/hooks/hook-cases.txt, in Copilot and Claude Code payload shapes, in a
# throwaway clone of the harness files on an agent branch.
set -uo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p .github && cp -r "$src/.github/hooks" .github/
git add -A && git commit -qm init && git checkout -qb claude/test
export FACTORY_LOG_DIR="$tmp/logs"

pass=0 fail=0
guard=(bash .github/hooks/scripts/guard.sh)
run() { # run <want> <desc> <payload>
  local out rc got
  out="$("${guard[@]}" <<<"$3" 2>/dev/null)"; rc=$?
  if [[ $rc -ne 0 || "$(jq -r '.permissionDecision // .hookSpecificOutput.permissionDecision // "allow"' <<<"${out:-{\}}")" == deny ]]; then got=deny; else got=allow; fi
  if [[ "$got" == "$1" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL [$fmt] $2: want $1, got $got"; fi
}
payload() { # payload <kind> <arg>
  if [[ "$1" == sh ]]; then
    if [[ "$fmt" == claude ]]; then jq -nc --arg c "$2" '{session_id:"t",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}'
    else jq -nc --arg c "$2" '{sessionId:"t",toolName:"bash",toolArgs:{command:$c}}'; fi
  else
    local t; case "$1" in view) t=Read ;; create) t=Write ;; *) t=Edit ;; esac
    if [[ "$fmt" == claude ]]; then jq -nc --arg t "$t" --arg p "$2" '{session_id:"t",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p}}'
    else jq -nc --arg t "$1" --arg p "$2" '{sessionId:"t",toolName:$t,toolArgs:{path:$p}}'; fi
  fi
}
# cases <desc-prefix>: every case in hook-cases.txt, in both payload shapes. Directives:
#   @checkout <branch>   switch the throwaway repo's branch ("-" = back to claude/test)
#   @worktree <branch>   add a second worktree (under .agent-work/) on <branch>, created if missing
# In arguments, {branch} is the agent branch, {worktree} the last @worktree's path, \n a newline.
cases() {
  local line want kind desc arg b worktree=""
  for fmt in copilot claude; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      if [[ "$line" =~ ^@checkout[[:space:]]+(.+)$ ]]; then
        b="${BASH_REMATCH[1]}"; [[ "$b" == "-" ]] && b=claude/test
        git checkout -q "$b"; continue
      fi
      if [[ "$line" =~ ^@worktree[[:space:]]+(.+)$ ]]; then
        b="${BASH_REMATCH[1]}"; worktree=".agent-work/wt-${b//\//-}"
        if [[ ! -d "$worktree" ]]; then
          git rev-parse -q --verify "refs/heads/$b" >/dev/null || git branch -q "$b"
          git worktree add -q "$worktree" "$b"
        fi
        continue
      fi
      read -r want kind _ <<<"$line"
      desc="$1$(sed -E 's/^[a-z]+[[:space:]]+[a-z]+[[:space:]]+//; s/[[:space:]]*::.*$//' <<<"$line")"
      arg="${line#*:: }"; arg="${arg//\{branch\}/claude/test}"; arg="${arg//\{worktree\}/$worktree}"
      arg="${arg//\\n/$'\n'}"
      run "$want" "$desc" "$(payload "$kind" "$arg")"
    done < .github/hooks/hook-cases.txt
    git checkout -q claude/test
  done
}
cases ""
# The PowerShell guard (Windows) must decide the same, when pwsh is available.
if command -v pwsh >/dev/null; then
  guard=(pwsh -NoProfile -File .github/hooks/scripts/guard.ps1)
  cases "ps1: "
  guard=(bash .github/hooks/scripts/guard.sh)
else
  echo "(pwsh not found: PowerShell guard not tested)"
fi
# Pushing is refused on main itself.
git checkout -q main; fmt=claude
run deny "push from main" "$(payload sh 'git push -u origin HEAD')"
# The hook configs are valid JSON.
for f in "$src/.github/hooks/repo-harness.json" "$src/.claude/settings.json"; do
  jq -e . "$f" >/dev/null || { echo "FAIL invalid JSON: $f"; fail=$((fail + 1)); }
done
echo "repo harness self-test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
