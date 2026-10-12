#!/usr/bin/env bash
# install.sh and install.ps1 must produce identical files for every combination. Needs pwsh.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pwsh >/dev/null || { echo "pwsh not found" >&2; exit 1; }
fail=0
for repo_dir in "$root"/template/repo/*/; do
  repo="$(basename "$repo_dir")"
  for os in linux wsl windows; do
    for assistant_dir in "$root"/template/assistant/*/; do
      assistant="$(basename "$assistant_dir")"
      a="$(mktemp -d)"; b="$(mktemp -d)"
      for d in "$a" "$b"; do (cd "$d" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i); done
      for cloud in none aws; do
        rm -rf "$a" "$b"; mkdir -p "$a" "$b"
        for d in "$a" "$b"; do (cd "$d" && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i); done
        bash "$root/install.sh" "$a" --repo "$repo" --os "$os" --assistant "$assistant" --cloud "$cloud" >/dev/null
        pwsh -NoProfile -File "$root/install.ps1" "$b" -Repo "$repo" -Os "$os" -Assistant "$assistant" -Cloud "$cloud" >/dev/null
        if diff -r -x .git "$a" "$b" >/dev/null; then echo "same: repo=$repo os=$os assistant=$assistant cloud=$cloud"
        else echo "DIFFERENT: repo=$repo os=$os assistant=$assistant cloud=$cloud"; diff -r -x .git "$a" "$b" | head -20; fail=1; fi
      done
      rm -rf "$a" "$b"
    done
  done
done
# --keep-harness / -KeepHarness, into clones of this repo (which has its own harness).
for os in linux windows; do
  for assistant_dir in "$root"/template/assistant/*/; do
    assistant="$(basename "$assistant_dir")"
    a="$(mktemp -d)"; b="$(mktemp -d)"
    git clone -q "$root" "$a/r" && git clone -q "$root" "$b/r"
    bash "$root/install.sh" "$a/r" --os "$os" --assistant "$assistant" --keep-harness >/dev/null
    pwsh -NoProfile -File "$root/install.ps1" "$b/r" -Os "$os" -Assistant "$assistant" -KeepHarness >/dev/null
    if diff -r -x .git "$a/r" "$b/r" >/dev/null; then echo "same: keep-harness os=$os assistant=$assistant"
    else echo "DIFFERENT: keep-harness os=$os assistant=$assistant"; diff -r -x .git "$a/r" "$b/r" | head -20; fail=1; fi
    rm -rf "$a" "$b"
  done
done
exit $fail
