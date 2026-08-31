# AGENTS.md

## Jolly Hopper Agent Instructions

This repository is a rapidly evolving native macOS application written in Swift and built with Xcode.

The repository is actively developed with frequent commits, rebases, merges, and pull requests. **`origin/main` is the canonical source of truth.** Local checkout state may be stale and must never be trusted without verification.

The application project is:

* Xcode project: `Siphon.xcodeproj`
* Scheme: `Siphon`
* Platform: macOS
* Minimum deployment target: macOS 14.0
* Primary language: Swift

---

## 1. Mandatory Repository Synchronization

### 1.1 Always synchronize before doing anything

Before analyzing code, planning a change, searching for a bug, editing files, or making architectural recommendations:

```bash
git fetch origin main --prune
```

Then verify the remote state:

```bash
git rev-parse origin/main
git log origin/main -n 25 --oneline --decorate
```

### 1.2 `origin/main` is the source of truth

Never assume the current checkout represents the latest repository state.

The agent must treat:

```text
origin/main
```

as authoritative.

A task must be evaluated against the **current latest `origin/main`**, not against:

* an older local `main`
* an old task branch
* previously generated agent changes
* stale build artifacts
* remembered state from an earlier session
* an outdated pull request
* an earlier analysis performed before new commits landed

### 1.3 Fresh-session requirement

When starting a new task, the working tree must be based on the latest `origin/main`.

The preferred bootstrap procedure is:

```bash
git fetch origin main --prune
git checkout -B main origin/main
git reset --hard origin/main
git clean -fdx
```

This intentionally discards stale local task state and untracked build/generated files.

**Do not preserve old agent work merely because it exists locally.**

If the execution environment already provides a fresh clone of the repository, still fetch `origin/main` and verify that `HEAD` matches the latest remote commit.

### 1.4 Verify the starting commit

Immediately before beginning work:

```bash
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

For a fresh task, `HEAD` should correspond to the latest `origin/main`.

Record the starting commit mentally as the baseline for the task.

### 1.5 Never silently continue from stale state

If `HEAD` is behind `origin/main`, do not begin analysis until the repository has been synchronized.

If the repository contains local modifications that cannot safely be discarded, stop and report that condition rather than silently building on top of stale state.

---

## 2. Re-Check Remote State Before Important Decisions

Because this repository changes frequently, synchronization is not only a startup requirement.

Before making a substantial implementation decision, especially after a long investigation, re-check:

```bash
git fetch origin main --prune
git rev-parse origin/main
```

If `origin/main` changed during the task:

1. inspect the new commits
2. determine whether they affect the task
3. update your analysis before continuing

Do not continue implementing against assumptions that were made from an earlier revision.

---

## 3. Avoid Redundant Work

Before implementing any bug fix, feature, refactor, optimization, or architectural change:

### 3.1 Search the current repository

Use repository search aggressively:

```bash
git grep "<symbol-or-term>"
```

Also inspect relevant Swift files, Xcode project configuration, tests, and recent commits.

Do not create a new helper, manager, service, type, extension, or utility until you have verified that an equivalent implementation does not already exist.

### 3.2 Check recent commits

Inspect recent history:

```bash
git log origin/main -n 25 --oneline --decorate
```

Use commit inspection when necessary:

```bash
git show <commit>
git diff <commit>^ <commit>
```

### 3.3 Check merged pull requests

When a task resembles a bug, feature, refactor, or audit item that may already have been addressed, inspect recent merged PRs and their changes before writing new code.

A requested fix may already exist under a different implementation or may have been partially addressed.

### 3.4 Do not duplicate completed work

If the requested change already exists in the current `origin/main`:

* do not re-implement it
* do not rewrite equivalent logic
* do not create a second implementation
* report the relevant commit or existing implementation

If the existing implementation is incomplete, identify exactly what remains rather than replacing the entire solution.

---

## 4. Understand the Existing Architecture Before Editing

Jolly Hopper is a native Swift/macOS application. Prefer existing platform-native APIs and project conventions over introducing additional frameworks or abstractions.

Before modifying a subsystem:

1. identify its owning type/service
2. trace its callers
3. inspect related models and state
4. inspect relevant tests
5. inspect recent changes to the subsystem
6. understand lifecycle and concurrency behavior

Do not fix isolated symptoms when the underlying state-management or lifecycle design is responsible.

Avoid broad architectural changes unless the task explicitly requires them or the existing design cannot safely support the requested behavior.

---

## 5. Swift and macOS Engineering Standards

Prefer:

* Swift-native APIs
* Swift concurrency where appropriate
* structured concurrency over unmanaged asynchronous work
* existing project abstractions
* deterministic state transitions
* explicit ownership and lifecycle management
* cancellation-safe asynchronous code
* thread-safe state access
* proper actor isolation
* existing macOS APIs rather than unnecessary third-party dependencies

Be particularly careful with:

* `Task`
* `TaskGroup`
* `Process`
* `NotificationCenter`
* timers
* delegates
* closures
* async callbacks
* `MainActor`
* observable state
* window/view lifecycle
* repeated event handlers
* retained closures
* cancellation
* resource cleanup

When changing asynchronous or lifecycle-sensitive code, verify that work is cancelled, released, and cleaned up on **all** relevant paths, including:

* success
* failure
* cancellation
* user interruption
* timeout
* application shutdown
* repeated invocation

Do not assume that cancellation automatically means an underlying process or resource has already stopped.

---

## 6. UI and SwiftUI Standards

Preserve the existing visual language and architecture unless the task specifically concerns design changes.

Prefer existing:

* view modifiers
* compatibility helpers
* shared components
* spacing conventions
* typography
* material/glass implementations
* animation patterns
* state-management mechanisms

Do not introduce one-off UI implementations when an existing abstraction already handles the same behavior.

Avoid unnecessary view identity changes, state duplication, or animation changes that may introduce transient rendering artifacts.

When fixing UI bugs, investigate:

* view lifecycle
* state propagation
* animation transactions
* conditional view insertion/removal
* transition timing
* asynchronous state updates
* window lifecycle
* stale bindings

before adding delays or arbitrary sleeps.

**Do not use `Task.sleep`, `DispatchQueue.asyncAfter`, or similar timing hacks as the default solution to a UI race.** Use them only when timing is genuinely part of the required behavior.

---

## 7. Download / Process Lifecycle

Jolly Hopper interacts with external media-processing/download processes.

When modifying download execution or process management:

* distinguish requested cancellation from actual process termination
* do not release concurrency slots before the underlying operation has actually stopped
* prevent duplicate process ownership
* prevent orphaned processes
* make cleanup idempotent
* ensure failure paths release resources
* ensure cancellation paths release resources
* ensure completion handlers cannot run multiple times
* preserve queue/accounting invariants

Any change to `DownloadManager`, process runners, task tracking, or cancellation behavior should include regression coverage for lifecycle edge cases.

---

## 8. Memory and Resource Management

Treat memory leaks, retained closures, abandoned tasks, orphaned processes, observers, timers, and duplicated subscriptions as bugs.

When reviewing code that owns long-lived resources, verify:

* ownership
* release conditions
* cancellation
* observer removal
* timer invalidation
* task cancellation
* process termination
* closure capture
* delegate lifetime
* repeated setup/teardown

Do not declare something a memory leak solely because an object remains alive temporarily. Establish an actual ownership cycle or unbounded retention path.

---

## 9. Testing

The repository uses Xcode-based testing.

The canonical validation command is:

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

Release validation may also be run with:

```bash
xcodebuild test \
  -project Siphon.xcodeproj \
  -scheme Siphon \
  -destination 'platform=macOS' \
  -configuration Release \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  ENABLE_TESTABILITY=YES \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

The repository's CI already uses `xcodebuild test` against the `Siphon` scheme on macOS. Match that environment when validating changes.

### Testing requirements

Every bug fix should include appropriate regression coverage when practical.

Tests should target behavior and failure modes rather than implementation details.

For concurrency or lifecycle bugs, test:

* normal execution
* repeated execution
* cancellation
* failure
* interruption
* cleanup
* race-sensitive paths
* state consistency after completion

For UI bugs, test the underlying state/lifecycle behavior whenever full UI automation is impractical.

### Do not weaken tests

Never:

* remove failing tests merely to make CI green
* disable assertions
* add meaningless sleeps
* hide failures
* loosen validation without justification
* mock away the behavior being tested

If an existing test is incorrect, explain why and replace it with a stronger test.

---

## 10. Build Validation

Before finalizing a code change:

1. compile the project
2. run the relevant test suite
3. inspect warnings/errors introduced by the change
4. verify that unrelated functionality was not broken

At minimum, use the repository's Xcode build/test workflow.

Do not claim that a change is verified unless the relevant validation was actually run.

If the environment prevents a test from being executed, state that explicitly.

---

## 11. No Ad-Hoc Repository Pollution

Do not commit temporary scripts, scratch files, generated audit artifacts, or debugging utilities.

Do not add files such as:

```text
check_*
find_*
fix_*
debug_*
print_*
audit_*
test_a11y*
scratch_*
tmp_*
```

unless they are explicitly intended to become maintained project tooling.

Temporary investigation scripts must not remain in the repository after the task.

Tests that provide lasting value should be integrated into the existing Xcode test structure.

---

## 12. Keep Changes Focused

Prefer the smallest correct change.

Do not:

* reformat unrelated files
* rename unrelated symbols
* reorganize folders without need
* refactor surrounding code merely because it could be prettier
* rewrite working implementations unnecessarily
* introduce abstractions without a concrete need

A bug fix should fix the bug.

A feature should implement the feature.

A refactor should have a clearly defined purpose.

Do not combine unrelated cleanup with the requested change unless required for correctness.

---

## 13. Preserve Existing Behavior

Unless the task explicitly requires a behavior change:

* preserve public behavior
* preserve user preferences
* preserve persistence formats
* preserve existing download semantics
* preserve supported sites
* preserve existing UI behavior
* preserve accessibility behavior
* preserve localization behavior
* preserve compatibility with supported macOS versions

When changing behavior, identify the affected paths and validate them explicitly.

---

## 14. Error Handling

Do not silently swallow errors.

Avoid empty:

```swift
catch { }
```

blocks unless there is a documented reason.

Errors should be:

* propagated
* handled
* logged appropriately
* converted into user-visible state where appropriate

Do not expose sensitive information in logs or user-facing errors.

---

## 15. Logging and Diagnostics

Use the application's existing logging infrastructure.

Do not add permanent `print()` debugging statements when an appropriate logger already exists.

Temporary debugging output must be removed before finalizing the task.

Do not log:

* secrets
* credentials
* tokens
* sensitive user data
* unnecessary URLs containing sensitive query parameters

---

## 16. Git Hygiene

Keep the repository clean.

Before finalizing:

```bash
git status --short
```

Do not leave behind:

* merge conflict markers
* temporary files
* generated junk
* debugging output
* unrelated modifications
* untracked scratch files

Check for conflict markers where appropriate:

```bash
git grep -n '<<<<<<<\|=======\|>>>>>>>'
```

### Commit messages

Use concise Conventional Commit messages:

```text
feat: ...
fix: ...
refactor: ...
test: ...
perf: ...
docs: ...
chore: ...
```

The commit message should describe the actual change, not the entire investigation.

---

## 17. Pull Request Awareness

Before implementing a change that appears related to an existing PR:

* inspect the PR
* inspect the changed files
* inspect the resulting implementation on `origin/main`
* determine whether the issue is already resolved

Do not duplicate fixes from merged PRs.

If a related PR exists but is not merged, do not assume its implementation exists in `origin/main`.

The current `origin/main` state always takes precedence.

---

## 18. Working Tree Discipline

During work, avoid modifying unrelated files.

At meaningful checkpoints, inspect:

```bash
git status --short
git diff --stat
git diff
```

Before finalizing, ensure the diff contains only intentional changes.

Never silently reset, revert, or delete the user's work if the environment is not explicitly designated as a disposable fresh Jules checkout.

For disposable Jules environments, the bootstrap process may intentionally reset the repository to `origin/main` before starting the task.

---

## 19. Stale Information and Long-Running Tasks

This repository changes frequently enough that information can become stale during a single task.

For long investigations:

1. refresh `origin/main`
2. verify whether new commits appeared
3. inspect any relevant changes
4. update conclusions if necessary

Do not spend significant time solving a problem against code that has already changed.

Before delivering a final conclusion, verify the repository state again.

---

## 20. Final Verification Checklist

Before declaring a task complete:

### Repository

* [ ] Started from the latest `origin/main`
* [ ] Checked recent commits
* [ ] Checked relevant merged PRs
* [ ] Confirmed no existing implementation already solves the task
* [ ] No unrelated files changed

### Implementation

* [ ] Change is minimal and targeted
* [ ] Existing architecture/conventions are respected
* [ ] Cancellation and cleanup paths are correct
* [ ] No unnecessary timing hacks were introduced
* [ ] No unnecessary dependencies were added

### Testing

* [ ] Relevant tests were added or updated
* [ ] `xcodebuild test` was run
* [ ] Failures were investigated rather than suppressed
* [ ] Build/test results are honestly reported

### Hygiene

* [ ] No temporary scripts remain
* [ ] No debug logging remains
* [ ] No conflict markers remain
* [ ] Working tree contains only intentional changes

---

## 21. Core Principle

**Never trust stale state. Never duplicate existing work. Never make a change without understanding its lifecycle.**

For every task:

```text
latest origin/main
        ↓
verify repository state
        ↓
inspect recent changes / existing solutions
        ↓
understand architecture
        ↓
make the smallest correct change
        ↓
test
        ↓
re-check against latest main
        ↓
finalize cleanly
```

The agent should optimize for **correctness, freshness, minimal diffs, and maintainability**, not for producing the largest possible patch.

