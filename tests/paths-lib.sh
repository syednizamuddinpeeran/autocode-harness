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

  # Get-ReusableFolder and Find-Draft: same result as the bash reuse_folder and find_draft for the same paths.env
  rf="$tmp/rf"; mkdir -p "$rf/wk1" "$rf/wk2" "$rf/dr"
  cp "$src/paths.env" "$src/lib-paths.sh" "$pssrc/lib-paths.ps1" "$rf/"
  sed -i "s|^WORK_DIR=.*|WORK_DIR=$rf/wk1|; s|^DRAFTS_DIR=.*|DRAFTS_DIR=$rf/dr|" "$rf/paths.env"
  mkdir -p "$rf/wk1/2026-01-01T00-00-00Z-slug" "$rf/wk1/2026-02-01T00-00-00Z-slug" "$rf/wk1/2026-03-01T00-00-00Z-x-slug"
  bash_reuse() { PATH="$tmp/shim:$PATH" bash -c ". '$rf/lib-paths.sh'; reuse_folder $1"; }
  ps_run() { pwsh -NoProfile -Command ". '$rf/lib-paths.ps1'; $1" 2>&1; }

  # AC1: newest existing folder is reused, decoy x-slug ignored, no folder created
  b="$(bash_reuse slug)"
  before="$(find "$rf/wk1" -mindepth 1 -maxdepth 1 | wc -l)"
  p="$(ps_run 'Get-ReusableFolder -Slug slug')"; p="${p%$'\r'}"
  after="$(find "$rf/wk1" -mindepth 1 -maxdepth 1 | wc -l)"
  check "ps reuse newest: bash == pwsh" "$b" "$p"
  check "ps reuse newest: 2026-02 folder" "$rf/wk1/2026-02-01T00-00-00Z-slug/" "$p"
  check "ps reuse creates no folder" "$before" "$after"

  # AC2: no match creates <stamp>-fresh under WORK_DIR and prints it (fixed time via the date shim for bash)
  b="$(bash_reuse fresh)"
  p="$(ps_run "Get-ReusableFolder -Slug fresh -At ([datetime]'2026-01-02T03:04:05Z')")"; p="${p%$'\r'}"
  check "ps reuse fresh: bash == pwsh" "$b" "$p"
  ok=no; [[ -d "${p%/}" ]] && ok=yes
  check "ps reuse fresh folder exists" yes "$ok"

  # AC3: WORK_DIR changed in paths.env is followed on the next call
  mkdir -p "$rf/wk2/2026-05-01T00-00-00Z-slug"
  sed -i "s|^WORK_DIR=.*|WORK_DIR=$rf/wk2|" "$rf/paths.env"
  b="$(bash_reuse slug)"
  p="$(ps_run 'Get-ReusableFolder -Slug slug')"; p="${p%$'\r'}"
  check "ps reuse follows changed WORK_DIR: bash == pwsh" "$b" "$p"
  check "ps reuse follows changed WORK_DIR: wk2 folder" "$rf/wk2/2026-05-01T00-00-00Z-slug/" "$p"
  pwsh -NoProfile -Command ". '$rf/lib-paths.ps1'; Get-ReusableFolder -Slug ''" >/dev/null 2>&1; rc=$?
  ok=zero; [[ "$rc" -ne 0 ]] && ok=nonzero
  check "ps reuse empty slug fails" nonzero "$ok"

  # AC4: Find-Draft matches whole number= / task= lines; prefix and no match print nothing
  mkdir -p "$rf/dr/2026-01-01T00-00-00Z-a" "$rf/dr/2026-01-02T00-00-00Z-b" "$rf/dr/2026-01-03T00-00-00Z-c"
  printf 'number=12\nurl=x\n' > "$rf/dr/2026-01-01T00-00-00Z-a/created.txt"
  printf 'task=T-5\n' > "$rf/dr/2026-01-02T00-00-00Z-b/created.txt"
  draft() { bash -c ". '$rf/lib-paths.sh'; find_draft $1"; }
  for v in 12 T-5 1 99; do
    b="$(draft "$v")"
    p="$(ps_run "Find-Draft -Value '$v'")"; p="${p%$'\r'}"
    check "ps find_draft $v: bash == pwsh" "$b" "$p"
  done
  check "ps find_draft number: a folder" "$rf/dr/2026-01-01T00-00-00Z-a/" "$(ps_run "Find-Draft -Value '12'")"
  check "ps find_draft task: b folder" "$rf/dr/2026-01-02T00-00-00Z-b/" "$(ps_run "Find-Draft -Value 'T-5'")"
  check "ps find_draft prefix prints nothing" "" "$(ps_run "Find-Draft -Value '1'")"

  # AC4: missing DRAFTS_DIR prints nothing and the pwsh process exits 0
  sed -i "s|^DRAFTS_DIR=.*|DRAFTS_DIR=$rf/nodrafts|" "$rf/paths.env"
  b="$(draft 12)"
  p="$(ps_run "Find-Draft -Value '12'")"; p="${p%$'\r'}"
  check "ps find_draft missing dir: bash == pwsh" "$b" "$p"
  pwsh -NoProfile -Command ". '$rf/lib-paths.ps1'; Find-Draft -Value '12'" >/dev/null 2>&1
  check "ps find_draft missing dir exits 0" 0 "$?"
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
