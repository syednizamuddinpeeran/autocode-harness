# Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Missing: gh/copilot/jq/git` | Tool not installed | Install it (see usage-guide) |
| `Not ready for the factory` (exit 4) | Goal, Acceptance criteria, Out of scope or Risk missing, or a template placeholder / `OPEN:` left in | Fill in the issue (or `tasks/<id>.md` and commit it) and run again |
| `The agent needs answers` (exit 5) | Intake found the requirements unclear and wrote `questions.md`; nothing was implemented | Answer the questions in the issue / task file and run again |
| `too big for one run` (exit 6) | The plan exceeded `scripts/factory/complexity.env`; the planner proposed a breakdown; nothing was implemented | Review `.agent-work/breakdowns/…`, then `create-issues.sh` / `create-tasks.sh` ([breakdown.md](breakdown.md)), or raise the limits yourself |
| `the work is committed but not pushed` (exit 7) | The agent committed on its branch but no PR is open for it, usually because its push or `gh pr create` failed or was blocked | Read the run's output for the blocked command; push the branch and open the PR yourself, or fix the cause and run again (the worktree is reused) |
| `git push refspec '…' is not the current branch` | The push named another branch, or the guard judged the push against the wrong directory | Push the current branch (`git push -u origin HEAD`). The guard checks the branch of the directory the push runs in (after `cd <dir>` or `git -C <dir>`); redirections such as `2>&1` and quoted text (commit messages, PR bodies) are not refspecs |
| `Breakdown is not valid` | An item is not ready, a dependency is missing or circular, or a parent AC is not covered | Edit the breakdown file and run `create-issues` / `create-tasks` again |
| CI `size` fails / `accept.sh` says the branch exceeds `complexity.env` | The real diff is bigger than the limits | Split the work; or merge anyway (`accept.sh --allow-large`, or override the required check on GitHub) if splitting would not help review |
| `the run produced no result` (exit 8) | The agent ended with no commits, no open PR, no `questions.md` and no `breakdown.md`: it stopped early, failed, or was cut off | Read the run's output for why it stopped; uncommitted edits, if any, are still in the worktree. Run again (the worktree is reused) |
| `a branch named 'agent/issue-…' already exists` | An older version of `run-issue` met a branch left over from a run whose worktree was removed | Update the factory scripts: `run-issue` now reuses that branch (restarted from the base if it has no commits, kept if it has some). To start over on a branch with commits, delete it: `git branch -D agent/issue-…` |
| `GitHub API call failed … giving up` (`run-batch`, exit 1) | A `gh api` call kept failing (network timeout, rate limit) after `BATCH_GH_RETRIES` retries | Check `gh auth status` and the network, then run the batch again; runs already started keep their worktrees |
| `run-batch` item says "needs you" | That run stopped with questions, a breakdown, unpushed work (exit 7), no result (exit 8) or an error | Read `.agent-logs/batch/<item>.log`; fix the item, delete its branch/worktree, run the batch again |
| `run-batch` item says "needs you: commits but no PR, run open-pr or delete the worktree" | The item's worktree has commits on its branch but no open PR for that branch (the earlier run stopped before opening one, or the PR was closed), so the batch does not wait for it | Run `open-pr` in that worktree to open the PR, or delete the worktree and branch and run the batch again |
| `run-batch --auto-continue` never ends | It waits for you to merge finished items | Merge them (PR / `accept.sh`), or stop it with Ctrl+C — runs already started keep their worktrees |
| `new-draft.sh is interactive` | Run without a terminal (CI, pipe) | Run it in a terminal; it asks you questions |
| `create-issue --draft` created nothing | It validates every draft first and creates none if any is not ready | Fix the draft it names and run again |
| `create-issue` / `create-task` says not ready | The draft still has `OPEN:` items or empty sections | Answer them (edit the draft or re-run `new-draft --id <id>`, which continues it) |
| After `--keep-harness`, `check.sh` fails with `factory_log_dir` / `factory_state_hash: command not found` (`check.ps1`: `Get-FactoryLogDir` / `Get-FactoryStateHash` not recognized) | `check` sources your own `common.sh` / `common.ps1`, which lacks the helpers the factory needs | Add those functions to your `common.*` (copy them from `.agent-work/harness/`); see [install.md](install.md#repos-that-already-have-their-own-harness---keep-harness) |
| `No checks configured` (exit 3) | All commands empty in `commands.env` | Configure them, or `ALLOW_NO_CHECKS=1` for docs-only repos |
| Copilot rejects flags | CLI flag names changed | `copilot help permissions`; adjust `run-issue.sh` (human edit) |
| Cloud agent can't build/test | Runtime missing in its environment | Uncomment the runtime in `copilot-setup-steps.yml`; the job must be named `copilot-setup-steps` and the file must be on the default branch |
| `factory` agent missing from the dropdown | Agent file not on the default branch | Merge `.github/agents/` into the default branch and refresh |
| CI never starts on a Copilot PR | Workflow runs need approval by default | Read the diff, then click **Approve and run workflows** |
| Local run: no `.agent-logs`, nothing blocked | Repository hooks not loaded in `-p` mode | Use `run-issue.sh` (sets `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true`) or trust the folder |
| "Blocked by factory guard" in the agent output | Policy matched a command/path | Check the `reason` in `.agent-logs`; if legitimate, change the issue approach or adjust the policy files yourself — the agent cannot |
| Legit command blocked (e.g. `.env.example`, a word matching `\bgh\b`) | Regex too broad | Narrow the pattern in `policy/` and rerun `test-hooks.sh` |
| Agent keeps being told to verify | Stop gate: changes since last green `check.sh` | Run `check.sh` and fix failures; the marker is invalidated by any edit |
| CI `guardrails-unchanged` fails | Agent PR touched hooks, workflows, `check.sh`, `commands.env`, `complexity.env` or the check scripts | Make that change yourself in a separate PR; revert it from the agent PR |
| PR is Draft | High risk, failed verification, or open questions | Read Risks and questions; refine the issue and rerun |
| Hooks seem not to run | Not in the repo/worktree where Copilot starts, or scripts not executable | Run `scripts/factory/setup.sh`; confirm `.github/hooks/factory.json` is on the branch the agent uses |
| Claude Code on Windows: every tool call fails with `PreToolUse:Bash hook error: [bash …]: timed out; blocking because onFailure is "block"` or `/bin/bash: E:OneDrive…/guard.sh: No such file or directory` | A hook in exec form (`"command": "bash"` plus `args`) started WSL's `bash.exe` instead of Git Bash | Use shell form with a quoted path, or `pwsh` for `--os windows` ([claude-code.md](claude-code.md#hooks-on-native-windows)); while you fix it, turn the hooks off with `/hooks` or a gitignored `.claude/settings.local.json` |
| `factory guard: jq not found on PATH` (every tool call blocked) | `jq` missing for the bash hooks | `winget install jqlang.jq` (Windows) or your package manager, then restart the session |
| Hook slow → a call slipped through | Timeout is fail-open | Keep policy files small; avoid heavy work in hooks |
| Sandbox blocks a legitimate write | Path outside allowed dirs | Add the path in `/sandbox config` → Filesystem, or move work inside the worktree |
| `/sandbox` says unavailable on Linux/WSL | Missing `bwrap` (≥ 0.5.0), `slirp4netns` or other requirements | Install them; see [sandboxing.md](sandboxing.md#platform-requirements) |
| Different results on `/mnt/c` | Slow filesystem, line endings | Use the WSL filesystem |
