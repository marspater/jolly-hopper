# AGENTS.md

## Agent modes

This repository is used by two distinct agent modes:

- **Antigravity:** interactive local development assistant. It works in the user's real workspace and must preserve uncommitted work unless the user explicitly authorizes a destructive operation.
- **Jules:** autonomous, headless, disposable batch runner. Its environment may be reset between tasks under `.jules/AGENTS.md`.

These modes must not be treated as interchangeable.

## Local-workspace safety

**Never run or recommend destructive working-tree commands in an interactive/local workspace unless the user explicitly requested that exact destructive action.** This includes `git reset --hard`, `git clean -fdx`, `git checkout`/`switch` that discards local changes, force branch rewrites, and mass file deletion.

Before editing locally:

```bash
git status --short --branch
git diff --stat
```

Preserve existing uncommitted changes. Do not overwrite, revert, stash, reset, clean, or delete them merely to reach `origin/main`. When synchronization is needed, fetch and inspect first; preserve the user's branch and working tree unless they explicitly instruct otherwise.

A clean or disposable environment must **not** be inferred from the presence of this file. Jules destructive bootstrap rules apply only to the explicitly identified Jules environment and are defined under `.jules/AGENTS.md`.

## Repository baseline

This is a native macOS application written in Swift and built with Xcode. `origin/main` is the canonical remote source of truth.

For non-destructive freshness checks:

```bash
git fetch origin main --prune
git rev-parse origin/main
```

Inspect recent commits and search the current code before implementing substantial changes. Do not duplicate work already present on the current branch or `origin/main`.

## Engineering rules

Prefer Swift-native/macOS-native APIs, existing project abstractions, structured concurrency, explicit ownership, deterministic state, cancellation-safe async work, correct actor isolation, and thread-safe shared state.

Treat `Task`, `TaskGroup`, `Process`, `NotificationCenter`, timers, delegates, closures, `MainActor`, observable state, window/view lifecycle, cancellation, repeated setup/teardown, and external process ownership as lifecycle-sensitive.

For download/process code, distinguish requested cancellation from actual termination, prevent duplicate ownership and orphaned processes, make cleanup idempotent, and preserve concurrency/accounting invariants.

Reuse existing UI components, modifiers, typography, materials/glass treatments, spacing, animation, and state-management patterns. Do not use arbitrary sleeps or delayed callbacks as a default fix for UI races.

Do not silently swallow errors. Use the existing logging infrastructure and never log credentials, tokens, secrets, or sensitive user data.

## Validation

The canonical test command is:

```bash
xcodebuild test \
  -project Siphon.xcodeproj \
  -scheme Siphon \
  -destination 'platform=macOS' \
  -configuration Debug \
  MACOSX_DEPLOYMENT_TARGET=15.0 \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

Run relevant build/tests for the change and report validation honestly. Add regression coverage when practical, especially for lifecycle, concurrency, persistence, cancellation, and security fixes. Never weaken tests to make CI green.

## Change discipline

Keep changes focused and minimal. Do not add temporary scripts, debug artifacts, unrelated refactors, generated junk, or unrelated formatting changes. Use the repository's existing conventions.

Before finalizing locally:

```bash
git status --short
git diff --stat
git grep -n '<<<<<<<\\|=======\\|>>>>>>>'
```

Use concise Conventional Commit messages when committing.

## Freshness rule

Because the repository changes frequently, re-check `origin/main` before major implementation decisions and before final conclusions. If the remote changed, inspect the affected commits and update the plan or conclusions as needed.

## Scope

This file contains only compact repository-wide rules that are safe and useful for both agent modes. Jules-only bootstrap, specialist orchestration, PR workflow, and journals belong in `.jules/AGENTS.md` and `.jules/*.md`. Antigravity-specific workspace guidance belongs in `.agents/rules/`.