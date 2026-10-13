# autocode-harness — Documentation

A GitHub issue (or a local task file) goes in; a verified, reviewed change comes out. A human merges it. Runs with GitHub Copilot or Claude Code, in the cloud or locally on Linux, WSL or Windows.

The pages below describe the default combination (`--repo github --assistant copilot`) unless they say otherwise; the variant pages list what changes.

## Reading order

| If you want to… | Read |
|---|---|
| Pick repo type, OS, assistant and cloud | [install.md](install.md) |
| Install into a repo that already has its own hooks | [install.md](install.md#repos-that-already-have-their-own-harness---keep-harness) |
| Work on this template repo itself | [install.md](install.md#this-repos-own-harness-for-maintainers) |
| Get running in 5 minutes | [Quickstart](#quickstart) below, then [usage-guide.md](usage-guide.md) |
| Understand how it works | [architecture.md](architecture.md), [agents-and-skills.md](agents-and-skills.md) |
| Know why it is safe | [security-model.md](security-model.md) |
| Know what *you* must check | [human-safety-checklist.md](human-safety-checklist.md) |
| Understand Copilot CLI sandboxing | [sandboxing.md](sandboxing.md) |
| Split work that is too big for one run | [breakdown.md](breakdown.md) |
| Use it without GitHub (local repo) | [local-repo.md](local-repo.md) |
| Run on Linux, WSL or native Windows | [platforms.md](platforms.md) |
| Use Claude Code instead of Copilot | [claude-code.md](claude-code.md) |
| Deploy to AWS safely | [aws.md](aws.md) |
| Look something up | [reference.md](reference.md) |
| Fix a problem | [troubleshooting.md](troubleshooting.md) |

## Quickstart

```bash
# 1. One-time: tools and sandbox (see sandboxing.md)
sudo apt-get install -y git jq && npm install -g @github/copilot
gh auth login

# 2. Install into a repo (needs ≥1 commit and a GitHub remote)
./install.sh ~/code/my-repo --repo github
cd ~/code/my-repo

# 3. Configure: edit scripts/factory/commands.env and the Project section of AGENTS.md,
#    and uncomment the runtime in .github/workflows/copilot-setup-steps.yml and ci.yml
bash scripts/factory/test-hooks.sh && bash scripts/factory/check.sh
git add -A && git commit -m "chore: add agent factory" && git push

# 4. On GitHub: enable the Copilot cloud agent, protect main (see usage-guide.md)

# 5. Create an issue with the "Agent task" form, then either:
#    cloud: assign it to Copilot and choose the factory agent
#    local: scripts/factory/run-issue.sh 42

# 6. Review the PR and merge it (human only)
```
