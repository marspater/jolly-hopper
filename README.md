# Siphon ⚡️

A high-performance, native macOS media extractor & downloader powered by `yt-dlp` and `FFmpeg`. Engineered with advanced anti-bot bypass mechanisms for Cloudflare, YouTube, and 1,000+ protected video streaming sites.

<div align="center">
  <img src="assets/app_screenshot.png?v=4" alt="Siphon main window" width="880" style="border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.3);" />
  <p>
    <a href="https://github.com/marspater/jolly-hopper/releases/latest"><img src="https://img.shields.io/badge/Version-v5.5.0-indigo?style=for-the-badge&logo=swift&logoColor=white" alt="Version 5.5.0" /></a>
    <a href="https://github.com/marspater/jolly-hopper/releases/latest"><img src="https://img.shields.io/badge/Download-macOS-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Download Siphon for macOS" /></a>
    <a href="https://github.com/marspater/jolly-hopper"><img src="https://img.shields.io/badge/Repository-jolly--hopper-818cf8?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Repository" /></a>
    <a href="https://github.com/marspater/jolly-hopper/blob/main/SUPPORTED_SITES.md"><img src="https://img.shields.io/badge/Supported--Sites-1000%2B-green?style=for-the-badge&logo=globe&logoColor=white" alt="Supported Sites" /></a>
  </p>
</div>

---

## ✨ Highlights & Features

- 💾 **Durable queue recovery**: Queued and running jobs are persisted atomically across state changes so interrupted work can be recovered with one click after unexpected exits or crashes.
- 🔐 **Credential-free browser handoff**: Safari, Chrome-family, and Firefox integrations pass browser identity without putting raw cookies into custom URLs. Session state is scoped to validated origins and private-network deep links are rejected.
- ♻️ **Reliable pause, resume, and cancellation**: Per-download scratch storage preserves resumable partial data, while executor ownership remains intact until process teardown actually finishes.
- 🛡️ **Hardened update trust chain**: App updates are checked against an Ed25519-signed release manifest, dependencies are pinned by SHA-256, and installs keep rollback protection, stale-operation guards, and explicit exclusion between yt-dlp replacement and active downloads.
- 🧱 **Public-network boundary for browser links**: Downloads that arrive from a browser extension run through a local egress proxy that refuses private, loopback, and reserved addresses at connection time, including after redirects.
- 🌐 **Protected-site recovery**: Hardened site-specific extraction keeps browser cookies, user agents, origins, signed streams, and CDN boundaries coherent.
- 💧 **Native macOS presentation**: Liquid Glass surfaces on one Display P3 palette, a status strip that only animates while downloading, downloads kept in arrival order with Recent newest first, a layered app icon, and accessible light/dark contrast.
- 🧭 **Explicit runtime ownership**: Download queueing, execution, app-level update state, shutdown, and browser ingress now have documented ownership boundaries and regression coverage.
- 🎯 **Broad extraction & media control**: yt-dlp-backed support for 1,000+ sites, quality/codec presets, playlists, subtitles, SponsorBlock, FFmpeg processing, and fast browser-triggered downloads.

For release-by-release details, see [CHANGELOG.md](CHANGELOG.md).

---

## 💻 Installation

### Homebrew (Recommended) 🍺

Install Siphon from this repository as a custom Homebrew tap:

```bash
brew tap marspater/jolly-hopper https://github.com/marspater/jolly-hopper.git
brew install --cask marspater/jolly-hopper/siphon
```

The explicit repository URL is required because this project repository is not named with Homebrew's `homebrew-` tap prefix.

To update in the future:
```bash
brew update
brew upgrade --cask marspater/jolly-hopper/siphon
```

---

### Manual Installation 📦

1. Download the latest `.dmg` release from the [Releases](https://github.com/marspater/jolly-hopper/releases) page.
2. Drag **Siphon** into your `/Applications` directory.
3. If macOS Gatekeeper alerts on first open:
```bash
xattr -cr /Applications/"Siphon.app"
```

---

### Browser Extensions 🌐

Integrate Siphon directly into your favorite web browser for 1-click video downloads:
- **Chrome / Brave / Edge / Helium**: Navigate to `chrome://extensions`, enable **Developer Mode**, and click **Load Unpacked** pointing to `SiphonExtension_Chrome`.
- **Safari**: Enable the extension in Safari > Settings > Extensions.
- **Firefox**: Load `SiphonExtension_Firefox` in `about:debugging#/runtime/this-firefox`.

Extensions hand Siphon only the page URL and which browser to read cookies from, never the cookies themselves. To use **Safari** cookies (for sites that need a signed-in session), grant Siphon **Full Disk Access** in System Settings > Privacy & Security, then relaunch Siphon. Without it, Siphon skips Safari cookies for the rest of the session and downloads without them.

---

## 🛠️ Technical Stack & Architecture

- **Language**: Swift 6.0 (Strict Concurrency & Sendable thread safety), SwiftUI, AppKit
- **Extraction Engine**: Custom `yt-dlp` process coordinator
- **Media Transcoder**: Native `FFmpeg` & `FFprobe` 6.1.1 (`arm64` / `x86_64`)
- **Logging & Diagnostics**: Centralized structured `LoggerService` & os_log tracing
- **Target OS**: macOS 15.0 (Sequoia) through macOS 27+

## 🔧 Building from Source

Requires Xcode 16 or later on macOS 15 or later. Open `Siphon.xcodeproj` and run the **Siphon** scheme, or run the test suite from the command line:

```bash
xcodebuild test -project Siphon.xcodeproj -scheme Siphon -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Siphon downloads its pinned `yt-dlp`, `FFmpeg`, and `FFprobe` builds on first launch and verifies each against its SHA-256 before use. Contributor and agent rules live in [AGENTS.md](AGENTS.md).

## 🧭 Architecture

Runtime ownership, cancellation guarantees, dependency-update exclusion, and browser-extension ingress are documented in [ARCHITECTURE.md](ARCHITECTURE.md).

## 🎨 Design language

The UI system, motion rules, accessibility expectations, and Liquid Glass policy
are documented in [DESIGN_LANGUAGE.md](DESIGN_LANGUAGE.md).

---

## ⚖️ License

Distributed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for details.

Developed & Maintained by **[marspater](https://github.com/marspater)**
