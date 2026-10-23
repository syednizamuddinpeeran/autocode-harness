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
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$here/common.sh"

root="$(factory_root)"
policy_dir="${FACTORY_POLICY_DIR:-$root/.github/hooks/policy}"

payload="$(cat)"
factory_context

tool="$(jq -r '.toolName // .tool_name // ""' <<<"$payload")" || exit 2
format="$(jq -r 'if has("toolName") or has("toolArgs") then "copilot" elif has("tool_name") or has("tool_input") or has("hook_event_name") then "claude" else "copilot" end' <<<"$payload")" || exit 2
args="$(jq -c '(.toolArgs // .tool_input // {}) | if type == "string" then (fromjson? // {raw: .}) else . end' <<<"$payload")" || exit 2

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

# Git branch rules for this repo type: policy/git-rules.env (KEY="value" lines, not sourced).
git_rule() { sed -nE "s/^$1=\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$policy_dir/git-rules.env" 2>/dev/null | tail -1; }
branch_prefixes="${FACTORY_BRANCH_PREFIXES:-$(git_rule BRANCH_PREFIXES)}"
branch_prefixes="${branch_prefixes:-agent/}"
branch_only_git="$(git_rule BRANCH_ONLY_GIT)"
push_current_only="$(git_rule PUSH_CURRENT_BRANCH_ONLY)"

# Read regex lines from a policy file, skipping comments/blank lines.
patterns() { [[ -f "$1" ]] && grep -Ev '^\s*(#|$)' "$1" || true; }

# ---------- shell commands ----------
check_shell() {
  local cmd norm pat
  cmd="$(jq -r '.command // .cmd // .script // .input // .raw // empty' <<<"$args")"
  [[ -z "$cmd" ]] && cmd="$(jq -r 'tostring' <<<"$args")"
  norm="$(tr '\n\t' '  ' <<<"$cmd" | tr -s ' ')"

  while IFS= read -r pat; do
    if grep -Eiq -- "$pat" <<<"$norm"; then
      deny "command matches denied pattern [$pat]"
    fi
  done < <(patterns "$policy_dir/deny-commands.txt")

  # Branch rules for the git commands the line really runs (see check_git_rules), from the
  # directory the tool call runs in.
  if [[ -n "$branch_only_git" || "$push_current_only" == "1" ]] && [[ "$cmd" =~ (^|[^A-Za-z0-9_.-])[Gg][Ii][Tt] ]]; then
    local start
    start="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)"; start="${start//\\//}"
    [[ -n "$start" && -d "$start" ]] || start="$root"
    check_git_rules "$cmd" "$start"
  fi
  allow
}

# ---------- git branch rules ----------
# A small shell tokenizer, just enough to find the git commands a command line really runs:
#   - quoted text stays one word, so push words in a commit message, PR title or body are data;
#   - redirections (2>&1, >/dev/null, 2> file, <<< word) are dropped, heredoc bodies and
#     PowerShell here-strings are skipped;
#   - ; && || | & newline ( ) { } end a simple command; ( ) also scope a cd;
#   - $( ) and backticks (also inside double quotes) are parsed as commands of their own.
# Bash and PowerShell commands both go through it (guard.ps1 mirrors it with PowerShell escapes).
# Result: global array TOKS, the words of each simple command followed by $TOK_SEP, with
# $TOK_OPEN / $TOK_CLOSE around subshells.
TOK_SEP=$'\x1e'; TOK_OPEN=$'\x1e('; TOK_CLOSE=$'\x1e)'
TOKS=()

# The helpers below work on the caller's word / inword / redir / _w (bash dynamic scoping).
tok_word_end() {
  if [[ $inword == 1 ]]; then
    if [[ $redir == 1 ]]; then redir=0; else _w+=("$word"); fi
  fi
  word=""; inword=0
}
tok_sep() {
  tok_word_end; redir=0
  if (( ${#_w[@]} )); then TOKS+=("${_w[@]}" "$TOK_SEP"); fi
  _w=()
}
# Heredoc delimiter after << or <<-: one word, quotes removed. Appends "<strip-tabs><delim>" to hd.
tok_heredoc_start() {
  local strip=0 d="" c
  [[ "${_s:_i:1}" == "-" ]] && { strip=1; ((_i++)); }
  while [[ "${_s:_i:1}" == " " || "${_s:_i:1}" == $'\t' ]]; do ((_i++)); done
  while (( _i < _n )); do
    c="${_s:_i:1}"
    case "$c" in
      "'"|'"') ((_i++)); while (( _i < _n )) && [[ "${_s:_i:1}" != "$c" ]]; do d+="${_s:_i:1}"; ((_i++)); done; ((_i++)) ;;
      '\') d+="${_s:_i+1:1}"; ((_i+=2)) ;;
      ' '|$'\t'|$'\r'|$'\n'|';'|'&'|'|'|'<'|'>'|'('|')') break ;;
      *) d+="$c"; ((_i++)) ;;
    esac
  done
  [[ -n "$d" ]] && hd+=("$strip$d")
}
# At a newline: skip the bodies of the heredocs started on the line just ended.
tok_skip_heredocs() {
  local e strip delim rest line
  for e in "${hd[@]}"; do
    strip="${e:0:1}"; delim="${e:1}"
    while (( _i < _n )); do
      rest="${_s:_i}"; line="${rest%%$'\n'*}"
      _i=$((_i + ${#line} + 1))
      line="${line%$'\r'}"
      [[ $strip == 1 ]] && line="${line#"${line%%[!$'\t']*}"}"
      [[ "$line" == "$delim" ]] && break
    done
  done
  hd=()
}
# Inside "...": bash escapes, $( ) and backticks are commands of their own.
tok_dquote() {
  local c rest q
  while (( _i < _n )); do
    rest="${_s:_i}"; q="${rest%%[\"\\\$\`]*}"
    word+="$q"; _i=$((_i + ${#q}))
    (( _i < _n )) || return 0
    c="${_s:_i:1}"
    case "$c" in
      '"') ((_i++)); return 0 ;;
      '\') case "${_s:_i+1:1}" in
             '"'|'\'|'$'|'`') word+="${_s:_i+1:1}"; ((_i+=2)) ;;
             $'\n') ((_i+=2)) ;;
             *) word+='\'; ((_i++)) ;;
           esac ;;
      '$') if [[ "${_s:_i+1:1}" == "(" ]]; then ((_i+=2)); word+='$(...)'; tok_parse ")"
           else word+='$'; ((_i++)); fi ;;
      '`') ((_i++)); word+='`...`'; tok_parse '`' ;;
    esac
  done
}
# tok_parse <closer>: parse from _i up to the closer (")" or a backtick) or the end of the input.
tok_parse() {
  local closer="$1" word="" inword=0 redir=0 depth=0 c c2 rest q line
  local -a _w=() hd=()
  while (( _i < _n )); do
    c="${_s:_i:1}"
    case "$c" in
      ' '|$'\t'|$'\r') tok_word_end; ((_i++)) ;;
      $'\n') tok_sep; ((_i++)); (( ${#hd[@]} )) && tok_skip_heredocs ;;
      "'") inword=1; rest="${_s:_i+1}"; q="${rest%%\'*}"; word+="$q"; _i=$((_i + ${#q} + 2)) ;;
      '"') inword=1; ((_i++)); tok_dquote ;;
      '\') if [[ "${_s:_i+1:1}" == $'\n' ]]; then ((_i+=2)); else inword=1; word+="${_s:_i+1:1}"; ((_i+=2)); fi ;;
      '`') ((_i++))
           if [[ "$closer" == '`' ]]; then tok_sep; return 0; fi
           inword=1; word+='`...`'; tok_parse '`' ;;
      '$') c2="${_s:_i+1:1}"; inword=1
           if [[ "$c2" == "(" ]]; then ((_i+=2)); word+='$(...)'; tok_parse ")"
           elif [[ "$c2" == "{" ]]; then rest="${_s:_i}"; q="${rest%%\}*}"; word+="$q}"; _i=$((_i + ${#q} + 1))
           else word+='$'; ((_i++)); fi ;;
      '@') c2="${_s:_i+1:1}"; rest="${_s:_i+2}"; line="${rest%%$'\n'*}"
           if [[ $inword == 0 && ( "$c2" == "'" || "$c2" == '"' ) && "$rest" == *$'\n'* && "$line" =~ ^[[:space:]]*$ ]]; then
             # PowerShell here-string @' ... '@ / @" ... "@: one word, its body skipped
             q="${rest%%$'\n'"$c2"@*}"; inword=1; word+="@$c2...$c2@"
             if [[ "$q" == "$rest" ]]; then _i=$_n; else _i=$((_i + 2 + ${#q} + 3)); fi
           else inword=1; word+="@"; ((_i++)); fi ;;
      ';') tok_sep; ((_i++)) ;;
      '&') c2="${_s:_i+1:1}"
           if [[ "$c2" == ">" ]]; then tok_word_end; ((_i+=2)); [[ "${_s:_i:1}" == ">" ]] && ((_i++)); redir=1
           else tok_sep; ((_i++)); [[ "$c2" == "&" ]] && ((_i++)); fi ;;
      '|') tok_sep; ((_i++)); [[ "${_s:_i:1}" == "|" || "${_s:_i:1}" == "&" ]] && ((_i++)) ;;
      '(') tok_sep; TOKS+=("$TOK_OPEN"); ((depth++)); ((_i++)) ;;
      ')') tok_sep; ((_i++))
           if (( depth > 0 )); then ((depth--)); TOKS+=("$TOK_CLOSE")
           elif [[ "$closer" == ")" ]]; then return 0
           else TOKS+=("$TOK_CLOSE"); fi ;;
      '{') if [[ $inword == 0 ]]; then tok_sep; else word+="{"; fi; ((_i++)) ;;
      '}') if [[ "$word" == *"{"* ]]; then word+="}"; else tok_sep; fi; ((_i++)) ;;
      '<'|'>')
           # a file-descriptor number (2>) or PowerShell's * (*>) belongs to the redirection
           if [[ $inword == 1 && "$word" =~ ^([0-9]+|\*)$ ]]; then word=""; inword=0; else tok_word_end; fi
           if [[ "${_s:_i:3}" == "<<<" ]]; then _i=$((_i + 3)); redir=1
           elif [[ "${_s:_i:2}" == "<<" ]]; then _i=$((_i + 2)); tok_heredoc_start
           elif [[ "${_s:_i+1:1}" == "(" ]]; then ((_i++))   # process substitution: parsed as a subshell
           else
             ((_i++)); c2="${_s:_i:1}"; [[ "$c2" == ">" || "$c2" == "|" ]] && ((_i++))
             if [[ "${_s:_i:1}" == "&" ]]; then
               ((_i++)); rest="${_s:_i}"; q="${rest%%[!0-9-]*}"; _i=$((_i + ${#q}))
               [[ -z "$q" ]] && redir=1
             else redir=1; fi
           fi ;;
      *) # a run of plain word characters at once (speed)
         rest="${_s:_i:256}"; q="${rest%%[!A-Za-z0-9_./:,+%=-]*}"; [[ -z "$q" ]] && q="$c"
         inword=1; word+="$q"; _i=$((_i + ${#q})) ;;
    esac
  done
  tok_sep
}
shell_tokens() { # shell_tokens <command>: sets TOKS
  local LC_ALL=C
  _s="$1"; _n=${#_s}; _i=0; TOKS=()
  tok_parse ""
}

# cmd_name <word>: sets low to the word's file name, lower-cased, without .exe (git.exe → git).
cmd_name() {
  low="${1##*[/\\]}"
  if (( ${#low} > 20 )); then low=""; return; fi   # longer than any command name we look for
  if (( BASH_VERSINFO[0] >= 4 )); then low="${low,,}"; else low="$(tr '[:upper:]' '[:lower:]' <<<"$low")"; fi
  low="${low%.exe}"
}
# resolve_dir <base> <target>: the directory a cd / git -C target names, or "" when it cannot be
# known (variables, globs, "cd -", a missing directory). An unknown directory means the repo root.
resolve_dir() {
  local base="$1" t="${2//\\//}"
  case "$t" in \~) t="$HOME" ;; \~/*) t="$HOME/${t#\~/}" ;; esac
  if [[ -z "$t" || "$t" == "-" || "$t" == *'$'* || "$t" == *'`'* || "$t" == *'*'* ]]; then echo ""; return; fi
  if [[ "$t" != /* && ! "$t" =~ ^[A-Za-z]:/ ]]; then
    [[ -n "$base" ]] || { echo ""; return; }
    t="${base%/}/$t"
  fi
  if [[ -d "$t" ]]; then echo "$t"; else echo ""; fi
}
branch_of() { git -C "${1:-$root}" branch --show-current 2>/dev/null || true; }

# check_git_rules <command> <dir>: deny when a git command in it breaks the branch rules, judged on
# the branch of the directory it runs in (after cd / pushd / Set-Location / git -C).
check_git_rules() {
  local dir="$2" t
  local -a toks=() words=() stack=() pstack=()
  shell_tokens "$1"
  (( ${#TOKS[@]} )) || return 0
  toks=("${TOKS[@]}")
  for t in "${toks[@]}"; do
    case "$t" in
      "$TOK_OPEN") stack+=("$dir") ;;
      "$TOK_CLOSE")
        if (( ${#stack[@]} )); then dir="${stack[${#stack[@]}-1]}"; unset "stack[${#stack[@]}-1]"; fi ;;
      "$TOK_SEP") (( ${#words[@]} )) && check_simple_command; words=() ;;
      *) words+=("$t") ;;
    esac
  done
  return 0
}
# One simple command in the caller's words, run in the caller's dir (which a cd changes).
check_simple_command() {
  local i=0 j k n=${#words[@]} w low gdir sub cur ok p r remote
  while (( i < n )); do   # skip VAR=value prefixes and shell keywords
    w="${words[i]}"
    if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= || " if then else elif do while until ! time " == *" $w "* ]]; then ((i++)); else break; fi
  done
  (( i < n )) || return 0
  cmd_name "${words[i]}"
  case "$low" in
    cd|chdir|pushd|sl|set-location|push-location)
      j=$((i + 1)); while (( j < n )) && [[ "${words[j]}" == -?* ]]; do ((j++)); done
      [[ "$low" == pushd || "$low" == push-location ]] && pstack+=("$dir")
      if (( j < n )); then dir="$(resolve_dir "$dir" "${words[j]}")"; else dir="$HOME"; fi
      return 0 ;;
    popd|pop-location)
      if (( ${#pstack[@]} )); then dir="${pstack[${#pstack[@]}-1]}"; unset "pstack[${#pstack[@]}-1]"; else dir=""; fi
      return 0 ;;
    eval|iex|invoke-expression)
      check_git_rules "${words[*]:i+1}" "$dir"; return 0 ;;
  esac
  for (( j = i; j < n; j++ )); do
    cmd_name "${words[j]}"
    case "$low" in
      bash|sh|zsh|dash|ksh|pwsh|powershell)
        # bash -c '…', sh -lc '…', pwsh -Command '…': check the command text too
        for (( k = j + 1; k < n; k++ )); do
          if [[ "${words[k]}" =~ ^-[A-Za-z]*c$ || "${words[k]}" =~ ^-[Cc][Oo][Mm][Mm][Aa][Nn][Dd]$ ]]; then
            (( k + 1 < n )) && check_git_rules "${words[k+1]}" "$dir"
            break
          fi
        done
        continue ;;
      git) ;;
      *) continue ;;
    esac
    gdir="$dir"; k=$((j + 1))
    while (( k < n )); do
      case "${words[k]}" in
        -C) gdir="$(resolve_dir "$gdir" "${words[k+1]:-}")"; k=$((k + 2)) ;;
        -c|--git-dir|--work-tree|--namespace|--config-env) k=$((k + 2)) ;;
        -*) ((k++)) ;;
        *) break ;;
      esac
    done
    sub="${words[k]:-}"
    # Some git subcommands (push, or commit/merge for local repos) only on agent branches.
    if [[ -n "$branch_only_git" && "$sub" =~ ^($branch_only_git)([^A-Za-z0-9_]|$) ]]; then
      cur="$(branch_of "$gdir")"
      ok=1
      for p in $branch_prefixes; do [[ "$cur" == "$p"* ]] && ok=0; done
      [[ $ok -ne 0 ]] && deny "git $branch_only_git is only allowed on branches starting with: $branch_prefixes (current: ${cur:-detached})"
    fi
    # Any explicit git push refspec must name the current branch or HEAD.
    if [[ "$push_current_only" == "1" && "$sub" == push ]]; then
      cur="$(branch_of "$gdir")"; remote=0
      for (( k = k + 1; k < n; k++ )); do
        r="${words[k]}"
        [[ "$r" == -* ]] && continue
        [[ $remote == 0 ]] && { remote=1; continue; }   # the first word is the remote
        [[ "$r" == "HEAD" || "$r" == "$cur" || "$r" == "HEAD:$cur" || "$r" == "$cur:$cur" ]] && continue
        [[ "$r" == "HEAD:refs/heads/$cur" ]] && continue
        deny "git push refspec '$r' is not the current branch '$cur'"
      done
    fi
    return 0   # the first git word of a simple command is the command
  done
  return 0
}

# ---------- file tools ----------
paths_in_args() {
  jq -r '[.. | objects | to_entries[] | select(.key | test("path|file"; "i")) | .value | strings] | .[]' <<<"$args" 2>/dev/null
  # apply_patch style headers: "*** Update File: path"
  jq -r 'tostring' <<<"$args" | grep -oE '\*\*\* (Add|Update|Delete) File: [^\\"]+' | sed -E 's/^\*\*\* (Add|Update|Delete) File: //'
}

check_paths() {
  local mode="$1" path rel pat rule
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    path="${path//\\//}"   # Windows separators
    rel="${path#"$root"/}"; rel="${rel#/workspace/}"; rel="${rel#./}"
    while IFS= read -r rule; do
      if [[ "$rule" == write:* ]]; then
        [[ "$mode" != "write" ]] && continue
        pat="${rule#write:}"
      else
        pat="$rule"
      fi
      if grep -Eq -- "$pat" <<<"$rel" || grep -Eq -- "$pat" <<<"$path"; then
        deny "$mode access to '$rel' is not allowed [$pat]"
      fi
    done < <(patterns "$policy_dir/deny-paths.txt")
  done < <(paths_in_args)
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
