# Jolly Hopper Local Workspace Rules

This is an **Antigravity / interactive-local** rule. Treat the current workspace as user-owned, non-disposable, and potentially full of uncommitted work.

## Safety

Never run or suggest destructive workspace operations without explicit user authorization for that operation. This includes `git reset --hard`, `git clean -fdx`, branch switches/checkouts that discard changes, force pushes/ref rewrites, bulk deletion, or commands intended to erase/overwrite uncommitted work.

Never infer that the workspace is disposable from `AGENTS.md`, `.jules/`, a previous task, or convenience. Jules-only reset rules do not apply here.

Before editing:

```bash
git status --short --branch
git diff --stat
```

Preserve pre-existing user changes. When local changes conflict with the task, make a non-destructive adjustment or ask before discarding anything.

## Freshness without destruction

Use these first when remote freshness matters:

```bash
git fetch origin main --prune
git rev-parse origin/main
git log origin/main -n 10 --oneline --decorate
```

Do not reset the current branch to `origin/main` just to synchronize. Compare and integrate deliberately while keeping the user's branch and working tree intact.

## Useful local workflow

Inspect the affected Swift/Xcode code, search for existing implementations, and check recent relevant commits before substantial edits. Prefer the smallest targeted change and preserve established architecture and conventions.

For SwiftUI, inspect existing components, materials/glass, typography, spacing, animation, accessibility, state propagation, and lifecycle before introducing new patterns. For concurrency/process code, trace ownership, cancellation, cleanup, and repeated invocation instead of masking races with arbitrary sleeps.

Run focused validation first and the repository's canonical Xcode tests when appropriate. Report exactly what was and was not verified.

Prefer reversible edits, focused diffs, and existing project tooling. Do not leave scratch files, debug output, generated junk, or unrelated refactors.

Before any action that could alter user data, Git history, or the working tree, make the risk explicit. Destructive Jules bootstrap instructions live only in `.jules/AGENTS.md`.