# Apple-native runtime safety audit: lifecycle, errors, and concurrency

**Baseline:** `main` at `59ef99193720c5f6882be9e9f58187ac03395039` (9 November 2026).  
**Method:** source-level inspection of app lifecycle, download execution, subprocesses, notification handling, update downloader, logs, network monitor, UI-test isolation, and current Xcode CI.  
**Important:** This is an initial risk-based audit, **not** a claim that every Swift file has been dynamically checked. No Instruments allocation trace, Thread Sanitizer run, Address Sanitizer run, macOS build, or live download was performed in this connected-GitHub environment. Those are explicit acceptance gates below.

## Scope and decision rules

- Prefer Swift 6 concurrency checking, `MainActor`, `Mutex` / `NSLock` with complete lock discipline, `os.Logger`, `OSSignposter`, and Xcode's test/diagnostic infrastructure.
- Treat a suspected retain cycle as **unverified** until ownership analysis or Instruments confirms it. Do not call ordinary long-lived singletons memory leaks.
- Never weaken the app update trust root, redirect/egress network boundary, cookie protections, process-group termination, queue recovery durability, or log redaction.
- Do not turn all `try?` into throwing calls: legitimate best-effort cleanup and optional fallbacks should remain best-effort. Differentiate failure of an operation from absence of optional data.
- Every change should have a focused regression test and be measured against Debug/Release Xcode tests.

## Confirmed findings addressed in this first PR

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:078a88769e02f98a8de805b2a1735f9449a8ce54bd41e62c01ce62c02023c7d2 -->

| ID | Severity | Location | Evidence and fix | Validation |
| --- | --- | --- | --- | --- |
| L-01 | P1 | `Siphon/Services/System/LoggerService.swift` | `LoggerService` stored `initialLogLoadTask`; the task's main-actor merge closure strongly captured `self`. A suspended reader could keep its owner alive. Captures the owner weakly and skips a merge after deallocation. | `LoggerLifecycleTests.startupReaderDoesNotKeepLoggerAlive` |
| E-01 | P1 | `Siphon/Services/System/NotificationService.swift` | The osascript fallback called `waitUntilExit()` before reading an unbounded stderr `Pipe`. A child emitting more than the pipe buffer can block forever. It now drains while the process is running, retains at most 16 KiB of diagnostics, and reaps the process on read failure. | `NotificationFallbackPipeTests.drainsLargeStderrWithoutDeadlock` |
| C-01 | P1 | `Siphon/Services/System/NotificationService.swift` | The `@unchecked Sendable` singleton used an ordinary unsynchronized `isSetup` bool. Concurrent setup calls could race and register multiple authorization callbacks. A lock now makes setup admission atomic. | Swift 6 build and focused notification path review; add a concurrently invoked setup test if an injected notification center becomes available |
| E-02 | P1 | `Siphon/Services/System/LoggerService.swift` | Log export swallowed every open/read failure and returned a successful empty export. It now opens the log directly: only a confirmed missing file (`CocoaError.fileReadNoSuchFile`) is empty history, and any other failure (unreadable file, inaccessible parent directory) is thrown. Test exports use the isolated test root instead of the shared temporary directory. | `LoggerLifecycleTests.exportReportsUnreadableExistingLog`, `exportReportsLogInInaccessibleDirectory`, `exportOfMissingLogIsEmptyHistory` |

<!-- /coderabbit-ai-generated:v1 -->

These changes are scoped to diagnostics and notification fallback; they do **not** change download admission, package verification, process-tree termination, or browser credential handling.

## Remaining prioritized audit queue

| ID | Priority | Area | Current evidence / next action | Status |
| --- | --- | --- | --- | --- |
| T-01 | **P0 addressed in this PR** | `Siphon.xcodeproj`, `SiphonTests/TestEnvironmentIsolation.swift` | Native `TestDebug`/`TestRelease` build the hosted app as `com.marspater.siphon.testing`, with a separate `Info-Testing.plist` (no production deep-link scheme); `UserDefaults.standard` is therefore not the installed app's domain. The test observer only verifies isolation and never snapshots or restores real state. Per-run test defaults and temporary recovery/log/dependency directories are injected. | Implemented, awaiting macOS CI and local TCC proof |
| T-02 | P1 | `Siphon/Services/System/UITestLaunchMode.swift` | UI tests replace AppKit autosave method implementations globally in Debug mode to avoid modifying real window geometry. Verify effects with two windows, repeated UI launches, and app-state before/after snapshots. Replace global method interception only if a safer native window-configuration alternative proves equivalent. | Open; behavior is intentional but invasive |
| C-02 | P1 | `Siphon/Services/Download/EgressProxyServer.swift` | Listener startup has a stored `Task`, a `withCheckedThrowingContinuation`, and a 5-second readiness timeout. `stop()` cancels the task before `listener` may be published. Add stress coverage for start/stop at each startup phase, restart after failure, and simultaneous callers; confirm cancellation settles and old listeners cannot publish. No actual leak is established by inspection. | Validation needed |
| C-03 | P1 | `Siphon/Services/Update/UpdateDownloader.swift` | Delegate callbacks and task cancellation exchange continuation ownership under `NSLock`. Existing code intentionally clears continuation exactly once; stress races between cancellation, URL redirects, progress callbacks and staging. Preserve URL trust and checksum verification. | Validation needed |
| L-02 | P2 | `Siphon/Extensions/View+Compatibility.swift` | `AdaptiveRenderingEnvironment` registers four block-based notifications without storing observer tokens. It is a process-lifetime singleton and closures capture `weak self`, so this is **not** evidence of an expanding memory leak. Retain tokens and remove them at teardown if the ownership model changes. | Hygiene |
| E-03 | P1 | `Siphon/Services/System/LoggerService.swift` | The best-effort asynchronous append path still uses `try?` around opening/writing log files and fallback writes. Surface disk/permission failures through `os.Logger` without recursive `LoggerService.log` calls, while preserving secure file permissions and bounded file size. | Open |
| P-01 | P1 | `.github/workflows/swift.yml` | Debug, Release, FFmpeg conversion, `xcresult`, and coverage run on pushes. UI and Performance jobs are workflow-dispatch only. Require at least one successful UI + performance run for the changed revision and periodically repeat them. | Open validation gate |
| P-02 | P1 | `Siphon.xcodeproj` and CI | Xcode scheme supports Analyze, but the workflow does not invoke `xcodebuild analyze`. Add a distinct native analyzer job on macOS, especially for `siphon-pgrp.c`. Keep CodeQL and Codacy: Xcode analysis does not replace them. | Open |
| P-03 | P1 | Runtime verification | A successful Swift 6 build does not demonstrate absence of retain cycles, memory growth, thread-safety defects, or resource leaks. Profile repeated download/pause/resume/cancel, updates, auxiliary windows, thumbnails, and large queue-recovery loads under Instruments and sanitizers. | Not run |
| S-01 | P2 | `Siphon/Services/System/NotificationService.swift` | Notification errors may use osascript fallback when authorization isn't available; explicit user denial is correctly respected. Verify timing, long titles, osascript launch errors, and sandbox/GUI behavior manually; unit test exercises only the pipe helper. | Manual QA needed |

## Controls already in good shape (do not rewrite without evidence)

- **Task / process ownership:** `DownloadExecutor` tracks active tasks and process controllers, explicitly cancels both, and avoids releasing queue slots until teardown. `DownloadProcessController` uses guarded lifecycle transitions and process-group termination. Existing process tests cover multiple cancellation windows.
- **Network state:** `NetworkEnvironmentService` uses `NSLock` around path data and test overrides, has a weak monitor callback, and cancels its `NWPathMonitor` in `deinit`.
- **Update integrity:** `UpdateDownloader` checks trusted GitHub URLs and redirect targets; app-update install/verification is a security boundary. Do not simplify this into generic URLSession download calls.
- **Logging:** Log lines are sanitized before entering public unified logging. Retained diagnostic logs are bounded in memory and written to a separate on-disk file for user export; preserve those guarantees.
- **Swift 6:** Strict concurrency compilation is already configured. `@unchecked Sendable` sites remain a **manual review inventory**, not automatic proof of data races.

## Xcode-native hosted-test isolation (this PR)

- **Production Run / Archive / Profile remain unchanged:** Debug and Release still produce `com.marspater.siphon` with its normal `Info.plist`, security identity and deep-link registration.
- **Test action uses an independent identity:** Xcode's shared `Siphon` scheme defaults to `TestDebug`; `TestRelease` supplies release-optimized hosted tests. Only these configurations use `com.marspater.siphon.testing` and `Siphon/Info-Testing.plist`, which omits `CFBundleURLTypes` so tests do not register as a handler for `siphon://`.
- **No restore transaction around real state:** `SiphonTests/TestEnvironmentIsolation.swift` checks the host bundle identity and recovery path and refuses to run when production state could be involved. It clears only the test app defaults and removes the per-run hosted root after the suite. `UITestLaunchMode.requireSafeTestHostIdentity()` also checks before app managers initialize. Neither path backs up nor changes the real defaults domain.
- **Unique storage from startup:** Hosted tests get their own temporary recovery, diagnostic and managed-binary root; the explicit `TestState` defaults suite is reset at start and again after the run. UI tests continue to use their explicit temporary root.
- **Historical safety:** An old `$TMPDIR/SiphonTestsStateBackup.plist` is never deleted automatically by the new code. It could hold the only recoverable copy from a failed **older** suite; assess it manually before removal. The new suite does not create such backups.
- **Regression coverage:** `HostedTestStorageIsolationTests` checks the runtime app identity, preference domain separation, queue-recovery destination, and log-file destination. The hosted suite is serial; isolated bundle identity does not itself authorize parallel use of test-specific singletons.
- **Not proven here:** CI must build both test configurations, verify these tests execute, and confirm no real `~/Library/Application Support/Siphon` files or Full Disk Access/TCC record are changed on a developer machine. Running Xcode UI previews or a standalone launch continues to use the normal preview/test-mode guards.

## Native verification matrix

| Tool | Target scenario | Pass criteria |
| --- | --- | --- |
| Xcode Debug + Release tests | `-testPlan All`, `-testPlan Conversion` | Zero new failures, correct intentional skips, no modified app state |
| Swift Testing / XCTest | Focused logger and subprocess regression tests | Weak logger deallocates with pending reader; unreadable log export throws; 256 KiB stderr producer exits with bounded capture |
| Thread Sanitizer | Network monitor + update cancellation + proxy start/stop + download event coalescer | No reproducible races; investigate each reported violation |
| Address Sanitizer | C helper integration, process handling, native bridges | No memory-safety failures |
| Instruments: Leaks + Allocations | 30+ open/close windows; repeated queue lifecycle cycles; thumbnail and update flows | Retained-object counts stabilize after cleanup and idle periods; no verified leaks |
| Instruments: Time Profiler / Points of Interest | Metadata fetch, queue admission, FFmpeg conversion, recovery load | No unexpected main-thread stalls; durations can be attributed to named signposts |
| Xcode Analyze | App, core, C helper | No new actionable analyzer findings |
| UI test plan | Launch, Settings, queue state, recovery, pausing | Passes without changing actual user defaults, history, or TCC identity |
| CI artifacts | Debug/Release coverage + result bundles | Result bundles and coverage remain available for the tested SHA |

### Local commands (macOS + Xcode required)

```bash
xcodebuild test -project Siphon.xcodeproj -scheme Siphon -testPlan All \
  -destination 'platform=macOS' -configuration TestDebug \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild test -project Siphon.xcodeproj -scheme Siphon -testPlan All \
  -destination 'platform=macOS' -configuration TestRelease ENABLE_TESTABILITY=YES \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild analyze -project Siphon.xcodeproj -scheme Siphon \
  -destination 'platform=macOS' -configuration Debug
```

Run TSan, ASan, and Instruments in separate diagnostic configurations, not all simultaneously; their overhead and instrumentation can change timing. Do not run hosted tests against a live Siphon instance without following `.agents/rules/jolly-hopper-local.md`.

## Exit criteria for a broader 'Apple-native quality' claim

1. All touched native targets compile under Debug and Release with Swift 6 checks.
2. Error paths have typed results or observable redacted diagnostics; cleanup-only best effort is documented.
3. Unstructured tasks have explicit ownership or are proven short-lived; every long-lived observer, process, and delegate has a teardown path.
4. Cross-actor state has an explicit isolation domain or a **complete** synchronization contract; no speculative actor annotations are applied solely to silence warnings.
5. Cold start, repeated window lifecycle, batch downloads and cancellations show no sustained heap growth under Instruments.
6. Real app defaults, log files, queue snapshots, cookie material, and TCC state survive tests untouched.
7. UI/Performance/Conversion/All test plans are actually executed on the relevant revision; CI artifacts are retained.

This PR delivers four targeted runtime fixes **and** native hosted-test identity isolation, subject to actual macOS CI and local TCC verification. The remaining risk register is a concrete next-pass checklist, not an undocumented promise of no leaks.
