#!/usr/bin/env bash
# Self-test for install.sh on an existing target: the migration runs after the copy, and an edited
# scripts/factory/paths.env is kept. Runs in throwaway git repos.
#   (a) AC1: old flat drafts and issue work move to the stamped layout during install
#   (b) AC2: --force keeps an edited paths.env, prints the kept line, and moves files to its DRAFTS_DIR
#   (c) AC3: a migration that refuses makes install exit non-zero
#   (d) an unedited paths.env is skipped on --force with "skip (exists)" and no kept line
# Linux only: uses GNU touch -d @EPOCH and date -d.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$root/install.sh"
fail=0
check() { # check <description> <want> <got>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 (want $2, got $3)"; fail=1; fi
}
yn() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
T1="$(date -u -d '2026-01-02T03:04:05Z' +%s)"; S1=2026-01-02T03-04-05Z
at() { touch -d "@$2" "$1"; } # at <path> <epoch>: set a fixed modification time

new_repo() { # new_repo <name>: throwaway git repo with the old flat layout and no factory installed
  local r="$tmp/$1"
  mkdir -p "$r/.agent-work/drafts" "$r/.agent-work/issue-7"
  git -C "$r" init -q -b main
  echo alpha > "$r/.agent-work/drafts/alpha.md"
  echo brief > "$r/.agent-work/issue-7/brief.md"
  echo plan > "$r/.agent-work/issue-7/plan.md"
  at "$r/.agent-work/drafts/alpha.md" "$T1"
  at "$r/.agent-work/issue-7/brief.md" "$T1"; at "$r/.agent-work/issue-7/plan.md" "$T1"
  at "$r/.agent-work/issue-7" "$T1"
  echo "$r"
}

# (a) flat layout is migrated by the install itself
a="$(new_repo a)"
out="$(bash "$installer" "$a" --repo github 2>&1)"; rc=$?
check "a: exit 0" 0 "$rc"
check "a: flat draft moved" yes "$(yn test -f "$a/.agent-work/drafts/$S1-alpha/draft.md")"
check "a: flat draft content kept" alpha "$(cat "$a/.agent-work/drafts/$S1-alpha/draft.md" 2>/dev/null)"
check "a: flat draft gone" no "$(yn test -e "$a/.agent-work/drafts/alpha.md")"
check "a: flat issue work moved" brief "$(cat "$a/.agent-work/$S1-issue-7/brief.md" 2>/dev/null)"
check "a: flat issue folder gone" no "$(yn test -e "$a/.agent-work/issue-7")"
check "a: output lists draft move" yes "$(grep -qF -- ".agent-work/drafts/alpha.md -> .agent-work/drafts/$S1-alpha/draft.md" <<<"$out" && echo yes || echo no)"
check "a: output lists issue move" yes "$(grep -qF -- ".agent-work/issue-7 -> .agent-work/$S1-issue-7" <<<"$out" && echo yes || echo no)"
check "a: default install writes no .layout" no "$(yn test -e "$a/.agent-work/.layout")"

# (b) --force keeps an edited paths.env and migrates to the locations it names
b="$(new_repo b)"
bash "$installer" "$b" --repo github >/dev/null 2>&1
cp "$b/scripts/factory/lib-paths.sh" "$tmp/b-lib-paths.fresh"
sed -i 's|^DRAFTS_DIR=.*|DRAFTS_DIR=elsewhere/drafts|' "$b/scripts/factory/paths.env"
echo "# edited" >> "$b/scripts/factory/lib-paths.sh"
cp "$b/scripts/factory/paths.env" "$tmp/b-paths.env.saved"
out="$(bash "$installer" "$b" --repo github --force 2>&1)"; rc=$?
check "b: --force exit 0" 0 "$rc"
check "b: edited paths.env byte-identical" yes "$(yn cmp -s "$tmp/b-paths.env.saved" "$b/scripts/factory/paths.env")"
check "b: kept line printed" yes "$(grep -qxF 'kept (your edits): scripts/factory/paths.env' <<<"$out" && echo yes || echo no)"
check "b: draft moved to edited DRAFTS_DIR" yes "$(yn test -f "$b/elsewhere/drafts/$S1-alpha/draft.md")"
check "b: old draft folder gone" no "$(yn test -e "$b/.agent-work/drafts/alpha.md")"
check "b: other factory files still overwritten" yes "$(yn cmp -s "$tmp/b-lib-paths.fresh" "$b/scripts/factory/lib-paths.sh")"

# (c) a migration that refuses makes install exit non-zero
c="$(new_repo c)"
mkdir -p "$c/.agent-work/drafts/$S1-alpha" && echo keep > "$c/.agent-work/drafts/$S1-alpha/draft.md"
out="$(bash "$installer" "$c" --repo github 2>&1)"; rc=$?
check "c: exit non-zero" yes "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "c: output names the migration failure" yes "$(grep -qF 'migration failed' <<<"$out" && echo yes || echo no)"
check "c: existing draft not overwritten" keep "$(cat "$c/.agent-work/drafts/$S1-alpha/draft.md")"

# (d) an unedited paths.env is skipped, not reported as kept
d="$(new_repo d)"
bash "$installer" "$d" --repo github >/dev/null 2>&1
out="$(bash "$installer" "$d" --repo github --force 2>&1)"; rc=$?
check "d: --force re-install exit 0" 0 "$rc"
check "d: skip line printed" yes "$(grep -qxF 'skip (exists): scripts/factory/paths.env' <<<"$out" && echo yes || echo no)"
check "d: no kept line" 0 "$(grep -c 'kept (your edits)' <<<"$out")"

exit "$fail"
