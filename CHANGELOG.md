# Changelog

## Unreleased

### Changes

- Siphon again downloads a pinned, SHA-256-verified yt-dlp: the Siphon fork 2026.10.06.1, which keeps its DRM-format and byte-range download fixes. The user-provided yt-dlp path in Settings is no longer used.

### Security

- Browser-link downloads accept only global unicast IPv6 destinations and reject IPv4-compatible addresses.
- `codesign` checks pass the binary path after `--`, so a path starting with `-` cannot be read as an option.
- Temporary cookie files live in a per-process session folder, and a Keychain or decryption failure in one Chromium browser is no longer hidden by another browser with no match.

### Fixes

- Recent on Home stays newest-first when the queue is reordered.
- Output reservations cover every video container for a file name, and overwrite only exempts the original name.
- No AppleScript notification fallback after notifications were denied.
- The egress proxy restarts a listener that died after startup, and process-tree cleanup never signals an already-reaped process.
- Faster download history loading, and clearer VoiceOver state for disclosure buttons in Add Download.

## 5.5.0 - 2026-09-28

Siphon 5.5.0 adds a public-network boundary for browser links, requires signed release manifests, and makes the main window calmer and more predictable.

### Highlights

- **Calmer main window:** The status strip shows Downloading, Completed, and Failed, and only Downloading animates, as a fill that tracks overall progress (paused with Reduce Motion). Finished rows and cards no longer glow.
- **Unified color and surfaces:** Theme colors are rebuilt on one Display P3 palette with ~5:1 text contrast in Light and Dark, and every window shares the same background treatment.
- **Predictable download lists:** The list keeps downloads in arrival order, Recent shows the newest first, and each list has a title and count header.
- **Queue reordering:** Move Up and Move Down follow the rows visible in the Queue tab instead of hidden positions in the full list.
- **New app icon:** A layered Icon Composer icon with default, dark, and mono variants replaces the legacy PNG set.
- **More sites:** PussySpace and StarWank support.

### UI polish

- Copy and Paste confirmations stay up for their full duration when clicked repeatedly.
- Clear History asks for confirmation, with a singular title for one item.
- The Home card says "Press ⏎ to download" instead of repeating the page subtitle, and row More menus use a neutral tint so Play is the only accent.
- The sidebar toggle no longer flashes into the toolbar overflow menu at narrow widths.
- Download preset rows read as one element in VoiceOver, and recent-download rows use the shared radius, badge, and button styles.

### Security

- **Egress boundary for browser links:** Downloads started from a browser extension, including their metadata preview and site-specific resolvers, run through a local proxy that refuses private, loopback, link-local, and reserved destinations at connection time and on every redirect.
- **Signed release manifests:** Releases after 5.4.5 must ship an Ed25519-signed `release-manifest.json`; the updater refuses a release without one instead of trusting the checksum alone.
- Exported debug logs redact API key and token headers.
- Tighter file-collision checks, protected output arguments (`-o`/`-P` and, for browser links, `--proxy` are ignored in extra arguments), hardened updater redirects, and bounded thumbnail and page fetches.

### Fixes

- Playlist jobs keep the entries that finished when others fail.
- Safari cookies without Full Disk Access are skipped for the rest of the session after the first denial instead of costing a failed attempt per site.
- Dropping a `.txt` list of URLs on the Home screen starts its downloads instead of reporting an invalid URL.
- Stop All stays responsive, quitting no longer leaves orphaned scratch data, and the log keeps its final lines.
- Protected-site recovery for BoyfriendTV (visible WebKit challenge), Recu, and Eporner.
- Missing completed files show "File moved or deleted", HTTP errors from dependency and update downloads are reported as such, and a full disk no longer crashes the logger.
- Many smaller fixes to format ranking, window reopening, menu bar presets, error messages, and missing translations.

### Maintenance

- CI runs the Swift tests once per push (Debug and Release), scans every `main` commit with CodeQL and Codacy, and validates release tags in the Homebrew workflow.
- The companion service binds to all interfaces on Render and to loopback elsewhere.

## 5.4.5 - 2026-09-20

Siphon 5.4.5 focuses on durable queue recovery, download reliability, browser-session security, updater integrity, and clearer runtime ownership.

### Highlights

- **Durable queue recovery:** Interrupted queued and running downloads are atomically persisted across state changes to disk. If the app closes unexpectedly, Siphon detects the interrupted session on launch and offers one-click queue recovery with preserved scratch data.
- **Credential-free browser handoff:** Browser extensions no longer transport raw cookies in custom URLs. Browser source and user-agent context are sanitized, scoped to the validated origin, and prevented from crossing hosts, schemes, or private-network boundaries.
- **Reliable pause and resume:** Each download owns isolated scratch storage so paused partial data can be reused safely. Cancellation retains executor ownership until the underlying task/process actually tears down.
- **Safer update pipeline:** GitHub release assets require trusted digests, staged packages are cleaned up deterministically, rollback paths preserve the installed app, and stale updater callbacks cannot overwrite newer state.
- **Download/update exclusion:** yt-dlp replacement is blocked while downloads are active, and the queue pauses admission during dependency replacement before resuming queued work.
- **Protected-site recovery:** Browser-sensitive extraction flows received stronger identity, signed-stream, anti-bot/session, referer/origin, and CDN-boundary handling. Safari and Chromium-family cookie sources are supported directly.
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
