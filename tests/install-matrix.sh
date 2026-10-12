#!/usr/bin/env bash
# Install every supported combination into a scratch git repo and run its self-tests there.
#   bash tests/install-matrix.sh            # all repo types × os linux, windows × all assistants
#   bash tests/install-matrix.sh github     # only repo type "github"
# For --os windows the PowerShell tests also run when pwsh is available.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repos=("$@")
[[ ${#repos[@]} -eq 0 ]] && mapfile -t repos < <(ls "$root/template/repo")

snapshot() { git status --porcelain | sort; find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum; }

# One combination. Every step is checked explicitly: set -e does not apply inside a function
# whose status is tested by the caller.
run_one() {
  local repo="$1" os="$2" assistant="$3" cloud="$4" tmp="$5" before
  cd "$tmp" || return 1
  git init -q -b main . && git config user.email t@t && git config user.name t || return 1
  echo "# scratch" > README.md && git add -A && git commit -qm init || return 1
  bash "$root/install.sh" "$tmp" --repo "$repo" --os "$os" --assistant "$assistant" --cloud "$cloud" >/dev/null || { echo "install failed"; return 1; }
  before="$(snapshot)"
  if bash "$root/install.sh" "$tmp" --repo "$repo" --os "$os" --assistant "$assistant" --cloud "$cloud" | grep -q '^added:'; then echo "re-install added files"; return 1; fi
  [[ "$before" == "$(snapshot)" ]] || { echo "re-install changed files"; return 1; }
  for f in .github/hooks/factory.json .claude/settings.json; do
    [[ -f "$f" ]] && { jq -e . "$f" >/dev/null || { echo "invalid JSON: $f"; return 1; }; }
  done
  grep -q "^ASSISTANT=\"$assistant\"" scripts/factory/commands.env || { echo "commands.env lacks ASSISTANT=$assistant"; return 1; }
  bash scripts/factory/test-hooks.sh || return 1
  # Readiness check: ok-* fixtures pass, bad-* fail with exit 4; launchers refuse to start without input.
  local fx want got
  for fx in "$root"/tests/fixtures/ready/*.md; do
    want=0; [[ "$(basename "$fx")" == bad-* ]] && want=4
    bash scripts/factory/check-ready.sh "$fx" >/dev/null; got=$?
    [[ $got -eq $want ]] || { echo "check-ready $(basename "$fx"): want $want, got $got"; return 1; }
    if [[ "$os" == windows ]] && command -v pwsh >/dev/null; then
      pwsh -NoProfile -File scripts/factory/check-ready.ps1 "$fx" >/dev/null; got=$?
      [[ $got -eq $want ]] || { echo "check-ready.ps1 $(basename "$fx"): want $want, got $got"; return 1; }
    fi
  done
  # Complexity and breakdown checks: expected exit codes per fixture.
  local d c
  for d in "$root"/tests/fixtures/complexity/*/; do
    c="$(basename "$d")"; want=6
    case "$c" in ok|high-risk-single|two-areas) want=0 ;; no-estimate) want=4 ;; esac
    bash scripts/factory/check-complexity.sh "$d/plan.md" "$d/brief.md" >/dev/null; got=$?
    [[ $got -eq $want ]] || { echo "check-complexity $c: want $want, got $got"; return 1; }
    if [[ "$os" == windows ]] && command -v pwsh >/dev/null; then
      pwsh -NoProfile -File scripts/factory/check-complexity.ps1 "$d/plan.md" "$d/brief.md" >/dev/null; got=$?
      [[ $got -eq $want ]] || { echo "check-complexity.ps1 $c: want $want, got $got"; return 1; }
    fi
  done
  for fx in "$root"/tests/fixtures/breakdown/{ok,bad-*}.md; do
    want=0; [[ "$(basename "$fx")" == bad-* ]] && want=4
    bash scripts/factory/check-breakdown.sh "$fx" "$root/tests/fixtures/breakdown/brief.md" >/dev/null; got=$?
    [[ $got -eq $want ]] || { echo "check-breakdown $(basename "$fx"): want $want, got $got"; return 1; }
    if [[ "$os" == windows ]] && command -v pwsh >/dev/null; then
      pwsh -NoProfile -File scripts/factory/check-breakdown.ps1 "$fx" "$root/tests/fixtures/breakdown/brief.md" >/dev/null; got=$?
      [[ $got -eq $want ]] || { echo "check-breakdown.ps1 $(basename "$fx"): want $want, got $got"; return 1; }
    fi
  done
  local launcher=scripts/factory/run-issue.sh; [[ "$repo" == local ]] && launcher=scripts/factory/run-task.sh
  bash "$launcher" >/dev/null 2>&1; got=$?
  [[ $got -eq 2 ]] || { echo "$launcher without input: want exit 2, got $got"; return 1; }
  bash scripts/factory/run-batch.sh >/dev/null 2>&1; got=$?
  [[ $got -eq 2 ]] || { echo "run-batch.sh without input: want exit 2, got $got"; return 1; }
  if bash scripts/factory/check.sh >/dev/null 2>&1; then echo "check.sh passed with no checks configured"; return 1; fi
  sed -i 's/^ALLOW_NO_CHECKS=0/ALLOW_NO_CHECKS=1/' scripts/factory/commands.env
  bash scripts/factory/setup.sh >/dev/null || { echo "setup.sh failed"; return 1; }
  bash scripts/factory/check.sh >/dev/null || { echo "check.sh failed"; return 1; }
  if [[ "$os" == "windows" ]] && command -v pwsh >/dev/null; then
    git checkout -q -- scripts/factory/commands.env 2>/dev/null || sed -i 's/^ALLOW_NO_CHECKS=1/ALLOW_NO_CHECKS=0/' scripts/factory/commands.env
    git add -A && git commit -qm installed || return 1
    pwsh -NoProfile -File scripts/factory/test-hooks.ps1 || return 1
    pwsh -NoProfile -File scripts/factory/check.ps1 >/dev/null 2>&1; [[ $? -eq 3 ]] || { echo "check.ps1 should exit 3 with no checks"; return 1; }
    sed -i 's/^ALLOW_NO_CHECKS=0/ALLOW_NO_CHECKS=1/' scripts/factory/commands.env
    pwsh -NoProfile -File scripts/factory/setup.ps1 >/dev/null || { echo "setup.ps1 failed"; return 1; }
    pwsh -NoProfile -File scripts/factory/check.ps1 >/dev/null || { echo "check.ps1 failed"; return 1; }
  fi
}

# --keep-harness into a clone of this repo (which has its own harness), even with --force: the harness
# stays byte for byte, the factory is installed and works on the repo's own hook helpers, and the
# template's harness files that were held back are under .agent-work/harness/.
keep_harness_one() {
  local os="$1" tmp="$2" out got f
  git clone -q "$root" "$tmp" && cd "$tmp" || return 1
  git config user.email t@t && git config user.name t || return 1
  out="$(bash "$root/install.sh" "$tmp" --repo github --os "$os" --assistant claude-code --force --keep-harness)" \
    || { echo "install failed"; return 1; }
  git diff --quiet -- .github .claude AGENTS.md CLAUDE.md || { echo "tracked harness files changed:"; git diff --stat; return 1; }
  got="$(git status --porcelain --untracked-files=all | grep -E '^\?\? (\.github/(hooks|workflows)/|\.claude/settings\.json|AGENTS\.md|CLAUDE\.md|scripts/factory/(test-hooks|hook-cases))')"
  [[ -z "$got" ]] || { echo "harness files written:"; echo "$got"; return 1; }
  for f in scripts/factory/run-issue.sh scripts/factory/check.sh .claude/agents/factory.md .github/ISSUE_TEMPLATE/agent-task.yml \
           .agent-work/harness/AGENTS.md; do
    [[ -f "$f" ]] || { echo "missing: $f"; return 1; }
  done
  grep -qx 'kept harness (differs): AGENTS.md' <<<"$out" || { echo "AGENTS.md not reported as kept"; return 1; }
  # The stop gate: a copy identical to the template's is skipped silently; otherwise it is held back.
  f=.github/hooks/scripts/stop-gate.sh
  if [[ -f "$f" ]] && cmp -s "$f" "$root/template/core/$f"; then
    if grep -q "kept harness .*: $f\$" <<<"$out" || [[ -e ".agent-work/harness/$f" ]]; then
      echo "identical $f reported as kept"; return 1
    fi
  else
    grep -Eqx "kept harness \((new|differs)\): $f" <<<"$out" && [[ -f ".agent-work/harness/$f" ]] \
      || { echo "$f not held back"; return 1; }
  fi
  [[ -z "$(git status --porcelain --untracked-files=all .agent-work)" ]] || { echo ".agent-work is not ignored"; return 1; }
  if bash "$root/install.sh" "$tmp" --repo github --os "$os" --assistant claude-code --keep-harness | grep -q '^added:'; then
    echo "re-install added files"; return 1
  fi
  sed -i 's/^ALLOW_NO_CHECKS=0/ALLOW_NO_CHECKS=1/' scripts/factory/commands.env
  bash scripts/factory/check.sh >/dev/null || { echo "check.sh failed on the repo's own hook helpers"; return 1; }
}

fail=0
for os in linux windows; do
  echo "=== keep-harness os=$os"
  tmp="$(mktemp -d)"
  ( keep_harness_one "$os" "$tmp/repo" ) || { echo "FAILED: keep-harness os=$os"; fail=1; }
  rm -rf "$tmp"
done
for repo in "${repos[@]}"; do
  for os in linux windows; do
    for assistant_dir in "$root"/template/assistant/*/; do
      assistant="$(basename "$assistant_dir")"
      # Each combination once without a cloud; the cloud layers once each on linux to keep CI short.
      clouds=(none)
      [[ "$os" == linux ]] && for c in "$root"/template/cloud/*/; do clouds+=("$(basename "$c")"); done
      for cloud in "${clouds[@]}"; do
        echo "=== repo=$repo os=$os assistant=$assistant cloud=$cloud"
        tmp="$(mktemp -d)"
        ( run_one "$repo" "$os" "$assistant" "$cloud" "$tmp" ) || { echo "FAILED: repo=$repo os=$os assistant=$assistant cloud=$cloud"; fail=1; }
        rm -rf "$tmp"
      done
    done
  done
done
if [[ $fail -eq 0 ]]; then echo "install matrix: all passed"; else echo "install matrix: FAILED"; fi
exit $fail
