#!/usr/bin/env bash
# Moves factory files into the timestamped layout. Run it with no agent session active:
#   bash scripts/factory/migrate-paths.sh
#
# What moves (each move is printed as "from -> to", paths relative to the repo root):
#   <old drafts>/<id>.md          -> <DRAFTS_DIR>/<stamp>-<id>/draft.md      old flat draft
#   <old work>/issue-N/           -> <WORK_DIR>/<stamp>-issue-N/            old flat issue work
#   .agent-logs/<session>.jsonl   -> .agent-logs/<stamp>-<session>/<session>.jsonl
#   <old drafts>/<stamp>-<slug>/  -> <DRAFTS_DIR>/<stamp>-<slug>/           DRAFTS_DIR changed
#   <old work>/<stamp>-<slug>/    -> <WORK_DIR>/<stamp>-<slug>/             WORK_DIR changed
# "old" is the location recorded in .agent-work/.layout by the last run; without that file the
# defaults (.agent-work/drafts, .agent-work) are used. <stamp> is the UTC modification time of the
# moved item, YYYY-MM-DDTHH-MM-SSZ, so reuse_folder keeps the order. index.jsonl and batch/ stay put.
#
# Safety: every destination is checked before anything moves. If one exists, or a new location is
# inside the old one, nothing moves and the script exits 1. Moves use mv -n. .agent-work/.layout is
# written last, after all moves succeed, so a failed run is finished by running again, and a second
# run on a migrated tree moves nothing.
set -euo pipefail
shopt -s nullglob

root="$(git rev-parse --show-toplevel)"
cd "$root"
# shellcheck disable=SC1091
. scripts/factory/paths.env

layout=".agent-work/.layout"
old_drafts=".agent-work/drafts"
old_work=".agent-work"
if [[ -f "$layout" ]]; then
  while IFS='=' read -r key val; do
    case "$key" in
      DRAFTS_DIR) old_drafts="$val" ;;
      WORK_DIR) old_work="$val" ;;
    esac
  done < "$layout"
fi

abs() { # abs <path>: absolute, no trailing slash
  local p="${1%/}"
  [[ "$p" == /* ]] || p="$root/$p"
  printf '%s\n' "$p"
}
rel() { # rel <absolute path>: relative to the repo root when inside it
  printf '%s\n' "${1#"$root"/}"
}
mtime_stamp() { # mtime_stamp <path>: UTC modification time as YYYY-MM-DDTHH-MM-SSZ
  local e
  if e="$(stat -c %Y -- "$1" 2>/dev/null)"; then
    date -u -d "@$e" +%Y-%m-%dT%H-%M-%SZ
  else
    e="$(stat -f %m -- "$1")"
    date -u -r "$e" +%Y-%m-%dT%H-%M-%SZ
  fi
}
check_location() { # check_location <name> <old abs> <new abs>
  if [[ "$2" != "$3" && "$3" == "$2"/* ]]; then
    echo "migrate-paths: refusing, nothing moved: $1 location $(rel "$3") is inside the old $(rel "$2")" >&2
    exit 1
  fi
}

old_d="$(abs "$old_drafts")"; new_d="$(abs "$DRAFTS_DIR")"
old_w="$(abs "$old_work")";   new_w="$(abs "$WORK_DIR")"
logs="$root/.agent-logs"
check_location drafts "$old_d" "$new_d"
check_location work "$old_w" "$new_w"

from=()
to=()
add() { from+=("$1"); to+=("$2"); }

# old flat drafts: <old drafts>/<id>.md
for f in "$old_d"/*.md; do
  [[ -f "$f" ]] || continue
  id="$(basename "$f" .md)"
  add "$f" "$new_d/$(mtime_stamp "$f")-$id/draft.md"
done
# old flat issue work: <old work>/issue-N/
for d in "$old_w"/issue-*; do
  [[ -d "$d" && ! -L "$d" ]] || continue
  n="$(basename "$d")"
  [[ "$n" =~ ^issue-[0-9]+$ ]] || continue
  add "$d" "$new_w/$(mtime_stamp "$d")-$n"
done
# old flat session logs: .agent-logs/<session>.jsonl (index.jsonl stays)
for f in "$logs"/*.jsonl; do
  [[ -f "$f" && ! -L "$f" && "$(basename "$f")" != index.jsonl ]] || continue
  session="$(basename "$f" .jsonl)"
  add "$f" "$logs/$(mtime_stamp "$f")-$session/$session.jsonl"
done
# stamped folders in a location that changed in paths.env
move_stamped() { # move_stamped <old abs> <new abs>
  [[ "$1" != "$2" ]] || return 0
  local d
  for d in "$1"/????-??-??T??-??-??Z-*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    add "$d" "$2/$(basename "$d")"
  done
}
move_stamped "$old_d" "$new_d"
move_stamped "$old_w" "$new_w"

if (( ${#from[@]} > 0 )); then
  # Preflight: every destination must be free and unique, and every source unique, before any move.
  bad=()
  for i in "${!from[@]}"; do
    if [[ -e "${to[$i]}" || -L "${to[$i]}" ]]; then
      bad+=("exists: $(rel "${to[$i]}") (for $(rel "${from[$i]}"))")
    fi
  done
  dup_from="$(printf '%s\n' "${from[@]}" | sort | uniq -d)"
  dup_to="$(printf '%s\n' "${to[@]}" | sort | uniq -d)"
  [[ -z "$dup_from" && -z "$dup_to" ]] || bad+=("two moves share a source or destination")
  if (( ${#bad[@]} > 0 )); then
    echo "migrate-paths: refusing, nothing moved:" >&2
    printf '  %s\n' "${bad[@]}" >&2
    exit 1
  fi

  for i in "${!from[@]}"; do
    mkdir -p "$(dirname "${to[$i]}")"
    mv -n -- "${from[$i]}" "${to[$i]}"
    if [[ -e "${from[$i]}" || ! -e "${to[$i]}" ]]; then
      echo "migrate-paths: move failed: $(rel "${from[$i]}") -> $(rel "${to[$i]}"); rerun after fixing it" >&2
      exit 1
    fi
    echo "$(rel "${from[$i]}") -> $(rel "${to[$i]}")"
  done
else
  echo "migrate-paths: nothing to move"
fi

# Record the applied locations last, so a rerun after a failure still sees the old ones.
mkdir -p "$(dirname "$layout")"
printf 'DRAFTS_DIR=%s\nWORK_DIR=%s\n' "$DRAFTS_DIR" "$WORK_DIR" > "$layout.tmp"
if ! cmp -s "$layout.tmp" "$layout" 2>/dev/null; then
  mv "$layout.tmp" "$layout"
else
  rm -f "$layout.tmp"
fi
