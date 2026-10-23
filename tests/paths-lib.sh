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
