#!/usr/bin/env bash
# agentStop gate: if the agent changed code but has not passed scripts/factory/check.sh
# since its last change, force one more turn telling it to verify.
# Disable for a session with FACTORY_STOP_GATE=off.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$here/common.sh"

payload="$(cat)"
factory_context
root="$(factory_root)"
# shellcheck disable=SC1091
[[ -f "$root/scripts/factory/commands.env" ]] && source "$root/scripts/factory/commands.env"

pass() { factory_log "agentStop" "$payload" "{\"gate\":\"$1\"}" || true; exit 0; }

[[ "${FACTORY_STOP_GATE:-on}" == "off" ]] && pass "disabled"
[[ "$(jq -r '.stop_hook_active // false' <<<"$payload")" == "true" ]] && pass "already-continued"
factory_has_changes || pass "no-changes"

marker="$(factory_log_dir)/.verified"
current="$(factory_state_hash)"
if [[ -f "$marker" && "$(cat "$marker")" == "$current" ]]; then
  pass "verified"
fi

factory_log "agentStop" "$payload" '{"gate":"blocked-unverified"}' || true
jq -nc '{
  decision: "block",
  reason: "Your changes have not passed verification since the last edit. Load the verify-changes skill, run bash scripts/factory/check.sh, fix any failures, and only then finish with the final step of your workflow (the open-pr or handoff skill)."
}'
exit 0
