# Jolly Hopper Local Workspace Rules

These rules apply to **all interactive-local agents**, including Antigravity, Claude Code, and Codex. Treat the current workspace as user-owned, non-disposable, and potentially full of uncommitted work.

Read [AGENTS.md](../../AGENTS.md) for repository-wide architecture, security, localization, and validation requirements. This file adds local-workspace guidance; Jules-only rules do not apply here.

## Safety

Never run or suggest destructive workspace operations without explicit user authorization for that operation. This includes `git reset --hard`, `git clean -fdx`, branch switches/checkouts that discard changes, force pushes/ref rewrites, bulk deletion, or commands intended to erase/overwrite uncommitted work.

Never infer that the workspace is disposable from `AGENTS.md`, `.jules/`, a previous task, or convenience. Jules-only reset rules do not apply here.

Before editing:

```bash
git status --short --branch
git diff --stat
git worktree list
```

Preserve pre-existing user changes, including untracked files. Do not stash or stage them as part of unrelated work. When local changes conflict with the task, use a separate worktree or ask before discarding anything. For broad or unrelated work, prefer an isolated worktree on a `mars/` branch; inspect existing worktrees first and do not repurpose another active task's checkout. Stage only the task's files or hunks.

## Freshness without destruction

Use these first when remote freshness matters:

```bash
git fetch origin main --prune
git rev-parse origin/main
git rev-list --left-right --count HEAD...origin/main
git log origin/main -n 10 --oneline --decorate
```

Do not reset the current branch to `origin/main` just to synchronize. Compare and integrate deliberately while keeping the user's branch and working tree intact. Re-fetch before final conclusions involving remote state; if fetching fails, report that freshness is unverified.

## Useful local workflow

Inspect the affected code, search for existing implementations, and check recent relevant commits before substantial edits. Trace callers and the full failing path before fixing a shared function. Prefer the smallest targeted change and preserve established architecture and conventions. Read [ARCHITECTURE.md](../../ARCHITECTURE.md) for runtime changes, and [DESIGN_LANGUAGE.md](../../DESIGN_LANGUAGE.md) plus [PRODUCTION_QA.md](../../PRODUCTION_QA.md) for UI changes.

For SwiftUI, inspect existing components, materials/glass, typography, spacing, animation, accessibility, state propagation, and lifecycle before introducing new patterns. For concurrency/process code, trace ownership, cancellation, cleanup, and repeated invocation instead of masking races with arbitrary sleeps.

## Validation and real app state

Run focused validation first, then the canonical tests in [AGENTS.md](../../AGENTS.md) as appropriate. Mirror the current workflows rather than relying on old test counts or commands: [Swift](../../.github/workflows/swift.yml) and [scripting](../../.github/workflows/scripts.yml). Scripting validation includes behavior tests, not just syntax:

```bash
npm test --prefix server
node --test scripts/test_chrome_handoff.js
node --test scripts/test_build_and_run.js
node scripts/test_capture_original_mp4.js
for script in scripts/*.sh; do bash -n "$script"; done
```

Run the relevant checks for the changed area; documentation-only edits need link and diff checks, not an app build. For version changes, also run `bash scripts/verify_bundle.sh`.

XCTest is hosted in Siphon.app. Reuse `NotificationService.isRunningTests` and the existing `SiphonTests/TestEnvironmentIsolation.swift`; do not invent another test-host detector. The suite temporarily changes the real defaults domain and recovery file, then restores them. Run Debug/Release suites sequentially, including across worktrees, and coordinate with any running Siphon instance before testing. Do not delete `$TMPDIR/SiphonTestsStateBackup.plist`: an interrupted run may need it to restore user state. Use unique temporary paths and injected stores for new persistence tests. Keep test logs outside the production log.

Report focused tests, full suites, skipped opt-in tests, live downloads, and visual/accessibility checks separately. A Swift parse check is syntax-only; a successful build does not prove runtime behavior.

## Build, launch, and installation

Use `bash scripts/build_and_run.sh --build` for the existing signed local Debug build. The default mode and `--verify` terminate running Siphon processes and launch the development bundle; use them only when app interruption fits the requested task. `--verify` checks process presence, so confirm the launched executable path and the requested behavior before claiming runtime success.

Unsigned Xcode test products must never replace the installed app. For an authorized installation, preserve the previous bundle and verify the installed path, version, architecture, and signature. Report launch and functional checks separately from build/install proof. Scope cache cleanup to the task's build directory; do not erase shared Xcode caches or app data by default.

## PR review and evidence

When reviewing or preparing a PR, inspect the current remote head, complete diff, inline analyzer findings, and individual checks. Tie validation to the tested commit and recheck the head before an authorized merge; changed contents require review again. A green analyzer wrapper is insufficient if its logs show incomplete analysis or missing output. Keep private URLs, cookies, tokens, and sensitive media metadata out of public PRs, fixtures, screenshots, and logs; use neutral terms such as “protected site” for public descriptions.

Prefer reversible edits, focused diffs, and existing project tooling. Do not leave scratch files, debug output, generated junk, or unrelated refactors.

Before a destructive operation or replacement of user data, explain the concrete consequences and obtain authorization if the user has not already authorized that operation. Ordinary scoped edits and read-only checks can proceed within the task. Destructive Jules bootstrap instructions live only in `.jules/AGENTS.md`.

Before finishing, run the status, diff, and conflict-marker checks in [AGENTS.md](../../AGENTS.md), plus `git diff --check`. Report the changed files and validation limits; distinguish pre-existing changes from the task's changes.
