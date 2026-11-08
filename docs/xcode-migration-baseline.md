# Xcode migration baseline and decisions

Measured and decided on commit `7c58cce` (8 November 2026), Xcode 27.0 (27A266a), Apple M5 with 10 cores, arm64 only. Another build was running on the machine during part of this (load average about 7), so treat the times as a rough baseline, not a benchmark.

## Baseline measurements (#585)

| Measurement | Wall clock | Notes |
| --- | --- | --- |
| Clean Debug build | 37 s | fresh derived data |
| Clean Release build | 58 s | fresh derived data |
| Hosted suite, Debug | 136 s | 87.0 s inside XCTest, the rest is the build and app launch |
| Hosted suite, Release with `ENABLE_TESTABILITY=YES` | 174 s | 92.3 s inside XCTest |

Both suites executed 827 tests with 6 skipped and 0 failures. The audit's figure of 830 came from counting `func test` in the source, which also matches helpers.

Clean builds:

```bash
for configuration in Debug Release; do
  started=$(date +%s)
  xcodebuild build -project Siphon.xcodeproj -scheme Siphon \
    -destination 'platform=macOS,arch=arm64' -configuration "$configuration" \
    -derivedDataPath "$(mktemp -d)" MACOSX_DEPLOYMENT_TARGET=15.0 \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  echo "$configuration: $(( $(date +%s) - started )) s"
done
```

Hosted suites used the same arguments with `xcodebuild test`, once as above in Debug and once with `-configuration Release ENABLE_TESTABILITY=YES`. I timed each suite the same way, with `date +%s` before and after the run.

Tests per class (Debug run, seconds inside XCTest):

| Class | Tests | Seconds |
| --- | ---: | ---: |
| YtdlpServiceTests | 292 | 60.3 |
| QueueAndErrorUXTests | 105 | 3.1 |
| DownloadManagerTests | 58 | 0.8 |
| MediaInfoTests | 43 | 0.03 |
| UpdateVerifierTests | 40 | 1.2 |
| ProcessLifecycleTests | 33 | 2.5 |
| QueueRecoveryStoreTests | 32 | 6.9 |
| EgressProxyTests | 29 | 1.5 |
| DownloadExecutorTests | 28 | 1.1 |
| DownloadTests | 26 | 0.05 |
| LogSanitizationTests | 18 | 0.1 |
| SecureCookieFileTests | 14 | 0.07 |
| DownloadHistoryStoreTests | 13 | 2.8 |
| DownloadQueueTests | 13 | 2.5 |
| AddDownloadWindowSizingTests | 12 | 1.8 |
| AdversarialAndPropertyTests | 11 | 0.01 |
| NotificationServiceTests | 11 | 0.01 |
| DependencyUpdateCoordinatorTests | 8 | 0.2 |
| ImageUtilitiesTests | 7 | 0.01 |
| ReleaseNotesServiceTests | 7 | 1.9 |
| CustomPresetTests | 6 | 0.01 |
| SiphonFontCoverageTests | 6 | 0.4 |
| GeistFontRegistrarTests | 5 | 0.01 |
| BrowserUtilsTests | 4 | 0.02 |
| DownloadEventCoalescerStressTests | 4 | 0.08 |
| UserDefaultsKeysTests | 2 | 0.00 |

Skips in this run:

| Test | Gate |
| --- | --- |
| `testCodecConversionsProduceRequestedCodecWithRealFFmpeg` | `SIPHON_CONVERSION_FFMPEG_DIR` |
| `testHDRToSDRToneMappingKeepsBrightnessWithRealFFmpeg` | `SIPHON_CONVERSION_FFMPEG_DIR` |
| `testManagedFFmpegVerifiesHTTPSWithSanitizedEnvironment` | `SIPHON_CONVERSION_FFMPEG_DIR` |
| `testRealHLSDownloadsClearAndAES128` | `SIPHON_HLS_SMOKE_BASE_URL`, `SIPHON_HLS_YTDLP`, `SIPHON_HLS_FFMPEG_DIR` |
| `testUserYtdlpMustIdentifyAsYtdlpBeforeItIsCommitted` | `DependencyChecksums.managedYtdlpEnabled` |
| `testVerifyAppBundleRejectsDamagedSignature` | unsigned test host |

`ProcessLifecycleTests` skips one test without `siphon-pgrp` (`Needs siphon-pgrp to own a process group`). It did not skip here because the build phase produced the helper. A few other tests skip conditionally on perl, codesign, Reduce Motion, network, a JS runtime or missing sources.

## Static analysis (#587)

| Tool | What it checks today | Xcode overlap | Decision |
| --- | --- | --- | --- |
| Compiler, Swift 6 strict concurrency | Types, isolation, data races | Native | Keep. `-warnings-as-errors` is not on and one deprecation warning exists; I would not turn it on in this migration. |
| Xcode static analyzer | Nothing in CI today | Native, strongest on the C helper | Not added here. Worth adding once #617 makes `siphon-pgrp` a real target. |
| CodeQL (Swift, JS) | `security-extended` and `security-and-quality` | Taint and security queries have no Xcode equivalent | Keep. |
| Codacy CI scan (opengrep, cppcheck, flawfinder) | Source security in Swift, JS and the C helper, published as SARIF | None | Keep. |
| Codacy GitHub app | Lint findings on PRs, including SwiftLint with Codacy's own rule set and Lizard complexity checks; it ignores `.swiftlint.yml` and the `.codacy.yml` engine switches, and honours `exclude_paths` | Partly overlaps compiler warnings | Keep. |
| SonarCloud automatic analysis | Maintainability and security hotspots | Partly overlaps | Keep, and **no coverage path**: automatic analysis does not import coverage reports. Coverage in SonarCloud would need a move to CI-based analysis plus a conversion from `xccov` JSON to Sonar's generic format, which I do not think is worth it now. The planned replacement is #616, which adds coverage as a CI artifact; until it lands, no coverage artifact exists. |
| SwiftLint | Runs on every PR through Codacy with Codacy's rule set; nothing reads `.swiftlint.yml` | Style only | Retire `.swiftlint.yml` (#623). |
| `node --check`, `npm test`, script tests | Extensions, server and scripts | None. This must stay outside Xcode. | Keep. |

## Second SiphonCore slice (#592)

Constraint for any move: the signed-manifest verification and the atomic replacement and rollback contract in `ARCHITECTURE.md` ("App update trust" and "App update installation") must keep working unchanged. Releases newer than `UpdateChecker.lastUnsignedRelease` (5.4.5) stay refused without a valid Ed25519-signed manifest checked against the pinned key, releases at or before it keep their documented unsigned exception, and replacement and rollback stay single `renameatx_np(RENAME_SWAP)` exchanges with no delete-and-copy fallback. A module boundary must not widen access to the pinned key or to the verification entry points.

| Type | Blockers | Decision |
| --- | --- | --- |
| `UpdateVerifier` (with `UpdateManifestVerifier`) | No AppKit or WebKit, no `isRunningTests`. Uses Security and CryptoKit, and `LoggerService.shared` once. Security boundary owner. | Keep. The 40 tests take about 1.2 s, so moving saves almost nothing and adds risk at the trust root. |
| `SecureCookieFile` | Foundation only, plus one `LoggerService.shared` call. Handles cookie file permissions. | Keep for now. This is the only clean candidate, but its 14 tests take 0.07 s. Revisit if `LoggerService` ever lands in SiphonCore. |
| `EgressProxyServer` | `static let shared`, `NWListener`, `LoggerService.shared` in three places, 964 lines. Owns the connection-time public-network boundary. | Keep. Splitting the listener out would cut through the security boundary. |

Nothing is marked move, so no follow-up issues are needed.

## MetricKit and file logs (#614)

| Item | Finding | Decision |
| --- | --- | --- |
| `MXMetricManager` | Delivers delayed, aggregated payloads to the app itself. Organizer dashboards assume App Store distribution, which Siphon does not use, so I would have to build the collection and viewing myself. | Do not adopt. |
| Crash reports | macOS already writes them to `~/Library/Logs/DiagnosticReports`, and users can attach those. | Keep relying on them. |
| `LoggerService` file buffer | The debug window and export read it. It is sanitized and persists across launches. `OSLogStore` in process scope only sees the current process, and wider scopes need extra privileges, so history from earlier runs would be lost. | Keep. |
| `os.Logger` | #611 adds it inside `LoggerService.log`, after sanitization. | Keep as a second output, not a replacement. |

No item is retired, so no follow-up issues are needed.

## String Catalogs (#621)

**Not now.** `LanguageService` has one language and about 430 keys, with roughly 620 call sites. A shim that reads an `.xcstrings` catalogue behind `s(_:)` would avoid touching the call sites, but with one language it changes nothing a user can see, and the `selectedLanguage` setting and its observers would need rework.

Trigger to revisit: a second language is actually planned.

## File-system synchronized groups (#622)

I tried the conversion on a throwaway export of `7c58cce`, not on a branch.

| Question | Result |
| --- | --- |
| New `objectVersion` | 77 (from 56). Needs Xcode 16 or later. |
| Local build | Debug build succeeded on Xcode 27 with 62 Swift compile steps. The bundle has the same resources as today, plus `Contents/Helpers/siphon-pgrp`. |
| CI `xcodebuild` | Not tested. `macos-latest` runners and the CodeQL job should accept it if their Xcode is 16 or later. |
| Exceptions needed | `Helpers/siphon-pgrp.c`, `Info.plist` and `Siphon.entitlements`. Without the first, the helper would compile into the app. `Resources` needed none. |
| Diff | `project.pbxproj` shrinks from 948 to 516 lines. It is almost all deletions, so it is reviewable. |
| Hosted suite | Not run. |

**Defer.** It works, but the SiphonCore and helper-target work is rewriting file membership in the same project right now. Converting underneath that would conflict with all of it.

Trigger to revisit: after the Phase B and Phase G project changes have merged. Convert in its own PR and run the full hosted suite then. A build with a broken group still reports `BUILD SUCCEEDED` with an empty app, as my first attempt did, so check the compile count and bundle contents.

## Stable designated requirement phase (#619)

**The phase stays.**

- `CODE_SIGNING_ALLOWED=NO`, used by the canonical test command and CI, turns off Xcode's signing step entirely. `OTHER_CODE_SIGN_FLAGS` and `CODE_SIGN_IDENTITY` in the project are therefore ignored for those builds, and no build setting can apply a designated requirement to them.
- The native route would be to sign test builds ad hoc, which means changing the canonical command and CI. The phase's own comment records that signing inside the bundle breaks once the test bundle is copied in, which is why it signs a detached copy.
- The phase works today: a build with `CODE_SIGNING_ALLOWED=NO` has `designated => identifier "com.marspater.siphon"`.
- The required proof is not available from an agent shell. Reading `/Library/Application Support/com.apple.TCC/TCC.db` fails with `authorization denied`, so I could not check `csreq` after a hosted run.

Trigger to revisit: someone runs the hosted suite on a build using native ad hoc signing, launches the installed app, and then runs the query from #619 in a terminal with Full Disk Access, and the record stays identifier-bound.

## SwiftLint (#623)

**Retired.** I removed `.swiftlint.yml` because nothing reads it. No workflow runs SwiftLint directly, and Codacy runs it on every PR with its own rule set: with the file present, Codacy still flagged rules the file disables. For the same reason the `.codacy.yml` engine switch does not stop SwiftLint.

Trigger to revisit: moving lint out of Codacy into a pinned CI step.
