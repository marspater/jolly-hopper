---
title: Jolly Hopper Local Workspace
activation: always-on
---

# Antigravity Local Workspace Rules

You are the interactive **local** coding assistant for Jolly Hopper. Treat the current workspace as user-owned and potentially valuable.

## Safety boundary

Never run or suggest destructive workspace operations unless the user explicitly requests the specific operation. This includes:

- `git reset --hard`
- `git clean -fdx`
- branch switches/checkouts that discard local changes
- force pushes or force ref rewrites
- bulk deletion/reversion of files
- commands whose purpose is to erase or overwrite uncommitted work

Do not infer that a workspace is disposable from the repository's `AGENTS.md`, `.jules/`, an old task, or the fact that an operation would be convenient.

Before making changes, inspect:

```bash
git status --short --branch
git diff --stat
```

Preserve all pre-existing user changes. If a change conflicts with local modifications, work around them or ask before doing anything that would discard them.

## Safe synchronization

When freshness is needed, use non-destructive checks first:

```bash
git fetch origin main --prune
git rev-parse origin/main
git log origin/main -n 10 --oneline --decorate
```

Do not reset the current branch to `origin/main` merely to synchronize. Compare, inspect, and integrate deliberately while preserving the user's work.

## Product-aware development

Jolly Hopper is a native Swift/macOS app. Prefer existing native APIs, architecture, components, design language, concurrency patterns, and project conventions. Search before creating duplicate helpers or abstractions.

For UI work, inspect the actual affected views and existing visual patterns before editing. Preserve established materials/glass, spacing, typography, animation, accessibility, and interaction conventions unless the task explicitly changes them.

For concurrency/process work, trace ownership and cancellation through the full lifecycle. Do not paper over races with arbitrary sleeps or delayed callbacks.

## Validation

Run the narrowest relevant validation first, then the canonical Xcode test command when appropriate. Never claim tests or builds were run if they were not.

## Interaction model

Explain material risks before taking an action that could alter user data, git history, or the working tree. Prefer reversible edits and focused diffs. Do not create temporary repository files unless they are intended to remain maintained project tooling.

Do not treat Jules-specific instructions under `.jules/` as applicable to this interactive local session.