#!/usr/bin/env bash
# Self-test for template/core/scripts/factory/migrate-paths.sh. Runs in throwaway git repos.
#   (a) old flat drafts, issue work and session logs move to the stamped names; the rest stays; each move printed
#   (b) a pre-existing destination refuses the run: tree byte-identical, nothing overwritten, no .layout
#   (c) a changed DRAFTS_DIR / WORK_DIR in paths.env moves stamped folders from the recorded location;
#       a new location inside the old one is refused with nothing moved
#   (d) a second run on a migrated tree exits 0, moves nothing and leaves .agent-work/.layout unchanged
# Linux only: uses GNU touch -d @EPOCH, date -d and stat -c.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/template/core/scripts/factory"
fail=0
check() { # check <description> <want> <got>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 (want $2, got $3)"; fail=1; fi
}
yn() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
T1="$(date -u -d '2026-01-02T03:04:05Z' +%s)"; S1=2026-01-02T03-04-05Z
S2=2026-02-03T04-05-06Z
at() { touch -d "@$2" "$1"; } # at <path> <epoch>: set a fixed modification time

new_repo() { # new_repo <name>: throwaway repo with the factory scripts and the old flat layout
  local r="$tmp/$1"
  mkdir -p "$r/scripts" && git -C "$r" init -q -b main
  cp -r "$src" "$r/scripts/factory"
  mkdir -p "$r/.agent-work/drafts/$S2-beta" "$r/.agent-work/issue-7" "$r/.agent-work/breakdowns" \
    "$r/.agent-work/harness" "$r/.agent-logs/batch"
  echo alpha > "$r/.agent-work/drafts/alpha.md"
  echo brief > "$r/.agent-work/issue-7/brief.md"
  echo plan > "$r/.agent-work/issue-7/plan.md"
  echo beta > "$r/.agent-work/drafts/$S2-beta/draft.md"
  echo keep > "$r/.agent-work/breakdowns/b.md"
  echo keep > "$r/.agent-work/harness/policy.txt"
  echo '{"event":"start"}' > "$r/.agent-logs/sess1.jsonl"
  echo '{"session":"x"}' > "$r/.agent-logs/index.jsonl"
  echo log > "$r/.agent-logs/batch/issue-7.log"
  at "$r/.agent-work/drafts/alpha.md" "$T1"
  at "$r/.agent-work/issue-7/brief.md" "$T1"; at "$r/.agent-work/issue-7/plan.md" "$T1"
  at "$r/.agent-work/issue-7" "$T1"; at "$r/.agent-logs/sess1.jsonl" "$T1"
  echo "$r"
}
run() { (cd "$1" && bash scripts/factory/migrate-paths.sh 2>&1); } # run <repo>; output on stdout, status in $?
manifest() { # manifest <repo>: every path and every file's checksum, so any change shows
  (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}

# (a) flat layout moves to the timestamped layout; everything else stays
a="$(new_repo a)"
out="$(run "$a")"; rc=$?
check "a: exit 0" 0 "$rc"
check "a: flat draft moved" yes "$(yn test -f "$a/.agent-work/drafts/$S1-alpha/draft.md")"
check "a: flat draft content kept" alpha "$(cat "$a/.agent-work/drafts/$S1-alpha/draft.md")"
check "a: flat draft gone" no "$(yn test -e "$a/.agent-work/drafts/alpha.md")"
check "a: flat issue work moved" brief "$(cat "$a/.agent-work/$S1-issue-7/brief.md" 2>/dev/null)"
check "a: flat issue folder gone" no "$(yn test -e "$a/.agent-work/issue-7")"
check "a: session log moved into its folder" yes "$(yn test -f "$a/.agent-logs/$S1-sess1/sess1.jsonl")"
check "a: flat session log gone" no "$(yn test -e "$a/.agent-logs/sess1.jsonl")"
check "a: index.jsonl stays" yes "$(yn test -f "$a/.agent-logs/index.jsonl")"
check "a: batch logs stay" yes "$(yn test -f "$a/.agent-logs/batch/issue-7.log")"
check "a: breakdowns and harness untouched" "keep:keep" "$(cat "$a/.agent-work/breakdowns/b.md"):$(cat "$a/.agent-work/harness/policy.txt")"
check "a: stamped draft untouched" beta "$(cat "$a/.agent-work/drafts/$S2-beta/draft.md")"
check "a: output lists draft move" yes "$(grep -qF -- ".agent-work/drafts/alpha.md -> .agent-work/drafts/$S1-alpha/draft.md" <<<"$out" && echo yes || echo no)"
check "a: output lists issue move" yes "$(grep -qF -- ".agent-work/issue-7 -> .agent-work/$S1-issue-7" <<<"$out" && echo yes || echo no)"
check "a: output lists session move" yes "$(grep -qF -- ".agent-logs/sess1.jsonl -> .agent-logs/$S1-sess1/sess1.jsonl" <<<"$out" && echo yes || echo no)"
check "a: layout records the applied locations" "$(printf 'DRAFTS_DIR=.agent-work/drafts\nWORK_DIR=.agent-work')" "$(cat "$a/.agent-work/.layout")"

# (d) rerun on the migrated tree changes nothing
m_a="$(manifest "$a")"
out="$(run "$a")"; rc=$?
check "d: rerun exit 0" 0 "$rc"
check "d: rerun changes nothing" "$m_a" "$(manifest "$a")"
check "d: rerun prints no moves" 0 "$(grep -c -- ' -> ' <<<"$out")"

# (b) a pre-existing destination refuses the whole run
b="$(new_repo b)"
mkdir -p "$b/.agent-work/drafts/$S1-alpha" && echo keep > "$b/.agent-work/drafts/$S1-alpha/draft.md"
m_b="$(manifest "$b")"
run "$b" >/dev/null; rc=$?
check "b: exit non-zero" yes "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "b: tree byte-identical" "$m_b" "$(manifest "$b")"
check "b: existing draft not overwritten" keep "$(cat "$b/.agent-work/drafts/$S1-alpha/draft.md")"
check "b: no layout written" no "$(yn test -e "$b/.agent-work/.layout")"

# (c) changed locations in paths.env move stamped folders from the recorded location
c="$(new_repo c)"
run "$c" >/dev/null; rc=$?
check "c: first run exit 0" 0 "$rc"
sed -i 's|^DRAFTS_DIR=.*|DRAFTS_DIR=elsewhere/drafts|' "$c/scripts/factory/paths.env"
out="$(run "$c")"; rc=$?
check "c: DRAFTS_DIR change exit 0" 0 "$rc"
check "c: stamped draft moved to new DRAFTS_DIR" yes "$(yn test -f "$c/elsewhere/drafts/$S1-alpha/draft.md")"
check "c: old draft folder gone" no "$(yn test -e "$c/.agent-work/drafts/$S1-alpha")"
check "c: issue work stays while WORK_DIR is unchanged" yes "$(yn test -f "$c/.agent-work/$S1-issue-7/brief.md")"
check "c: layout records new DRAFTS_DIR" yes "$(grep -qx 'DRAFTS_DIR=elsewhere/drafts' "$c/.agent-work/.layout" && echo yes || echo no)"
sed -i 's|^WORK_DIR=.*|WORK_DIR=elsewhere/work|' "$c/scripts/factory/paths.env"
out="$(run "$c")"; rc=$?
check "c: WORK_DIR change exit 0" 0 "$rc"
check "c: issue work moved to new WORK_DIR" yes "$(yn test -f "$c/elsewhere/work/$S1-issue-7/brief.md")"
mkdir -p "$c/elsewhere/drafts/$S2-delta"
sed -i 's|^DRAFTS_DIR=.*|DRAFTS_DIR=elsewhere/drafts/inner|' "$c/scripts/factory/paths.env"
m_c="$(manifest "$c")"
run "$c" >/dev/null; rc=$?
check "c: nested new location refused" yes "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "c: nested refusal moves nothing" "$m_c" "$(manifest "$c")"

exit "$fail"
