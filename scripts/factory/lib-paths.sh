#!/usr/bin/env bash
# Path helper. Source it: . scripts/factory/lib-paths.sh
#   new_folder <drafts|work> <slug>
# prints <location>/<YYYY-MM-DDTHH-MM-SSZ>-<slug>/ (UTC stamp), where the location comes from paths.env.
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
