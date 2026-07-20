# VeloX Pro ⚡️

A high-performance, native macOS media extractor & downloader powered by `yt-dlp` and `FFmpeg`. Engineered with advanced anti-bot bypass mechanisms for Cloudflare and protected sites.

<div align="center">
  <img src="VeloX/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="128" />
  <p>
    <a href="https://github.com/marspater/jolly-hopper/releases/latest">
      <img src="https://img.shields.io/badge/Download-macOS-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Download VeloX Pro for macOS" />
    </a>
    <a href="https://github.com/marspater/jolly-hopper">
      <img src="https://img.shields.io/badge/Repository-jolly--hopper-818cf8?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Repository" />
    </a>
  </p>
</div>

VeloX Pro is a native macOS application built with Swift and SwiftUI. It provides an intuitive, powerful interface over `yt-dlp`, optimized for high speeds, multi-threaded fragment processing, and seamless anti-bot challenge solving.

---

## Key Features ⚡️

- **Advanced Anti-Bot Bypasses**: Automatic impersonation and full Chrome 124 Client Hints header emulation for Cloudflare-protected sites (e.g. BoyfriendTV, JustTheGays).
- **Atomic Dependency Engine**: Safe, atomic, and self-testing updates for `yt-dlp`, `FFmpeg`, and `FFprobe`.
- **Persistent Debug Logging**: In-app live log viewer and export (`~/Library/Application Support/VeloX/velox_debug.log`).
- **macOS 27 SDK Ready**: Built for modern macOS 12+ with futuristic compatibility for upcoming macOS versions.
- **Native macOS Interface**: Built with pure SwiftUI for a crisp dark/light native UI experience.
- **Menu Bar App & Browser Extensions**: Launch downloads directly from your browser (Chrome, Safari & Firefox) or menu bar popover.
- **Format & Codec Customization**: Smart presets, 4K/8K resolution support, audio extraction (MP3, FLAC, WAV, Opus), and SponsorBlock integration.

---

## Installation 🚀

### Manual Download
1. Download the latest release `.dmg` from the [Releases](https://github.com/marspater/jolly-hopper/releases) page.
2. Drag **VeloX Pro** into your `/Applications` folder.
3. If prompted by macOS Gatekeeper:
```bash
xattr -cr /Applications/"VeloX Pro.app"
```

### Browser Extensions 🌐
- **Chrome / Brave / Edge**: Load `VeloXExtension_Chrome` via `chrome://extensions` (Developer Mode > Load Unpacked).
- **Safari**: Load `VeloXExtension_Safari` in Safari.
- **Firefox**: Load `VeloXExtension_Firefox` via `about:debugging#/runtime/this-firefox`.

---

## Technical Architecture 🛠️

- **Framework**: Swift 5.0, SwiftUI, AppKit
- **Core Engine**: `yt-dlp` + `FFmpeg` / `FFprobe`
- **Challenge Solvers**: `JavaScriptCore` runtime for Sucuri / JS cookie solving
- **Target OS**: macOS 12.0+ (Monterey through macOS 27)

---

## License ⚖️

This project is licensed under the **GNU General Public License v3.0**. See the [LICENSE](LICENSE) file for details.

Maintained by **[marspater](https://github.com/marspater)**
