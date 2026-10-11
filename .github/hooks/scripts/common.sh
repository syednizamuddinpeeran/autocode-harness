#!/usr/bin/env bash
# Shared helpers for factory hooks. Sourced, not executed.
# Requires: bash, jq, git.

factory_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

factory_log_dir() {
  local d="${FACTORY_LOG_DIR:-$(factory_root)/.agent-logs}"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}

# Mask common secret shapes before anything touches disk.
factory_redact() {
  sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED_GH_TOKEN]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED_GH_TOKEN]/g' \
    -e 's/(A3T[A-Z0-9]|AKIA|ASIA)[A-Z0-9]{16}/[REDACTED_AWS_KEY]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED_API_KEY]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----[^"]*/[REDACTED_PRIVATE_KEY]/g' \
    -e 's/((password|passwd|secret|token|api[_-]?key)[\\"]*[[:space:]]*[:=][[:space:]]*[\\"]*)[^\\",[:space:]]+/\1[REDACTED]/Ig'
}

# factory_log <event> <payload-json> [extra-json]
# Appends one JSON line to .agent-logs/<sessionId>.jsonl and to index.jsonl.
# Runs on every tool call, so it starts as few processes as possible (jq once, sed once): on some
# Windows machines each process costs 0.5-1 s.
factory_log() {
  local event="$1" payload="$2" extra="${3:-}"
  local dir sid ts line out
  [[ -z "$extra" ]] && extra='{}'
  dir="${FACTORY_LOG_DIR:-${_factory_root:-$(factory_root)}/.agent-logs}"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || true
  if [[ -n "${EPOCHREALTIME:-}" ]]; then   # bash 5: no date process
    ts="$(TZ=UTC0 printf '%(%Y-%m-%dT%H:%M:%S)T' "${EPOCHREALTIME%[.,]*}").${EPOCHREALTIME#*[.,]}"
    ts="${ts:0:23}Z"
  else
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  # Line 1: session id; line 2: the log line.
  if out="$(jq -rc --arg e "$event" --arg ts "$ts" --argjson extra "$extra" '
      def clip: if type == "string" and length > 4000 then .[0:4000] + "…[truncated]" else . end;
      ((if type == "object" then (.sessionId // .session_id) else null end) // "unknown-session"
        | tostring | gsub("[^A-Za-z0-9._-]"; "_")),
      ({ts: $ts, event: $e, branch: env.FACTORY_BRANCH, surface: env.FACTORY_SURFACE}
        + (. | walk(clip))
        + $extra | tojson)
    ' <<<"$payload" 2>/dev/null)" && out="${out//$'\r'/}" && [[ "$out" == *$'\n'* ]]; then
    # (CRs removed: native Windows jq writes CRLF; inside the JSON line a CR is always escaped.)
    sid="${out%%$'\n'*}"; line="${out#*$'\n'}"
  else
    sid="unknown-session"
    line="$(jq -nc --arg e "$event" --arg ts "$ts" --arg raw "${payload:0:4000}" \
        '{ts: $ts, event: $e, unparsed: $raw}')"
  fi
  sid="${sid//[^A-Za-z0-9._-]/_}"

  printf '%s\n' "$line" | factory_redact >> "$dir/$sid.jsonl"
  if [[ "$event" == "sessionStart" || "$event" == "sessionEnd" ]]; then
    jq -c --arg sid "$sid" '{ts, event, sessionId: $sid, branch, surface, reason, source}' <<<"$line" \
      2>/dev/null | factory_redact >> "$dir/index.jsonl"
  fi
}

factory_context() {
  export FACTORY_BRANCH
  FACTORY_BRANCH="$(git branch --show-current 2>/dev/null || echo detached)"
  export FACTORY_SURFACE
  if [[ -n "${COPILOT_AGENT_PROMPT:-}" || -d /workspace/.git ]]; then
    FACTORY_SURFACE="cloud"
  else
    FACTORY_SURFACE="cli"
  fi
}

# Hash of the working state (HEAD + tracked diff + untracked files).
# Used to tell whether anything changed since the last successful check.sh run.
factory_state_hash() {
  {
    git rev-parse HEAD 2>/dev/null
    git diff HEAD 2>/dev/null
    git ls-files --others --exclude-standard -z 2>/dev/null | xargs -0 -r sha1sum 2>/dev/null
  } | sha1sum | cut -d' ' -f1
}

# Does the branch differ from base (commits ahead or a dirty tree)?
factory_has_changes() {
  local base="${BASE_BRANCH:-main}" mb
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && return 0
  mb="$(git merge-base HEAD "origin/$base" 2>/dev/null || git merge-base HEAD "$base" 2>/dev/null || true)"
  [[ -n "$mb" && "$mb" != "$(git rev-parse HEAD 2>/dev/null)" ]]
}
