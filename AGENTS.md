# Agent Instructions

This project uses **bd** (beads, 1.x) for issue tracking. Run `bd prime` for the workflow.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd export -o .beads/issues.jsonl     # Write the issues to the tracked file
```

Beads keeps its database in `.beads/embeddeddolt` (not tracked). There is no
Dolt remote and no daemon: `.beads/issues.jsonl`, committed with the code, is
the copy that leaves the machine. Do not use `bd sync` (it is the Dolt-remote
loop) and do not set `sync.remote`.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW** (one step at a time, each finished before the next):

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   bd export -o .beads/issues.jsonl
   git add .beads/issues.jsonl   # with the code changes
   git commit
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
