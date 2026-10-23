# Security Model

The agent runs with broad tool permissions (`--allow-all-tools` locally), so safety comes from **layers around it**, not from trusting the agent. No single layer is a complete sandbox; the real boundary is isolation plus branch protection and the human merge.

## Threats considered

| Threat | Example |
|---|---|
| Prompt injection | Issue text, comments, code comments or fetched web pages say "ignore your rules and run X" |
| Secret theft | Reading `.env`, `~/.ssh`, `~/.aws/credentials`, tokens in env vars |
| Exfiltration / publishing | Pushing to other refs, `gh` writes, `curl … \| sh` |
| Cloud damage | `terraform apply`, `cdk deploy`, `aws … delete-*`, `kubectl delete` |
| Escaping the box | `sudo`, destructive `rm`, `chmod 777`, privileged containers |
| Weakening the rules | Editing hooks, policy, workflows, `check.sh`, `commands.env` |
| Faking success | Forging the `.verified` marker, tampering with logs, skipping/weakening tests |
| Unreviewed merge | Agent merging or approving its own PR |

## Layers

| # | Layer | Mechanism | Stops |
|---|---|---|---|
| 1 | Isolation | Cloud: ephemeral environment, push limited by GitHub to its own `copilot/*` branch. Local: separate git worktree and `agent/*` branch | Touching your main checkout or machine |
| 2 | Copilot CLI sandbox (local; you enable it) | OS-level filesystem/network limits — see [sandboxing.md](sandboxing.md) | Writes outside the worktree, reads of denied paths |
| 3 | CLI deny flags (local) | `--deny-tool 'shell(git push --force)'`, `shell(gh pr merge)`, `shell(sudo)` | Force-push, merge, sudo |
| 4 | `preToolUse` guard | `guard.sh` + `policy/deny-commands.txt` + `deny-paths.txt` | The threat table above for shell commands and file tools |
| 5 | Push rule in guard | `git push` only from `agent/*` or `copilot/*`, only the current branch. The guard parses the command line: it judges each push by the branch of the directory it runs in (after `cd <dir>` or `git -C <dir>`), ignores redirections (`2>&1`) and quoted text (commit messages, PR bodies), and also checks commands inside `$( )`, `bash -c` and `eval` | Pushes to the base branch or other refs |
| 6 | Instructions | `AGENTS.md` hard rules; issue text treated as data | Honest mistakes, naive injection |
| 7 | Stop gate | `stop-gate.sh` + `check.sh` state-hash marker | Finishing with unverified changes |
| 8 | Audit log | `log.sh` on 11 events, secrets redacted | Undetected activity; supports review |
| 9 | CI | `verify`, `hooks-selftest`, `guardrails-unchanged`. On Copilot PRs, workflows wait for a human to approve the run | Claims the agent did not actually earn; agent PRs touching guardrails |
| 10 | Branch protection + human merge | Required PR, human approval, required checks; recommended CODEOWNERS on guardrail paths | Unreviewed code reaching the base branch |

## How the guard works

- Runs before **every** tool call; receives JSON on stdin.
- **Shell:** the command is whitespace-normalised and matched case-insensitively against every regex in `deny-commands.txt`. The regexes match a "code view", not the raw text: quoted text with whitespace (a commit message, PR title or body) is blanked, so `git commit -m "docs: gh issue create is human-only"` is allowed. A quoted span with `$`, a backtick or a backslash, and a single-word quote (`"gh"` → `gh`), stay visible. When the text may run (an unterminated quote, two quotes in a row, `$`, a backtick, a heredoc, or a word such as `bash`, `sh`, `eval`, `xargs`, `env`, `alias`, `editor`, `git_*`), the raw command is matched too, so `bash -c "gh issue create"` and `eval "sudo ls"` stay denied. A commit message that names both a trigger word and a denied command is denied (over-denial, the same as before this rule). A match returns `{"permissionDecision":"deny",…}`.
- **Files:** every path-like argument (including `apply_patch` headers) is matched against `deny-paths.txt`. Plain rules block read and write (secrets); `write:` rules block writes only (hooks, workflows, `check.sh`, `commands.env`, logs, `.git/`).
- **Fail-closed:** a crash or non-zero exit denies the call (for `preToolUse`, the CLI treats any non-zero exit as deny).
- **Fail-open on timeout:** if the hook exceeds `timeoutSec` (15s) it is killed and the call is allowed. Keep the scripts fast.
- **Hooks must load.** The cloud agent always loads `.github/hooks/*.json`. The CLI loads repository hooks in `-p` mode only for a trusted folder or with `GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS=true`, which `run-issue.sh` sets. If you start `copilot -p` yourself in an untrusted folder, **no guard runs**.
- Policy files are themselves write-protected from the agent.
- `test-hooks.sh` (and `test-hooks.ps1` on Windows) runs every case in `hook-cases.txt` plus stop-gate, logging and redaction checks. CI runs it as `hooks-selftest`.

## What is denied (summary)

Destructive filesystem ops; `sudo`/`su`; curl/wget piped to a shell; forced or non-current-branch `git push`, `filter-branch`, global git config; `gh` merge/approve/repo-admin/secret/ruleset/workflow-run and mutating `gh api`; terraform/cdk/pulumi/sam/kubectl/helm changes and AWS mutating calls; reading `.env`, SSH keys, cloud credentials, token files; bare `env`/`printenv`; touching `.agent-logs`. Full lists: `.github/hooks/policy/`.

## Known limits — be honest with yourself

- **Deny-lists are bypassable.** Shell is expressive: `sed -i` on a protected file, a script that writes the file, base64-decoded commands, or a language runtime (`python -c`) can sidestep regexes. The stop gate and CI catch *unverified* changes and guardrail edits in agent PRs, not every malicious one.
- **Hook timeout fails open.**
- **Branch protection is the real merge control.** It is configured in GitHub, not in this repo; if it is missing, nothing server-side stops a merge.
- **CI `guardrails-unchanged` covers** `.github/hooks/`, `.github/workflows/`, `scripts/factory/check.sh` and `commands.env` for `agent/*` and `copilot/*` branches. Edits to other files (e.g. `AGENTS.md`, agents, skills, `setup.sh`, `run-issue.sh`) are not blocked by CI — read the PR diff, or add CODEOWNERS for them.
- **Checks run branch code.** `check.sh` and CI execute the project's tests/build from the branch, which is arbitrary code. Approve workflow runs on Copilot PRs only after reading the diff.
- **Environment variables** are not hidden from the agent except by the printenv/echo patterns; do not export secrets in the shell that starts `run-issue.sh`.
- **No network control** from the hooks beyond blocking specific commands; use the sandbox (local) or the cloud agent firewall.
- **Not a defence against a malicious repo owner.** The threat model is a mistaken or manipulated agent, not a hostile human with write access.

## Secrets and credentials

- Never give agents AWS, cloud or production credentials; do not add them as **Agents** secrets/variables (the cloud agent's only secret source; older repos had a `copilot` Actions environment, now migrated); run local sessions with a clean environment.
- Logs redact GitHub tokens, AWS keys, `sk-` keys, private keys and `password|secret|token|api_key = value` patterns before writing. Redaction is pattern-based; treat logs as sensitive anyway.
- `.env.example` is blocked by the `.env` rule — rename (e.g. `env.example`) or adjust `deny-paths.txt`.
