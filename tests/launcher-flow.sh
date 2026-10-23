#!/usr/bin/env bash
# End-to-end launcher flow with fake `copilot` and `gh` CLIs (no network, no real agent):
#   - not ready  → exit 4 and the agent never starts
#   - ready, agent writes questions.md → exit 5 and the questions are shown
#   - ready, agent finishes → exit 0
#   - github: agent commits but opens no PR → exit 7 (with an open PR → exit 0)
#   - local: an edited task restarts a worktree that has no commits yet
#   - agent proposes a breakdown → exit 6, saved; create-tasks / create-issues create the sub-items
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
if [[ "${FAKE_AGENT:-}" == questions ]]; then
  d="$(ls -d .agent-work/*/ | head -1)"
  printf '1. Which columns are exported? — Why it matters: changes the CSV header.\n' > "${d}questions.md"
fi
if [[ "${FAKE_AGENT:-}" == commit ]]; then
  echo "$PWD" > "work-$(basename "$PWD").txt" && git add work-*.txt && git commit -qm "feat: fake work"
fi
if [[ "${FAKE_AGENT:-}" == breakdown ]]; then
  d="$(ls -d .agent-work/*/ | head -1)"
  cp "$FAKE_BREAKDOWN" "${d}breakdown.md"; cp "$FAKE_BRIEF" "${d}brief.md"
fi
exit 0
SH
# Fake gh: `gh issue view N --json …` prints an issue whose body is $FAKE_ISSUE_BODY;
# `gh issue create …` records its arguments and body, and prints an issue URL.
cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue view" ]]; then
  jq -n --arg b "$(cat "$FAKE_ISSUE_BODY")" '{number: 7, title: "Add CSV export", body: $b, labels: [], url: "https://example.test/7"}'
elif [[ "$1 $2" == "issue create" ]]; then
  n=$(( $(cat "$FAKE_GH_SEQ" 2>/dev/null || echo 7) + 1 )); echo "$n" > "$FAKE_GH_SEQ"
  printf '%s\n' "$@" > "$FAKE_GH_CREATE"
  while [[ $# -gt 0 ]]; do [[ "$1" == --body-file ]] && cp "$2" "$FAKE_GH_CREATE.body" && cp "$2" "$FAKE_GH_CREATE.body.$n"; shift; done
  echo "https://example.test/issues/$n"
elif [[ "$1 $2" == "issue comment" ]]; then
  printf '%s\n' "$@" > "$FAKE_GH_COMMENT"
elif [[ "$1 $2" == "pr list" ]]; then
  # open PRs for --head <branch>: FAKE_PR_OPEN=1 reports one (as `--jq length` would print it)
  printf '%s\n' "$@" > "$FAKE_GH_PR_LIST"
  [[ -n "${FAKE_PR_OPEN:-}" ]] && echo 1 || echo 0
elif [[ "$1 $2" == "pr view" ]]; then
  jq -n --arg b "$(cat "$FAKE_PR_BODY")" --arg h "$FAKE_PR_HEAD" '{body: $b, headRefName: $h, author: {login: "Copilot"}, url: "https://example.test/pull/9"}'
elif [[ "$1" == api && "$2" == */sub_issues ]]; then
  cat "$FAKE_SUBS"          # already in the --jq output form: "<number> <state>"
elif [[ "$1" == api && "$2" == */dependencies/blocked_by ]]; then
  n="${2%/dependencies/blocked_by}"; cat "$FAKE_BLOCKED.${n##*/}" 2>/dev/null || true   # "#<number>" of open blockers
elif [[ "$1" == api ]]; then
  echo "${*:2}" >> "$FAKE_GH_API"
  # GET repos/{owner}/{repo}/issues/N --jq .id → a fake issue id (1000 + N)
  [[ "$2" != -X ]] && echo $(( 1000 + ${2##*/} ))
fi
exit 0
SH
chmod +x "$bin"/*
export PATH="$bin:$PATH" FAKE_LOG="$tmp/agent.log" FAKE_GH_CREATE="$tmp/gh-create.args"
export FAKE_GH_SEQ="$tmp/gh-seq" FAKE_GH_API="$tmp/gh-api.log" FAKE_GH_COMMENT="$tmp/gh-comment.args"
export FAKE_GH_PR_LIST="$tmp/gh-pr-list.args"
bd="$root/tests/fixtures/breakdown"
export FAKE_BRIEF="$bd/brief.md"

setup_repo() { # setup_repo <repo-type> <dir>
  mkdir -p "$2" && cd "$2" || exit 1
  git init -q -b main . && git config user.email t@t && git config user.name t
  echo x > README.md && git add -A && git commit -qm init
  bash "$root/install.sh" . --repo "$1" >/dev/null
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

# ---- github repo ----
setup_repo github "$tmp/gh"
git init -q --bare "$tmp/origin.git" && git remote add origin "$tmp/origin.git" && git push -q origin main 2>/dev/null
rm -f "$FAKE_LOG"
export FAKE_ISSUE_BODY="$fx/bad-issue-empty-field.md"
out="$(bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: not-ready issue exits 4" 4 "$rc"
check "github: agent not started for not-ready issue" 0 "$(runs)"
grep -q "issue #7" <<<"$out" || { echo "FAIL github: reason does not name the issue"; fail=1; }

export FAKE_ISSUE_BODY="$fx/ok-issue-form.md"
out="$(FAKE_AGENT=questions bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: agent questions exit 5" 5 "$rc"
grep -q "Which columns are exported" <<<"$out" || { echo "FAIL github: questions not shown"; fail=1; }

out="$(bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: ready issue runs" 0 "$rc"
[[ ! -e "$tmp/gh-worktrees/issue-7/.agent-work/issue-7/questions.md" ]] || { echo "FAIL github: stale questions.md kept"; fail=1; }

# github: the agent committed but opened no PR (e.g. its push was blocked) → exit 7, "needs you"
out="$(FAKE_AGENT=commit bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: committed but no PR exits 7" 7 "$rc"
grep -q "committed but not pushed" <<<"$out" || { echo "FAIL github: unpushed work not reported"; echo "$out"; fail=1; }
grep -qx "agent/issue-7-add-csv-export" "$FAKE_GH_PR_LIST" || { echo "FAIL github: PR not looked up for the issue branch"; fail=1; }
out="$(FAKE_PR_OPEN=1 bash scripts/factory/run-issue.sh 7 </dev/null 2>&1)"; rc=$?
check "github: committed with an open PR exits 0" 0 "$rc"

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
out="$(bash scripts/factory/run-batch.sh 7 2>&1)"; rc=$?
check "github: run-batch runs the unblocked sub-issue" 0 "$rc"
grep -q "start    #9" <<<"$out" && ! grep -q "start    #10" <<<"$out" || { echo "FAIL github: run-batch started the wrong sub-issues"; echo "$out"; fail=1; }
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

[[ $fail -eq 0 ]] && echo "launcher flow: all passed"
exit $fail
