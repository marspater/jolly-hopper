import XCTest
@testable import SiphonCore

@MainActor
final class DownloadModelTests: XCTestCase {
    func testPurgeKeepsOldScratchWithLiveOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSinceNow: -3 * 24 * 3600)
        func scratch(pid: Int32?) throws -> URL {
            let dir = root.appendingPathComponent(ScratchDirectoryPolicy.directoryPrefix + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let pid { ScratchDirectoryPolicy.markOwner(dir, pid: pid) }
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
            return dir
        }
        let live = try scratch(pid: getpid())
        let dead = try scratch(pid: 2_000_000_000)
        let unmarked = try scratch(pid: nil)
        // Age the marker files too so only the owner check can save `live`.
        for dir in [live, dead] {
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent(".siphon-owner-pid").path)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        }
        ScratchDirectoryPolicy.purgeAbandoned(keeping: [], in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unmarked.path))
    }

    /// Real second process: its scratch survives the sweep while it runs and is purged after it exits.
    func testPurgeFollowsRealOwnerProcessLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }

        let dir = root.appendingPathComponent(ScratchDirectoryPolicy.directoryPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ScratchDirectoryPolicy.markOwner(dir, pid: child.processIdentifier)
        let old = Date(timeIntervalSinceNow: -3 * 24 * 3600)
        for url in [dir, dir.appendingPathComponent(".siphon-owner-pid")] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        ScratchDirectoryPolicy.purgeAbandoned(keeping: [], in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "Live owner process must protect its scratch")

        child.terminate()
        child.waitUntilExit()
        ScratchDirectoryPolicy.purgeAbandoned(keeping: [], in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "Exited owner's scratch must be purged")
    }

    func testHistoryDropsSignedThumbnailURLs() {
        XCTAssertNil(HistoricDownload.persistableThumbnailURL(URL(string: "https://cdn.example.com/t.jpg?token=abc")!))
        XCTAssertNil(HistoricDownload.persistableThumbnailURL(URL(string: "https://u:p@cdn.example.com/t.jpg")!))
        let plain = URL(string: "https://cdn.example.com/t.jpg?w=320")!
        XCTAssertEqual(HistoricDownload.persistableThumbnailURL(plain), plain)
    }

    func testPrimaryFileExistsOnDiskReflectsTheFileSystem() throws {
        let download = Download(url: "https://example.com/v", options: .default, title: "V")
        XCTAssertNil(download.primaryFileExistsOnDisk)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("presence_\(UUID().uuidString).mp4")
        download.filePaths = [file]
        XCTAssertEqual(download.primaryFileExistsOnDisk, false)

        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(download.primaryFileExistsOnDisk, true)
    }

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

    func testPrimaryFilePathComputedProperty() {
        let download = Download(url: "https://example.com/video", options: .default)

        XCTAssertNil(download.primaryFilePath, "Primary file path should be nil when filePaths is empty")

        let file1 = URL(fileURLWithPath: "/tmp/video.mp4")
        let file2 = URL(fileURLWithPath: "/tmp/video.srt")
        download.filePaths = [file1, file2]

        XCTAssertEqual(download.primaryFilePath, file1, "Primary file path should return the first item in filePaths")
    }

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
    }

    func testDisplayTitleFallback() {
        let dlSlug = Download(url: "https://www.example.com/videos/1140993/hot-beach-workout", options: .default)
        XCTAssertEqual(dlSlug.displayTitle, "Hot Beach Workout")

        let dlNumeric = Download(url: "https://www.example.com/videos/1140993/", options: .default)
        XCTAssertEqual(dlNumeric.displayTitle, "Example.com Video")

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
        let dl = Download(url: "https://www.example.com/videos/12345/summer-fun", options: .default, title: "___FETCHING___")
        let historic = HistoricDownload(download: dl)
        XCTAssertNotEqual(historic.title, "___FETCHING___")
        XCTAssertEqual(historic.title, "Summer Fun")
    }

    func testURLValidatorLowercasesScheme() throws {
        let url = try XCTUnwrap(URL(string: "https://vimeo.com/76979871"))
        XCTAssertEqual(DownloadURLValidator.validate("Https://vimeo.com/76979871"), .valid(url: url, original: url.absoluteString))
        XCTAssertEqual(DownloadURLValidator.extractURLs(from: "HTTP://example.com/V"), ["http://example.com/V"])
    }

    func testDefaultFromPreferencesAppliesSelectedCustomPreset() throws {
        let suiteName = "testDefaults_\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let preset = CustomPreset(configuration: CustomPresetConfiguration(name: "Lectures", videoCodec: .h264, audioCodec: .aac, videoResolution: .r720p, fileType: .mp4, subtitles: CustomPresetSubtitles(downloadSubtitles: true, subtitleLanguage: "embed:de", subtitleFormat: .vtt), sponsorBlock: true, splitChapters: true))
        testDefaults.set(try JSONEncoder().encode([preset]), forKey: UserDefaultsKeys.customPresets)
        testDefaults.set(preset.id.uuidString, forKey: UserDefaultsKeys.selectedCustomPresetId)

        let options = DownloadOptions.defaultFromPreferences(userDefaults: testDefaults)
        XCTAssertTrue(options.downloadSubtitles)
        XCTAssertTrue(options.embedSubtitles)
        XCTAssertEqual(options.subtitleLanguages, ["de"])
        XCTAssertEqual(options.subtitleFormat, .vtt)
        XCTAssertTrue(options.splitChapters)
        XCTAssertTrue(options.sponsorBlock)

        let plain = DownloadOptions.defaultFromPreferences(userDefaults: testDefaults, applyingSelectedCustomPreset: false)
        // Unset codec keys fall back to what Settings shows on a fresh install.
        XCTAssertEqual(plain.videoCodec, .h264)
        XCTAssertEqual(plain.audioCodec, .aac)
        XCTAssertFalse(plain.downloadSubtitles)
        XCTAssertFalse(plain.splitChapters)
        XCTAssertFalse(plain.sponsorBlock)
    }

    func testDownloadOptionsDefaultFromPreferences() {
        let suiteName = "testDefaults_\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let customDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customDir) }

        testDefaults.set(customDir.path, forKey: UserDefaultsKeys.defaultSaveFolder)
        testDefaults.set("mkv", forKey: UserDefaultsKeys.defaultFileType)
        testDefaults.set("r720p", forKey: UserDefaultsKeys.defaultVideoResolution)
        testDefaults.set("h265", forKey: UserDefaultsKeys.defaultVideoCodec)
        testDefaults.set("opus", forKey: UserDefaultsKeys.defaultAudioCodec)
        testDefaults.set(false, forKey: UserDefaultsKeys.embedThumbnail)
        testDefaults.set(false, forKey: UserDefaultsKeys.embedMetadata)
        testDefaults.set(true, forKey: UserDefaultsKeys.sponsorBlock)
        testDefaults.set("--geo-bypass", forKey: UserDefaultsKeys.defaultAdditionalArguments)
        testDefaults.set(ResolutionFallbackPolicy.allowHigher.rawValue, forKey: UserDefaultsKeys.resolutionFallbackPolicy)

        let options = DownloadOptions.defaultFromPreferences(userDefaults: testDefaults)

        XCTAssertEqual(options.saveFolder.path, customDir.path)
        XCTAssertEqual(options.fileType, .mkv)
        XCTAssertEqual(options.videoResolution, .r720p)
        XCTAssertEqual(options.videoCodec, .h265)
        XCTAssertEqual(options.audioCodec, .opus)
        XCTAssertFalse(options.embedThumbnail)
        XCTAssertFalse(options.embedMetadata)
        XCTAssertTrue(options.sponsorBlock)
        XCTAssertEqual(options.additionalArguments, "--geo-bypass")
        XCTAssertEqual(options.resolutionFallbackPolicy, .allowHigher)
    }

    func testAbandonedScratchSweepKeepsOwnedAndRecentDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scratch_sweep_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        func scratch(touched: Date, partTouched: Date? = nil) throws -> URL {
            let dir = root.appendingPathComponent(ScratchDirectoryPolicy.directoryPrefix + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let partTouched {
                let part = dir.appendingPathComponent("video.mp4.part")
                try Data([0]).write(to: part)
                try FileManager.default.setAttributes([.modificationDate: partTouched], ofItemAtPath: part.path)
            }
            try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: dir.path)
            return dir
        }
        let abandoned = try scratch(touched: old, partTouched: old)
        let paused = try scratch(touched: old)
        let stillWriting = try scratch(touched: old, partTouched: Date())
        let updatePackage = root.appendingPathComponent("Siphon_Update_\(UUID().uuidString).dmg")
        try Data([0]).write(to: updatePackage)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: updatePackage.path)
        let notScratch = root.appendingPathComponent("siphon_scratch_not-a-uuid")
        try FileManager.default.createDirectory(at: notScratch, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: notScratch.path)

        let removed = ScratchDirectoryPolicy.purgeAbandoned(keeping: [paused.lastPathComponent], in: root)

        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), [abandoned.lastPathComponent, updatePackage.lastPathComponent])
        for kept in [paused, stillWriting, notScratch] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
    }

    func testSiblingTempSweepRemovesOnlyOldSiphonTempsOncePerFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sibling_sweep_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        func file(_ name: String, touched: Date) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data([0]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: url.path)
            return url
        }
        let media = folder.appendingPathComponent("video.mp4")
        let current = ScratchDirectoryPolicy.siblingTempURL(beside: media, extension: "mp4")
        XCTAssertEqual(current.deletingLastPathComponent().path, folder.path)
        let abandoned = [
            try file(current.lastPathComponent, touched: old),
            try file("thumb_temp_\(UUID().uuidString).mkv", touched: old),
            try file(".converted-\(UUID().uuidString).m4a", touched: old),
            try file("decrypted_\(UUID().uuidString)_video.mp4", touched: old),
            try file(".\(UUID().uuidString).mp4.partial", touched: old),
        ]
        let kept = [
            try file(ScratchDirectoryPolicy.siblingTempURL(beside: media, extension: "mkv").lastPathComponent, touched: Date()),
            try file("thumb_temp_notes.mp4", touched: old),
            // An older build moved the original media here; its real name is unknown.
            try file("thumb_orig_\(UUID().uuidString).mp4", touched: old),
            try file("video.mp4", touched: old),
        ]

        let removed = ScratchDirectoryPolicy.purgeAbandonedSiblingTemps(in: folder)

        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), Set(abandoned.map(\.lastPathComponent)))
        for url in kept {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
        _ = try file(".siphon-tmp-\(UUID().uuidString).mp4", touched: old)
        XCTAssertEqual(ScratchDirectoryPolicy.purgeAbandonedSiblingTemps(in: folder), [], "One sweep per folder per launch")
    }
}
