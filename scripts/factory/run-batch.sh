#!/usr/bin/env bash
# Run the sub-issues of a broken-down issue (create-issues.sh), in dependency order, several at a time,
# locally with the coding assistant CLI.
#
#   scripts/factory/run-batch.sh <parent-issue>                   # run every sub-issue that is unblocked now
#   scripts/factory/run-batch.sh <parent-issue> --auto-continue   # …then keep going as their PRs are merged
#   scripts/factory/run-batch.sh <parent-issue> --list            # show the state of each sub-issue only
#   options: --parallel <n> (default: MAX_PARALLEL in complexity.env)
#
# A sub-issue is ready to run when it is open and every issue it is "blocked by" (GitHub issue
# dependencies) is closed — its PR was merged with "Closes #N". Each one runs as its own
# run-issue.sh (autonomous) in its own worktree and branch, at most <n> at the same time; output goes
# to .agent-logs/batch/issue-<N>.log. Each opens its own PR.
#
# Without --auto-continue the batch stops when the runs it could start have finished: review and
# merge their PRs, then run it again. With --auto-continue it waits for those merges (checking every
# BATCH_POLL_SECONDS, default 60) and starts the sub-issues they unblock, until every sub-issue is
# closed or nothing more can start without you. Merging stays a human step.
# Cloud agent instead: run with --list and assign the "ready" ones to Copilot.
#
# Exit codes: 0 every run it started finished, 1 a run failed or stopped (questions, breakdown),
# 2 no sub-issues found.
set -euo pipefail

parent="" auto="" list="" parallel=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-continue) auto=1; shift ;;
    --list) list=1; shift ;;
    --parallel) parallel="${2:?--parallel needs a number}"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) parent="$1"; shift ;;
  esac
done
[[ "$parent" =~ ^[0-9]+$ ]] || { echo "usage: run-batch.sh <parent-issue> [--auto-continue] [--list] [--parallel <n>]" >&2; exit 2; }
for tool in git gh jq; do command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }; done

root="$(git rev-parse --show-toplevel)"
cd "$root"
# shellcheck disable=SC1091
source scripts/factory/complexity.env
parallel="${parallel:-${MAX_PARALLEL:-3}}"
[[ "$parallel" =~ ^[1-9][0-9]*$ ]] || { echo "--parallel must be a positive number" >&2; exit 1; }
poll="${BATCH_POLL_SECONDS:-60}"
logs="$root/.agent-logs/batch"; mkdir -p "$logs"
wt_root="${FACTORY_WORKTREE_ROOT:-$(dirname "$root")/$(basename "$root")-worktrees}"

declare -A pid=() rc=() st=() blockers=()
subs=()
# Refresh sub-issue states and open blockers from GitHub.
refresh() {
  local n s
  subs=(); st=(); blockers=()
  while read -r n s; do
    [[ -n "$n" ]] || continue
    subs+=("$n"); st[$n]="$s"
    if [[ "$s" == open ]]; then
      blockers[$n]="$(gh api "repos/{owner}/{repo}/issues/$n/dependencies/blocked_by" --paginate \
        --jq '.[] | select(.state == "open") | "#\(.number)"' | tr '\n' ' ')"
    fi
  done < <(gh api "repos/{owner}/{repo}/issues/$parent/sub_issues" --paginate --jq '.[] | "\(.number) \(.state)"')
}
# State of one sub-issue: closed | running | stopped | review | blocked | ready
state() {
  local n="$1"
  [[ "${st[$n]}" == open ]] || { echo closed; return; }
  [[ -n "${pid[$n]:-}" ]] && { echo running; return; }
  [[ -n "${rc[$n]:-}" && "${rc[$n]}" != 0 ]] && { echo stopped; return; }
  [[ -n "${rc[$n]:-}" || -d "$wt_root/issue-$n" ]] && { echo review; return; }
  [[ -z "${blockers[$n]// /}" ]] && { echo ready; return; }
  echo blocked
}
show() {
  local n
  echo "Sub-issues of #$parent:"
  for n in "${subs[@]}"; do
    case "$(state "$n")" in
      closed)  printf '  #%-6s closed\n' "$n" ;;
      running) printf '  #%-6s running (log: .agent-logs/batch/issue-%s.log)\n' "$n" "$n" ;;
      review)  printf '  #%-6s started: review and merge its PR (worktree %s)\n' "$n" "$wt_root/issue-$n" ;;
      stopped) printf '  #%-6s needs you: see .agent-logs/batch/issue-%s.log (questions, breakdown or failure)\n' "$n" "$n" ;;
      blocked) printf '  #%-6s blocked by: %s\n' "$n" "${blockers[$n]}" ;;
      ready)   printf '  #%-6s ready\n' "$n" ;;
    esac
  done
}

refresh
[[ ${#subs[@]} -gt 0 ]] || { echo "Issue #$parent has no sub-issues. Create them with create-issues.sh." >&2; exit 2; }
[[ -n "$list" ]] && { show; exit 0; }

failed=0
reap() {
  local n
  for n in "${!pid[@]}"; do
    if ! kill -0 "${pid[$n]}" 2>/dev/null; then
      local r=0; wait "${pid[$n]}" || r=$?
      rc[$n]=$r; unset "pid[$n]"
      [[ $r -eq 0 ]] || failed=1
      echo "finished #$n (exit $r)"
    fi
  done
}
while true; do
  reap
  for n in "${subs[@]}"; do
    (( ${#pid[@]} < parallel )) || break
    [[ "$(state "$n")" == ready ]] || continue
    echo "start    #$n"
    bash scripts/factory/run-issue.sh "$n" </dev/null >"$logs/issue-$n.log" 2>&1 &
    pid[$n]=$!
    sleep "${BATCH_STAGGER_SECONDS:-2}"   # let each run create its worktree before the next starts
  done
  if [[ ${#pid[@]} -gt 0 ]]; then sleep 2; continue; fi

  # Nothing running. Done, or waiting for PRs to be merged?
  pending=0 waiting=0
  for n in "${subs[@]}"; do
    case "$(state "$n")" in
      closed) ;;
      review|ready) pending=1; waiting=1 ;;
      *) pending=1 ;;
    esac
  done
  [[ $pending -eq 0 ]] && { echo "All sub-issues of #$parent are closed."; break; }
  [[ -n "$auto" && $waiting -eq 1 ]] || break
  sleep "$poll"
  refresh
done
echo
show
if [[ -z "$auto" ]]; then
  echo
  echo "Review and merge the PRs, then run the batch again (or use --auto-continue to start the next"
  echo "ones as their blockers are merged)."
fi
exit "$failed"
