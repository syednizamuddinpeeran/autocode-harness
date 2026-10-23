#!/usr/bin/env bash
# Self-test for the guard and stop-gate hooks. Runs in a throwaway git repo.
#   bash scripts/factory/test-hooks.sh
set -uo pipefail
src="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p .github scripts
cp -r "$src/.github/hooks" .github/
cp -r "$src/scripts/factory" scripts/
printf '.agent-logs/\n.agent-work/\n' > .gitignore
# Neutral config: the self-test must not run the project's real checks in this throwaway repo.
printf 'BASE_BRANCH="main"\nSETUP_CMD=""\nFORMAT_CHECK_CMD=""\nLINT_CMD=""\nTYPECHECK_CMD=""\nTEST_CMD=""\nBUILD_CMD=""\nALLOW_NO_CHECKS=0\n' > scripts/factory/commands.env
git add -A && git commit -qm init
git checkout -qb agent/test-1

pass=0; fail=0
expect() { # expect <allow|deny> <description> <payload-json>
  local want="$1" desc="$2" out got
  out="$(bash .github/hooks/scripts/guard.sh <<<"$3" 2>/dev/null)"; rc=$?
  if [[ $rc -ne 0 ]]; then got="deny"
  elif [[ "$(jq -r '.permissionDecision // .hookSpecificOutput.permissionDecision // "allow"' <<<"${out:-{\}}")" == "deny" ]]; then got="deny"
  else got="allow"; fi
  if [[ "$got" == "$want" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $desc (want $want, got $got) $out"; fi
}
# Payloads in Copilot (camelCase) or Claude Code (snake_case) shape; FORMAT picks one.
sh() {
  if [[ "$FORMAT" == claude ]]; then jq -nc --arg c "$1" '{session_id:"test",cwd:".",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}'
  else jq -nc --arg c "$1" '{sessionId:"test",timestamp:0,cwd:".",toolName:"bash",toolArgs:{command:$c}}'; fi
}
ed() {
  if [[ "$FORMAT" == claude ]]; then
    local t; case "$1" in view) t=Read ;; create) t=Write ;; *) t=Edit ;; esac
    jq -nc --arg t "$t" --arg p "$2" '{session_id:"test",cwd:".",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p}}'
  else jq -nc --arg t "$1" --arg p "$2" '{sessionId:"test",timestamp:0,cwd:".",toolName:$t,toolArgs:{path:$p}}'; fi
}

# guard cases from hook-cases.txt (core + repo type + other layers), in both payload shapes
agent_branch="$(git branch --show-current)"
for FORMAT in copilot claude; do
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  if [[ "$line" =~ ^@checkout[[:space:]]+(.+)$ ]]; then
    b="${BASH_REMATCH[1]}"; [[ "$b" == "-" ]] && b="$agent_branch"
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
  want="$(awk '{print $1}' <<<"$line")"; kind="$(awk '{print $2}' <<<"$line")"
  desc="$(sed -E 's/^[[:space:]]*[a-z]+[[:space:]]+[a-z]+[[:space:]]+//; s/[[:space:]]*::.*$//' <<<"$line")"
  arg="${line#* :: }"; arg="${arg//\{branch\}/$agent_branch}"; arg="${arg//\{worktree\}/${worktree:-}}"
  arg="${arg//\\n/$'\n'}"
  case "$kind" in
    sh) expect "$want" "$desc [$FORMAT]" "$(sh "$arg")" ;;
    *)  expect "$want" "$desc [$FORMAT]" "$(ed "$kind" "$arg")" ;;
  esac
done < scripts/factory/hook-cases.txt
git checkout -q "$agent_branch"
done

# payload shapes
expect deny  "apply_patch hook"        "$(jq -nc '{sessionId:"test",toolName:"apply_patch",toolArgs:{input:"*** Begin Patch\n*** Update File: .github/hooks/factory.json\n@@"}}')"
expect deny  "claude exit code 2"      "$(jq -nc '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"sudo ls"}}')"
out="$(bash .github/hooks/scripts/guard.sh <<<'{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sudo ls"}}' 2>/dev/null)"; rc=$?
[[ $rc -eq 2 && "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" == deny ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: claude deny must exit 2 with hookSpecificOutput (rc=$rc)"; }
expect deny  "string toolArgs"         "$(jq -nc '{sessionId:"test",toolName:"bash",toolArgs:"{\"command\":\"sudo ls\"}"}')"

# stop gate
stop() { bash .github/hooks/scripts/stop-gate.sh <<<'{"sessionId":"test","stop_hook_active":false}'; }
[[ -z "$(stop)" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: stop gate should pass with no changes"; }
echo "x" > new.txt
[[ "$(stop | jq -r .decision)" == "block" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: stop gate should block unverified changes"; }
sed -i 's/^ALLOW_NO_CHECKS=0/ALLOW_NO_CHECKS=1/' scripts/factory/commands.env
bash scripts/factory/check.sh >/dev/null
[[ -z "$(stop)" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: stop gate should pass after check.sh"; }
echo "y" >> new.txt
[[ "$(stop | jq -r .decision)" == "block" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: stop gate should block after a new edit"; }

# logging
shopt -s nullglob
folders=(.agent-logs/*Z-test)
if [[ ${#folders[@]} -eq 1 && "$(basename "${folders[0]}")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-test$ \
      && -s "${folders[0]}/test.jsonl" ]] && jq -e . "${folders[0]}/test.jsonl" >/dev/null; then
  pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: expected one UTC-timestamped session folder with a valid test.jsonl"; fi
lines_before="$(wc -l < "${folders[0]}/test.jsonl")"
echo '{"sessionId":"test","toolName":"bash","toolArgs":{"command":"echo ghp_abcdefghijklmnopqrstuvwxyz0123"}}' | bash .github/hooks/scripts/log.sh postToolUse
folders=(.agent-logs/*Z-test)
[[ ${#folders[@]} -eq 1 && "$(wc -l < "${folders[0]}/test.jsonl")" -gt "$lines_before" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: same-session event should append to the existing folder"; }
grep -q 'ghp_abcdefghij' "${folders[0]}/test.jsonl" && { fail=$((fail+1)); echo "FAIL: token not redacted"; } || pass=$((pass+1))
echo '{"sessionId":"other","toolName":"bash","toolArgs":{"command":"true"}}' | bash .github/hooks/scripts/log.sh postToolUse
others=(.agent-logs/*Z-other)
[[ ${#others[@]} -eq 1 && -s "${others[0]}/other.jsonl" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: a different session should get its own folder"; }
[[ ! -e .agent-logs/test.jsonl ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: flat .agent-logs/test.jsonl should not exist"; }
for f in deny-paths.txt deny-commands.txt; do
  cmp -s ".github/hooks/policy/$f" "$src/.github/hooks/policy/$f" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: $f differs from source"; }
done
shopt -u nullglob

echo "hooks self-test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
