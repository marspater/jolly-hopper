# AGENTS.md

## Repository Context & Sync Directives (Jolly Hopper)

This repository evolves rapidly with frequent pushes and merged pull requests. Always align with the latest remote state before executing any task.

---

### 1. Mandatory Pre-Flight Sync
Before analyzing, planning, or editing any files:
1. Fetch latest remote changes:
   `git fetch origin main`
2. Inspect recent commits and merged PR history:
   `git log origin/main -n 25 --oneline --decorate`
3. Verify current branch status:
   `git status`

---

### 2. Avoid Redundant Work
- **Check Existing Solutions**: Always verify whether the requested task, bug fix, or refactor has already been implemented in a recent commit or merged PR.
- **Search Before Creating**: Before creating new helper functions, types, or boilerplate, use search (`git grep` or symbol search) to reuse existing utilities and patterns.
- **Flag Completed Items**: If a requested change already exists in `origin/main`, stop and report the relevant commit SHA rather than rewriting duplicate logic.

---

### 3. Execution & Code Standards
- **Minimal & Targeted Diffs**: Limit edits strictly to what is necessary for the objective. Do not reformat or refactor unrelated files.
- **Respect Repo Conventions**: Follow the architectural patterns, typing practices, and formatting established in recent commits.
- **Validation**:
  - Run project linting, type checks, and formatting commands before finalizing.
  - Run relevant unit/integration tests to ensure no regressions are introduced.

---

### 4. Git Hygiene
- Write concise Conventional Commit messages (`feat: ...`, `fix: ...`, `refactor: ...`, `test: ...`).
- Never leave behind merge conflict markers, temporary debug logs, or unstaged scratch files.
