#!/usr/bin/env bash
# preToolUse guard: logs every tool call, then allows or denies it.
#
# Output contract: print ONE JSON object, or nothing.
#   Copilot (camelCase payload: toolName/toolArgs)
#     deny  -> {"permissionDecision":"deny","permissionDecisionReason":"..."}
#   Claude Code (snake_case payload: tool_name/tool_input)
#     deny  -> {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",...}},
#              the reason on stderr, and exit 2 (Claude Code treats only exit 2 as a block)
#   allow -> print nothing (fall through to normal permissions)
# A crash exits non-zero, which denies the call (Copilot: any non-zero; Claude Code: exit 2, or any
# failure with onFailure "block"). A Copilot hook timeout ALLOWS the call, so keep this script fast.
#
# Speed: every external process costs 0.5-1 s on some Windows machines (Git Bash process creation
# plus antivirus scanning), so the allow path starts as few as possible: git x2, jq x2, grep, sed.
# Policy files are read with bash builtins, one jq call parses the payload, and one grep checks all
# patterns; the per-pattern loop only runs to name the pattern that matched.
set -uo pipefail
here="${BASH_SOURCE[0]%/*}"; [[ "$here" == "${BASH_SOURCE[0]}" ]] && here=.; here="${here:-/}"
# shellcheck source=common.sh
source "$here/common.sh"

command -v jq >/dev/null 2>&1 || {
  echo "factory guard: jq not found on PATH; every tool call is blocked until it is installed (Windows: winget install jqlang.jq, then restart the session). See docs/troubleshooting.md." >&2
  exit 2
}

root="$(factory_root)"
_factory_root="$root"   # reused by factory_log, saves a git call
policy_dir="${FACTORY_POLICY_DIR:-$root/.github/hooks/policy}"

IFS= read -r -d '' payload || true
factory_context

# One jq call: tool, payload format, tool args (compact JSON), the shell command with newlines and
# tabs turned into spaces and runs of spaces squeezed, then any path arguments, one per line.
parsed="$(jq -r '
  ((.toolArgs // .tool_input // {}) | if type == "string" then (fromjson? // {raw: .}) else . end) as $a
  | ((.toolName // .tool_name // "") | tostring | gsub("[\r\n]"; " ")),
    (if has("toolName") or has("toolArgs") then "copilot"
     elif has("tool_name") or has("tool_input") or has("hook_event_name") then "claude"
     else "copilot" end),
    ($a | tojson),
    ((if ($a | type) == "object" then ($a | .command // .cmd // .script // .input // .raw // "") else "" end)
      | (if type == "string" then . else tojson end)
      | (if . == "" then ($a | tostring) else . end)
      | (. + "\n") | gsub("[\n\t]"; " ") | gsub(" +"; " ")),
    ([$a | .. | objects | to_entries[] | select(.key | test("path|file"; "i")) | .value | strings] | .[]),
    ($a | tostring | [match("\\*\\*\\* (?:Add|Update|Delete) File: ([^\\\\\"]+)"; "g") | .captures[0].string] | .[])
' <<<"$payload")" || exit 2
parsed="${parsed//$'\r\n'/$'\n'}"   # native Windows jq writes CRLF (jq -b would fail on jq 1.6)
{ IFS= read -r tool; IFS= read -r format; IFS= read -r args; IFS= read -r norm; } <<<"$parsed"
[[ -n "${format:-}" ]] || exit 2
path_args="$parsed"   # lines 5+ (builtins, no sed)
for _ in 1 2 3 4; do
  if [[ "$path_args" == *$'\n'* ]]; then path_args="${path_args#*$'\n'}"; else path_args=""; fi
done

deny() {
  local reason="$1"
  factory_log "preToolUse" "$payload" "$(jq -nc --arg r "$reason" '{decision: "deny", reason: $r}')" || true
  local msg="Blocked by factory guard: $reason. Do not retry this action or work around it; choose a safe alternative or record it as a follow-up in the PR or handoff."
  if [[ "$format" == "claude" ]]; then
    jq -nc --arg r "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    echo "$msg" >&2
    exit 2
  fi
  jq -nc --arg r "$msg" '{permissionDecision: "deny", permissionDecisionReason: $r}'
  exit 0
}

allow() {
  factory_log "preToolUse" "$payload" '{"decision":"allow"}' || true
  exit 0
}

# Lines of a policy file into the global array PATTERNS, skipping comments/blank lines. Builtins only
# (bash 3.2 safe); strips the CR that a Windows (core.autocrlf) checkout adds, which would otherwise
# stop every pattern matching.
read_patterns() { # read_patterns <file>
  local line
  PATTERNS=()
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    PATTERNS+=("$line")
  done < "$1"
}

# Git branch rules for this repo type: policy/git-rules.env (KEY="value" lines, not sourced; last wins).
branch_prefixes="" branch_only_git="" push_current_only=""
if [[ -f "$policy_dir/git-rules.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^(BRANCH_PREFIXES|BRANCH_ONLY_GIT|PUSH_CURRENT_BRANCH_ONLY)=\"?([^\"]*)\"?[[:space:]]*$ ]] || continue
    case "${BASH_REMATCH[1]}" in
      BRANCH_PREFIXES) branch_prefixes="${BASH_REMATCH[2]}" ;;
      BRANCH_ONLY_GIT) branch_only_git="${BASH_REMATCH[2]}" ;;
      PUSH_CURRENT_BRANCH_ONLY) push_current_only="${BASH_REMATCH[2]}" ;;
    esac
  done < "$policy_dir/git-rules.env"
fi
branch_prefixes="${FACTORY_BRANCH_PREFIXES:-$branch_prefixes}"
branch_prefixes="${branch_prefixes:-agent/}"

# Does any of the patterns match the text? One grep for all of them; exit 2 (a broken pattern) is
# treated as "maybe", so the per-pattern loop still checks every valid pattern.
any_match() { # any_match <grep-flags> <text> <pattern>...
  local flags="$1" text="$2" p rc; shift 2
  local e=()
  for p in "$@"; do e+=(-e "$p"); done
  [[ ${#e[@]} -eq 0 ]] && return 1
  grep "$flags" "${e[@]}" <<<"$text" >/dev/null 2>&1; rc=$?
  [[ $rc -ne 1 ]]
}

# ---------- shell commands ----------
check_shell() {
  local pat
  read_patterns "$policy_dir/deny-commands.txt"
  if any_match -Ei "$norm" ${PATTERNS[@]+"${PATTERNS[@]}"}; then
    for pat in "${PATTERNS[@]}"; do
      if grep -Eiq -- "$pat" <<<"$norm"; then
        deny "command matches denied pattern [$pat]"
      fi
    done
  fi

  # Some git subcommands (push, or commit/merge for local repos) only on agent branches.
  local cur ok p refs r
  if [[ -n "$branch_only_git" ]] && grep -Eq "(^|[;&|[:space:]])git\s+(-C\s+\S+\s+)?($branch_only_git)\b" <<<"$norm"; then
    cur="$(git -C "$root" branch --show-current 2>/dev/null || true)"
    ok=1
    for p in $branch_prefixes; do [[ "$cur" == "$p"* ]] && ok=0; done
    [[ $ok -ne 0 ]] && deny "git $branch_only_git is only allowed on branches starting with: $branch_prefixes (current: ${cur:-detached})"
  fi

  # Any explicit git push refspec must name the current branch or HEAD.
  if [[ "$push_current_only" == "1" ]] && grep -Eq '(^|[;&|[:space:]])git\s+push\b' <<<"$norm"; then
    cur="$(git -C "$root" branch --show-current 2>/dev/null || true)"
    refs="$(sed -E 's/.*git\s+push\s*//; s/[;&|].*//; s/(^|\s)-[-a-zA-Z=]+//g' <<<"$norm" | awk '{for (i=2;i<=NF;i++) print $i}')"
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      [[ "$r" == "HEAD" || "$r" == "$cur" || "$r" == "HEAD:$cur" || "$r" == "$cur:$cur" ]] && continue
      [[ "$r" == "HEAD:refs/heads/$cur" ]] && continue
      deny "git push refspec '$r' is not the current branch '$cur'"
    done <<<"$refs"
  fi
  allow
}

# ---------- file tools ----------
check_paths() {
  local mode="$1" path rel pat rule pats=()
  read_patterns "$policy_dir/deny-paths.txt"
  for rule in ${PATTERNS[@]+"${PATTERNS[@]}"}; do
    if [[ "$rule" == write:* ]]; then
      [[ "$mode" != "write" ]] && continue
      pats+=("${rule#write:}")
    else
      pats+=("$rule")
    fi
  done
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    path="${path//\\//}"   # Windows separators
    rel="${path#"$root"/}"; rel="${rel#/workspace/}"; rel="${rel#./}"
    any_match -E "$rel"$'\n'"$path" ${pats[@]+"${pats[@]}"} || continue
    for pat in "${pats[@]}"; do
      if grep -Eq -- "$pat" <<<"$rel" || grep -Eq -- "$pat" <<<"$path"; then
        deny "$mode access to '$rel' is not allowed [$pat]"
      fi
    done
  done <<<"$path_args"
  allow
}

if [[ "$tool" == "str_replace_editor" && "$(jq -r '.command // ""' <<<"$args")" == "view" ]]; then
  tool="view"
fi

case "$tool" in
  bash|powershell|shell|Bash|PowerShell|execute) check_shell ;;
  edit|create|str_replace_editor|str_replace|apply_patch|write|Write|Edit|MultiEdit|NotebookEdit) check_paths write ;;
  view|read|Read|Glob|Grep|NotebookRead)          check_paths read ;;
  *)                                            allow ;;
esac
