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

# reuse_folder: newest existing {stamp}-{slug} is reused, else a new stamped folder; follows WORK_DIR
mkdir -p "$tmp/reuse" "$tmp/wk1" "$tmp/wk2"; cp "$src/paths.env" "$src/lib-paths.sh" "$tmp/reuse/"
sed -i "s|^WORK_DIR=.*|WORK_DIR=$tmp/wk1|" "$tmp/reuse/paths.env"
mkdir -p "$tmp/wk1/2026-01-01T00-00-00Z-slug" "$tmp/wk1/2026-02-01T00-00-00Z-slug" \
  "$tmp/wk1/2026-03-01T00-00-00Z-x-slug" "$tmp/wk1/2026-04-01T00-00-00Z-other"
reuse() { bash -c ". '$tmp/reuse/lib-paths.sh'; reuse_folder $1"; }
check "reuse newest existing" "$tmp/wk1/2026-02-01T00-00-00Z-slug/" "$(reuse slug)"
out="$(reuse fresh)"
re2="^$tmp/wk1/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-fresh/\$"
ok=no; [[ "$out" =~ $re2 ]] && ok=yes
check "reuse: new stamped folder when none" yes "$ok"
sed -i "s|^WORK_DIR=.*|WORK_DIR=$tmp/wk2|" "$tmp/reuse/paths.env"
out="$(reuse slug)"
ok=no; [[ "$out" == "$tmp/wk2/"*-slug/ ]] && ok=yes
check "reuse follows changed WORK_DIR" yes "$ok"

# find_draft: prints the draft folder whose created.txt records number=N or task=ID; nothing otherwise
mkdir -p "$tmp/dr/2026-01-01T00-00-00Z-a" "$tmp/dr/2026-01-02T00-00-00Z-b" "$tmp/dr/2026-01-03T00-00-00Z-c"
printf 'number=12\nurl=x\n' > "$tmp/dr/2026-01-01T00-00-00Z-a/created.txt"
printf 'task=T-5\n' > "$tmp/dr/2026-01-02T00-00-00Z-b/created.txt"
sed -i "s|^DRAFTS_DIR=.*|DRAFTS_DIR=$tmp/dr|" "$tmp/reuse/paths.env"
draft() { bash -c ". '$tmp/reuse/lib-paths.sh'; find_draft $1"; }
check "find_draft by issue number" "$tmp/dr/2026-01-01T00-00-00Z-a/" "$(draft 12)"
check "find_draft by task id" "$tmp/dr/2026-01-02T00-00-00Z-b/" "$(draft T-5)"
check "find_draft prefix does not match" "" "$(draft 1)"
check "find_draft no match" "" "$(draft 99)"
sed -i "s|^DRAFTS_DIR=.*|DRAFTS_DIR=$tmp/nodrafts|" "$tmp/reuse/paths.env"
draft 12 >/dev/null; check "find_draft missing dir exits 0" 0 "$?"
check "find_draft missing dir prints nothing" "" "$(draft 12)"

# Parity: the PowerShell helper gives the same result as bash for the same paths.env and a fixed UTC time
if command -v pwsh >/dev/null 2>&1; then
  pssrc="$root/template/os/windows/scripts/factory"
  fixed="2026-01-02T03-04-05Z"
  mkdir -p "$tmp/shim" "$tmp/pscopy"
  real_date="$(command -v date)"
  cat > "$tmp/shim/date" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == "-u +%Y-%m-%dT%H-%M-%SZ" ]]; then echo "$fixed"; else exec "$real_date" "\$@"; fi
SHIM
  chmod +x "$tmp/shim/date"
  cp "$src/paths.env" "$src/lib-paths.sh" "$pssrc/lib-paths.ps1" "$tmp/pscopy/"
  mkdir -p "$tmp/pscopy2"; cp "$tmp/copy/paths.env" "$tmp/copy/lib-paths.sh" "$pssrc/lib-paths.ps1" "$tmp/pscopy2/"
  for dir in "$src:$pssrc" "$tmp/pscopy2:$tmp/pscopy2"; do
    bdir="${dir%%:*}"; pdir="${dir##*:}"
    for which in drafts work; do
      b="$(PATH="$tmp/shim:$PATH" bash -c ". '$bdir/lib-paths.sh'; new_folder $which my-slug")"
      p="$(pwsh -NoProfile -Command ". '$pdir/lib-paths.ps1'; New-Folder -Kind $which -Slug my-slug -At ([datetime]'2026-01-02T03:04:05Z')" 2>&1)"
      p="${p%$'\r'}"
      check "parity $which ($(basename "$bdir")): bash == pwsh" "$b" "$p"
      if [[ "$p" =~ $re ]]; then
        check "ps $which: stamp and slug" "$fixed" "${BASH_REMATCH[2]}"
      else
        check "ps $which: output shape" "match" "no match: $p"
      fi
    done
  done
  if pwsh -NoProfile -Command ". '$pssrc/lib-paths.ps1'; New-Folder -Kind bad -Slug s" >/dev/null 2>&1; then
    check "ps bad kind fails" nonzero zero
  else
    check "ps bad kind fails" nonzero nonzero
  fi
else
  echo "skip parity (pwsh not installed)"
fi

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
