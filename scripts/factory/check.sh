#!/usr/bin/env bash
# Verification gate. Same script runs for agents, humans, CI and accept.sh.
# On success, records a state hash that the agentStop hook uses to know the work is verified.
set -uo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root" || exit 1
# shellcheck disable=SC1091
source scripts/factory/commands.env
# shellcheck source=../../.github/hooks/scripts/common.sh
source .github/hooks/scripts/common.sh

declare -a names=(format lint typecheck test build)
declare -a cmds=("$FORMAT_CHECK_CMD" "$LINT_CMD" "$TYPECHECK_CMD" "$TEST_CMD" "$BUILD_CMD")

ran=0; failed=()
for i in "${!names[@]}"; do
  name="${names[$i]}"; cmd="${cmds[$i]}"
  [[ -z "$cmd" ]] && { echo "── $name: skipped (not configured)"; continue; }
  ran=$((ran + 1))
  echo "── $name: $cmd"
  start=$(date +%s)
  if bash -c "$cmd"; then
    echo "── $name: PASS ($(( $(date +%s) - start ))s)"
  else
    echo "── $name: FAIL ($(( $(date +%s) - start ))s)"
    failed+=("$name")
  fi
done

marker="$(factory_log_dir)/.verified"
if [[ $ran -eq 0 && "${ALLOW_NO_CHECKS:-0}" != "1" ]]; then
  echo "No checks configured. Edit scripts/factory/commands.env for this project." >&2
  rm -f "$marker"
  exit 3
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "RESULT: FAIL (${failed[*]})"
  rm -f "$marker"
  exit 1
fi

factory_state_hash > "$marker"
echo "RESULT: PASS ($ran checks)"
