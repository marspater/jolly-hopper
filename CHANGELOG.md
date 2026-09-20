# Changelog

## 5.4.0 - 2026-09-20

Siphon 5.4.0 focuses on download reliability, browser-session security, updater integrity, and clearer runtime ownership.

### Highlights

- **Credential-free browser handoff:** Browser extensions no longer transport raw cookies in custom URLs. Browser source and user-agent context are sanitized, scoped to the validated origin, and prevented from crossing hosts, schemes, or private-network boundaries.
- **Reliable pause and resume:** Each download owns isolated scratch storage so paused partial data can be reused safely. Cancellation retains executor ownership until the underlying task/process actually tears down.
- **Safer update pipeline:** GitHub release assets require trusted digests, staged packages are cleaned up deterministically, rollback paths preserve the installed app, and stale updater callbacks cannot overwrite newer state.
- **Download/update exclusion:** yt-dlp replacement is blocked while downloads are active, and the queue pauses admission during dependency replacement before resuming queued work.
- **Protected-site recovery:** BoyfriendTV, Recu, and GayPornTube flows received stronger browser identity, signed-stream, Cloudflare/session, referer/origin, and CDN-boundary handling. Helium and Chromium-family cookie sources are supported explicitly.
- **macOS UI and accessibility:** Main-window, Settings, Add Download, menu bar, status animation, light/dark contrast, focus, long-content handling, and download-row transitions were refined for the macOS 15 baseline.
- **Architecture hardening:** `DownloadExecutor` exclusively owns active task/process state, release/dependency presentation moved to `AppState`, shutdown semantics are terminal and documented, and browser-extension ingress has an explicit validation boundary.
- **Quality gates:** CodeQL, Sonar, Codacy, scripting checks, and lifecycle/security regression coverage were expanded and stabilized.

### Engineering notes

- The large `YtdlpService` facade remains intentionally intact for this release. Its internal decomposition is postponed to a separate, dedicated refactor.
- Runtime ownership and lifecycle invariants are documented in [ARCHITECTURE.md](ARCHITECTURE.md).
- Visual and interaction rules are documented in [DESIGN_LANGUAGE.md](DESIGN_LANGUAGE.md), with release QA guidance in [PRODUCTION_QA.md](PRODUCTION_QA.md).

## 5.3.0 - 2026-09-17

- Modularized download queue, executor, history, dependency-update, and update services.
- Added secure cookie-file lifecycle and hardened updater staging/rollback.
- Expanded diagnostics redaction, Swift 6 concurrency coverage, and accessibility.
