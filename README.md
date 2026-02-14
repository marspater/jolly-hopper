# Macabolic 🚀

A modern, fast, and beautiful video downloader for macOS. Powered by `yt-dlp`.

<div align="center">
  <img src="Macabolic/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="128" />
  <p>
    <a href="https://github.com/alinuxpengui/Macabolic/releases/latest/download/Macabolic-v3.0.0.dmg">
      <img src="https://img.shields.io/badge/Download-macOS-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Download Macabolic for macOS" />
    </a>
    <a href="https://github.com/alinuxpengui/homebrew-macabolic">
      <img src="https://img.shields.io/badge/Homebrew-tap-FBB040?style=for-the-badge&logo=homebrew&logoColor=white" alt="Install via Homebrew" />
    </a>
    <a href="https://github.com/alinuxpengui/Macabolic/releases">
      <img src="https://img.shields.io/github/downloads/alinuxpengui/Macabolic/total?style=for-the-badge&color=818cf8" alt="Total Downloads" />
    </a>
  </p>
  <p>
    <a href="https://mastodon.social/@macabolic_app">
      <img src="https://img.shields.io/badge/Follow-Mastodon-2b90d9?style=for-the-badge&logo=mastodon&logoColor=white" alt="Follow on Mastodon" />
    </a>
    <a href="https://bsky.app/profile/macabolicapp.bsky.social">
      <img src="https://img.shields.io/badge/Follow-Bluesky-0085ff?style=for-the-badge&logo=bluesky&logoColor=white" alt="Follow on Bluesky" />
    </a>
    <a href="https://x.com/macabolic_app">
      <img src="https://img.shields.io/badge/Follow-X-black?style=for-the-badge&logo=x&logoColor=white" alt="Follow on X" />
    </a>
  </p>
</div>

Macabolic is a native macOS frontend for the powerful [yt-dlp](https://github.com/yt-dlp/yt-dlp) command-line tool. It allows you to download videos and audio from YouTube and thousands of other supported sites with ease.

## Screenshots 📸

<div align="center">
  <table>
    <tr>
      <td width="50%"><img src="docs/screenshots/1.png" alt="Main Dashboard - Overview of all downloads" /></td>
      <td width="50%"><img src="docs/screenshots/2.png" alt="Smart Download - Custom settings and options" /></td>
    </tr>
    <tr>
      <td width="50%"><img src="docs/screenshots/3.png" alt="Advanced Preferences - Global application settings" /></td>
      <td width="50%"><img src="docs/screenshots/4.png" alt="Custom Presets - Create and manage your own templates" /></td>
    </tr>
  </table>
</div>

---

## Support My Journey ❤️

It’s about the motivation of knowing my work truly helped someone and made their life a little easier. Your support is what keeps me building and improving these tools for everyone.

### 🏆 The "First 5" Wall of Fame
To show my gratitude, the **first 5 sponsors** of any amount will be **permanently featured** in the "About" section of the Macabolic app. Your name will be part of the app's history forever!

[👉 Become a Sponsor on GitHub](https://github.com/sponsors/alinuxpengui)

---

## Roadmap 🗺️

Here is what I'm planning to bring to Macabolic in the near future:

- [x] ~~**Browser Cookies Support:** Use cookies from your browser to bypass YouTube's bot detection and access age-restricted or private content.~~ ✅ (Completed in v2.2.0)
- [x] ~~**Advanced Codec Default Settings & Presets:** Save and manage custom download presets with preferred codecs, resolutions, and audio quality settings.~~ ✅ (Completed in v2.2.0)
- [x] ~~**Persistent History & Re-download:** Categorized completed/failed downloads that persist across sessions and easy re-downloading.~~ ✅ (Completed in v2.3.0)
- [x] ~~**Notification Support:** Get notified instantly when downloads are finished.~~ ✅ (Completed in v3.0.0)
- [x] ~~**Browser Extensions:** One-click download directly from Chrome and Firefox.~~ ✅ (Completed in v3.0.0)
- [x] ~~**Menu Bar Integration:** Manage ind downloads from your menu bar.~~ ✅ (Completed in v3.0.0)
- [ ] **Official Apple Notarization:** Removing the "Unidentified Developer" warning for a professional experience.
- [ ] **Custom Post-Processing:** More tools to trim, convert, and manage your downloaded files.

---

## Features ✨

- **Native macOS Experience:** Built with SwiftUI for a seamless look and feel.
- **Menu Bar App:** Manage your downloads directly from the menu bar. 🆕
- **Browser Extensions:** Start downloads with one click from Chrome and Firefox. 🆕
- **Native Notifications:** Instant updates when downloads are finished. 🆕
- **Vast Site Support:** Downloads from YouTube, Vimeo, Twitter, and [thousands more](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).
- **Multiple Formats:** Support for MP4, WebM, MP3, Opus, FLAC, and WAV.
- **High Quality:** Up to 4K (2160p) resolution support.
- **Smart Features:**
  - Embed subtitles, metadata, and thumbnails into your files.
  - **SponsorBlock** integration to automatically skip sponsors and intros.
  - Playlist downloading support.
  - Concurrent download management.
- **Multi-language:** Supports English and Turkish (automatically detects system language).
- **Auto-Update:** Self-manages `yt-dlp` updates to ensure maximum compatibility.

## Installation 🚀

### Option 1: Homebrew (Recommended)

```bash
brew tap alinuxpengui/macabolic
brew install --cask macabolic
xattr -cr /Applications/Macabolic.app
```

### Option 2: Manual Download

- **Download:** Download the latest `Macabolic-v3.0.0.dmg` from the [Releases](https://github.com/alinuxpengui/Macabolic/releases) page.
- **Install:** Open the DMG file and drag **Macabolic** to your `Applications` folder.
- **First Launch:** Since the app is not notarized, you have two options to open it:
  - **Terminal Way:** Run the following command to remove the quarantine flag:
```bash
xattr -cr /Applications/Macabolic.app
```
  - **Other Way:** Right-click the app in your Applications folder and select Open, or go to System Settings > Privacy & Security and click Open Anyway.
- **Initial Setup:** When the app opens, you will be greeted by a **Legal Disclaimer**. Please read and confirm it. Go to **Preferences (⌘,)** to set your **Language** and **Default Save Folder**.

### Option 3: Browser Extensions 🌐

#### Chrome / Brave / Edge:
1. Go to `chrome://extensions/`
2. Enable **"Developer mode"** (top right).
3. Click **"Load unpacked"** and select the `MacabolicExtension_Chrome` folder from this repository.

#### Firefox:
1. Go to `about:debugging#/runtime/this-firefox`
2. Click **"Load Temporary Add-on..."**.
3. Select the `manifest.json` file inside the `MacabolicExtension_Firefox` folder.

---

## Build Requirements 🛠️

- macOS 13.0 or later (Ventura+)
- Xcode 14.0 or later
- Swift 5.7+

## Credits ❤️

- **Parabolic by Nickvision:** This project is a macOS-native port based on the original [Parabolic](https://github.com/NickvisionApps/Parabolic) application.
- **yt-dlp:** The core engine that makes video downloading possible.

## Legal Disclaimer ⚖️

This tool is intended solely for personal use and educational or research purposes.
Videos on YouTube and other sites may be subject to DMCA protection. The authors of Parabolic/Macabolic do not endorse, and are not responsible for, the use of this application in means that will violate these laws.
Downloading videos from YouTube may violate their Terms of Service unless the video has an explicit download button or the content is licensed in a way that permits downloading.
By using this app, you assume full responsibility for any content you download and how you use it. The developer does not condone or support any misuse of this tool to infringe upon copyrights or violate platform rules.

## License ⚖️

This project is licensed under the **GNU General Public License v3.0**. See the [LICENSE](LICENSE) file for details.

---
**Maintained by [alinuxpengui](https://github.com/alinuxpengui)**

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=alinuxpengui/Macabolic&type=date&legend=top-left)](https://www.star-history.com/#alinuxpengui/Macabolic&type=date&legend=top-left)
