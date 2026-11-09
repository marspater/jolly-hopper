import XCTest
@testable import Siphon
@testable import SiphonCore

@MainActor
final class DownloadTests: XCTestCase {
    func testDRMOnlyFormatIsNotSingleUnprobedFormat() {
        XCTAssertFalse(YtdlpService.isSingleUnprobedFormat(MediaInfo(
            id: "x", title: "DRM only", formats: [MediaFormat(formatId: "drm", ext: "mp4", hasDRM: .protected)])))
    }

    func testRowFilePresenceStoresOnlyChangesARowShows() throws {
        let download = Download(url: "https://example.com/v", options: .default, title: "V")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("presence_\(UUID().uuidString).mp4")
        download.filePaths = [file]
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // Unknown and present look the same, so a present file writes nothing.
        var shown: Bool?
        shown.refreshPresence(of: download)
        XCTAssertNil(shown)

        try FileManager.default.removeItem(at: file)
        shown.refreshPresence(of: download)
        XCTAssertEqual(shown, false)

        try Data([0]).write(to: file)
        shown.refreshPresence(of: download)
        XCTAssertEqual(shown, true)
    }

    func testFormatSubtitleVideoAndAudioScenarios() {
        let lang = LanguageService()

        // 1. Standard Video with resolution, video codec, HDR diagnostics, and duration
        var videoOptions = DownloadOptions.default
        videoOptions.fileType = .mp4
        videoOptions.videoResolution = .r1080p
        videoOptions.videoCodec = .h264
        let videoDownload = Download(url: "https://www.youtube.com/watch?v=123", options: videoOptions)
        videoDownload.duration = "05:30"
        videoDownload.diagnostics.dynamicRange = "HDR10"
        videoDownload.diagnostics.bitDepth = 10
        XCTAssertEqual(videoDownload.formatSubtitle(lang: lang), "YouTube • 1080p • H264 • HDR10 • 10-bit • MP4 • 05:30")

        // 2. Video with .best resolution deriving height from mediaInfo
        var bestVideoOptions = DownloadOptions.default
        bestVideoOptions.fileType = .mkv
        bestVideoOptions.videoResolution = .best
        bestVideoOptions.videoCodec = .auto
        let bestVideoDownload = Download(url: "https://vimeo.com/98765432", options: bestVideoOptions)
        let fmt1 = MediaFormat(formatId: "1", ext: "mp4", resolution: "1280x720")
        let fmt2 = MediaFormat(formatId: "2", ext: "mp4", resolution: "3840x2160")
        bestVideoDownload.mediaInfo = MediaInfo(id: "98765432", title: "Test", formats: [fmt1, fmt2])
        bestVideoDownload.duration = "10:00"
        XCTAssertEqual(bestVideoDownload.formatSubtitle(lang: lang), "Vimeo • 2160p • MKV • 10:00")

        // 3. Audio with quality, codec, and duration
        var audioOptions = DownloadOptions.default
        audioOptions.fileType = .mp3
        audioOptions.audioQuality = .q320
        audioOptions.audioCodec = .mp3
        let audioDownload = Download(url: "https://soundcloud.com/artist/track", options: audioOptions)
        audioDownload.duration = "03:45"
        XCTAssertEqual(audioDownload.formatSubtitle(lang: lang), "SoundCloud • 320kbps • MP3 • 03:45")

        // 4. Subtitle count formatting
        var subOptions = DownloadOptions.default
        subOptions.fileType = .mp4
        subOptions.downloadSubtitles = true
        subOptions.subtitleLanguages = ["en", "es", "fr"]
        subOptions.subtitleFormat = .srt
        let subDownload = Download(url: "https://www.youtube.com/watch?v=sub", options: subOptions)
        let subtitleText = subDownload.formatSubtitle(lang: lang)
        XCTAssertTrue(subtitleText.contains("3"))
        XCTAssertTrue(subtitleText.contains("SRT"))
    }

    func testErrorUXInfoCategorizationAndSanitization() {
        let lang = LanguageService()
        let options = DownloadOptions.default
        let download = Download(url: "https://www.youtube.com/watch?v=123", options: options)

        // 1. YouTube Authentication / Bot error
        download.errorMessage = "Sign in to confirm you are not a bot"
        download.log = "Error log with token=secret123 and session=abc987"
        var info = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.headline, lang.s("couldnt_download"))
        XCTAssertEqual(info?.description, lang.s("youtube_auth_required"))
        XCTAssertEqual(info?.actionType, .fixInSettings)
        XCTAssertFalse(info?.rawError.contains("secret123") ?? true)

        // 2. DRM protected
        download.errorMessage = "This video is protected by DRM encryption"
        info = download.errorUXInfo(lang: lang)
        XCTAssertEqual(info?.actionType, .noAction)
        XCTAssertEqual(info?.description, lang.s("drm_protected_desc"))

        // 3. Video unavailable
        download.errorMessage = "HTTP Error 404: Not Found"
        info = download.errorUXInfo(lang: lang)
        XCTAssertEqual(info?.actionType, .retry)
        XCTAssertEqual(info?.description, lang.s("video_unavailable_desc"))

        // 4. Disk full
        download.errorMessage = "No space left on device"
        info = download.errorUXInfo(lang: lang)
        XCTAssertEqual(info?.actionType, .changeFolder)
        XCTAssertEqual(info?.description, lang.s("disk_full_desc"))

        // 4b. The executor stores localized messages; these must classify too.
        download.errorMessage = lang.s("disk_full")
        info = download.errorUXInfo(lang: lang)
        XCTAssertEqual(info?.actionType, .changeFolder)
        download.errorMessage = lang.s("ytdlp_not_found")
        info = download.errorUXInfo(lang: lang)
        XCTAssertEqual(info?.actionType, .fixInSettings, "A missing yt-dlp is not an unavailable video")

        // 5. Permission denied
        download.errorMessage = "Permission denied writing to folder"
        info = download.errorUXInfo(lang: lang)
        XCTAssertEqual(info?.actionType, .changeFolder)
        XCTAssertEqual(info?.description, lang.s("permission_denied_desc"))

        // 6. Network timeout
        download.errorMessage = "Connection timed out"
        info = download.errorUXInfo(lang: lang)
        XCTAssertEqual(info?.actionType, .retry)
        XCTAssertEqual(info?.description, lang.s("network_timeout_desc"))

        // 7. Unsupported URL
        download.errorMessage = "Unsupported URL: invalid link"
        info = download.errorUXInfo(lang: lang)
        XCTAssertEqual(info?.actionType, .noAction)
        XCTAssertEqual(info?.description, lang.s("unsupported_url_desc"))

        // 8. Nil error message and non-failed status
        download.errorMessage = nil
        download.status = .completed
        XCTAssertNil(download.errorUXInfo(lang: lang))

        // 9. Status is failed with generic fallback
        download.status = .failed
        info = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.actionType, .retry)
    }

    func testDownloadStatusPropertiesAndDecoding() throws {
        let lang = LanguageService()
        let cases: [(DownloadStatus, String)] = [
            (.fetching, "blue"),
            (.queued, "orange"),
            (.downloading, "blue"),
            (.processing, "purple"),
            (.completed, "green"),
            (.failed, "red"),
            (.stopped, "gray"),
            (.paused, "yellow"),
            (.fileExists, "orange")
        ]

        for (status, expectedColor) in cases {
            XCTAssertEqual(status.color, expectedColor)
            XCTAssertFalse(status.title(lang: lang).isEmpty)
        }

        // Test JSON Codable roundtrip
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for (status, _) in cases {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(DownloadStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }

        // Test legacy Turkish decoding
        let turkishMap: [String: DownloadStatus] = [
            "\"Bilgi Alınıyor\"": .fetching,
            "\"Kuyrukta\"": .queued,
            "\"İndiriliyor\"": .downloading,
            "\"İşleniyor\"": .processing,
            "\"Tamamlandı\"": .completed,
            "\"Hata\"": .failed,
            "\"Durduruldu\"": .stopped,
            "\"Duraklatıldı\"": .paused,
            "\"Dosya Mevcut\"": .fileExists
        ]

        for (jsonString, expectedStatus) in turkishMap {
            let data = jsonString.data(using: .utf8)!
            let status = try decoder.decode(DownloadStatus.self, from: data)
            XCTAssertEqual(status, expectedStatus)
        }
    }

    func testHDROptionProperties() {
        let lang = LanguageService()

        XCTAssertEqual(HDRAction.preserveHDR.id, "preserve_hdr")
        XCTAssertEqual(HDRAction.convertToSDR.id, "convert_to_sdr")
        XCTAssertEqual(HDRAction.preserveHDR.title(lang: lang), "Preserve HDR (Original)")
        XCTAssertEqual(HDRAction.convertToSDR.title(lang: lang), "Convert HDR to SDR (Tone-mapped)")
    }

    func testCodecsAndPresets() {
        let lang = LanguageService()

        for preset in DownloadPreset.allCases {
            XCTAssertFalse(preset.title(lang: lang).isEmpty)
            XCTAssertFalse(preset.description(lang: lang).isEmpty)
        }
    }

    func testFormatSubtitleShowsResolvedHeightAndSingularLanguage() {
        var options = DownloadOptions.default
        options.videoResolution = .r1080p
        options.downloadSubtitles = true
        options.subtitleLanguages = ["en"]
        options.subtitleFormat = nil
        let download = Download(url: "https://www.youtube.com/watch?v=123", options: options)
        XCTAssertEqual(download.formatSubtitle(lang: LanguageService()), "YouTube • 1080p • MP4 • 1 language selected")
        download.diagnostics.resolvedHeight = 720
        XCTAssertEqual(download.formatSubtitle(lang: LanguageService()), "YouTube • 720p • MP4 • 1 language selected")
    }

    func testMenuBarAppliesOnlyItsOwnPreset() throws {
        let suiteName = "testDefaults_\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let preferences = CustomPreset(configuration: CustomPresetConfiguration(name: "Preferences", videoCodec: .h264, audioCodec: .aac, videoResolution: .r720p, fileType: .mp4, subtitles: CustomPresetSubtitles(downloadSubtitles: true, subtitleLanguage: "embed:de"), sponsorBlock: true, splitChapters: true))
        let menuBar = CustomPreset(configuration: CustomPresetConfiguration(name: "Menu bar", videoCodec: .h264, audioCodec: .aac, videoResolution: .r1080p, fileType: .mkv, subtitles: CustomPresetSubtitles(downloadSubtitles: true, subtitleLanguage: "fr", subtitleFormat: .ass)))
        testDefaults.set(preferences.id.uuidString, forKey: UserDefaultsKeys.selectedCustomPresetId)
        testDefaults.set(try JSONEncoder().encode([preferences, menuBar]), forKey: UserDefaultsKeys.customPresets)

        // A built-in menu bar choice must not pick up the Preferences preset's extras.
        let builtIn = MenuBarView.downloadOptions(selectedPreset: DownloadPreset.bestQuality.rawValue, selectedType: "video",
                                                  customPresets: [preferences, menuBar], userDefaults: testDefaults)
        XCTAssertFalse(builtIn.downloadSubtitles)
        XCTAssertFalse(builtIn.splitChapters)
        XCTAssertFalse(builtIn.sponsorBlock)

        let custom = MenuBarView.downloadOptions(selectedPreset: "custom_\(menuBar.id.uuidString)", selectedType: "video",
                                                 customPresets: [preferences, menuBar], userDefaults: testDefaults)
        XCTAssertEqual(custom.fileType, .mkv)
        XCTAssertTrue(custom.downloadSubtitles)
        XCTAssertFalse(custom.embedSubtitles)
        XCTAssertEqual(custom.subtitleLanguages, ["fr"])
        XCTAssertEqual(custom.subtitleFormat, .ass)
        XCTAssertFalse(custom.splitChapters)
        XCTAssertFalse(custom.sponsorBlock)
    }
}
