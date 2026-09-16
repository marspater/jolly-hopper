# Jules Agent Instructions

These instructions apply to **Jules only**. Follow the shared repository contract in the root `AGENTS.md` as well.

## Execution mode

Jules is an autonomous, headless, disposable runner. The environment is assumed disposable **only because Jules explicitly provides that execution mode**; never generalize these rules to Antigravity or a user's local workspace.

## Destructive bootstrap

At the start of a Jules session, synchronize and reset to the current remote baseline:

```bash
git fetch origin main --prune
git checkout -B main origin/main
git reset --hard origin/main
git clean -fdx
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

These destructive commands are authorized **only inside the disposable Jules environment**. Never copy this bootstrap into Antigravity/local-workspace instructions.

Do not preserve stale work from previous Jules sessions unless the task explicitly requires an existing branch/worktree.

## Task loop

1. Read the root contract and this file.
2. Read only the relevant specialist file: Palette for UI/UX/accessibility, Bolt for performance, Sentinel for security, Testing for test-specific guidance.
3. Inspect current `origin/main`, relevant code, recent commits, and existing implementations before changing anything.
4. Make one focused change with the smallest correct diff; do not manufacture work.
5. Re-check `origin/main` before major implementation decisions and before finalizing.
6. Run relevant Xcode build/tests and report results honestly.
7. Create a focused PR only when the task is implemented and verified.

## Specialist boundaries

Do not mix unrelated specialist scopes into one PR. Specialist journals are not work logs and should be updated only when a reusable, application-specific learning is discovered.

## PR expectations

PR titles and descriptions should be concise, factual, and limited to the implemented task. Include what changed, why, validation performed, and relevant limitations. Add screenshots for visually meaningful UI changes when practical.

## Repository hygiene

Do not leave temporary scripts, debug output, generated artifacts, unrelated changes, merge markers, or stale worktree modifications. Follow the root validation and engineering rules.

**Jules principle:** destructive Git operations are acceptable only because the Jules environment is explicitly disposable; treat every local human workspace as protected unless separately authorized.