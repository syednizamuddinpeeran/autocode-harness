#!/usr/bin/env bash
# Generic audit logger for Copilot hook events.
# Usage (from .github/hooks/factory.json): bash log.sh <eventName>   (payload JSON on stdin)
# Never blocks the agent: always exits 0 and prints nothing.
set -uo pipefail
here="${BASH_SOURCE[0]%/*}"; [[ "$here" == "${BASH_SOURCE[0]}" ]] && here=.; here="${here:-/}"
# shellcheck source=common.sh
source "$here/common.sh"
command -v jq >/dev/null 2>&1 || exit 0   # no jq: nothing to log with (guard.sh reports it)

event="${1:-unknown}"
IFS= read -r -d '' payload || true
factory_context
factory_log "$event" "$payload" || true
exit 0
