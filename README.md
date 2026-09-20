# Siphon ⚡️

A high-performance, native macOS media extractor & downloader powered by `yt-dlp` and `FFmpeg`. Engineered with advanced anti-bot bypass mechanisms for Cloudflare, YouTube, and 1,000+ protected video streaming sites.

<div align="center">
  <img src="assets/app_screenshot.png?v=3" alt="Siphon Interface" width="880" style="border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.3);" />
  <p>
    <a href="https://github.com/marspater/jolly-hopper/releases/latest"><img src="https://img.shields.io/badge/Version-v5.4.0-indigo?style=for-the-badge&logo=swift&logoColor=white" alt="Version 5.4.0" /></a>
    <a href="https://github.com/marspater/jolly-hopper/releases/latest"><img src="https://img.shields.io/badge/Download-macOS-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Download Siphon for macOS" /></a>
    <a href="https://github.com/marspater/jolly-hopper"><img src="https://img.shields.io/badge/Repository-jolly--hopper-818cf8?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Repository" /></a>
    <a href="https://github.com/marspater/jolly-hopper/blob/main/SUPPORTED_SITES.md"><img src="https://img.shields.io/badge/Supported--Sites-1000%2B-green?style=for-the-badge&logo=globe&logoColor=white" alt="Supported Sites" /></a>
  </p>
</div>

---

## ✨ Highlights & Features

- 🔐 **Credential-free browser handoff**: Safari, Chrome-family, Firefox, and Helium integrations pass browser identity without putting raw cookies into custom URLs. Session state is scoped to validated origins and private-network deep links are rejected.
- ♻️ **Reliable pause, resume, and cancellation**: Per-download scratch storage preserves resumable partial data, while executor ownership remains intact until process teardown actually finishes.
- 🛡️ **Hardened update trust chain**: App and dependency updates use verified release metadata, pinned digests, rollback protection, stale-operation guards, and explicit exclusion between yt-dlp replacement and active downloads.
- 🌐 **Protected-site recovery**: Hardened BoyfriendTV, Recu, and GayPornTube extraction keeps browser cookies, user agents, origins, signed streams, and CDN boundaries coherent.
- 💧 **Native macOS presentation**: Refined Liquid Glass surfaces, stronger light/dark contrast, responsive download rows, accessibility improvements, and lower idle rendering overhead.
- 🧭 **Explicit runtime ownership**: Download queueing, execution, app-level update state, shutdown, and browser ingress now have documented ownership boundaries and regression coverage.
- 🎯 **Broad extraction & media control**: yt-dlp-backed support for 1,000+ sites, quality/codec presets, playlists, subtitles, SponsorBlock, FFmpeg processing, and fast browser-triggered downloads.

For release-by-release details, see [CHANGELOG.md](CHANGELOG.md).

---

## 💻 Installation

### Homebrew (Recommended) 🍺

Install Siphon using Homebrew Cask:

```bash
brew tap marspater/jolly-hopper
brew install --cask siphon
```

Or install in a single command without tapping first:

```bash
brew install --cask marspater/jolly-hopper/siphon
```

To update in the future:
```bash
brew upgrade --cask siphon
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
- **Safari**: Enable the extension in Safari Preferences > Extensions.
- **Firefox**: Load `SiphonExtension_Firefox` in `about:debugging#/runtime/this-firefox`.

---

## 🛠️ Technical Stack & Architecture

- **Language**: Swift 6.0 (Strict Concurrency & Sendable thread safety), SwiftUI, AppKit
- **Extraction Engine**: Custom `yt-dlp` process coordinator
- **Media Transcoder**: Native `FFmpeg` & `FFprobe` 6.0 (`arm64` / `x86_64`)
- **Logging & Diagnostics**: Centralized structured `LoggerService` & os_log tracing
- **Target OS**: macOS 15.0 (Sequoia) through macOS 27+

## 🧭 Architecture

Runtime ownership, cancellation guarantees, dependency-update exclusion, and browser-extension ingress are documented in [ARCHITECTURE.md](ARCHITECTURE.md).

## 🎨 Design language

The UI system, motion rules, accessibility expectations, and Liquid Glass policy
are documented in [DESIGN_LANGUAGE.md](DESIGN_LANGUAGE.md).

---

## ⚖️ License

Distributed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for details.

Developed & Maintained by **[marspater](https://github.com/marspater)**
