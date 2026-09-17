import XCTest
@testable import Siphon

@MainActor
final class DownloadTests: XCTestCase {

    // MARK: - Initialization & Core Properties

    func testDownloadInitializationDefaults() {
        let options = DownloadOptions.default
        let urlString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let customId = UUID()
        let customDate = Date(timeIntervalSince1970: 1000000)

        let download = Download(
            url: urlString,
            options: options,
            title: "Testing &amp; Building",
            id: customId,
            createdAt: customDate
        )

        XCTAssertEqual(download.id, customId)
        XCTAssertEqual(download.url, urlString)
        XCTAssertEqual(download.createdAt, customDate)
        XCTAssertEqual(download.title, "Testing & Building", "Title should decode HTML entities during init")
        XCTAssertEqual(download.status, .queued)
        XCTAssertEqual(download.progress, 0.0)
        XCTAssertEqual(download.sourceDomain, "YouTube")
        XCTAssertTrue(download.filePaths.isEmpty)
        XCTAssertNil(download.primaryFilePath)
        XCTAssertNil(download.duration)
        XCTAssertNil(download.thumbnailURL)
        XCTAssertNil(download.speed)
        XCTAssertNil(download.eta)
        XCTAssertNil(download.errorMessage)
        XCTAssertEqual(download.log, "")
        XCTAssertNil(download.mediaInfo)
        XCTAssertNil(download.diagnostics.pid)
    }

    func testDownloadDefaultTitleAndInitArguments() {
        let options = DownloadOptions.default
        let download = Download(url: "https://example.com/video", options: options)

        XCTAssertEqual(download.title, "___FETCHING___")
        XCTAssertNotNil(download.id)
        XCTAssertNotNil(download.createdAt)
    }

    // MARK: - Primary File Path & File Paths

    func testPrimaryFilePathComputedProperty() {
        let download = Download(url: "https://example.com/video", options: .default)

        XCTAssertNil(download.primaryFilePath, "Primary file path should be nil when filePaths is empty")

        let file1 = URL(fileURLWithPath: "/tmp/video.mp4")
        let file2 = URL(fileURLWithPath: "/tmp/video.srt")
        download.filePaths = [file1, file2]

        XCTAssertEqual(download.primaryFilePath, file1, "Primary file path should return the first item in filePaths")
    }

    // MARK: - Display Progress Formatting & Clamping

    func testDisplayProgressFormattingAndClamping() {
        let download = Download(url: "https://example.com/video", options: .default)

        // Basic percentage only
        download.progress = 0.50
        XCTAssertEqual(download.displayProgress, "50%")

        // Percentage with speed and ETA
        download.speed = "2.5 MB/s"
        download.eta = "00:30"
        XCTAssertEqual(download.displayProgress, "50% • 2.5 MB/s • 00:30")

        // Edge Cases & Clamping
        download.progress = -0.25
        XCTAssertEqual(download.displayProgress, "0% • 2.5 MB/s • 00:30")

        download.progress = 1.75
        XCTAssertEqual(download.displayProgress, "100% • 2.5 MB/s • 00:30")

        download.progress = Double.nan
        XCTAssertEqual(download.displayProgress, "0% • 2.5 MB/s • 00:30", "NaN progress must be clamped safely to 0%")

        download.progress = Double.infinity
        XCTAssertEqual(download.displayProgress, "100% • 2.5 MB/s • 00:30", "Infinite progress must be clamped safely to 100%")

        download.progress = -Double.infinity
        XCTAssertEqual(download.displayProgress, "0% • 2.5 MB/s • 00:30", "Negative infinite progress must be clamped safely to 0%")
    }

    // MARK: - Source Domain Extraction

    func testExtractSourceDomain() {
        let domains: [(String, String)] = [
            ("https://www.youtube.com/watch?v=123", "YouTube"),
            ("https://youtu.be/123", "YouTube"),
            ("https://m.youtube.com/watch?v=123", "YouTube"),
            ("https://twitter.com/user/status/123", "X (Twitter)"),
            ("https://x.com/user/status/123", "X (Twitter)"),
            ("https://www.instagram.com/p/123", "Instagram"),
            ("https://www.tiktok.com/@user/video/123", "TikTok"),
            ("https://vimeo.com/123", "Vimeo"),
            ("https://www.reddit.com/r/videos/123", "Reddit"),
            ("https://www.facebook.com/watch/123", "Facebook"),
            ("https://fb.watch/123", "Facebook"),
            ("https://www.twitch.tv/streamer", "Twitch"),
            ("https://soundcloud.com/artist/track", "SoundCloud"),
            ("https://www.dailymotion.com/video/123", "Dailymotion"),
            ("https://www.bilibili.com/video/123", "Bilibili.com"),
            ("https://media.mysite.org/video.mp4", "Media.mysite.org"),
            ("invalid_url", "Web")
        ]

        for (url, expected) in domains {
            XCTAssertEqual(Download.extractSourceDomain(from: url), expected, "URL '\(url)' should resolve source domain to '\(expected)'")
        }
    }

    // MARK: - Subtitle Formatting

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

    // MARK: - Error UX Information

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

    // MARK: - DownloadStatus Enum

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

    // MARK: - HDRAction Enum

    func testHDROptionProperties() {
        let lang = LanguageService()

        XCTAssertEqual(HDRAction.preserveHDR.id, "preserve_hdr")
        XCTAssertEqual(HDRAction.convertToSDR.id, "convert_to_sdr")
        XCTAssertEqual(HDRAction.preserveHDR.title(lang: lang), "Preserve HDR (Original)")
        XCTAssertEqual(HDRAction.convertToSDR.title(lang: lang), "Convert HDR to SDR (Tone-mapped)")
    }

    // MARK: - DownloadDiagnostics Struct

    func testDownloadDiagnosticsHDRSummary() {
        var diag = DownloadDiagnostics()
        XCTAssertNil(diag.hdrSummary)

        diag.dynamicRange = "HDR10"
        diag.bitDepth = 10
        diag.colorSpace = "BT.2020"
        XCTAssertEqual(diag.hdrSummary, "HDR10 • 10-bit • BT.2020")

        diag.dynamicRange = "SDR"
        diag.bitDepth = 8
        diag.colorSpace = nil
        XCTAssertNil(diag.hdrSummary)
    }

    // MARK: - DownloadOptions Struct & Ephemeral Raw Cookies

    func testDownloadOptionsDefaultsAndSerialization() throws {
        let defaultOpts = DownloadOptions.default

        XCTAssertEqual(defaultOpts.fileType, .mp4)
        XCTAssertFalse(defaultOpts.downloadSubtitles)
        XCTAssertEqual(defaultOpts.subtitleLanguages, ["en"])
        XCTAssertEqual(defaultOpts.subtitleFormat, .srt)
        XCTAssertTrue(defaultOpts.embedThumbnail)
        XCTAssertTrue(defaultOpts.embedMetadata)
        XCTAssertFalse(defaultOpts.splitChapters)
        XCTAssertFalse(defaultOpts.sponsorBlock)

        // Raw cookies must be excluded from Codable encoding
        var customOpts = defaultOpts
        customOpts.rawCookies = "secret_session_cookies_123"

        let encoder = JSONEncoder()
        let data = try encoder.encode(customOpts)
        let jsonString = String(data: data, encoding: .utf8) ?? ""

        XCTAssertFalse(jsonString.contains("secret_session_cookies_123"))
        XCTAssertFalse(jsonString.contains("rawCookies"))

        let decoder = JSONDecoder()
        let decodedOpts = try decoder.decode(DownloadOptions.self, from: data)
        XCTAssertNil(decodedOpts.rawCookies)
    }

    // MARK: - Associated Enums

    func testMediaFileTypeProperties() {
        XCTAssertTrue(MediaFileType.mp4.isVideo)
        XCTAssertFalse(MediaFileType.mp4.isAudio)
        XCTAssertEqual(MediaFileType.mp4.fileExtension, "mp4")

        XCTAssertTrue(MediaFileType.mp3.isAudio)
        XCTAssertFalse(MediaFileType.mp3.isVideo)
        XCTAssertEqual(MediaFileType.mp3.fileExtension, "mp3")

        XCTAssertEqual(MediaFileType.videoTypes, [.mp4, .webm, .mkv])
        XCTAssertEqual(MediaFileType.audioTypes, [.mp3, .opus, .flac, .wav, .m4a])
    }

    func testAudioQualityYtdlpValues() {
        XCTAssertEqual(AudioQuality.best.ytdlpValue, "0")
        XCTAssertEqual(AudioQuality.q320.ytdlpValue, "320K")
        XCTAssertEqual(AudioQuality.q256.ytdlpValue, "256K")
        XCTAssertEqual(AudioQuality.q192.ytdlpValue, "192K")
        XCTAssertEqual(AudioQuality.q128.ytdlpValue, "128K")
    }

    func testVideoResolutionYtdlpValuesAndMaxHeight() {
        XCTAssertEqual(VideoResolution.r2160p.maxHeight, 2160)
        XCTAssertEqual(VideoResolution.r1080p.maxHeight, 1080)
        XCTAssertNil(VideoResolution.best.maxHeight)

        XCTAssertTrue(VideoResolution.r1080p.ytdlpValue.contains("height<=1080"))
        XCTAssertTrue(VideoResolution.r1080p.ytdlpCombinedValue.contains("bestaudio"))
    }

    func testCodecsAndPresets() {
        let lang = LanguageService()

        XCTAssertEqual(VideoCodec.h264.ytdlpFilter, "[vcodec^=avc1]")
        XCTAssertNil(VideoCodec.auto.ytdlpFilter)

        XCTAssertEqual(AudioCodec.aac.ytdlpFilter, "[acodec^=mp4a]")
        XCTAssertNil(AudioCodec.auto.ytdlpFilter)

        for preset in DownloadPreset.allCases {
            XCTAssertFalse(preset.title(lang: lang).isEmpty)
            XCTAssertFalse(preset.description(lang: lang).isEmpty)
        }
    }

    func testDisplayTitleFallback() {
        let dlSlug = Download(url: "https://www.boyfriendtv.com/videos/1140993/hot-beach-workout", options: .default)
        XCTAssertEqual(dlSlug.displayTitle, "Hot Beach Workout")

        let dlNumeric = Download(url: "https://www.boyfriendtv.com/videos/1140993/", options: .default)
        XCTAssertEqual(dlNumeric.displayTitle, "Boyfriendtv.com Video")

        var customOpts = DownloadOptions.default
        customOpts.customFilename = "My Custom Title"
        let dlCustom = Download(url: "https://example.com/video", options: customOpts)
        XCTAssertEqual(dlCustom.displayTitle, "My Custom Title")

        let dlFetched = Download(url: "https://example.com/video", options: .default, title: "Fetched Real Title")
        XCTAssertEqual(dlFetched.displayTitle, "Fetched Real Title")

        // Crucial invariant: displayTitle must NEVER return "___FETCHING___"
        let dlFetching = Download(url: "https://example.com/test", options: .default, title: "___FETCHING___")
        XCTAssertNotEqual(dlFetching.displayTitle, "___FETCHING___")
    }

    func testHistoricDownloadNeverStoresPlaceholder() {
        let dl = Download(url: "https://www.boyfriendtv.com/videos/12345/summer-fun", options: .default, title: "___FETCHING___")
        let historic = HistoricDownload(download: dl)
        XCTAssertNotEqual(historic.title, "___FETCHING___")
        XCTAssertEqual(historic.title, "Summer Fun")
    }
}

