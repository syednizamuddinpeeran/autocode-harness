#!/usr/bin/env bash
# Environment setup for agents (cloud setup job, local runs), CI and accept.sh.
set -euo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"
# shellcheck disable=SC1091
source scripts/factory/commands.env

for tool in git jq; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

chmod +x .github/hooks/scripts/*.sh scripts/factory/*.sh 2>/dev/null || true
mkdir -p .agent-logs .agent-work

if [[ -n "${SETUP_CMD:-}" ]]; then
  echo "── setup: $SETUP_CMD"
  bash -c "$SETUP_CMD"
else
  echo "── setup: nothing configured (SETUP_CMD empty)"
fi
