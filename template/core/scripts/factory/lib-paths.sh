#!/usr/bin/env bash
# Path helper. Source it: . scripts/factory/lib-paths.sh
#   new_folder <drafts|work> <slug>
# prints <location>/<YYYY-MM-DDTHH-MM-SSZ>-<slug>/ (UTC stamp), where the location comes from paths.env.
#   reuse_folder <slug>
# prints the newest existing <WORK_DIR>/<stamp>-<slug>/, else a new one like new_folder work <slug>.
#   find_draft <value>
# prints the <DRAFTS_DIR>/<folder>/ whose created.txt has number=<value> or task=<value>; nothing if none.
_paths_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_paths_dir/paths.env"

new_folder() {
  local loc
  case "${1:-}" in
    drafts) loc="$DRAFTS_DIR" ;;
    work) loc="$WORK_DIR" ;;
    *) echo "new_folder: first argument must be 'drafts' or 'work'" >&2; return 2 ;;
  esac
  [[ -n "${2:-}" ]] || { echo "new_folder: slug required" >&2; return 2; }
  printf '%s/%s-%s/\n' "${loc%/}" "$(date -u +%Y-%m-%dT%H-%M-%SZ)" "$2"
}

reuse_folder() {
  [[ -n "${1:-}" ]] || { echo "reuse_folder: slug required" >&2; return 2; }
  local d best=""
  for d in "${WORK_DIR%/}"/????-??-??T??-??-??Z-"$1"; do
    [[ -d "$d" ]] && best="$d"
  done
  if [[ -n "$best" ]]; then printf '%s/\n' "$best"; else new_folder work "$1"; fi
}

find_draft() {
  [[ -n "${1:-}" ]] || { echo "find_draft: value required" >&2; return 2; }
  local f
  for f in "${DRAFTS_DIR%/}"/*/created.txt; do
    [[ -f "$f" ]] || continue
    if grep -qxF -e "number=$1" -e "task=$1" "$f"; then
      printf '%s/\n' "$(dirname "$f")"
      return 0
    fi
  done
  return 0
}
