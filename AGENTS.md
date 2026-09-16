# AGENTS.md

## Repository Agent Contract

This repository is a native macOS application written in Swift and built with Xcode.

### Canonical source of truth

`origin/main` is the canonical repository state.

Before starting work:

```bash
git fetch origin main --prune
git rev-parse origin/main
git status --short --branch
```

For disposable agent environments, reset the checkout to the latest `origin/main` before analysis:

```bash
git checkout -B main origin/main
git reset --hard origin/main
git clean -fdx
```

Never base conclusions or changes on stale local state, old task branches, previous agent work, remembered repository state, or stale build artifacts.

### Before changing code

1. Inspect the current repository and relevant files.
2. Check recent commits and relevant existing implementations.
3. Search for existing helpers, services, components, tests, and equivalent fixes before creating new ones.
4. Understand the owning subsystem, callers, state, lifecycle, and concurrency behavior.
5. Keep the change focused and minimal.

Do not duplicate work already present on `origin/main`.

### Engineering standards

Prefer:

- Swift-native and macOS-native APIs
- existing project abstractions and conventions
- Swift structured concurrency
- deterministic state transitions
- explicit ownership and lifecycle management
- cancellation-safe asynchronous code
- actor isolation and thread-safe state access
- existing logging, styling, and component patterns

Be especially careful with `Task`, `TaskGroup`, `Process`, `NotificationCenter`, timers, delegates, closures, `MainActor`, observable state, window/view lifecycle, cancellation, and repeated setup/teardown.

When changing lifecycle-sensitive or asynchronous code, verify success, failure, cancellation, interruption, timeout, shutdown, and repeated-invocation paths as applicable. Do not assume cancellation means the underlying operation has already stopped.

### UI / SwiftUI

Preserve the existing design language and architecture unless the task is explicitly a UI/design change.

Reuse existing view modifiers, compatibility helpers, components, spacing, typography, material/glass treatments, animation patterns, and state-management mechanisms.

Do not solve UI races with arbitrary sleeps or delayed callbacks unless timing is genuinely part of the required behavior.

### Download / process lifecycle

When touching download execution or external process management:

- distinguish requested cancellation from actual termination
- prevent duplicate process ownership
- prevent orphaned processes
- make cleanup idempotent
- release resources on all exit paths
- ensure completion handlers cannot run multiple times
- preserve queue and concurrency-accounting invariants

### Error handling and logging

Do not silently swallow errors without a documented reason.

Use the existing logging infrastructure rather than permanent `print()` debugging.

Never log secrets, credentials, tokens, or sensitive user data.

### Testing and validation

The canonical test command is:

```bash
xcodebuild test \
  -project Siphon.xcodeproj \
  -scheme Siphon \
  -destination 'platform=macOS' \
  -configuration Debug \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

Use the repository's actual tooling and run the relevant build/tests for the change.

Bug fixes should include regression coverage when practical. Test behavior and failure modes, especially for concurrency, lifecycle, persistence, and cancellation changes.

Never weaken tests merely to obtain a green result.

Do not claim validation that was not actually performed.

### Git hygiene

Keep changes focused.

Do not modify unrelated files, add temporary/debug scripts, leave generated junk, or introduce unrelated refactors.

Before finalizing:

```bash
git status --short
git diff --stat
git grep -n '<<<<<<<\\|=======\\|>>>>>>>'
```

Use concise Conventional Commit messages when committing.

### Repository freshness

This repository changes frequently. Before major implementation decisions and before final conclusions, re-check `origin/main` and confirm relevant new commits have not changed the problem.

### Scope

This file contains only repository-wide engineering rules that should apply to any coding agent.

Tool-specific instructions, task orchestration, specialist roles, PR templates, journals, and agent-specific workflows belong in their tool-specific configuration directories and should not be added here.

**Core principle:** work from the latest `origin/main`, understand the existing system, make the smallest correct change, validate it honestly, and keep the repository clean.
