# VeloX Pro ⚡️

A high-performance, native macOS media extractor & downloader powered by `yt-dlp` and `FFmpeg`. Engineered with advanced anti-bot bypass mechanisms for Cloudflare, BoyfriendTV, GayForFans, YouTube, and 1,000+ protected video streaming sites.

<div align="center">
  <img src="assets/app_screenshot.png" alt="VeloX Pro Interface" width="880" style="border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.3);" />
  <p>
    <a href="https://github.com/marspater/jolly-hopper/releases/latest">
      <img src="https://img.shields.io/badge/Download-macOS-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Download VeloX Pro for macOS" />
    </a>
    <a href="https://github.com/marspater/jolly-hopper">
      <img src="https://img.shields.io/badge/Repository-jolly--hopper-818cf8?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Repository" />
    </a>
    <a href="https://github.com/marspater/jolly-hopper/blob/main/SUPPORTED_SITES.md">
      <img src="https://img.shields.io/badge/Supported--Sites-1000%2B-green?style=for-the-badge&logo=globe&logoColor=white" alt="Supported Sites" />
    </a>
  </p>
</div>

---

## ✨ Highlights & Features

- 💧 **Translucent macOS Glassmorphism**: Engineered using native Apple SwiftUI materials and AppKit window translucency for a sleek macOS experience.
- ⚡ **Advanced Anti-Bot Bypasses**: Native header impersonation, Chrome 124 Client Hints emulation, and cookie session synchronization for Cloudflare and protected sites.
- 🎯 **Deep Provider Resolvers**: Built-in specialized stream extraction for BoyfriendTV, GayForFans, YouTube Playlists, TikTok, X (Twitter), Instagram, and Twitch.
- 🚀 **Atomic Dependency Engine**: Safe, self-testing background updates for `yt-dlp` and native Apple Silicon (`arm64`) + Intel (`x86_64`) `FFmpeg` / `FFprobe` 6.0 binaries.
- 🛠 **Custom Quality Presets & Codec Control**: Full control over H.264, VP9, AV1, AAC, Opus, MP3, FLAC extraction, resolution scaling (up to 8K), and SponsorBlock segment skipping.
- 🌐 **Browser Extensions & Menu Bar Companion**: 1-click downloading directly from Safari, Chrome, and Firefox, plus a lightweight macOS status bar popover.

---

## 💻 Installation

### Manual Installation
1. Download the latest `.dmg` release from the [Releases](https://github.com/marspater/jolly-hopper/releases) page.
2. Drag **VeloX Pro** into your `/Applications` directory.
3. If macOS Gatekeeper alerts on first open:
```bash
xattr -cr /Applications/"VeloX Pro.app"
```

### Browser Extensions 🌐
Integrate VeloX Pro directly into your favorite web browser for 1-click video downloads:
- **Chrome / Brave / Edge**: Navigate to `chrome://extensions`, enable **Developer Mode**, and click **Load Unpacked** pointing to `VeloXExtension_Chrome`.
- **Safari**: Enable the extension in Safari Preferences > Extensions.
- **Firefox**: Load `VeloXExtension_Firefox` in `about:debugging#/runtime/this-firefox`.

---

## 🛠️ Technical Stack & Architecture

- **Language**: Swift 5.0, SwiftUI, AppKit
- **Extraction Engine**: Custom `yt-dlp` process coordinator
- **Media Transcoder**: Native `FFmpeg` & `FFprobe` 6.0 (`arm64` / `x86_64`)
- **Logging & Diagnostics**: Centralized structured `LoggerService` & os_log tracing
- **Target OS**: macOS 12.0 (Monterey) through macOS 27+

---

## ⚖️ License

Distributed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for details.

Developed & Maintained by **[marspater](https://github.com/marspater)**
