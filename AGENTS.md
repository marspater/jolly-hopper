# AGENTS.md

## Agent modes

This repository is used by two distinct agent modes:

- **Interactive local** (Antigravity, Claude Code, Codex, or any assistant running in the user's checkout): works in the user's real workspace and must preserve uncommitted work unless the user explicitly authorizes a destructive operation. Read [.agents/rules/jolly-hopper-local.md](.agents/rules/jolly-hopper-local.md) before local work; do not assume the client loads it automatically.
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

Siphon is a native macOS 15+ yt-dlp/FFmpeg downloader written in Swift 6 (strict concurrency) with SwiftUI/AppKit and built with Xcode. `origin/main` is the canonical remote source of truth.

Read before touching the matching area: `ARCHITECTURE.md` (runtime ownership, cancellation, recovery, update exclusion, URL ingress), `DESIGN_LANGUAGE.md` (UI tokens, motion, glass, accessibility), `PRODUCTION_QA.md` (visual QA matrix).

Where things live:

- `Siphon/SiphonApp.swift`: app entry, commands, `siphon://`/`siphon://` URL ingress.
- `Siphon/Models/`: `AppState` (app-level state, `ExternalDownloadTargetPolicy`), `Download.swift` (`Download`, `DownloadOptions`, `MediaInfo`, format ranking, history/validator types).
- `Siphon/Services/Download/`: `DownloadManager` (queue admission, history, recovery) → `DownloadExecutor` (sole owner of active tasks/process controllers) → `YtdlpService` (large facade: binaries, extraction, site-specific handlers, argument building) → `YtdlpProcessRunner` (process launch, output parsing, process-tree termination). Plus `DownloadQueue`, `QueueRecoveryStore`, `DownloadHistoryStore`, `DependencyUpdateCoordinator`.
- `Siphon/Services/{Update,Cookies,System,Windows}/`: app self-update, browser cookie handling, logging/localization/notifications/menu bar, auxiliary windows.
- `Siphon/Helpers/siphon-pgrp.c`: process-group helper compiled by a build phase into `Contents/Helpers/`.
- `Siphon/Extensions/View+Compatibility.swift`: `SiphonTheme`/`SiphonAnimation` design tokens.
- `SiphonTests/`: XCTest suite. `SiphonExtension_{Chrome,Firefox,Safari}/`: browser extensions. `server/`: self-contained Node companion service (keep it isolated; no root `package.json`).

Repository-specific guardrails:

- User-facing strings go through `LanguageService.s("key")`; add keys to its translation table.
- Managed dependency binaries are pinned in `DependencyChecksums` (`YtdlpService.swift`). Bumping yt-dlp means updating version, URL, and SHA-256 together; FFmpeg/FFprobe updates require both archive and executable digests for each supported architecture. Never bypass managed-binary verification. Preserve the explicit user-provided yt-dlp mode, which validates executability/version rather than a pinned checksum; use `resolvedYtdlpBinary` instead of reconstructing binary paths in individual callers.
- Browser extensions must never put cookies or other credentials in deep links, and the Chrome manifest must not request `cookies`/`host_permissions`. External targets must pass `ExternalDownloadTargetPolicy`. CI enforces both.
- External-target validation is only admission control. Preserve the connection-time public-network boundary through subprocesses, site-specific resolvers, WebKit, and redirects; user arguments must not override it. For updater changes, preserve signed-manifest verification and atomic replacement/rollback as described in `ARCHITECTURE.md`.
- Do not add `allow-unsigned-executable-memory` or `disable-library-validation` to `Siphon/Siphon.entitlements` (CI-enforced).
- Release version bumps touch `Siphon/Info.plist`, every `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.pbxproj` (checked by `scripts/verify_bundle.sh`), the `AppState.appVersion` fallback, the `whats_new_message` string, `README.md` badge, and `CHANGELOG.md`. `Casks/siphon.rb` is updated by the release workflow.

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

CI (`.github/workflows/swift.yml`) also runs the same suite with `-configuration Release ENABLE_TESTABILITY=YES`; run it for changes that may behave differently under optimization. For extension, server, or script changes, mirror the relevant checks in `.github/workflows/scripts.yml`: `node --check` on the affected JS, `npm test --prefix server`, `node --test scripts/test_chrome_handoff.js`, `node scripts/test_capture_original_mp4.js`, and `bash -n` on the shell scripts. For version changes, run `bash scripts/verify_bundle.sh`.

Xcode/macOS SDKs are required for native validation. On Linux/headless runners without them, run available scripting checks and report native builds/tests as not run. `swiftc -parse` proves syntax only. Documentation-only changes need link and diff checks, not an app build.

Reuse `NotificationService.isRunningTests` and `SiphonTests/TestEnvironmentIsolation.swift` for test-host behavior. Hosted XCTest temporarily changes real app defaults and recovery state before restoring them: run native suites sequentially, preserve the interrupted-run state backup, and use temporary paths/injected stores for new persistence tests. See the local rules for coordination with a running app. Report focused tests, full suites, skipped tests, live downloads, and visual/accessibility checks separately.

Run relevant build/tests for the change and report validation honestly. Add regression coverage when practical, especially for lifecycle, concurrency, persistence, cancellation, and security fixes. Never weaken tests to make CI green.

## Change discipline

Keep changes focused and minimal. Do not add temporary scripts, debug artifacts, unrelated refactors, generated junk, or unrelated formatting changes. Use the repository's existing conventions.

Before finalizing locally:

```bash
git status --short
git diff --stat
git diff --check
git grep -nE '^(<<<<<<<|=======|>>>>>>>)( |$)'
```

Use concise Conventional Commit messages when committing.

## Freshness rule

Because the repository changes frequently, re-check `origin/main` before major implementation decisions and before final conclusions. If the remote changed, inspect the affected commits and update the plan or conclusions as needed.

## Scope

This file contains only compact repository-wide rules that are safe and useful for both agent modes. Jules-only bootstrap, specialist orchestration, PR workflow, and journals belong in `.jules/AGENTS.md` and `.jules/*.md`. Interactive-local workspace guidance belongs in `.agents/rules/`.
