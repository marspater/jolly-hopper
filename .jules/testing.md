## 2024-09-12 - Added CustomPreset Serialization Tests
**Learning:** Testing pure data structures that conform to Codable in Swift requires verifying full serialization, minimal instantiation defaults, and legacy JSON payload mapping (where optional properties are missing).
**Action:** Always create tests that use minimal/legacy string payloads to test robust `nil` fallback mapping for properties that might have been added in later application versions.

## 2026-09-17 - Render Mock Test Fixtures for Extractor/Subtitle Verification
**Learning:** Calling external streaming services during testing leads to anti-bot throttles and flaky tests in headless CI environments.
**Action:** Use the companion service mock endpoints (`https://jolly-hopper.onrender.com/mock/subtitles.vtt`, `/mock/playlist.m3u8`, `/mock/video.mp4`) when testing media extraction, parsing, and format resolution.
