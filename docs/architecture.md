# Architecture

## End-to-end flow

```
Issue (agent-task form, or create-issue --draft → you review → add label agent-ready)
      │
      ├─ cloud: assign to Copilot, pick the factory agent → branch copilot/*
      └─ local: scripts/factory/run-issue.sh <N>
                 creates worktree ../<repo>-worktrees/issue-N on branch agent/issue-N-<slug>
                 runs setup.sh, then: copilot --agent factory -p "<prompt>" --allow-all-tools --deny-tool …
      ▼
factory agent (orchestrator)
  1. skill issue-intake     → .agent-work/issue-N/brief.md
  2. planner subagent       → plan.md        (writes only the plan)
  3. implementer subagent   → one commit per plan task, test-first (looped over T1…Tn)
  4. skill verify-changes   → scripts/factory/check.sh → verify.log (≤3 fix loops)
  5. reviewer subagent      → review.md      (BLOCKING / NIT, VERDICT) (≤2 fix loops)
  6. skill open-pr          → PR "Closes #N" (draft if high risk / failed / open questions)
      ▼
CI (verify, hooks-selftest, guardrails-unchanged) + branch protection
      ▼
human: reviews and merges the PR
```

Hooks wrap every step (see [security-model.md](security-model.md)) and write an audit trail to `.agent-logs/`.

## Key design ideas

- **Small orchestrator context.** The factory passes file paths between steps, not content. Heavy work runs in subagents.
- **Files are the interface.** Each step reads and writes files in `.agent-work/issue-N/`, so any step can be inspected or resumed.
- **One verification gate.** `check.sh` is the single definition of "good"; agents, humans and CI all use it.
- **Humans own the rules.** Hooks, workflows, policy and the check scripts cannot be edited by the agent (guard hook), and CI fails agent PRs that touch them.
- **Merge is human-only.** Branch protection requires a human approval and the required checks; the agent never merges.

## Where things live

| Path | Purpose | Git-tracked |
|---|---|---|
| `AGENTS.md` | Always-loaded rules and project description | yes |
| `.github/ISSUE_TEMPLATE/agent-task.yml` | Task input form | yes |
| `.github/agents/*.agent.md` (Claude Code: `.claude/agents/*.md`) | Agent definitions | yes |
| `.github/skills/*/SKILL.md` (Claude Code: `.claude/skills/`) | Step procedures loaded on demand | yes |
| `.github/hooks/factory.json` (Claude Code: `.claude/settings.json`) | Hook wiring (11 events) | yes |
| `.github/hooks/scripts/` | `guard.sh`, `stop-gate.sh`, `log.sh`, `common.sh` (+ `.ps1` on Windows) | yes |
| `.github/hooks/policy/` | `deny-commands.txt`, `deny-paths.txt`, `git-rules.env` | yes |
| `.github/workflows/` | `copilot-setup-steps.yml` (cloud agent environment), `ci.yml` | yes |
| `.github/pull_request_template.md` | PR body layout | yes |
| `scripts/factory/` | `commands.env`, `check.sh`, `setup.sh`, `run-issue.sh`, `test-hooks.sh`, `hook-cases.txt` (+ `.ps1` on Windows) | yes |
| `.agent-work/issue-N/` | issue.json, brief, plan, verify.log, review, decisions, pr-body | no (gitignored) |
| `.agent-logs/` | `<session>.jsonl`, `index.jsonl`, `.verified` marker | no (gitignored) |
| `../<repo>-worktrees/issue-N/` | Isolated checkout per local run | outside repo |

## Isolation model

- **Cloud:** the agent runs in an ephemeral GitHub Actions–based Linux environment prepared by `copilot-setup-steps.yml`, behind GitHub's firewall, and can push only to its own `copilot/*` branch. Hook logs there are discarded with the environment.
- **Local:** each issue gets its own git worktree on its own `agent/issue-N-*` branch; your main checkout is never touched. `.agent-work/` and `.agent-logs/` are per-worktree.

## The verification marker

`check.sh` computes a hash of the working state (HEAD + tracked diff + untracked file hashes) and stores it in `.agent-logs/.verified` only if every configured check passes. The `agentStop` hook recomputes the hash; any edit after the last green run changes the hash and the agent is forced to re-verify before it can finish.
