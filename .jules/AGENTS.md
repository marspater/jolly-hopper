# Jules Agent Instructions

These instructions apply to Jules sessions only. Repository-wide engineering rules remain in the root `AGENTS.md` and must also be followed.

## Fresh repository bootstrap

Jules environments are disposable. Start every session from the latest `origin/main`:

```bash
git fetch origin main --prune
git checkout -B main origin/main
git reset --hard origin/main
git clean -fdx
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

Do not preserve stale local changes from previous Jules sessions unless the task explicitly requires work on an existing branch and the environment is not disposable.

## Specialist role files

Specialist instructions live in:

- `.jules/palette.md` for UI/UX/accessibility work
- `.jules/bolt.md` for performance work
- `.jules/sentinel.md` for security work
- `.jules/testing.md` for testing learnings

Read only the specialist file relevant to the current Jules task. Do not load every specialist journal by default.

These files are task-specific guidance and journals, not replacements for the root repository contract.

## Jules task boundaries

- Perform one focused task per session.
- Do not manufacture work merely to produce a PR.
- Search the current `origin/main` before implementing.
- Inspect recent commits and related merged PRs when the task could already be resolved.
- Re-check `origin/main` before substantial implementation decisions and before finalizing.
- Keep the diff minimal and avoid unrelated cleanup.
- Add or update regression coverage when practical.
- Run the relevant build/test validation before creating a PR.
- Report validation honestly.
- Do not leave temporary scripts, debug output, generated artifacts, or unrelated changes.

## PR expectations

When a task is complete, create a focused PR only when the requested change is actually implemented and verified.

The PR description should briefly state:

1. what changed
2. why it was needed
3. what was tested
4. any relevant limitations

Do not exaggerate impact or include unrelated changes.

## Specialist selection

Use the specialist role only when it matches the task. For example:

- UI polish, UX, accessibility, visual consistency -> Palette
- performance, allocations, CPU/memory efficiency -> Bolt
- vulnerability/security hardening -> Sentinel
- test strategy or regression coverage -> Testing guidance

A Jules session should not mix unrelated specialist scopes into one PR.
