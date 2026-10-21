#!/usr/bin/env bash
# Checks scripts/factory/paths.env and the bash path helper lib-paths.sh:
#   - drafts and issue-work locations are separate items with the default values
#   - new_folder returns <location>/<UTC YYYY-MM-DDTHH-MM-SSZ>-<slug>/ from any cwd
#   - overriding one location in paths.env changes only that location
#   - paths.env has no log setting and the guard policy files are unchanged
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/template/core/scripts/factory"
fail=0
check() { # check <description> <want> <got>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 (want $2, got $3)"; fail=1; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# AC1: separate items with the stated defaults
check "paths.env DRAFTS_DIR default" ".agent-work/drafts" "$(bash -c ". '$src/paths.env'; echo \"\${DRAFTS_DIR-}\"")"
check "paths.env WORK_DIR default" ".agent-work" "$(bash -c ". '$src/paths.env'; echo \"\${WORK_DIR-}\"")"

# AC2: helper output shape, UTC stamp, any cwd
re='^([^ ]+)/([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z)-my-slug/$'
for which in drafts work; do
  want_loc=".agent-work"; [[ "$which" == drafts ]] && want_loc=".agent-work/drafts"
  before="$(date -u +%Y-%m-%dT%H-%M)"
  out="$(cd "$tmp" && bash -c ". '$src/lib-paths.sh'; new_folder $which my-slug")"
  after="$(date -u +%Y-%m-%dT%H-%M)"
  if [[ "$out" =~ $re ]]; then
    check "$which: location" "$want_loc" "${BASH_REMATCH[1]}"
    stamp="${BASH_REMATCH[2]}"
    ok=no; [[ "${stamp:0:16}" == "$before" || "${stamp:0:16}" == "$after" ]] && ok=yes
    check "$which: stamp is current UTC" yes "$ok"
  else
    check "$which: output shape" "match" "no match: $out"
  fi
done

# Overriding one location changes only that one
mkdir -p "$tmp/copy"; cp "$src/paths.env" "$src/lib-paths.sh" "$tmp/copy/"
sed -i 's|^DRAFTS_DIR=.*|DRAFTS_DIR=elsewhere/drafts|' "$tmp/copy/paths.env"
d="$(bash -c ". '$tmp/copy/lib-paths.sh'; new_folder drafts s")"
w="$(bash -c ". '$tmp/copy/lib-paths.sh'; new_folder work s")"
check "override changes drafts" "elsewhere/drafts" "${d%/*????-??-??T??-??-??Z-s/}"
check "override leaves work" ".agent-work" "${w%/*????-??-??T??-??-??Z-s/}"

# AC3: no log setting; policy files unchanged
check "paths.env has no log setting" 0 "$(grep -v '^[[:space:]]*#' "$src/paths.env" | grep -ci log)"
base=""
for r in origin/main main; do git -C "$root" rev-parse --verify -q "$r" >/dev/null && { base="$r"; break; }; done
if [[ -z "$base" ]]; then
  echo "skip policy unchanged (no origin/main or main ref)"
elif git -C "$root" diff --quiet "$base"... -- .github/hooks/policy; then
  check "guard policy files unchanged" 0 0
else
  check "guard policy files unchanged" 0 1
fi

exit "$fail"
