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
  # Windows hook logger: per-session UTC-timestamped folder (same layout as common.sh); deny lists untouched.
  if [[ "$os" == windows ]]; then
    grep -q 'Z-\$sid' .github/hooks/scripts/common.ps1 || { echo "common.ps1 lacks the Z-\$sid session folder logic"; return 1; }
    for f in deny-paths.txt deny-commands.txt; do
      # Layers only append to the core list, so the installed file must start with it unchanged.
      cmp -s -n "$(stat -c %s "$root/template/core/.github/hooks/policy/$f")" ".github/hooks/policy/$f" \
        "$root/template/core/.github/hooks/policy/$f" || { echo "$f no longer starts with the template list"; return 1; }
    done
  fi
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

# The migration through install.sh (not migrate-paths.sh directly). Stamps come from fixed UTC mtimes,
# so the expected names are fixed strings. Each scenario gets its own fresh repo.
migrate_one() {
  local tmp="$1" out when stamp="2026-01-02T03-04-05Z" pair before
  when="@$(date -u -d '2026-01-02T03:04:05Z' +%s)"
  # AC1: old flat files, then a plain re-run moves each one to its stamped name.
  mkdir -p "$tmp/a" && cd "$tmp/a" || return 1
  git init -q -b main . && git config user.email t@t && git config user.name t || return 1
  echo "# scratch" > README.md && git add -A && git commit -qm init || return 1
  bash "$root/install.sh" "$tmp/a" --repo github --os linux --assistant claude-code >/dev/null || { echo "install failed"; return 1; }
  mkdir -p .agent-work/drafts .agent-work/issue-7 .agent-logs
  echo alpha > .agent-work/drafts/alpha.md && touch -d "$when" .agent-work/drafts/alpha.md
  echo brief > .agent-work/issue-7/brief.md && touch -d "$when" .agent-work/issue-7
  echo sess > .agent-logs/sess1.jsonl && touch -d "$when" .agent-logs/sess1.jsonl
  out="$(bash "$root/install.sh" "$tmp/a" --repo github --os linux --assistant claude-code)" || { echo "re-install failed"; return 1; }
  for pair in ".agent-work/drafts/alpha.md -> .agent-work/drafts/$stamp-alpha/draft.md" \
              ".agent-work/issue-7 -> .agent-work/$stamp-issue-7" \
              ".agent-logs/sess1.jsonl -> .agent-logs/$stamp-sess1/sess1.jsonl"; do
    grep -qxF "$pair" <<<"$out" || { echo "no move line: $pair"; return 1; }
  done
  [[ -f ".agent-work/drafts/$stamp-alpha/draft.md" && -f ".agent-work/$stamp-issue-7/brief.md" \
     && -f ".agent-logs/$stamp-sess1/sess1.jsonl" ]] || { echo "moved files missing"; return 1; }
  [[ ! -e .agent-work/drafts/alpha.md && ! -e .agent-work/issue-7 && ! -e .agent-logs/sess1.jsonl ]] \
    || { echo "flat sources still present"; return 1; }

  # AC2: DRAFTS_DIR edited in the kept paths.env, then --force twice.
  mkdir -p "$tmp/b" && cd "$tmp/b" || return 1
  git init -q -b main . && git config user.email t@t && git config user.name t || return 1
  echo "# scratch" > README.md && git add -A && git commit -qm init || return 1
  bash "$root/install.sh" "$tmp/b" --repo github --os linux --assistant claude-code >/dev/null || { echo "install failed"; return 1; }
  sed -i 's|^DRAFTS_DIR=.agent-work/drafts$|DRAFTS_DIR=elsewhere/drafts|' scripts/factory/paths.env
  grep -qxF 'DRAFTS_DIR=elsewhere/drafts' scripts/factory/paths.env || { echo "test setup: paths.env not edited"; return 1; }
  mkdir -p .agent-work/drafts && echo gamma > .agent-work/drafts/gamma.md && touch -d "$when" .agent-work/drafts/gamma.md
  out="$(bash "$root/install.sh" "$tmp/b" --repo github --os linux --assistant claude-code --force)" || { echo "--force failed"; return 1; }
  grep -qxF 'kept (your edits): scripts/factory/paths.env' <<<"$out" || { echo "paths.env not reported as kept"; return 1; }
  grep -qxF 'DRAFTS_DIR=elsewhere/drafts' scripts/factory/paths.env || { echo "edited DRAFTS_DIR was overwritten"; return 1; }
  grep -qxF ".agent-work/drafts/gamma.md -> elsewhere/drafts/$stamp-gamma/draft.md" <<<"$out" \
    || { echo "gamma move line missing"; return 1; }
  [[ -f "elsewhere/drafts/$stamp-gamma/draft.md" && ! -e .agent-work/drafts/gamma.md ]] || { echo "gamma not moved"; return 1; }
  before="$(snapshot)"
  out="$(bash "$root/install.sh" "$tmp/b" --repo github --os linux --assistant claude-code --force)" || { echo "second --force failed"; return 1; }
  if grep -q ' -> ' <<<"$out"; then echo "second --force moved something"; return 1; fi
  [[ "$before" == "$(snapshot)" ]] || { echo "second --force changed files"; return 1; }
  return 0
}

# A git worktree as the target (its .git is a file, not a directory) installs like a normal checkout.
worktree_one() {
  local tmp="$1"
  mkdir -p "$tmp/main" && cd "$tmp/main" || return 1
  git init -q -b main . && git config user.email t@t && git config user.name t || return 1
  echo "# scratch" > README.md && git add -A && git commit -qm init || return 1
  git worktree add -q -b wt "$tmp/wt" || return 1
  [[ -f "$tmp/wt/.git" ]] || { echo "test setup: worktree .git is not a file"; return 1; }
  bash "$root/install.sh" "$tmp/wt" --repo github >/dev/null || { echo "install into a worktree failed"; return 1; }
  [[ -f "$tmp/wt/scripts/factory/run-issue.sh" ]] || { echo "worktree install wrote no factory scripts"; return 1; }
  bash "$root/install.sh" "$tmp/nope" --repo github >/dev/null 2>&1 && { echo "install into a non-repo succeeded"; return 1; }
  mkdir -p "$tmp/plain"
  bash "$root/install.sh" "$tmp/plain" --repo github >/dev/null 2>&1 && { echo "install into a plain folder succeeded"; return 1; }
  return 0
}

fail=0
echo "=== install into a git worktree"
tmp="$(mktemp -d)"
( worktree_one "$tmp" ) || { echo "FAILED: install into a git worktree"; fail=1; }
rm -rf "$tmp"
for os in linux windows; do
  echo "=== keep-harness os=$os"
  tmp="$(mktemp -d)"
  ( keep_harness_one "$os" "$tmp/repo" ) || { echo "FAILED: keep-harness os=$os"; fail=1; }
  rm -rf "$tmp"
done
echo "=== migrate through install.sh"
tmp="$(mktemp -d)"
( migrate_one "$tmp" ) || { echo "FAILED: migrate through install.sh"; fail=1; }
rm -rf "$tmp"
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
