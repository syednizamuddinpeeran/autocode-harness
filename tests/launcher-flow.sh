#!/usr/bin/env bash
# End-to-end launcher flow with fake `copilot` and `gh` CLIs (no network, no real agent):
#   - not ready  → exit 4 and the agent never starts
#   - ready, agent writes questions.md → exit 5 and the questions are shown
#   - ready, agent finishes → exit 0
#   - github: agent commits but opens no PR → exit 7 (with an open PR → exit 0)
#   - github: agent ends with nothing (no commits, PR, questions or breakdown) → exit 8
#   - github: a leftover agent/issue-N branch without a worktree is reused (kept when it has commits)
#   - github: run-batch retries a failing GitHub API call
#   - claude-code: the autonomous run lifts the background-task time limit
#   - local: an edited task restarts a worktree that has no commits yet
#   - agent proposes a breakdown → exit 6, saved; create-tasks / create-issues create the sub-items
#   - pwsh (run-issue.ps1, when pwsh is installed): stamped work folder reused, WORK_DIR followed, and
#     questions.md / breakdown.md filed in the recorded draft folder as in bash
#   - windows (pwsh, skipped without pwsh): run-task.ps1 uses the stamped work folder, names it in the prompt,
#     and files questions / breakdown in the recorded draft folder
#   - windows (pwsh, skipped without pwsh): create-issues.ps1 reuses sub-issues by title and refuses a duplicate title
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fx="$root/tests/fixtures/ready"
fail=0
check() { # check <description> <want> <got>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 (want $2, got $3)"; fail=1; fi
}

tmp="${KEEP_TMP:-$(mktemp -d)}"; [[ -n "${KEEP_TMP:-}" ]] || trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; mkdir -p "$bin"
# Fake agent CLI: records that it ran; writes questions.md when FAKE_AGENT=questions.
cat > "$bin/copilot" <<'SH'
#!/usr/bin/env bash
# Analyst session (new-draft): write the draft the "human" would end up with.
if [[ "$1 $2" == "--agent analyst" ]]; then
  [[ -n "${FAKE_DRAFT:-}" ]] && cp "$FAKE_DRAFT" .agent-work/draft.md
  # Record whether an earlier Q&A file was staged in before this session, then write the new one.
  if [[ -f .agent-work/questions-and-answers.md ]]; then echo staged >> "$FAKE_LOG.qa"; else echo absent >> "$FAKE_LOG.qa"; fi
  [[ -n "${FAKE_QA:-}" ]] && cp "$FAKE_QA" .agent-work/questions-and-answers.md
  echo "analyst:$PWD" >> "$FAKE_LOG.analyst"
  exit 0
fi
echo ran >> "$FAKE_LOG"
# Record the prompt the agent received, one argument per line (the pwsh block checks its Work folder line).
printf '%s\n' "$@" > "$FAKE_LOG.prompt"
# The work folder is named in the prompt ("Work folder: <path>"); fall back to the first folder under .agent-work.
d="$(sed -n 's/^Work folder: \([^ ]*\).*/\1/p' <<<"$*" | head -1)"
[[ -n "$d" ]] && d="${d%/}/" || d="$(ls -d .agent-work/*/ | head -1)"
if [[ "${FAKE_AGENT:-}" == questions ]]; then
  printf '1. Which columns are exported? — Why it matters: changes the CSV header.\n' > "${d}questions.md"
fi
if [[ "${FAKE_AGENT:-}" == commit ]]; then
  echo "$PWD" > "work-$(basename "$PWD").txt" && git add work-*.txt && git commit -qm "feat: fake work"
fi
if [[ "${FAKE_AGENT:-}" == breakdown ]]; then
  cp "$FAKE_BREAKDOWN" "${d}breakdown.md"; cp "$FAKE_BRIEF" "${d}brief.md"
fi
exit 0
SH
# Fake gh: `gh issue view N --json …` prints an issue whose body is $FAKE_ISSUE_BODY;
# `gh issue create …` records its arguments and body, and prints an issue URL.
# Failures are counted in files: FAKE_GH_CREATE_FAIL / FAKE_GH_CREATE_LOST / FAKE_GH_LINK_FAIL hold a count, and
# that many calls fail (create: before anything is created; lost: created, but the reply is lost; link: the
# sub_issues POST). FAKE_GH_ISSUES=<file> keeps the created issues as JSON lines, which `issue list` returns.
cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
# counted <file>: true, and the file counts down, while the file holds a positive count
counted() { [[ -f "${1:-/nonexistent}" ]] && (( $(cat "$1") > 0 )) && echo $(( $(cat "$1") - 1 )) > "$1"; }
if [[ "$1 $2" == "issue view" ]]; then
  jq -n --arg b "$(cat "$FAKE_ISSUE_BODY")" '{number: 7, title: "Add CSV export", body: $b, labels: [], url: "https://example.test/7"}'
elif [[ "$1 $2" == "issue create" ]]; then
  if counted "${FAKE_GH_CREATE_FAIL:-}"; then echo 'Post "https://api.github.com/repos/o/r/issues": dial tcp: i/o timeout' >&2; exit 1; fi
  n=$(( $(cat "$FAKE_GH_SEQ" 2>/dev/null || echo 7) + 1 )); echo "$n" > "$FAKE_GH_SEQ"
  printf '%s\n' "$@" > "$FAKE_GH_CREATE"
  title=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == --title ]] && title="$2"
    [[ "$1" == --body-file ]] && cp "$2" "$FAKE_GH_CREATE.body" && cp "$2" "$FAKE_GH_CREATE.body.$n"
    shift
  done
  [[ -z "${FAKE_GH_ISSUES:-}" ]] || jq -cn --argjson n "$n" --arg t "$title" --rawfile b "$FAKE_GH_CREATE.body.$n" \
    '{number: $n, title: $t, body: $b}' >> "$FAKE_GH_ISSUES"
  if counted "${FAKE_GH_CREATE_LOST:-}"; then echo 'Post "https://api.github.com/repos/o/r/issues": EOF' >&2; exit 1; fi
  echo "https://example.test/issues/$n"
elif [[ "$1 $2" == "issue list" ]]; then
  if [[ -n "${FAKE_GH_ISSUES:-}" && -f "$FAKE_GH_ISSUES" ]]; then jq -s . "$FAKE_GH_ISSUES"; else echo '[]'; fi
elif [[ "$1 $2" == "issue comment" ]]; then
  printf '%s\n' "$@" > "$FAKE_GH_COMMENT"
elif [[ "$1 $2" == "pr list" ]]; then
  # open PRs for --head <branch>: FAKE_PR_OPEN=1 reports one (as `--jq length` would print it)
  printf '%s\n' "$@" > "$FAKE_GH_PR_LIST"
  [[ -n "${FAKE_PR_OPEN:-}" ]] && echo 1 || echo 0
elif [[ "$1 $2" == "pr view" ]]; then
  jq -n --arg b "$(cat "$FAKE_PR_BODY")" --arg h "$FAKE_PR_HEAD" '{body: $b, headRefName: $h, author: {login: "Copilot"}, url: "https://example.test/pull/9"}'
elif [[ "$1" == api && -n "${FAKE_GH_API_FAIL:-}" && "$2" == *${FAKE_GH_API_FAIL_ON:-}* \
        && "$(cat "$FAKE_GH_API_FAIL" 2>/dev/null || echo 0)" -gt 0 ]]; then
  # Simulated network failure: the next <count in $FAKE_GH_API_FAIL> matching api calls fail.
  echo $(( $(cat "$FAKE_GH_API_FAIL") - 1 )) > "$FAKE_GH_API_FAIL"
  echo "Get \"https://api.github.com/$2\": dial tcp: i/o timeout" >&2; exit 1
elif [[ "$1" == api && "$2" == -X && "$4" == */sub_issues ]] && counted "${FAKE_GH_LINK_FAIL:-}"; then
  echo 'Post "https://api.github.com/repos/o/r/issues/7/sub_issues": dial tcp: i/o timeout' >&2; exit 1
elif [[ "$1" == api && "$2" == */sub_issues ]]; then
  cat "${FAKE_SUBS:-/dev/null}"   # already in the --jq output form: "<number> <state>" (create-issues: "<number>\t<title>")
elif [[ "$1" == api && "$2" == */dependencies/blocked_by ]]; then
  n="${2%/dependencies/blocked_by}"; cat "$FAKE_BLOCKED.${n##*/}" 2>/dev/null || true   # "#<number>" of open blockers
elif [[ "$1" == api ]]; then
  echo "${*:2}" >> "$FAKE_GH_API"
  # GET repos/{owner}/{repo}/issues/N --jq .id → a fake issue id (1000 + N)
  [[ "$2" != -X ]] && echo $(( 1000 + ${2##*/} ))
fi
exit 0
SH
# Fake Claude Code CLI: records whether the background-task time limit was lifted, and its arguments.
cat > "$bin/claude" <<'SH'
#!/usr/bin/env bash
echo "bg=${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-unset} $*" >> "$FAKE_LOG.claude"
SH
chmod +x "$bin"/*
export PATH="$bin:$PATH" FAKE_LOG="$tmp/agent.log" FAKE_GH_CREATE="$tmp/gh-create.args"
export FAKE_GH_SEQ="$tmp/gh-seq" FAKE_GH_API="$tmp/gh-api.log" FAKE_GH_COMMENT="$tmp/gh-comment.args"
export FAKE_GH_PR_LIST="$tmp/gh-pr-list.args"
bd="$root/tests/fixtures/breakdown"
export FAKE_BRIEF="$bd/brief.md"

setup_repo() { # setup_repo <repo-type> <dir> [os: linux|windows, default linux]
  mkdir -p "$2" && cd "$2" || exit 1
  git init -q -b main . && git config user.email t@t && git config user.name t
  echo x > README.md && git add -A && git commit -qm init
  bash "$root/install.sh" . --repo "$1" --os "${3:-linux}" >/dev/null
  sed -i 's/^ALLOW_NO_CHECKS=0/ALLOW_NO_CHECKS=1/' scripts/factory/commands.env
  git add -A && git commit -qm factory
}
runs() { [[ -f "$FAKE_LOG" ]] && wc -l < "$FAKE_LOG" | tr -d ' ' || echo 0; }

# ---- local repo ----
setup_repo local "$tmp/local"
cp "$fx/bad-no-ac.md" tasks/t1.md && git add tasks && git commit -qm "task: t1"
rm -f "$FAKE_LOG"
out="$(bash scripts/factory/run-task.sh t1 2>&1)"; rc=$?
check "local: not-ready task exits 4" 4 "$rc"
check "local: agent not started for not-ready task" 0 "$(runs)"
grep -q "Acceptance criteria" <<<"$out" || { echo "FAIL local: reason not shown"; fail=1; }

cp "$fx/ok-task.md" tasks/t1.md && git add tasks && git commit -qm "task: t1 ready"
out="$(FAKE_AGENT=questions bash scripts/factory/run-task.sh t1 2>&1)"; rc=$?
check "local: agent questions exit 5" 5 "$rc"
grep -q "Which columns are exported" <<<"$out" || { echo "FAIL local: questions not shown"; fail=1; }

sed -i 's/^Users can download the report table as CSV.$/Users can download the visible report table as CSV./' tasks/t1.md
git add tasks && git commit -qm "task: t1 answered"
out="$(bash scripts/factory/run-task.sh t1 2>&1)"; rc=$?
check "local: answered task runs" 0 "$rc"
grep -q "recreating the worktree" <<<"$out" || { echo "FAIL local: worktree not refreshed after task edit"; fail=1; }
grep -q "visible report table" "$tmp/local-worktrees/t1/tasks/t1.md" || { echo "FAIL local: worktree has the old task"; fail=1; }

# local: the work folder is <UTC stamp>-t1 under WORK_DIR, reused on rerun, and follows a changed WORK_DIR
wtd="$tmp/local-worktrees/t1"
w1=("$wtd"/.agent-work/*Z-t1)
[[ "${#w1[@]}" == 1 && "${w1[0]##*/}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-t1$ ]] \
  || { echo "FAIL local: run-task work folder is not <UTC stamp>-t1 (got: ${w1[*]})"; fail=1; }
bash scripts/factory/run-task.sh t1 >/dev/null 2>&1
w2=("$wtd"/.agent-work/*Z-t1)
[[ "${#w2[@]}" == 1 && "${w2[0]}" == "${w1[0]}" ]] || { echo "FAIL local: rerun did not reuse the work folder (got: ${w2[*]})"; fail=1; }
sed -i 's|^WORK_DIR=.*|WORK_DIR=.moved-work|' "$wtd/scripts/factory/paths.env"
bash scripts/factory/run-task.sh t1 >/dev/null 2>&1
w3=("$wtd"/.moved-work/*Z-t1)
[[ "${#w3[@]}" == 1 && -d "${w3[0]}" ]] || { echo "FAIL local: changed WORK_DIR did not move a new run's work folder (got: ${w3[*]})"; fail=1; }
w4=("$wtd"/.agent-work/*Z-t1)
[[ "${#w4[@]}" == 1 ]] || { echo "FAIL local: run after WORK_DIR change wrote under the old location"; fail=1; }

# local: drafts → tasks (human-only script)
bash scripts/factory/create-task.sh "$fx/bad-open-question.md" --id t2 --yes >/dev/null 2>&1; rc=$?
check "local: create-task refuses a draft with OPEN items" 4 "$rc"
mkdir -p .agent-work/drafts && cp "$fx/ok-task.md" .agent-work/drafts/csv-export.md
bash scripts/factory/create-task.sh .agent-work/drafts/csv-export.md --yes >/dev/null; rc=$?
check "local: create-task commits a ready draft" 0 "$rc"
check "local: task committed on base" "task: csv-export" "$(git log -1 --format=%s)"
bash scripts/factory/create-task.sh .agent-work/drafts/csv-export.md --yes >/dev/null 2>&1; rc=$?
check "local: create-task refuses to overwrite a task" 1 "$rc"

# local: the created task's id and path are recorded in the draft's own folder
[[ ! -e "$fx/created.txt" ]] || { echo "FAIL local: record written beside a draft not named draft.md"; fail=1; }
rt="$tmp/drafts/2026-01-02T03-04-05Z-rec"; mkdir -p "$rt" && cp "$fx/ok-task.md" "$rt/draft.md"
bash scripts/factory/create-task.sh "$rt/draft.md" --id t-rec --yes >/dev/null 2>&1; rc=$?
check "local: create-task on a draft folder" 0 "$rc"
[[ "$(cat "$rt/created.txt" 2>/dev/null)" == "$(printf 'task=t-rec\npath=tasks/t-rec.md')" ]] \
  || { echo "FAIL local: created.txt missing or wrong:"; cat "$rt/created.txt" 2>&1; fail=1; }
cmp -s "$rt/draft.md" "$fx/ok-task.md" || { echo "FAIL local: draft.md changed"; fail=1; }
rt2="$tmp/drafts/2026-01-02T03-04-06Z-rec"; mkdir -p "$rt2" && cp "$fx/ok-task.md" "$rt2/draft.md"
bash scripts/factory/create-task.sh "$rt2/draft.md" --id t-rec --yes >/dev/null 2>&1; rc=$?
check "local: create-task refuses an existing task id" 1 "$rc"
[[ ! -e "$rt2/created.txt" ]] || { echo "FAIL local: record written after a refusal"; fail=1; }
rt3="$tmp/drafts/2026-01-02T03-04-07Z-rec"; mkdir -p "$rt3" && cp "$fx/bad-open-question.md" "$rt3/draft.md"
bash scripts/factory/create-task.sh "$rt3/draft.md" --id t-rec3 --yes >/dev/null 2>&1; rc=$?
check "local: create-task refuses a not-ready draft" 4 "$rc"
[[ ! -e "$rt3/created.txt" ]] || { echo "FAIL local: record written for a not-ready draft"; fail=1; }
bash scripts/factory/new-draft.sh "add csv export" </dev/null >/dev/null 2>&1; rc=$?
check "local: new-draft needs a terminal" 2 "$rc"
if command -v script >/dev/null; then
  # Run new-draft in a pseudo-terminal; the fake analyst writes a draft with an OPEN item.
  printf '1. Q: Which columns?\n   A: id and name.\n' > "$tmp/qa.md"
  out="$(FAKE_QA="$tmp/qa.md" FAKE_DRAFT="$fx/bad-open-question.md" script -qec 'bash scripts/factory/new-draft.sh --id csv2 "add csv export"' /dev/null 2>&1)"; rc=$?
  check "local: new-draft saves the analyst's draft" 0 "$rc"
  d2=(.agent-work/drafts/*Z-csv2)
  [[ "${#d2[@]}" == 1 && "${d2[0]}" =~ ^\.agent-work/drafts/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-csv2$ ]] \
    || { echo "FAIL local: draft folder is not <UTC stamp>-csv2 (got: ${d2[*]})"; fail=1; }
  cmp -s "$fx/bad-open-question.md" "${d2[0]}/draft.md" || { echo "FAIL local: draft not saved as draft.md in the dated folder"; fail=1; }
  cmp -s "$tmp/qa.md" "${d2[0]}/questions-and-answers.md" || { echo "FAIL local: Q&A not saved as questions-and-answers.md in the draft folder"; fail=1; }
  # A rerun with the same id reuses the folder.
  rm -f "$FAKE_LOG.qa"
  FAKE_QA="$tmp/qa.md" FAKE_DRAFT="$fx/bad-open-question.md" script -qec 'bash scripts/factory/new-draft.sh --id csv2 "add csv export"' /dev/null >/dev/null 2>&1
  d2=(.agent-work/drafts/*Z-csv2)
  check "local: new-draft rerun reuses the draft folder" 1 "${#d2[@]}"
  check "local: rerun stages the earlier Q&A for the analyst" staged "$(tail -1 "$FAKE_LOG.qa")"
  # A session that writes no Q&A file still succeeds and leaves only the draft.
  FAKE_DRAFT="$fx/bad-open-question.md" script -qec 'bash scripts/factory/new-draft.sh --id csv4 "add csv export"' /dev/null >/dev/null 2>&1; rc=$?
  check "local: new-draft without Q&A succeeds" 0 "$rc"
  d4=(.agent-work/drafts/*Z-csv4)
  [[ -f "${d4[0]}/draft.md" && ! -e "${d4[0]}/questions-and-answers.md" ]] || { echo "FAIL local: no-Q&A session should leave only draft.md"; fail=1; }
  # Changing DRAFTS_DIR in paths.env moves new drafts.
  sed -i 's|^DRAFTS_DIR=.*|DRAFTS_DIR=elsewhere/drafts|' scripts/factory/paths.env
  FAKE_QA="$tmp/qa.md" FAKE_DRAFT="$fx/bad-open-question.md" script -qec 'bash scripts/factory/new-draft.sh --id csv3 "add csv export"' /dev/null >/dev/null 2>&1
  d3=(elsewhere/drafts/*Z-csv3)
  [[ -f "${d3[0]}/draft.md" ]] || { echo "FAIL local: draft not written under the configured DRAFTS_DIR"; fail=1; }
  cmp -s "$tmp/qa.md" "${d3[0]}/questions-and-answers.md" || { echo "FAIL local: Q&A not saved under the configured DRAFTS_DIR"; fail=1; }
  [[ ! -e .agent-work/drafts/csv3.md && -z "$(ls -d .agent-work/drafts/*csv3* 2>/dev/null)" ]] \
    || { echo "FAIL local: draft still written under .agent-work/drafts after DRAFTS_DIR changed"; fail=1; }
  git checkout -q scripts/factory/paths.env; rm -rf elsewhere
  grep -q "OPEN" <<<"$out" || { echo "FAIL local: new-draft did not report the OPEN item"; fail=1; }
  grep -q "create-task.sh" <<<"$out" || { echo "FAIL local: new-draft did not show the next step"; fail=1; }
  grep -q -- "-worktrees/draft-csv2" "$FAKE_LOG.analyst" || { echo "FAIL local: analyst did not run in a throwaway worktree"; fail=1; }
  [[ ! -d "$tmp/local-worktrees/draft-csv2" ]] || { echo "FAIL local: draft worktree not removed"; fail=1; }
fi

# local: too big → breakdown → sub-tasks (human-only script)
sed 's/^# Breakdown of issue #7:/# Breakdown of task t1:/' "$bd/ok.md" > "$tmp/bd-task.md"
out="$(FAKE_AGENT=breakdown FAKE_BREAKDOWN="$tmp/bd-task.md" bash scripts/factory/run-task.sh t1 2>&1)"; rc=$?
check "local: breakdown proposed exits 6" 6 "$rc"
[[ -f .agent-work/breakdowns/t1.md && -f .agent-work/breakdowns/t1.brief.md ]] || { echo "FAIL local: breakdown not saved"; fail=1; }
grep -q "create-tasks.sh" <<<"$out" || { echo "FAIL local: breakdown next step not shown"; fail=1; }
# local: questions.md / breakdown.md are also filed in the draft folder that recorded the task
shopt -s nullglob; none=(.agent-work/drafts/*/questions.md .agent-work/drafts/*/breakdown.md); shopt -u nullglob
check "local: no recorded draft, nothing filed in any draft folder" 0 "${#none[@]}"
ld=".agent-work/drafts/2026-01-02T03-04-08Z-t1"; mkdir -p "$ld" && printf 'task=t1\npath=tasks/t1.md\n' > "$ld/created.txt"
out="$(FAKE_AGENT=questions bash scripts/factory/run-task.sh t1 2>&1)"; rc=$?
check "local: questions run with a recorded draft exits 5" 5 "$rc"
check "local: questions.md filed in the recorded draft folder" \
  "1. Which columns are exported? — Why it matters: changes the CSV header." "$(cat "$ld/questions.md" 2>/dev/null)"
[[ ! -e "$ld/breakdown.md" ]] || { echo "FAIL local: breakdown.md filed after a questions run"; fail=1; }
rm -f "$ld/questions.md"
out="$(FAKE_AGENT=breakdown FAKE_BREAKDOWN="$tmp/bd-task.md" bash scripts/factory/run-task.sh t1 2>&1)"; rc=$?
check "local: breakdown run with a recorded draft exits 6" 6 "$rc"
cmp -s "$tmp/bd-task.md" "$ld/breakdown.md" || { echo "FAIL local: breakdown.md not filed in the recorded draft folder"; fail=1; }
[[ ! -e "$ld/questions.md" ]] || { echo "FAIL local: questions.md filed after a breakdown run"; fail=1; }
rm -rf "$ld"
bash scripts/factory/create-tasks.sh .agent-work/breakdowns/t1.md --yes >/dev/null; rc=$?
check "local: create-tasks commits the sub-tasks" 0 "$rc"
check "local: sub-tasks committed in one commit" "task: breakdown of t1 into 3 sub-tasks" "$(git log -1 --format=%s)"
grep -qx "Depends on: t1.1, t1.2" tasks/t1.3.md || { echo "FAIL local: sub-task dependencies not rewritten"; fail=1; }
grep -qx "Parent: t1" tasks/t1.2.md || { echo "FAIL local: sub-task parent missing"; fail=1; }
grep -q "^## Broken down into" tasks/t1.md || { echo "FAIL local: parent task not updated"; fail=1; }
bash scripts/factory/check-ready.sh tasks/t1.2.md >/dev/null || { echo "FAIL local: sub-task not ready"; fail=1; }
bash scripts/factory/create-tasks.sh .agent-work/breakdowns/t1.md --yes >/dev/null 2>&1; rc=$?
check "local: create-tasks refuses to create twice" 1 "$rc"
bash scripts/factory/create-tasks.sh "$bd/bad-cycle.md" --yes >/dev/null 2>&1; rc=$?
check "local: create-tasks refuses an invalid breakdown" 4 "$rc"

# local: run the sub-tasks in dependency order (run-batch)
export BATCH_STAGGER_SECONDS=0 BATCH_POLL_SECONDS=1
out="$(bash scripts/factory/run-batch.sh t1 --list 2>&1)"
grep -qE "t1\.1 +ready" <<<"$out" && grep -qE "t1\.3 +blocked by: t1\.1 t1\.2" <<<"$out" || { echo "FAIL local: run-batch --list states wrong"; echo "$out"; fail=1; }
out="$(FAKE_AGENT=commit bash scripts/factory/run-batch.sh t1 2>&1)"; rc=$?
check "local: run-batch runs the unblocked sub-task" 0 "$rc"
grep -q "start    t1.1" <<<"$out" && ! grep -q "start    t1.2" <<<"$out" || { echo "FAIL local: run-batch started the wrong sub-tasks"; echo "$out"; fail=1; }
grep -qE "t1\.1 +waiting for your review" <<<"$out" || { echo "FAIL local: finished sub-task not waiting for review"; fail=1; }
# --auto-continue: a stand-in for the human merges each finished branch; the batch starts what that unblocks.
( for _ in $(seq 1 120); do
    for b in $(git for-each-ref --format='%(refname:short)' 'refs/heads/agent/t1.*'); do
      id="${b#agent/}"
      git log --format=%s main | grep -qxF "merge: $id" && continue
      [[ "$(git rev-list --count "main..$b")" -gt 0 ]] && git merge -q --no-ff "$b" -m "merge: $id"
    done
    sleep 1
  done ) >/dev/null 2>&1 &
merger=$!
out="$(FAKE_AGENT=commit timeout 120 bash scripts/factory/run-batch.sh t1 --auto-continue 2>&1)"; rc=$?
kill "$merger" 2>/dev/null; wait "$merger" 2>/dev/null
check "local: run-batch --auto-continue finishes" 0 "$rc"
grep -q "All sub-tasks of t1 are merged" <<<"$out" || { echo "FAIL local: auto-continue did not run every sub-task"; echo "$out"; fail=1; }
[[ "$(grep -c '^start' <<<"$out")" == 2 ]] || { echo "FAIL local: auto-continue should start t1.2 and t1.3"; fail=1; }
check "local: run-batch with no sub-tasks" 2 "$(bash scripts/factory/run-batch.sh nope >/dev/null 2>&1; echo $?)"

# ---- local repo, Windows: run-task.ps1 (pwsh) ----
# The PowerShell launcher mirrors run-task.sh: a stamped work folder that is reused on rerun and follows a
# changed WORK_DIR, a "Work folder:" prompt line, and questions/breakdown filed in the recorded draft folder.
if command -v pwsh >/dev/null 2>&1; then
  setup_repo local "$tmp/win" windows
  cp "$fx/ok-task.md" tasks/tw.md && git add tasks && git commit -qm "task: tw"
  wtw="$tmp/win-worktrees/tw"
  stamp_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-tw$'
  rm -f "$FAKE_LOG.prompt"
  out="$(pwsh -NoProfile -File scripts/factory/run-task.ps1 tw 2>&1)"; rc=$?
  check "win: run-task.ps1 exits 0" 0 "$rc"
  # AC1: one <UTC stamp>-tw folder under WORK_DIR, reused on rerun.
  w1=("$wtw"/.agent-work/*Z-tw)
  [[ "${#w1[@]}" == 1 && "$(basename "${w1[0]}")" =~ $stamp_re ]] \
    || { echo "FAIL win: work folder is not <UTC stamp>-tw (got: ${w1[*]})"; fail=1; }
  # AC3: the prompt the agent received names that folder on its own line.
  wf1="${w1[0]#"$wtw"/}"
  grep -qxF "Work folder: $wf1" "$FAKE_LOG.prompt" 2>/dev/null \
    || { echo "FAIL win: prompt does not name the Work folder ($wf1)"; fail=1; }
  pwsh -NoProfile -File scripts/factory/run-task.ps1 tw >/dev/null 2>&1
  w2=("$wtw"/.agent-work/*Z-tw)
  [[ "${#w2[@]}" == 1 && "${w2[0]}" == "${w1[0]}" ]] || { echo "FAIL win: rerun did not reuse the work folder (got: ${w2[*]})"; fail=1; }
  # AC2: a changed WORK_DIR moves the next run's folder and writes nothing under the old location.
  sed -i 's|^WORK_DIR=.*|WORK_DIR=.moved-work|' "$wtw/scripts/factory/paths.env"
  pwsh -NoProfile -File scripts/factory/run-task.ps1 tw >/dev/null 2>&1
  w3=("$wtw"/.moved-work/*Z-tw)
  [[ "${#w3[@]}" == 1 && -d "${w3[0]}" ]] || { echo "FAIL win: changed WORK_DIR did not move the new run's work folder (got: ${w3[*]})"; fail=1; }
  w4=("$wtw"/.agent-work/*Z-tw)
  [[ "${#w4[@]}" == 1 && "${w4[0]}" == "${w1[0]}" ]] || { echo "FAIL win: run after WORK_DIR change wrote under the old location (got: ${w4[*]})"; fail=1; }
  # AC4: questions.md / breakdown.md are filed in the draft folder whose created.txt names the task.
  ld=".agent-work/drafts/2026-01-02T03-04-08Z-tw"; mkdir -p "$ld" && printf 'task=tw\npath=tasks/tw.md\n' > "$ld/created.txt"
  out="$(FAKE_AGENT=questions pwsh -NoProfile -File scripts/factory/run-task.ps1 tw 2>&1)"; rc=$?
  check "win: questions run with a recorded draft exits 5" 5 "$rc"
  check "win: questions.md filed in the recorded draft folder" \
    "1. Which columns are exported? — Why it matters: changes the CSV header." "$(cat "$ld/questions.md" 2>/dev/null)"
  [[ ! -e "$ld/breakdown.md" ]] || { echo "FAIL win: breakdown.md filed after a questions run"; fail=1; }
  rm -f "$ld/questions.md"
  out="$(FAKE_AGENT=breakdown FAKE_BREAKDOWN="$tmp/bd-task.md" pwsh -NoProfile -File scripts/factory/run-task.ps1 tw 2>&1)"; rc=$?
  check "win: breakdown run with a recorded draft exits 6" 6 "$rc"
  cmp -s "$tmp/bd-task.md" "$ld/breakdown.md" || { echo "FAIL win: breakdown.md not filed in the recorded draft folder"; fail=1; }
  [[ ! -e "$ld/questions.md" ]] || { echo "FAIL win: questions.md filed after a breakdown run"; fail=1; }
  rm -rf "$ld"
  out="$(FAKE_AGENT=questions pwsh -NoProfile -File scripts/factory/run-task.ps1 tw 2>&1)"; rc=$?
  check "win: questions run without a record exits 5" 5 "$rc"
  shopt -s nullglob; none=(.agent-work/drafts/*/questions.md .agent-work/drafts/*/breakdown.md); shopt -u nullglob
  check "win: nothing filed without a record" 0 "${#none[@]}"
else
  echo "skip win: run-task.ps1 checks (pwsh not installed)"
fi

# ---- github repo ----
setup_repo github "$tmp/gh"
git init -q --bare "$tmp/origin.git" && git remote add origin "$tmp/origin.git" && git push -q origin main 2>/dev/null
rm -f "$FAKE_LOG"
export FAKE_ISSUE_BODY="$fx/bad-issue-empty-field.md"
out="$(bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: not-ready issue exits 4" 4 "$rc"
check "github: agent not started for not-ready issue" 0 "$(runs)"
grep -q "issue #7" <<<"$out" || { echo "FAIL github: reason does not name the issue"; fail=1; }

# claude-code: an autonomous run must not let `claude -p` stop background sub-agents after 10 minutes.
( unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS; export ASSISTANT=claude-code
  # shellcheck disable=SC1091
  source scripts/factory/agent-cli.sh; agent_cli auto "do the work" "denied-cmd" ) >/dev/null 2>&1
grep -q '^bg=0 .*-p do the work$' "$FAKE_LOG.claude" \
  || { echo "FAIL claude-code: autonomous run does not set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0"; cat "$FAKE_LOG.claude" 2>/dev/null; fail=1; }

export FAKE_ISSUE_BODY="$fx/ok-issue-form.md"
# A branch left over from an earlier run (its worktree removed) without commits is reused.
git branch agent/issue-7-add-csv-export main
out="$(FAKE_AGENT=questions bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: agent questions exit 5" 5 "$rc"
check "github: leftover branch without commits reused" "agent/issue-7-add-csv-export" \
  "$(git -C "$tmp/gh-worktrees/issue-7" branch --show-current 2>/dev/null)"
grep -q "Which columns are exported" <<<"$out" || { echo "FAIL github: questions not shown"; fail=1; }
[[ ! -e .agent-work/drafts ]] || { echo "FAIL github: drafts folder created with no recorded draft"; fail=1; }
# The work folder is a UTC-stamped one, and every rerun reuses it.
stamped_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-issue-7$'
wf=("$tmp"/gh-worktrees/issue-7/.agent-work/*Z-issue-7)
check "github: one stamped work folder" 1 "${#wf[@]}"
[[ "$(basename "${wf[0]}")" =~ $stamped_re ]] || { echo "FAIL github: work folder name not stamped: ${wf[0]}"; fail=1; }
[[ -f "${wf[0]}/issue.json" ]] || { echo "FAIL github: issue.json not in the stamped folder"; fail=1; }

# The agent ended without a result: no commits, no PR, no questions, no breakdown → exit 8, "needs you".
out="$(bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: run with no result exits 8" 8 "$rc"
grep -q "produced no result" <<<"$out" || { echo "FAIL github: empty run not reported"; echo "$out"; fail=1; }
wf2=("$tmp"/gh-worktrees/issue-7/.agent-work/*Z-issue-7)
check "github: rerun reuses the stamped folder" "${wf[0]}" "${wf2[0]}"
check "github: rerun leaves one stamped folder" 1 "${#wf2[@]}"
[[ ! -e "${wf2[0]}/questions.md" ]] || { echo "FAIL github: stale questions.md kept"; fail=1; }

# github: the agent committed but opened no PR (e.g. its push was blocked) → exit 7, "needs you"
out="$(FAKE_AGENT=commit bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: committed but no PR exits 7" 7 "$rc"
grep -q "committed but not pushed" <<<"$out" || { echo "FAIL github: unpushed work not reported"; echo "$out"; fail=1; }
grep -qx "agent/issue-7-add-csv-export" "$FAKE_GH_PR_LIST" || { echo "FAIL github: PR not looked up for the issue branch"; fail=1; }
out="$(FAKE_PR_OPEN=1 bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: committed with an open PR exits 0" 0 "$rc"
wf3=("$tmp"/gh-worktrees/issue-7/.agent-work/*Z-issue-7)
check "github: reruns after exit 7 still leave one stamped folder" 1 "${#wf3[@]}"
# A changed WORK_DIR in the paths file is picked up by the next run.
pf="$tmp/gh-worktrees/issue-7/scripts/factory/paths.env"; orig_paths="$(<"$pf")"
sed -i 's|^WORK_DIR=.*|WORK_DIR=elsewhere/work|' "$pf"
out="$(FAKE_PR_OPEN=1 bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: run with a changed WORK_DIR exits 0" 0 "$rc"
nw=("$tmp"/gh-worktrees/issue-7/elsewhere/work/*Z-issue-7)
[[ -f "${nw[0]}/issue.json" ]] || { echo "FAIL github: changed WORK_DIR not used"; fail=1; }
wf4=("$tmp"/gh-worktrees/issue-7/.agent-work/*Z-issue-7)
check "github: nothing new under the old location" 1 "${#wf4[@]}"
printf '%s\n' "$orig_paths" > "$pf"
# A leftover branch WITH commits and no worktree is kept, never reset: the new worktree is attached to it.
git worktree remove --force "$tmp/gh-worktrees/issue-7"
out="$(FAKE_PR_OPEN=1 bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: leftover branch with commits reused" 0 "$rc"
check "github: leftover branch keeps its commits" 1 "$(git rev-list --count main..agent/issue-7-add-csv-export)"
check "github: worktree attached to the leftover branch" "agent/issue-7-add-csv-export" \
  "$(git -C "$tmp/gh-worktrees/issue-7" branch --show-current 2>/dev/null)"
grep -q "keeping its 1 commit" <<<"$out" || { echo "FAIL github: reuse of a branch with commits not reported"; echo "$out"; fail=1; }

# github: drafts → issue (human-only script)
bash scripts/factory/create-issue.sh "$fx/bad-no-ac.md" --yes >/dev/null 2>&1; rc=$?
check "github: create-issue refuses a not-ready draft" 4 "$rc"
bash scripts/factory/create-issue.sh "$fx/ok-issue-form.md" --yes >/dev/null 2>&1; rc=$?
check "github: create-issue needs a title line" 4 "$rc"
out="$(bash scripts/factory/create-issue.sh "$fx/ok-task.md" --yes 2>&1)"; rc=$?
check "github: create-issue creates a ready draft" 0 "$rc"
grep -qx "Add CSV export" "$FAKE_GH_CREATE" || { echo "FAIL github: issue title not passed"; fail=1; }
grep -qx "agent-ready" "$FAKE_GH_CREATE" || { echo "FAIL github: agent-ready label not passed"; fail=1; }
grep -q "^## Acceptance criteria" "$FAKE_GH_CREATE.body" && ! grep -q "^# Add CSV export" "$FAKE_GH_CREATE.body" \
  || { echo "FAIL github: issue body wrong"; fail=1; }
bash scripts/factory/check-ready.sh "$FAKE_GH_CREATE.body" >/dev/null || { echo "FAIL github: created issue body is not ready"; fail=1; }
seq_before="$(cat "$FAKE_GH_SEQ")"   # keep later issue numbers stable
dout="$(bash scripts/factory/create-issue.sh --draft "$fx/ok-task.md" </dev/null 2>&1)"; rc=$?
echo "$seq_before" > "$FAKE_GH_SEQ"
check "github: create-issue --draft creates without a prompt" 0 "$rc"
grep -qx "agent-draft" "$FAKE_GH_CREATE" && ! grep -qx "agent-ready" "$FAKE_GH_CREATE" \
  || { echo "FAIL github: --draft must label agent-draft, not agent-ready"; fail=1; }
grep -q "add the agent-ready label" <<<"$dout" || { echo "FAIL github: --draft review hint not shown"; fail=1; }
grep -q "run-issue.sh 8" <<<"$out" || { echo "FAIL github: next step not shown"; fail=1; }

# github: the created issue's number and URL are recorded in the draft's own folder
[[ ! -e "$fx/created.txt" ]] || { echo "FAIL github: record written beside a draft not named draft.md"; fail=1; }
seq_before="$(cat "$FAKE_GH_SEQ")"
rd="$tmp/drafts/2026-01-02T03-04-05Z-rec"; mkdir -p "$rd" && cp "$fx/ok-task.md" "$rd/draft.md"
bash scripts/factory/create-issue.sh "$rd/draft.md" --yes >/dev/null 2>&1; rc=$?
check "github: create-issue on a draft folder" 0 "$rc"
n=$((seq_before + 1))
[[ "$(cat "$rd/created.txt" 2>/dev/null)" == "$(printf 'number=%s\nurl=https://example.test/issues/%s' "$n" "$n")" ]] \
  || { echo "FAIL github: created.txt missing or wrong:"; cat "$rd/created.txt" 2>&1; fail=1; }
cmp -s "$rd/draft.md" "$fx/ok-task.md" || { echo "FAIL github: draft.md changed"; fail=1; }
rd2="$tmp/drafts/2026-01-02T03-04-06Z-rec"; mkdir -p "$rd2" && cp "$fx/ok-task.md" "$rd2/draft.md"
bash scripts/factory/create-issue.sh --draft "$rd2/draft.md" </dev/null >/dev/null 2>&1; rc=$?
check "github: create-issue --draft on a draft folder" 0 "$rc"
grep -qx "number=$((n + 1))" "$rd2/created.txt" 2>/dev/null || { echo "FAIL github: --draft did not record the issue"; fail=1; }
echo "$seq_before" > "$FAKE_GH_SEQ"

# github: too big → breakdown → native sub-issues with blocked-by (human-only script)
out="$(FAKE_AGENT=breakdown FAKE_BREAKDOWN="$bd/ok.md" bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: breakdown proposed exits 6" 6 "$rc"
[[ -f .agent-work/breakdowns/issue-7.md && -f .agent-work/breakdowns/issue-7.brief.md ]] || { echo "FAIL github: breakdown not saved"; fail=1; }
[[ ! -e .agent-work/drafts ]] || { echo "FAIL github: drafts folder created with no recorded draft"; fail=1; }
# github: questions.md / breakdown.md are also filed in the draft folder that recorded the issue
gd=".agent-work/drafts/2026-01-02T03-04-08Z-rec"; mkdir -p "$gd" && printf 'number=7\nurl=https://example.test/7\n' > "$gd/created.txt"
out="$(FAKE_AGENT=questions bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: questions run with a recorded draft exits 5" 5 "$rc"
check "github: questions.md filed in the recorded draft folder" \
  "1. Which columns are exported? — Why it matters: changes the CSV header." "$(cat "$gd/questions.md" 2>/dev/null)"
[[ ! -e "$gd/breakdown.md" ]] || { echo "FAIL github: breakdown.md filed after a questions run"; fail=1; }
rm -f "$gd/questions.md"
out="$(FAKE_AGENT=breakdown FAKE_BREAKDOWN="$bd/ok.md" bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: breakdown run with a recorded draft exits 6" 6 "$rc"
cmp -s "$bd/ok.md" "$gd/breakdown.md" || { echo "FAIL github: breakdown.md not filed in the recorded draft folder"; fail=1; }
[[ ! -e "$gd/questions.md" ]] || { echo "FAIL github: questions.md filed after a breakdown run"; fail=1; }
rm -rf "$gd"
rm -f "$FAKE_GH_API"
out="$(bash scripts/factory/create-issues.sh .agent-work/breakdowns/issue-7.md --yes 2>&1)"; rc=$?
check "github: create-issues creates the sub-issues" 0 "$rc"
grep -q "could not" <<<"$out" && { echo "FAIL github: create-issues reported a failed link"; fail=1; }
# Issues 9, 10, 11 (ids 1009..1011): all sub-issues of #7; 10 blocked by 9; 11 blocked by 9 and 10.
for want in "issues/7/sub_issues -F sub_issue_id=1009" "issues/7/sub_issues -F sub_issue_id=1010" "issues/7/sub_issues -F sub_issue_id=1011" \
            "issues/10/dependencies/blocked_by -F issue_id=1009" "issues/11/dependencies/blocked_by -F issue_id=1009" "issues/11/dependencies/blocked_by -F issue_id=1010"; do
  grep -q -- "$want" "$FAKE_GH_API" || { echo "FAIL github: missing gh api call: $want"; fail=1; }
done
grep -qx "Depends on: #9, #10" "$FAKE_GH_CREATE.body.11" || { echo "FAIL github: sub-issue dependencies not rewritten"; fail=1; }
grep -qx "agent-ready" "$FAKE_GH_CREATE" && { echo "FAIL github: blocked sub-issue got the agent-ready label"; fail=1; }
grep -qx "Parent: #7" "$FAKE_GH_CREATE.body.9" || { echo "FAIL github: sub-issue parent missing"; fail=1; }
grep -qx "7" "$FAKE_GH_COMMENT" || { echo "FAIL github: summary not commented on the parent"; fail=1; }

# github: a rerun reuses a sub-issue that already exists under the parent (matched by exact title)
seq_keep="$(cat "$FAKE_GH_SEQ")"; echo 20 > "$FAKE_GH_SEQ"   # the rerun's creates get #21 and #22
printf '15\tExport service\n' > "$tmp/subs-reuse"             # item 1 was created by an earlier run as #15
rm -f "$FAKE_GH_API" "$FAKE_GH_CREATE"
out="$(FAKE_SUBS="$tmp/subs-reuse" bash scripts/factory/create-issues.sh .agent-work/breakdowns/issue-7.md --yes 2>&1)"; rc=$?
check "github: create-issues rerun with an existing sub-issue exits 0" 0 "$rc"
check "github: rerun creates only the missing items (#21, #22)" 22 "$(cat "$FAKE_GH_SEQ")"
grep -q "Reused #15: Export service" <<<"$out" || { echo "FAIL github: reused sub-issue not reported"; echo "$out"; fail=1; }
grep -q "Created #21: Export button" <<<"$out" || { echo "FAIL github: missing item not created"; echo "$out"; fail=1; }
check "github: reused item looked up only for its id" 1 "$(grep -c 'issues/15 ' "$FAKE_GH_API")"
grep -qx "Export audit log" "$FAKE_GH_CREATE" || { echo "FAIL github: last create is not the last item"; fail=1; }
# The reused item is linked again and is the blocker of the items that depend on it.
for want in "issues/7/sub_issues -F sub_issue_id=1015" "issues/7/sub_issues -F sub_issue_id=1021" "issues/7/sub_issues -F sub_issue_id=1022" \
            "issues/21/dependencies/blocked_by -F issue_id=1015" "issues/22/dependencies/blocked_by -F issue_id=1015" "issues/22/dependencies/blocked_by -F issue_id=1021"; do
  grep -q -- "$want" "$FAKE_GH_API" || { echo "FAIL github: rerun missing gh api call: $want"; cat "$FAKE_GH_API"; fail=1; }
done
grep -qx "Depends on: #15" "$FAKE_GH_CREATE.body.21" || { echo "FAIL github: rerun body does not name the reused number"; fail=1; }
grep -qx "Depends on: #15, #21" "$FAKE_GH_CREATE.body.22" || { echo "FAIL github: rerun body names the wrong numbers"; fail=1; }
grep -q "could not" <<<"$out" && { echo "FAIL github: rerun reported a failed link"; echo "$out"; fail=1; }

# github: two items with the same title are refused before anything is created
sed 's/^## Item 2: Export button/## Item 2: Export service/' "$bd/ok.md" > "$tmp/bd-dup.md"
rm -f "$FAKE_GH_CREATE"; seq_before="$(cat "$FAKE_GH_SEQ")"
out="$(bash scripts/factory/create-issues.sh "$tmp/bd-dup.md" --yes 2>&1)"; rc=$?
check "github: create-issues refuses a duplicate title in the breakdown" 1 "$rc"
grep -q 'Export service' <<<"$out" || { echo "FAIL github: duplicate title not named"; echo "$out"; fail=1; }
[[ ! -e "$FAKE_GH_CREATE" ]] || { echo "FAIL github: an issue was created despite the duplicate title"; fail=1; }
check "github: duplicate title creates nothing" "$seq_before" "$(cat "$FAKE_GH_SEQ")"
echo "$seq_keep" > "$FAKE_GH_SEQ"

# github: every gh call is retried like gh_api (BATCH_GH_RETRIES, BATCH_GH_RETRY_SECONDS); a create is not repeated
# when its title is already there (under the parent, or as an unlinked "Parent: #7" issue). Breakdown of #7, no sub-issues.
seq_t2="$(cat "$FAKE_GH_SEQ")"
gfail="$tmp/gh-create-fail" glost="$tmp/gh-create-lost" glink="$tmp/gh-link-fail" gissues="$tmp/gh-issues.jsonl"
run_cc() { BATCH_GH_RETRY_SECONDS=0 FAKE_GH_CREATE_FAIL="$gfail" FAKE_GH_CREATE_LOST="$glost" FAKE_GH_LINK_FAIL="$glink" \
  FAKE_GH_ISSUES="$gissues" bash scripts/factory/create-issues.sh .agent-work/breakdowns/issue-7.md --yes 2>&1; }
count_issues() { if [[ -f "$gissues" ]]; then jq -s length "$gissues"; else echo 0; fi; }
reset_gh() { echo 30 > "$FAKE_GH_SEQ"; rm -f "$FAKE_GH_CREATE" "$FAKE_GH_API" "$gissues" "$gfail" "$glost" "$glink"; }

# (a) one transient create failure: retried, each item created once
reset_gh; echo 1 > "$gfail"
out="$(run_cc)"; rc=$?
check "github: a transient create failure is retried (exit 0)" 0 "$rc"
check "github: transient create failure creates each item once (#31-#33)" 33 "$(cat "$FAKE_GH_SEQ")"
check "github: transient create failure leaves three issues" 3 "$(count_issues)"
grep -q "retrying in 0s (1/3): gh issue create" <<<"$out" || { echo "FAIL github: retry not logged"; echo "$out"; fail=1; }

# (b) the create succeeded on the server but its reply was lost: the retry finds the title and does not create again
reset_gh; echo 1 > "$glost"
out="$(run_cc)"; rc=$?
check "github: a create whose reply was lost exits 0" 0 "$rc"
check "github: a lost-reply create is found again, not repeated (#31-#33)" 33 "$(cat "$FAKE_GH_SEQ")"
check "github: a lost-reply create leaves each title once" 3 "$(count_issues)"

# (c) retries exhausted: exit 1 and the call is named; nothing created
reset_gh; echo 99 > "$gfail"
out="$(run_cc)"; rc=$?
check "github: exhausted create retries exit 1" 1 "$rc"
grep -q "giving up: gh issue create" <<<"$out" || { echo "FAIL github: exhausted create does not name the call"; echo "$out"; fail=1; }
check "github: exhausted create made no issue" 30 "$(cat "$FAKE_GH_SEQ")"

# (d) rerun on the same breakdown once the failure is gone: exit 0, no duplicates
echo 0 > "$gfail"
out="$(run_cc)"; rc=$?
check "github: rerun after exhausted retries exits 0" 0 "$rc"
check "github: rerun after exhausted retries creates each item once (#31-#33)" 33 "$(cat "$FAKE_GH_SEQ")"
check "github: rerun after exhausted retries leaves each title once" 3 "$(count_issues)"

# (e) the sub-issue link keeps failing: exit 1 and the call is named; the rerun links the unlinked issue, no duplicate
reset_gh; echo 99 > "$glink"
out="$(run_cc)"; rc=$?
check "github: exhausted link retries exit 1" 1 "$rc"
grep -q "giving up: gh api -X POST repos/{owner}/{repo}/issues/7/sub_issues" <<<"$out" || { echo "FAIL github: exhausted link does not name the call"; echo "$out"; fail=1; }
check "github: exhausted link keeps the issue it created" 1 "$(count_issues)"
echo 0 > "$glink"
out="$(run_cc)"; rc=$?
check "github: rerun after a failed link exits 0" 0 "$rc"
check "github: rerun after a failed link creates the other items only (#31-#33)" 33 "$(cat "$FAKE_GH_SEQ")"
check "github: rerun after a failed link leaves each title once" 3 "$(count_issues)"
grep -q "issues/7/sub_issues -F sub_issue_id=1031" "$FAKE_GH_API" || { echo "FAIL github: unlinked issue not linked on rerun"; fail=1; }
echo "$seq_t2" > "$FAKE_GH_SEQ"

export FAKE_PR_BODY="$bd/ok.md" FAKE_PR_HEAD="feature/x"
bash scripts/factory/create-issues.sh --from-pr 9 --yes >/dev/null 2>&1; rc=$?
check "github: create-issues --from-pr refuses a non-agent branch" 1 "$rc"
bash scripts/factory/create-issues.sh "$bd/bad-cycle.md" --parent 7 --yes >/dev/null 2>&1; rc=$?
check "github: create-issues refuses an invalid breakdown" 4 "$rc"

# github: run the sub-issues whose blockers are closed (run-batch)
export FAKE_SUBS="$tmp/subs" FAKE_BLOCKED="$tmp/blocked" FAKE_ISSUE_BODY="$fx/ok-issue-form.md"
printf '9 open\n10 open\n11 open\n' > "$FAKE_SUBS"; echo "#9" > "$FAKE_BLOCKED.10"; printf '#9\n#10\n' > "$FAKE_BLOCKED.11"
out="$(bash scripts/factory/run-batch.sh 7 --list 2>&1)"
grep -qE "#9 +ready" <<<"$out" && grep -qE "#11 +blocked by: #9 #10" <<<"$out" || { echo "FAIL github: run-batch --list states wrong"; echo "$out"; fail=1; }
# A failing GitHub API call is retried; one that succeeds on retry keeps the batch going.
export BATCH_GH_RETRY_SECONDS=0
echo 2 > "$tmp/gh-fail"
out="$(FAKE_GH_API_FAIL="$tmp/gh-fail" bash scripts/factory/run-batch.sh 7 --list 2>&1)"; rc=$?
check "github: run-batch retries a failing sub_issues call" 0 "$rc"
grep -qE "#11 +blocked by: #9 #10" <<<"$out" || { echo "FAIL github: run-batch after a retry shows wrong states"; echo "$out"; fail=1; }
echo 3 > "$tmp/gh-fail"
out="$(FAKE_GH_API_FAIL="$tmp/gh-fail" FAKE_GH_API_FAIL_ON=blocked_by bash scripts/factory/run-batch.sh 7 --list 2>&1)"; rc=$?
check "github: run-batch retries a blocked_by call up to 3 times" 0 "$rc"
grep -qE "#11 +blocked by: #9 #10" <<<"$out" || { echo "FAIL github: run-batch after 3 retries shows wrong states"; echo "$out"; fail=1; }
echo 99 > "$tmp/gh-fail"
out="$(FAKE_GH_API_FAIL="$tmp/gh-fail" FAKE_GH_API_FAIL_ON=blocked_by bash scripts/factory/run-batch.sh 7 --list 2>&1)"; rc=$?
check "github: run-batch gives up after 3 retries" 1 "$rc"
grep -q "GitHub API call failed" <<<"$out" || { echo "FAIL github: run-batch give-up not reported"; echo "$out"; fail=1; }
check "github: run-batch tried 4 times before giving up" 95 "$(cat "$tmp/gh-fail")"
# Sub-issue 9's agent ends without a result (exit 8): the batch shows it as needing you.
out="$(bash scripts/factory/run-batch.sh 7 2>&1)"; rc=$?
check "github: run-batch reports a run without a result" 1 "$rc"
grep -q "start    #9" <<<"$out" && ! grep -q "start    #10" <<<"$out" || { echo "FAIL github: run-batch started the wrong sub-issues"; echo "$out"; fail=1; }
grep -qE "#9 +needs you" <<<"$out" || { echo "FAIL github: run without a result not shown as needing you"; echo "$out"; fail=1; }
[[ -d "$tmp/gh-worktrees/issue-9" ]] || { echo "FAIL github: sub-issue 9 did not get its own worktree"; fail=1; }
# A later batch: a worktree without commits is a stopped run (questions, breakdown), not one awaiting
# review, so --auto-continue must not wait for its PR; a worktree with commits is awaiting review.
out="$(bash scripts/factory/run-batch.sh 7 --list 2>&1)"
grep -qE "#9 +needs you" <<<"$out" || { echo "FAIL github: a worktree without commits is not shown as needing you"; echo "$out"; fail=1; }
BATCH_POLL_SECONDS=1 timeout 30 bash scripts/factory/run-batch.sh 7 --auto-continue >/dev/null 2>&1; rc=$?
[[ $rc -ne 124 ]] || { echo "FAIL github: run-batch --auto-continue waits for a stopped sub-issue"; fail=1; }
(cd "$tmp/gh-worktrees/issue-9" && echo w > work.txt && git add work.txt && git commit -qm "feat: work")
out="$(bash scripts/factory/run-batch.sh 7 --list 2>&1)"
grep -qE "#9 +started: review" <<<"$out" || { echo "FAIL github: a worktree with commits is not shown as awaiting review"; echo "$out"; fail=1; }
printf '9 closed\n10 closed\n11 closed\n' > "$FAKE_SUBS"
out="$(bash scripts/factory/run-batch.sh 7 2>&1)"; rc=$?
grep -q "All sub-issues of #7 are closed" <<<"$out" || { echo "FAIL github: closed sub-issues not recognised"; fail=1; }

# ---- github repo, Windows launcher (run-issue.ps1, needs pwsh) ----
if command -v pwsh >/dev/null; then
  shopt -s nullglob
  ps="$tmp/ps"; psw="$tmp/ps-worktrees/issue-7"
  mkdir -p "$ps" && cd "$ps" || exit 1
  git init -q -b main . && git config user.email t@t && git config user.name t
  echo x > README.md && git add -A && git commit -qm init
  bash "$root/install.sh" . --repo github --os windows >/dev/null
  sed -i 's/^ALLOW_NO_CHECKS=0/ALLOW_NO_CHECKS=1/' scripts/factory/commands.env
  git add -A && git commit -qm factory
  git init -q --bare "$tmp/ps-origin.git" && git remote add origin "$tmp/ps-origin.git" && git push -q origin main 2>/dev/null
  export FAKE_ISSUE_BODY="$fx/ok-issue-form.md"
  unset FAKE_PR_OPEN
  # The work folder is a UTC-stamped one, and a rerun reuses it.
  out="$(pwsh -NoProfile -File scripts/factory/run-issue.ps1 7 </dev/null 2>&1)"; rc=$?
  check "ps: run with no result exits 8" 8 "$rc"
  grep -q "produced no result" <<<"$out" || { echo "FAIL ps: empty run not reported"; echo "$out"; fail=1; }
  wf=("$psw"/.agent-work/*Z-issue-7)
  check "ps: one stamped work folder" 1 "${#wf[@]}"
  [[ "$(basename "${wf[0]}")" =~ $stamped_re ]] || { echo "FAIL ps: work folder name not stamped: ${wf[0]}"; fail=1; }
  [[ -f "${wf[0]}/issue.json" ]] || { echo "FAIL ps: issue.json not in the stamped folder"; fail=1; }
  pwsh -NoProfile -File scripts/factory/run-issue.ps1 7 </dev/null >/dev/null 2>&1; rc=$?
  wf2=("$psw"/.agent-work/*Z-issue-7)
  check "ps: rerun exits 8 again" 8 "$rc"
  check "ps: rerun reuses the stamped folder" "${wf[0]}" "${wf2[0]}"
  check "ps: rerun leaves one stamped folder" 1 "${#wf2[@]}"

  # A changed WORK_DIR in the paths file is picked up by the next run.
  pf="$psw/scripts/factory/paths.env"; orig_paths="$(<"$pf")"
  sed -i 's|^WORK_DIR=.*|WORK_DIR=elsewhere/work|' "$pf"
  FAKE_PR_OPEN=1 pwsh -NoProfile -File scripts/factory/run-issue.ps1 7 </dev/null >/dev/null 2>&1; rc=$?
  check "ps: run with a changed WORK_DIR exits 0" 0 "$rc"
  nw=("$psw"/elsewhere/work/*Z-issue-7)
  check "ps: changed WORK_DIR used" 1 "${#nw[@]}"
  [[ -f "${nw[0]}/issue.json" ]] || { echo "FAIL ps: changed WORK_DIR not used"; fail=1; }
  wf3=("$psw"/.agent-work/*Z-issue-7)
  check "ps: nothing new under the old location" 1 "${#wf3[@]}"
  printf '%s\n' "$orig_paths" > "$pf"; rm -rf "$psw/elsewhere"

  # Filing: a run with no recorded draft files nothing and creates no drafts folder.
  FAKE_AGENT=questions pwsh -NoProfile -File scripts/factory/run-issue.ps1 7 </dev/null >/dev/null 2>&1; rc=$?
  check "ps: no recorded draft, questions run exits 5" 5 "$rc"
  [[ -f "${wf3[0]}/questions.md" ]] || { echo "FAIL ps: questions.md not in the work folder"; fail=1; }
  none=("$ps"/.agent-work/drafts/*/questions.md "$ps"/.agent-work/drafts/*/breakdown.md)
  check "ps: no recorded draft, nothing filed" 0 "${#none[@]}"
  [[ ! -e "$ps/.agent-work/drafts" ]] || { echo "FAIL ps: no .agent-work/drafts folder created"; fail=1; }

  # A questions run files questions.md in the recorded draft folder, and not breakdown.md.
  ld="$ps/.agent-work/drafts/2026-01-02T03-04-08Z-rec"; mkdir -p "$ld" && printf 'number=7\nurl=https://example.test/7\n' > "$ld/created.txt"
  FAKE_AGENT=questions pwsh -NoProfile -File scripts/factory/run-issue.ps1 7 </dev/null >/dev/null 2>&1; rc=$?
  check "ps: questions run with a recorded draft exits 5" 5 "$rc"
  check "ps: questions.md filed in the recorded draft folder" \
    "1. Which columns are exported? — Why it matters: changes the CSV header." "$(cat "$ld/questions.md" 2>/dev/null)"
  [[ ! -e "$ld/breakdown.md" ]] || { echo "FAIL ps: breakdown.md filed after a questions run"; fail=1; }
  rm -f "$ld/questions.md"

  # A breakdown run files breakdown.md in the recorded draft folder, and not questions.md.
  FAKE_AGENT=breakdown FAKE_BREAKDOWN="$bd/ok.md" pwsh -NoProfile -File scripts/factory/run-issue.ps1 7 </dev/null >/dev/null 2>&1; rc=$?
  check "ps: breakdown run with a recorded draft exits 6" 6 "$rc"
  cmp -s "$bd/ok.md" "$ld/breakdown.md" || { echo "FAIL ps: breakdown.md not filed in the recorded draft folder"; fail=1; }
  [[ ! -e "$ld/questions.md" ]] || { echo "FAIL ps: questions.md filed after a breakdown run"; fail=1; }
  shopt -u nullglob
else
  echo "skip ps launcher flow (pwsh not installed)"
fi

# ---- github repo, Windows create-issues (create-issues.ps1, needs pwsh) ----
# The reuse and duplicate-title rules of create-issues.sh, run with pwsh -File on the same fixture.
if command -v pwsh >/dev/null; then
  setup_repo github "$tmp/psc" windows
  mkdir -p .agent-work/breakdowns && cp "$bd/ok.md" .agent-work/breakdowns/issue-7.md && cp "$bd/brief.md" .agent-work/breakdowns/issue-7.brief.md
  echo 20 > "$FAKE_GH_SEQ"; rm -f "$FAKE_GH_API" "$FAKE_GH_CREATE"
  printf '15\tExport service\n' > "$tmp/subs-reuse-ps"   # item 1 was created by an earlier run as #15
  out="$(FAKE_SUBS="$tmp/subs-reuse-ps" pwsh -NoProfile -File scripts/factory/create-issues.ps1 .agent-work/breakdowns/issue-7.md -Yes 2>&1)"; rc=$?
  check "ps: create-issues rerun with an existing sub-issue exits 0" 0 "$rc"
  check "ps: rerun creates only the missing items (#21, #22)" 22 "$(cat "$FAKE_GH_SEQ")"
  grep -q "Reused #15: Export service" <<<"$out" || { echo "FAIL ps: reused sub-issue not reported"; echo "$out"; fail=1; }
  grep -q "Created #21: Export button" <<<"$out" || { echo "FAIL ps: missing item not created"; echo "$out"; fail=1; }
  check "ps: reused item looked up only for its id" 1 "$(grep -c 'issues/15 ' "$FAKE_GH_API")"
  grep -qx "Export audit log" "$FAKE_GH_CREATE" || { echo "FAIL ps: last create is not the last item"; fail=1; }
  for want in "issues/7/sub_issues -F sub_issue_id=1015" "issues/7/sub_issues -F sub_issue_id=1021" "issues/7/sub_issues -F sub_issue_id=1022" \
              "issues/21/dependencies/blocked_by -F issue_id=1015" "issues/22/dependencies/blocked_by -F issue_id=1015" "issues/22/dependencies/blocked_by -F issue_id=1021"; do
    grep -q -- "$want" "$FAKE_GH_API" || { echo "FAIL ps: rerun missing gh api call: $want"; cat "$FAKE_GH_API"; fail=1; }
  done
  grep -qx "Depends on: #15" "$FAKE_GH_CREATE.body.21" || { echo "FAIL ps: rerun body does not name the reused number"; fail=1; }
  grep -qx "Depends on: #15, #21" "$FAKE_GH_CREATE.body.22" || { echo "FAIL ps: rerun body names the wrong numbers"; fail=1; }
  grep -q "could not" <<<"$out" && { echo "FAIL ps: rerun reported a failed link"; echo "$out"; fail=1; }

  # two items with the same title are refused before anything is created
  rm -f "$FAKE_GH_CREATE"; seq_before="$(cat "$FAKE_GH_SEQ")"
  out="$(pwsh -NoProfile -File scripts/factory/create-issues.ps1 "$tmp/bd-dup.md" -Yes 2>&1)"; rc=$?
  check "ps: create-issues refuses a duplicate title in the breakdown" 1 "$rc"
  grep -q 'Export service' <<<"$out" || { echo "FAIL ps: duplicate title not named"; echo "$out"; fail=1; }
  [[ ! -e "$FAKE_GH_CREATE" ]] || { echo "FAIL ps: an issue was created despite the duplicate title"; fail=1; }
  check "ps: duplicate title creates nothing" "$seq_before" "$(cat "$FAKE_GH_SEQ")"
else
  echo "skip ps create-issues checks (pwsh not installed)"
fi

[[ $fail -eq 0 ]] && echo "launcher flow: all passed"
exit $fail
