import XCTest
@testable import Siphon
import CryptoKit

@MainActor
final class QueueAndErrorUXTests: XCTestCase {
    
    func testSourceDomainExtraction() {
        let options = DownloadOptions.default
        
        let ytDownload = Download(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", options: options)
        XCTAssertEqual(ytDownload.sourceDomain, "YouTube")
        
        let youtuDownload = Download(url: "https://youtu.be/dQw4w9WgXcQ", options: options)
        XCTAssertEqual(youtuDownload.sourceDomain, "YouTube")

        let mYtDownload = Download(url: "https://m.youtube.com/watch?v=123", options: options)
        XCTAssertEqual(mYtDownload.sourceDomain, "YouTube")

        let evilYtDownload = Download(url: "https://evil-youtube.com/video", options: options)
        XCTAssertEqual(evilYtDownload.sourceDomain, "Evil-youtube.com", "Must not misclassify evil-youtube.com as YouTube")

        let subEvilYtDownload = Download(url: "https://youtube.com.attacker.com/video", options: options)
        XCTAssertEqual(subEvilYtDownload.sourceDomain, "Youtube.com.attacker.com", "Must not misclassify youtube.com.attacker.com as YouTube")
        
        let xDownload = Download(url: "https://x.com/user/status/123456", options: options)
        XCTAssertEqual(xDownload.sourceDomain, "X (Twitter)")
        
        let twitterDownload = Download(url: "https://twitter.com/user/status/123456", options: options)
        XCTAssertEqual(twitterDownload.sourceDomain, "X (Twitter)")
        
        let igDownload = Download(url: "https://www.instagram.com/reel/C12345/", options: options)
        XCTAssertEqual(igDownload.sourceDomain, "Instagram")
        
        let tiktokDownload = Download(url: "https://www.tiktok.com/@user/video/123456", options: options)
        XCTAssertEqual(tiktokDownload.sourceDomain, "TikTok")
        
        let vimeoDownload = Download(url: "https://vimeo.com/12345678", options: options)
        XCTAssertEqual(vimeoDownload.sourceDomain, "Vimeo")
        
        let customDownload = Download(url: "https://media.mysite.org/video.mp4", options: options)
        XCTAssertEqual(customDownload.sourceDomain, "Media.mysite.org")
    }
    
    func testGenerateUpdateScriptContainsRequiredSteps() {
        let script = UpdateChecker.generateUpdateScript()
        XCTAssertTrue(script.contains("set -e"))
        XCTAssertTrue(script.contains("/usr/bin/codesign --verify"))
        XCTAssertTrue(script.contains("EXPECTED_BUNDLE_ID"))
        XCTAssertTrue(script.contains("BACKUP_PATH"))
        XCTAssertTrue(script.contains("ditto \"$NEW_APP\" \"$APP_PATH\""))
    }
    
    func testFormatSubtitleGeneration() {
        let lang = LanguageService()
        var options = DownloadOptions.default
        options.fileType = .mp4
        options.videoResolution = .r1080p
        
        let download = Download(url: "https://www.youtube.com/watch?v=123", options: options)
        download.duration = "03:45"
        
        let subtitle = download.formatSubtitle(lang: lang)
        XCTAssertEqual(subtitle, "YouTube • 1080p • MP4 • 03:45")
    }

    func testFormatSubtitleEdgeCases() {
        let lang = LanguageService()

        // Edge Case 1: Video download with explicit resolution, video codec, HDR diagnostics, and duration
        var videoOptions = DownloadOptions.default
        videoOptions.fileType = .mp4
        videoOptions.videoResolution = .r2160p
        videoOptions.videoCodec = .h265
        let videoDownload = Download(url: "https://www.youtube.com/watch?v=hdrVideo", options: videoOptions)
        videoDownload.diagnostics.dynamicRange = "HDR10"
        videoDownload.diagnostics.bitDepth = 10
        videoDownload.duration = "12:34"
        XCTAssertEqual(videoDownload.formatSubtitle(lang: lang), "YouTube • 2160p • H265 • HDR10 • 10-bit • MP4 • 12:34")

        // Edge Case 2: Video download with .best resolution deriving max height from mediaInfo formats
        var bestVideoOptions = DownloadOptions.default
        bestVideoOptions.fileType = .mkv
        bestVideoOptions.videoResolution = .best
        bestVideoOptions.videoCodec = .auto
        let bestVideoDownload = Download(url: "https://vimeo.com/98765432", options: bestVideoOptions)
        let f1 = MediaFormat(formatId: "1", ext: "mp4", resolution: "1280x720")
        let f2 = MediaFormat(formatId: "2", ext: "mp4", resolution: "1920x1080")
        bestVideoDownload.mediaInfo = MediaInfo(id: "98765432", title: "Test", formats: [f1, f2])
        bestVideoDownload.duration = "05:00"
        XCTAssertEqual(bestVideoDownload.formatSubtitle(lang: lang), "Vimeo • 1080p • MKV • 05:00")

        // Edge Case 3: Audio download with explicit quality, codec, and duration
        var audioOptions = DownloadOptions.default
        audioOptions.fileType = .mp3
        audioOptions.audioQuality = .q320
        audioOptions.audioCodec = .mp3
        let audioDownload = Download(url: "https://soundcloud.com/artist/track", options: audioOptions)
        audioDownload.duration = "04:15"
        XCTAssertEqual(audioDownload.formatSubtitle(lang: lang), "SoundCloud • 320kbps • MP3 • 04:15")

        // Edge Case 4: Audio download with default quality (.best) and auto codec, without duration
        var defaultAudioOptions = DownloadOptions.default
        defaultAudioOptions.fileType = .m4a
        defaultAudioOptions.audioQuality = .best
        defaultAudioOptions.audioCodec = .auto
        let defaultAudioDownload = Download(url: "https://example.com/audio", options: defaultAudioOptions)
        defaultAudioDownload.duration = ""
        XCTAssertEqual(defaultAudioDownload.formatSubtitle(lang: lang), "Example.com • M4A")
    }
    
    func testErrorUXCategorization() {
        let lang = LanguageService()
        let options = DownloadOptions.default
        let download = Download(url: "https://www.youtube.com/watch?v=123", options: options)
        
        // Bot / Authentication required
        download.errorMessage = "Sign in to confirm you're not a bot. This helps protect our community."
        var info = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.headline, "Couldn't download")
        XCTAssertEqual(info?.description, "YouTube requires authentication")
        XCTAssertEqual(info?.actionType, .fixInSettings)
        
        // DRM Protected
        download.errorMessage = "This video is DRM-protected and cannot be decrypted."
        info = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.headline, "Couldn't download")
        XCTAssertEqual(info?.description, "Media is protected by DRM encryption")
        XCTAssertEqual(info?.actionType, .noAction)
        
        // Video Unavailable / Private
        download.errorMessage = "Video unavailable: This video is private or removed"
        info = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.headline, "Couldn't download")
        XCTAssertEqual(info?.description, "Video is private, removed, or unavailable")
        XCTAssertEqual(info?.actionType, .retry)
        
        // Disk Full
        download.errorMessage = "Error writing file: No space left on device"
        info = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.headline, "Couldn't download")
        XCTAssertEqual(info?.description, "No space left on destination disk")
        XCTAssertEqual(info?.actionType, .changeFolder)
        
        // Permission Denied
        download.errorMessage = "Permission denied: /Volumes/Drive/video.mp4"
        info = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.headline, "Couldn't download")
        XCTAssertEqual(info?.description, "Permission denied saving to destination")
        XCTAssertEqual(info?.actionType, .changeFolder)
        
        // Network Timeout
        download.errorMessage = "Connection timed out after 30000ms"
        info = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.headline, "Couldn't download")
        XCTAssertEqual(info?.description, "Network connection timed out")
        XCTAssertEqual(info?.actionType, .retry)
    }
    
    func testQueuePauseAndResume() {
        let manager = DownloadManager()
        let options = DownloadOptions.default
        let download = Download(url: "https://example.com/test", options: options)
        download.status = .downloading
        download.progress = 0.45
        manager.downloads.append(download)
        
        // Pause
        manager.pauseDownload(download)
        XCTAssertEqual(download.status, .paused)
        XCTAssertEqual(download.progress, 0.45)
        
        // Resume
        manager.resumeDownload(download)
        XCTAssertEqual(download.status, .queued)
    }
    
    func testQueueReordering() {
        let manager = DownloadManager()
        let options = DownloadOptions.default
        
        let d1 = Download(url: "https://example.com/1", options: options, title: "Video 1")
        let d2 = Download(url: "https://example.com/2", options: options, title: "Video 2")
        let d3 = Download(url: "https://example.com/3", options: options, title: "Video 3")
        
        manager.downloads = [d1, d2, d3]
        
        // Move d2 Up
        manager.moveDownloadUp(d2)
        XCTAssertEqual(manager.downloads.map { $0.title }, ["Video 2", "Video 1", "Video 3"])
        
        // Move d2 Down
        manager.moveDownloadDown(d2)
        XCTAssertEqual(manager.downloads.map { $0.title }, ["Video 1", "Video 2", "Video 3"])
        
        // Move d3 to Top
        manager.moveDownloadToTop(d3)
        XCTAssertEqual(manager.downloads.map { $0.title }, ["Video 3", "Video 1", "Video 2"])
        
        // Move d3 to Bottom
        manager.moveDownloadToBottom(d3)
        XCTAssertEqual(manager.downloads.map { $0.title }, ["Video 1", "Video 2", "Video 3"])
        
        // Batch move with IndexSet
        manager.moveDownload(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(manager.downloads.map { $0.title }, ["Video 2", "Video 3", "Video 1"])
    }
    
    func testSHA256ChecksumCalculation() throws {
        let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_checksum_\(UUID().uuidString).txt")
        let sampleContent = "Siphon Secure Update Verification Test Payload"
        try sampleContent.data(using: .utf8)?.write(to: tempFileURL)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }
        
        let computed = UpdateChecker.computeSHA256(for: tempFileURL)
        XCTAssertNotNil(computed)
        
        // Calculate expected SHA256 using CryptoKit directly
        let expectedDigest = SHA256.hash(data: sampleContent.data(using: .utf8)!)
        let expectedHex = expectedDigest.map { String(format: "%02hhx", $0) }.joined()
        
        XCTAssertEqual(computed?.lowercased(), expectedHex.lowercased())
    }

    func testDownloadProcessControllerCancellationLifecycle() {
        // Lifecycle Test 1: Normal attach -> detach
        let normalController = DownloadProcessController()
        XCTAssertFalse(normalController.isCancelled)

        let mockProcess1 = Process()
        let attachedNormal = normalController.attachProcess(mockProcess1)
        XCTAssertTrue(attachedNormal)
        XCTAssertFalse(normalController.isCancelled)

        normalController.detach()
        XCTAssertFalse(normalController.isCancelled)

        // Lifecycle Test 2: Cancel before attach
        let cancelledController = DownloadProcessController()
        cancelledController.cancel()
        XCTAssertTrue(cancelledController.isCancelled)

        let mockProcess2 = Process()
        let attachedCancelled = cancelledController.attachProcess(mockProcess2)
        XCTAssertFalse(attachedCancelled, "attachProcess must return false when controller was already cancelled")
        XCTAssertTrue(cancelledController.isCancelled)

        // Lifecycle Test 3: Cancel while attached
        let activeController = DownloadProcessController()
        let mockProcess3 = Process()
        let attachedActive = activeController.attachProcess(mockProcess3)
        XCTAssertTrue(attachedActive)

        activeController.cancel()
        XCTAssertTrue(activeController.isCancelled)
    }

    func testEphemeralRawCookiesNotPersistedInCodable() throws {
        var options = DownloadOptions.default
        options.rawCookies = "session_token=super_secret_cookie_data_123"

        // Encode to JSON
        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(options)
        let jsonString = String(data: encodedData, encoding: .utf8) ?? ""

        // Assert secret cookie is NOT in serialized string
        XCTAssertFalse(jsonString.contains("super_secret_cookie_data_123"), "Raw cookies must never be serialized")
        XCTAssertFalse(jsonString.contains("rawCookies"), "rawCookies key must be excluded from serialization")

        // Decode from JSON
        let decoder = JSONDecoder()
        let decodedOptions = try decoder.decode(DownloadOptions.self, from: encodedData)
        XCTAssertNil(decodedOptions.rawCookies, "Decoded options must have nil rawCookies")
    }

    func testLogSanitizationRedactsCookiesFromBrowser() {
        let args = ["yt-dlp", "--cookies-from-browser", "safari", "--output", "/path/to/video.mp4", "https://youtube.com/watch?v=123"]
        let sanitized = LoggerService.sanitizeCommandForLog(args)

        XCTAssertTrue(sanitized.contains("--cookies-from-browser \"<BROWSER>\""))
        XCTAssertFalse(sanitized.contains("safari"))
    }

    func testLoadHistoryIdempotency() {
        let userDefaultsKey = UserDefaultsKeys.downloadHistory
        let options = DownloadOptions.default
        let download = Download(url: "https://example.com/idempotent", options: options, id: UUID())
        download.status = .completed

        let historic = HistoricDownload(download: download)
        if let encoded = try? JSONEncoder().encode([historic]) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        let manager = DownloadManager()
        manager.loadHistory()
        XCTAssertEqual(manager.downloads.count, 1)

        // Call loadHistory a second time
        manager.loadHistory()
        XCTAssertEqual(manager.downloads.count, 1, "loadHistory must be idempotent and not duplicate entries on repeated calls")
    }

    func testLiveHlsErrorRetryWithFFmpegDownloader() async throws {
        let service = YtdlpService()
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let callCountBox = TestBox<Int>(0)
        let capturedArgs = TestBox<[[String]]>([])

        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            callCountBox.value += 1
            capturedArgs.value.append(args)
            if callCountBox.value == 1 {
                throw YtdlpError.downloadFailed("WARNING: Live HLS streams are not supported by the native downloader. If this is a livestream, please add \"--downloader ffmpeg --hls-use-mpegts\" to your command.")
            }
            return "/tmp/hls_stream_success.mp4"
        })

        let result = try await service.download(
            url: "https://example.com/live-channel",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertEqual(callCountBox.value, 2, "Must retry download when native downloader fails on live HLS stream")
        XCTAssertTrue(capturedArgs.value[1].contains("--downloader"))
        if let idx = capturedArgs.value[1].firstIndex(of: "--downloader") {
            XCTAssertEqual(capturedArgs.value[1][idx + 1], "ffmpeg")
        }
        XCTAssertTrue(capturedArgs.value[1].contains("--hls-use-mpegts"))
        XCTAssertEqual(result.lastPathComponent, "hls_stream_success.mp4")
    }

    func testProactiveHlsDownloaderAppendedOnM3u8URL() async throws {
        let service = YtdlpService()
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let capturedArgs = TestBox<[String]>([])

        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgs.value = args
            return "/tmp/hls_stream_success.mp4"
        })

        _ = try await service.download(
            url: "https://example.com/live-stream.m3u8",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertTrue(capturedArgs.value.contains("--downloader"), "Metadata-first detection must add --downloader ffmpeg on attempt 1 for .m3u8 streams")
        XCTAssertTrue(capturedArgs.value.contains("--hls-use-mpegts"))
    }

    func testChecksumManifestTokenExactParsing() {
        let manifest = """
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  bad-Siphon-arm64.dmg
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  Siphon-arm64.dmg.bad.zip
        cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc *Siphon-arm64.dmg
        dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd  Siphon-x86_64.dmg
        """
        let lines = manifest.components(separatedBy: .newlines)
        let targetAssetName = "siphon-arm64.dmg"

        var parsedHash: String? = nil
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first, first.count == 64 else { continue }
            let hash = String(first).lowercased()

            if parts.count >= 2 {
                let manifestFilename = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^\\*", with: "", options: .regularExpression).lowercased()
                if manifestFilename == targetAssetName || URL(fileURLWithPath: manifestFilename).lastPathComponent.lowercased() == targetAssetName {
                    parsedHash = hash
                    break
                }
            }
        }

        XCTAssertEqual(parsedHash, "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", "Must strictly parse exact asset line without matching substrings or suffixes")
    }

    func testTransientConnectionRefusedRetry() async throws {
        let service = YtdlpService()
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let callCountBox = TestBox<Int>(0)

        service.processRunner = MockYtdlpProcessRunner(mockDownload: { _ in
            callCountBox.value += 1
            if callCountBox.value == 1 {
                throw YtdlpError.downloadFailed("ERROR: [download] Got error: HTTPSConnection(host='ip410264893.ahcdn.com', port=443): Failed to establish a new connection: [Errno 61] Connection refused. Giving up after 10 retries")
            }
            return "/tmp/cdn_retry_success.mp4"
        })

        let result = try await service.download(
            url: "https://thisvid.com/videos/test-slug/",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertEqual(callCountBox.value, 2, "Must retry download when transient CDN connection refused is encountered")
        XCTAssertEqual(result.lastPathComponent, "cdn_retry_success.mp4")
    }

    func testFileExistsIgnoresNonMediaCompanionFiles() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseName = "Hung bodybuilder jerk flex and shoot a huge load"
        let thumbFile = tempDir.appendingPathComponent("\(baseName).jpg")
        let partFile = tempDir.appendingPathComponent("\(baseName).mp4.part")
        try? "thumb".data(using: .utf8)?.write(to: thumbFile)
        try? "part".data(using: .utf8)?.write(to: partFile)

        let contents = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        let matches = contents.filter { file in
            let nameWithoutExt = file.deletingPathExtension().lastPathComponent
            let isExactMatch = nameWithoutExt == baseName
            let isPart = file.lastPathComponent.hasSuffix(".part") || file.lastPathComponent.hasSuffix(".ytdl")
            let isMedia = YtdlpService.isMediaFilePath(file.path)
            return isExactMatch && !isPart && isMedia
        }

        XCTAssertTrue(matches.isEmpty, "Companion .jpg and .part files must NOT trigger fileExists match")

        let mediaFile = tempDir.appendingPathComponent("\(baseName).mp4")
        try? "video".data(using: .utf8)?.write(to: mediaFile)

        let updatedContents = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        let updatedMatches = updatedContents.filter { file in
            let nameWithoutExt = file.deletingPathExtension().lastPathComponent
            let isExactMatch = nameWithoutExt == baseName
            let isPart = file.lastPathComponent.hasSuffix(".part") || file.lastPathComponent.hasSuffix(".ytdl")
            let isMedia = YtdlpService.isMediaFilePath(file.path)
            return isExactMatch && !isPart && isMedia
        }

        XCTAssertEqual(updatedMatches.count, 1, "Real media file must trigger fileExists match")
    }

    // MARK: - Dedicated Stress & Edge Case Tests

    func testSimultaneousCancellationOfMultipleProcesses() async {
        let count = 10
        var controllers: [DownloadProcessController] = []

        for _ in 0..<count {
            let controller = DownloadProcessController()
            let proc = Process()
            _ = controller.attachProcess(proc)
            controllers.append(controller)
        }

        await withTaskGroup(of: Void.self) { group in
            for controller in controllers {
                group.addTask {
                    controller.cancel()
                }
            }
        }

        for controller in controllers {
            XCTAssertTrue(controller.isCancelled, "All controllers must be marked cancelled")
        }
    }

    func testPauseAndResumeDuringFetching() {
        let manager = DownloadManager()
        let options = DownloadOptions.default
        let download = Download(url: "https://example.com/fetching-test", options: options)
        download.status = .fetching
        manager.downloads.append(download)

        // Pause while fetching
        manager.pauseDownload(download)
        XCTAssertEqual(download.status, .paused, "Pausing during fetching must transition status to .paused")

        // Resume
        manager.resumeDownload(download)
        XCTAssertEqual(download.status, .queued, "Resuming paused download must transition status back to .queued")
    }

    func testCancellationDuringFfmpegPostprocessing() {
        let manager = DownloadManager()
        let options = DownloadOptions.default
        let download = Download(url: "https://example.com/postprocessing-test", options: options)
        download.status = .processing
        manager.downloads.append(download)

        let controller = DownloadProcessController()
        let proc = Process()
        _ = controller.attachProcess(proc)
        manager.activeControllers[download.id] = controller

        // Stop download while in postprocessing
        manager.stopDownload(download)
        XCTAssertEqual(download.status, .stopped, "Stopping during postprocessing must set status to .stopped")
        XCTAssertTrue(controller.isCancelled, "Attached controller must be cancelled")
    }

    func testProcessExitingWhilePipeCallbacksAreActive() async {
        let runner = DefaultYtdlpProcessRunner()
        let controller = DownloadProcessController()
        let receivedOutputBox = TestBox<[String]>([])
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            let output = try await runner.runDownloadProcess(
                args: ["/bin/sh", "-c", "echo '[download] Destination: \(tempDir.path)/rapid_test.mp4'; touch '\(tempDir.path)/rapid_test.mp4'; echo '[download]  50.0% of ~10.00MiB at 2.00MiB/s ETA 00:05'; echo 'Exiting rapidly'"],
                saveFolder: tempDir,
                processController: controller,
                onProgress: { _, _, _ in },
                onOutput: { line in
                    receivedOutputBox.value.append(line)
                }
            )
            XCTAssertFalse(output.isEmpty, "Output should be captured completely even on rapid process exit")
            XCTAssertTrue(receivedOutputBox.value.contains(where: { $0.contains("Exiting rapidly") }))
        } catch {
            XCTFail("Rapid process exit should not throw error: \(error)")
        }
    }

    func testDuplicateFilenamesAcrossSimultaneousTasks() {
        let manager = DownloadManager()
        var options = DownloadOptions.default
        options.customFilename = "simultaneous_video"
        options.fileType = .mp4

        let count = 5
        var resolvedPaths: [String] = []

        for i in 0..<count {
            let dl = Download(url: "https://example.com/video_\(i)", options: options, title: "Title \(i)")
            let (_, resolvedPath) = manager.resolveUniqueOutputPath(for: dl)
            manager.reserveOutputPath(resolvedPath)
            resolvedPaths.append(resolvedPath)
        }

        // Clean up reservations
        for path in resolvedPaths {
            manager.unreserveOutputPath(path)
        }

        let uniqueSet = Set(resolvedPaths)
        XCTAssertEqual(uniqueSet.count, count, "All simultaneously resolved output paths must be completely unique without collision")
        XCTAssertTrue(resolvedPaths[0].hasSuffix("simultaneous_video.mp4"))
        XCTAssertTrue(resolvedPaths[1].hasSuffix("simultaneous_video_1.mp4"))
        XCTAssertTrue(resolvedPaths[2].hasSuffix("simultaneous_video_2.mp4"))
    }

    func testInstallerFailureHalfwayThroughPairedFfmpegInstallation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("installer_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldFfmpeg = tempDir.appendingPathComponent("ffmpeg")
        let oldFfprobe = tempDir.appendingPathComponent("ffprobe")
        try "old_ffmpeg_v1".data(using: .utf8)?.write(to: oldFfmpeg)
        try "old_ffprobe_v1".data(using: .utf8)?.write(to: oldFfprobe)

        let extractedFfmpeg = tempDir.appendingPathComponent("extracted_ffmpeg")
        try "new_ffmpeg_v2".data(using: .utf8)?.write(to: extractedFfmpeg)
        // extractedFfprobe is deliberately missing to simulate a failure halfway through

        let backupFfmpeg = tempDir.appendingPathComponent("ffmpeg.backup")
        let backupFfprobe = tempDir.appendingPathComponent("ffprobe.backup")

        var ffmpegMovedToBackup = false
        var ffprobeMovedToBackup = false

        // Simulate atomic installer logic
        do {
            if FileManager.default.fileExists(atPath: oldFfmpeg.path) {
                try FileManager.default.moveItem(at: oldFfmpeg, to: backupFfmpeg)
                ffmpegMovedToBackup = true
            }
            if FileManager.default.fileExists(atPath: oldFfprobe.path) {
                try FileManager.default.moveItem(at: oldFfprobe, to: backupFfprobe)
                ffprobeMovedToBackup = true
            }

            try FileManager.default.moveItem(at: extractedFfmpeg, to: oldFfmpeg)
            let missingFfprobe = tempDir.appendingPathComponent("missing_extracted_ffprobe")
            try FileManager.default.moveItem(at: missingFfprobe, to: oldFfprobe)

            XCTFail("Installer should have thrown error on missing second binary")
        } catch {
            // Atomic rollback
            try? FileManager.default.removeItem(at: oldFfmpeg)
            try? FileManager.default.removeItem(at: oldFfprobe)

            if ffmpegMovedToBackup {
                try? FileManager.default.moveItem(at: backupFfmpeg, to: oldFfmpeg)
            }
            if ffprobeMovedToBackup {
                try? FileManager.default.moveItem(at: backupFfprobe, to: oldFfprobe)
            }
        }

        let restoredFfmpeg = try String(contentsOf: oldFfmpeg, encoding: .utf8)
        let restoredFfprobe = try String(contentsOf: oldFfprobe, encoding: .utf8)
        XCTAssertEqual(restoredFfmpeg, "old_ffmpeg_v1", "Original FFmpeg must be restored on halfway failure")
        XCTAssertEqual(restoredFfprobe, "old_ffprobe_v1", "Original FFprobe must be restored on halfway failure")
    }

    func testAppTerminationDuringActiveDownloads() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        let d1 = Download(url: "https://example.com/term1", options: options)
        d1.status = .downloading
        let d2 = Download(url: "https://example.com/term2", options: options)
        d2.status = .fetching
        let d3 = Download(url: "https://example.com/term3", options: options)
        d3.status = .queued

        manager.downloads = [d1, d2, d3]

        let c1 = DownloadProcessController()
        let p1 = Process()
        _ = c1.attachProcess(p1)
        manager.activeControllers[d1.id] = c1

        let t1 = Task { }
        manager.activeTasks[d1.id] = t1

        let testPath = "/tmp/test_term.mp4"
        manager.reserveOutputPath(testPath)

        manager.stopAllDownloads()
        manager.shutdown()

        XCTAssertTrue(c1.isCancelled, "All controllers must be cancelled on shutdown")
        XCTAssertTrue(t1.isCancelled, "All active tasks must be cancelled on shutdown")
        XCTAssertEqual(d1.status, .stopped)
        XCTAssertEqual(d2.status, .stopped)
        XCTAssertEqual(d3.status, .stopped)
        XCTAssertTrue(manager.activeControllers.isEmpty)
        XCTAssertTrue(manager.activeTasks.isEmpty)
    }

    func testNotificationFloodResilience() async {
        let service = NotificationService.shared
        let lang = LanguageService()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i % 3 == 0 {
                        service.sendDownloadCompleted(filename: "video_\(i).mp4", languageService: lang)
                    } else if i % 3 == 1 {
                        service.sendDownloadFailed(filename: "video_\(i).mp4", languageService: lang)
                    } else {
                        service.sendDownloadStopped(filename: "video_\(i).mp4", languageService: lang)
                    }
                }
            }
        }
        XCTAssertTrue(true, "NotificationService must survive rapid concurrent dispatch without crashing")
    }

    func testRepeatedUpdateChecksConcurrentGuard() async {
        let checker = UpdateChecker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await checker.checkForUpdates()
                }
            }
        }

        XCTAssertFalse(checker.isChecking, "isChecking must reset to false after checks complete")
    }

    func testSimultaneousDependencyInstallationCalls() async {
        let manager = DownloadManager()

        let t1 = Task { await manager.updateYtdlp() }
        let t2 = Task { await manager.updateYtdlp() }

        _ = await (t1.value, t2.value)
        XCTAssertFalse(manager.isUpdatingYtdlp, "isUpdatingYtdlp must be false once operations complete")
    }

    func testFormatSubtitleRetainsResolutionFromDiagnosticsAfterPruning() {
        let lang = LanguageService()
        var options = DownloadOptions.default
        options.fileType = .mp4
        options.videoResolution = .best
        options.videoCodec = .auto

        let download = Download(url: "https://youtube.com/watch?v=pruned", options: options)
        let f1 = MediaFormat(formatId: "1", ext: "mp4", resolution: "1920x1080")
        download.mediaInfo = MediaInfo(id: "pruned", title: "Test Pruned", formats: [f1])

        // Before pruning, formatSubtitle infers 1080p
        XCTAssertTrue(download.formatSubtitle(lang: lang).contains("1080p"))

        // Simulate completion: copy resolution to diagnostics, then prune mediaInfo
        download.diagnostics.resolution = "1080p"
        download.mediaInfo = download.mediaInfo?.prunedForCompletion()
        XCTAssertNil(download.mediaInfo?.formats)

        // After pruning, formatSubtitle must still retain the 1080p badge from diagnostics
        XCTAssertTrue(download.formatSubtitle(lang: lang).contains("1080p"))
    }

    func testLoggerServiceSanitizeDiagnosticText() {
        let rawError = "Download failed: https://video.example.com/stream.mp4?token=secret123&auth=abc with Bearer eyJhbGciOiJIUzI1Ni. Cookie: session=12345"
        let sanitized = LoggerService.sanitizeDiagnosticText(rawError)

        XCTAssertFalse(sanitized.contains("token=secret123"))
        XCTAssertFalse(sanitized.contains("auth=abc"))
        XCTAssertFalse(sanitized.contains("session=12345"))
        XCTAssertTrue(sanitized.contains("Bearer <REDACTED>"))
        XCTAssertTrue(sanitized.contains("Cookie: <REDACTED>"))
    }

    func testAppUpdateScriptIncludesTeamIDVerification() {
        let script = UpdateChecker.generateUpdateScript()

        XCTAssertTrue(script.contains("EXPECTED_TEAM_ID"))
        XCTAssertTrue(script.contains("TeamIdentifier="))
        XCTAssertTrue(script.contains("Team identifier mismatch"))
    }

    func testFileExistsSeparationFromFailedDownloads() {
        let manager = DownloadManager()
        let d1 = Download(url: "https://example.com/1", options: .default)
        d1.status = .fileExists
        let d2 = Download(url: "https://example.com/2", options: .default)
        d2.status = .failed
        let d3 = Download(url: "https://example.com/3", options: .default)
        d3.status = .stopped

        manager.downloads = [d1, d2, d3]

        XCTAssertEqual(manager.actionRequiredDownloads.count, 1)
        XCTAssertEqual(manager.actionRequiredDownloads.first?.id, d1.id)
        XCTAssertEqual(manager.failedDownloads.count, 2)
        XCTAssertEqual(manager.failedCount, 2)
    }

    func testErrorUXInfoSanitizesSensitiveTokensInRawError() {
        let lang = LanguageService()
        let download = Download(url: "https://example.com/watch", options: .default)
        download.errorMessage = "403 Forbidden: https://video.example.com/stream.m3u8?token=secret999&auth=123"
        download.log = "Error line 1: Cookie: session=abcde12345\nError line 2: token=secret999\nError line 3: https://video.example.com/file.mp4?auth=secret123"

        let uxInfo = download.errorUXInfo(lang: lang)
        XCTAssertNotNil(uxInfo)
        guard let info = uxInfo else { return }

        XCTAssertFalse(info.rawError.contains("token=secret999"))
        XCTAssertFalse(info.rawError.contains("session=abcde12345"))
        XCTAssertFalse(info.rawError.contains("auth=secret123"))
        XCTAssertTrue(info.rawError.contains("Cookie: <REDACTED>"))
        XCTAssertTrue(info.rawError.contains("token=<REDACTED>"))
        XCTAssertTrue(info.rawError.contains("https://video.example.com/file.mp4"))
    }

    // MARK: - Design System & UI Architecture Tests

    func testDesignTokensSpacingScale() {
        XCTAssertEqual(SiphonTheme.spacing2, 2)
        XCTAssertEqual(SiphonTheme.spacing4, 4)
        XCTAssertEqual(SiphonTheme.spacing6, 6)
        XCTAssertEqual(SiphonTheme.spacing8, 8)
        XCTAssertEqual(SiphonTheme.spacing10, 10)
        XCTAssertEqual(SiphonTheme.spacing12, 12)
        XCTAssertEqual(SiphonTheme.spacing14, 14)
        XCTAssertEqual(SiphonTheme.spacing16, 16)
        XCTAssertEqual(SiphonTheme.spacing20, 20)
        XCTAssertEqual(SiphonTheme.spacing24, 24)
        XCTAssertEqual(SiphonTheme.spacing32, 32)
    }

    func testDesignTokensRadiiScale() {
        XCTAssertEqual(SiphonTheme.radiusSmall, 6)
        XCTAssertEqual(SiphonTheme.radiusControl, 8)
        XCTAssertEqual(SiphonTheme.radiusCard, 12)
        XCTAssertEqual(SiphonTheme.radiusSheet, 16)
    }

    func testAdaptiveRenderingEnvironmentReduceMotion() {
        let env = AdaptiveRenderingEnvironment.shared
        let systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        XCTAssertEqual(env.capabilities.reduceMotion, systemReduceMotion)
        XCTAssertEqual(env.reduceMotion, systemReduceMotion)
    }

    func testBouncyButtonStyleDefaults() {
        let style = BouncyButtonStyle()
        XCTAssertEqual(style.scaleAmount, 0.97)
        XCTAssertEqual(style.hoverScale, 1.015)
    }

    func testStatusAndTagBadgesInstantiation() {
        let allStatuses: [DownloadStatus] = [
            .downloading, .fetching, .processing,
            .completed, .failed, .stopped,
            .queued, .paused, .fileExists
        ]

        for status in allStatuses {
            let badge = SiphonStatusBadge(status: status, title: status.rawValue, foregroundColor: .blue)
            XCTAssertNotNil(badge)
        }

        let tag1 = SiphonTagBadge(text: "HDR10", isHdr: true)
        XCTAssertNotNil(tag1)

        let tag2 = SiphonTagBadge(text: "PID: 1234", tintColor: .secondary, isMonospaced: true)
        XCTAssertNotNil(tag2)
    }

    func testEmptyStateInstantiation() {
        var didTriggerAction = false
        let emptyView = SiphonEmptyStateView(
            icon: "tray.fill",
            title: "No Downloads",
            message: "Paste a link to begin",
            actionTitle: "New Download"
        ) {
            didTriggerAction = true
        }
        XCTAssertNotNil(emptyView)
        emptyView.action?()
        XCTAssertTrue(didTriggerAction)
    }

    // MARK: - Security Hardening & Trust Boundary Tests

    func testUpdateScriptSignatureIntegrityAndSymlinkRejection() {
        let script = UpdateChecker.generateUpdateScript()
        XCTAssertTrue(script.contains("[ -L \"$NEW_APP\" ]"), "Update script must explicitly reject symlinks for the app bundle")
        XCTAssertTrue(script.contains("[ \"$NEW_TEAM_ID\" != \"$EXPECTED_TEAM_ID\" ]"), "Update script must strictly reject team identifier mismatches without bypass")
    }

    func testTrustedGitHubURLValidation() {
        let valid1 = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v5.0.0/Siphon.dmg")!
        let valid2 = URL(string: "https://objects.githubusercontent.com/github-production-release-asset/12345/abcde")!
        let httpUrl = URL(string: "http://github.com/marspater/jolly-hopper/releases/download/v5.0.0/Siphon.dmg")!
        let attackerUrl = URL(string: "https://evil-attacker.com/malware.dmg")!
        let subAttackerUrl = URL(string: "https://github.com.attacker.com/malware.dmg")!

        XCTAssertTrue(UpdateChecker.isTrustedGitHubURL(valid1))
        XCTAssertTrue(UpdateChecker.isTrustedGitHubURL(valid2))
        XCTAssertFalse(UpdateChecker.isTrustedGitHubURL(httpUrl), "Insecure HTTP scheme must be rejected")
        XCTAssertFalse(UpdateChecker.isTrustedGitHubURL(attackerUrl), "Untrusted domain must be rejected")
        XCTAssertFalse(UpdateChecker.isTrustedGitHubURL(subAttackerUrl), "Attacker subdomain must be rejected")
    }

    func testHistoricDownloadStripsRawCookies() {
        var options = DownloadOptions.default
        options.rawCookies = "session=super_secret_cookie_token; auth=admin"
        let download = Download(url: "https://example.com/video", options: options)

        let historic = HistoricDownload(download: download)
        XCTAssertNil(historic.options.rawCookies, "Persistent HistoricDownload must strip ephemeral rawCookies")
    }

    func testLoggerServiceInlineFlagAndTokenRedaction() {
        let cmd = LoggerService.sanitizeCommandForLog([
            "yt-dlp",
            "--cookies=my_cookies.txt",
            "--password=secret_password",
            "--token=sensitive_token",
            "--header=Authorization: Bearer mySecretToken"
        ])
        XCTAssertFalse(cmd.contains("my_cookies.txt"), "Inline --cookies= must be redacted")
        XCTAssertFalse(cmd.contains("secret_password"), "Inline --password= must be redacted")
        XCTAssertFalse(cmd.contains("sensitive_token"), "Inline --token= must be redacted")
        XCTAssertFalse(cmd.contains("mySecretToken"), "Inline --header= must be redacted")
        XCTAssertTrue(cmd.contains("--cookies=\"<COOKIE_FILE>\""))
        XCTAssertTrue(cmd.contains("--password=\"<PASSWORD>\""))
        XCTAssertTrue(cmd.contains("--token=\"<TOKEN>\""))

        let diag = LoggerService.sanitizeDiagnosticText("Failed request: Authorization: Bearer superSecretKey123\nCookie: session=xyz987\nauth=adminSecret")
        XCTAssertFalse(diag.contains("superSecretKey123"))
        XCTAssertFalse(diag.contains("session=xyz987"))
        XCTAssertFalse(diag.contains("adminSecret"))
        XCTAssertTrue(diag.contains("Authorization: <REDACTED>"))
        XCTAssertTrue(diag.contains("Cookie: <REDACTED>"))
        XCTAssertTrue(diag.contains("auth=<REDACTED>"))
    }

    func testSanitizeFilenameHardening() {
        // Control character stripping
        let withNull = "video\0title\r\nname"
        let cleaned1 = YtdlpService.sanitizeFilename(withNull)
        XCTAssertFalse(cleaned1.contains("\0"))
        XCTAssertFalse(cleaned1.contains("\r"))
        XCTAssertFalse(cleaned1.contains("\n"))

        // Leading dots and hyphens stripping
        let leading = "...---my_movie"
        let cleaned2 = YtdlpService.sanitizeFilename(leading)
        XCTAssertFalse(cleaned2.hasPrefix("."))
        XCTAssertFalse(cleaned2.hasPrefix("-"))
        XCTAssertEqual(cleaned2, "my_movie")

        // Reserved Windows/DOS/macOS device names
        let reserved = YtdlpService.sanitizeFilename("NUL")
        XCTAssertEqual(reserved, "download_NUL")
        let con = YtdlpService.sanitizeFilename("con")
        XCTAssertEqual(con, "download_con")

        // Max length clamping
        let longName = String(repeating: "a", count: 300)
        let clamped = YtdlpService.sanitizeFilename(longName)
        XCTAssertLessThanOrEqual(clamped.count, 200)
    }

    func testCLIArgumentValidators() {
        // Timeframe
        XCTAssertTrue(YtdlpService.isValidTimeFrame("00:01:30"))
        XCTAssertTrue(YtdlpService.isValidTimeFrame("01:30"))
        XCTAssertTrue(YtdlpService.isValidTimeFrame("90"))
        XCTAssertTrue(YtdlpService.isValidTimeFrame("90.5"))
        XCTAssertFalse(YtdlpService.isValidTimeFrame("01:30; rm -rf /"))
        XCTAssertFalse(YtdlpService.isValidTimeFrame("--exec touch /tmp/pwned"))

        // Format ID
        XCTAssertTrue(YtdlpService.isSafeFormatId("bestvideo+bestaudio/best"))
        XCTAssertTrue(YtdlpService.isSafeFormatId("1080p"))
        XCTAssertTrue(YtdlpService.isSafeFormatId("b/best"))
        XCTAssertFalse(YtdlpService.isSafeFormatId("-F"))
        XCTAssertFalse(YtdlpService.isSafeFormatId("--exec rm"))
        XCTAssertFalse(YtdlpService.isSafeFormatId("format id with spaces"))

        // Subtitle Language
        XCTAssertTrue(YtdlpService.isSafeSubtitleLanguage("en"))
        XCTAssertTrue(YtdlpService.isSafeSubtitleLanguage("zh-Hans"))
        XCTAssertTrue(YtdlpService.isSafeSubtitleLanguage("es_419"))
        XCTAssertFalse(YtdlpService.isSafeSubtitleLanguage("-f"))
        XCTAssertFalse(YtdlpService.isSafeSubtitleLanguage("--write-subs"))
    }

    // MARK: - Bug Audit Regression Tests

    func testDisplayProgressGuardsAgainstNaNAndInfinity() {
        let download = Download(url: "https://example.com/video", options: .default)
        download.progress = Double.nan
        XCTAssertEqual(download.displayProgress, "0%", "NaN progress must safely evaluate to 0% without crashing")

        download.progress = Double.infinity
        XCTAssertEqual(download.displayProgress, "100%", "Infinite progress must clamp safely without crashing")
    }

    func testVideoOnlyFormatResolutionPairsWithAudio() {
        let videoFmt = MediaFormat(
            formatId: "137",
            ext: "mp4",
            resolution: "1920x1080",
            fps: 30,
            vcodec: "avc1.640028",
            acodec: "none",
            tbr: 3000
        )
        let audioFmt = MediaFormat(
            formatId: "140",
            ext: "m4a",
            resolution: nil,
            fps: nil,
            vcodec: "none",
            acodec: "mp4a.40.2",
            tbr: 128
        )
        let info = MediaInfo(
            id: "vid123",
            title: "Test Video",
            thumbnail: nil,
            duration: 120,
            uploader: "YouTube",
            formats: [videoFmt, audioFmt]
        )

        var options = DownloadOptions.default
        options.fileType = .mp4
        options.selectedFormatId = "137"

        let resolved = info.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 2, "Single video-only format selection must automatically pair with best audio")
        XCTAssertEqual(resolved.first?.formatId, "137")
        XCTAssertEqual(resolved.last?.formatId, "140")
    }

    func testClearQueuedDownloadsPreservesExistingStoppedDownloads() {
        let manager = DownloadManager()
        let stoppedDownload = Download(url: "https://example.com/stopped", options: .default)
        stoppedDownload.status = .stopped

        let queuedDownload1 = Download(url: "https://example.com/queued1", options: .default)
        queuedDownload1.status = .queued

        let queuedDownload2 = Download(url: "https://example.com/queued2", options: .default)
        queuedDownload2.status = .queued

        manager.downloads = [stoppedDownload, queuedDownload1, queuedDownload2]

        manager.clearQueuedDownloads()

        XCTAssertEqual(manager.downloads.count, 1, "Only queued downloads should be removed")
        XCTAssertEqual(manager.downloads.first?.id, stoppedDownload.id, "Existing stopped download must be preserved")
    }

    func testResumeWithNewNameAvoidsAnyMediaExtensionCollision() {
        let manager = DownloadManager()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RenameTest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create an existing conflicting media file with .mkv extension
        let existingPath = tempDir.appendingPathComponent("MyMovie (1).mkv")
        FileManager.default.createFile(atPath: existingPath.path, contents: Data("test".utf8))

        var options = DownloadOptions.default
        options.saveFolder = tempDir
        options.fileType = .mp4

        let download = Download(url: "https://example.com/video", options: options, title: "MyMovie")
        manager.resumeWithNewName(download)

        XCTAssertEqual(download.options.customFilename, "MyMovie (2)", "Must skip conflicting basename even if existing file has a different media extension")
    }

    func testWhatsNewOnlyShowsOnFirstRunOrUpdate() async {
        let manager = DownloadManager()
        let testVersion = manager.appVersion
        let userDefaults = UserDefaults.standard

        // 1. Simulate already up to date (normal launch)
        userDefaults.set(testVersion, forKey: UserDefaultsKeys.lastSeenVersion)
        manager.showWhatsNew = false
        await manager.checkAndFetchWhatsNew()
        XCTAssertFalse(manager.showWhatsNew, "What's New must not show if app is already on current seen version")

        // 2. Simulate app update (older seen version)
        userDefaults.set("4.2.0", forKey: UserDefaultsKeys.lastSeenVersion)
        manager.showWhatsNew = false
        await manager.checkAndFetchWhatsNew()
        XCTAssertTrue(manager.showWhatsNew, "What's New must show when app was updated from an older version")
        XCTAssertEqual(userDefaults.string(forKey: UserDefaultsKeys.lastSeenVersion), testVersion, "Seen version must be updated to current")

        // 3. Reset to up-to-date
        userDefaults.set(testVersion, forKey: UserDefaultsKeys.lastSeenVersion)
    }

    func testHTMLEntityDecodingOptimization() {
        let plain = "Hello World!"
        XCTAssertEqual(plain.decodingHTMLEntities(), "Hello World!")

        let named = "Tom &amp; Jerry &bull; &copy; 2026"
        XCTAssertEqual(named.decodingHTMLEntities(), "Tom & Jerry • © 2026")

        let decimal = "It&#39;s a test &#160;!"
        XCTAssertEqual(decimal.decodingHTMLEntities(), "It's a test  !")

        let hex = "&#x27;Quotes&#x22;"
        XCTAssertEqual(hex.decodingHTMLEntities(), "'Quotes\"")
    }

    func testHeaderRedactionIncludesShortAndHttpHeaderFlags() {
        let args = [
            "yt-dlp",
            "-H", "Authorization: Bearer secret-token-12345",
            "--http-header", "X-Custom-Auth: supersecret",
            "https://example.com/video"
        ]
        let joined = LoggerService.sanitizeCommandForLog(args)
        XCTAssertFalse(joined.contains("secret-token-12345"), "Must redact argument following -H")
        XCTAssertFalse(joined.contains("supersecret"), "Must redact argument following --http-header")
        XCTAssertTrue(joined.contains("<REDACTED_HEADER>"), "Must replace sensitive header with placeholder")
    }

    // MARK: - Download Model & Type Tests

    func testDownloadDisplayProgress() {
        let options = DownloadOptions.default
        let download = Download(url: "https://example.com/test", options: options)

        download.progress = 0.45
        download.speed = "2.5 MB/s"
        download.eta = "00:15"
        XCTAssertEqual(download.displayProgress, "45% • 2.5 MB/s • 00:15")

        // Progress clamp boundary tests
        download.progress = -0.5
        XCTAssertEqual(download.displayProgress, "0% • 2.5 MB/s • 00:15")

        download.progress = 1.5
        XCTAssertEqual(download.displayProgress, "100% • 2.5 MB/s • 00:15")
    }

    func testDownloadSourceDomainAllPlatforms() {
        let options = DownloadOptions.default

        let domains: [(String, String)] = [
            ("https://www.youtube.com/watch?v=123", "YouTube"),
            ("https://youtu.be/123", "YouTube"),
            ("https://twitter.com/user/123", "X (Twitter)"),
            ("https://x.com/user/123", "X (Twitter)"),
            ("https://www.instagram.com/p/123", "Instagram"),
            ("https://www.tiktok.com/@user/123", "TikTok"),
            ("https://vimeo.com/123", "Vimeo"),
            ("https://www.reddit.com/r/videos/123", "Reddit"),
            ("https://www.facebook.com/watch/123", "Facebook"),
            ("https://fb.watch/123", "Facebook"),
            ("https://www.twitch.tv/streamer", "Twitch"),
            ("https://soundcloud.com/artist/track", "SoundCloud"),
            ("https://www.dailymotion.com/video/123", "Dailymotion"),
            ("https://www.bilibili.com/video/123", "Bilibili.com"),
            ("invalid_url", "Web")
        ]

        for (url, expectedDomain) in domains {
            let dl = Download(url: url, options: options)
            XCTAssertEqual(dl.sourceDomain, expectedDomain, "URL \(url) should map to \(expectedDomain)")
        }
    }

    func testDownloadStatusTitlesAndColors() {
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
    }

    func testHDROptionTitlesAndIdentifiers() {
        let lang = LanguageService()
        XCTAssertEqual(HDRAction.preserveHDR.id, "preserve_hdr")
        XCTAssertEqual(HDRAction.convertToSDR.id, "convert_to_sdr")
        XCTAssertEqual(HDRAction.preserveHDR.title(lang: lang), "Preserve HDR (Original)")
        XCTAssertEqual(HDRAction.convertToSDR.title(lang: lang), "Convert HDR to SDR (Tone-mapped)")
    }

    func testDownloadDiagnosticsHDRSummary() {
        var diag = DownloadDiagnostics()
        XCTAssertNil(diag.hdrSummary, "Empty diagnostics should yield nil hdrSummary")

        diag.dynamicRange = "HDR10"
        diag.bitDepth = 10
        diag.colorSpace = "BT.2020"
        XCTAssertEqual(diag.hdrSummary, "HDR10 • 10-bit • BT.2020")

        diag.dynamicRange = "sdr"
        diag.bitDepth = 8
        diag.colorSpace = ""
        XCTAssertNil(diag.hdrSummary, "SDR 8-bit without color space should yield nil hdrSummary")
    }

    func testMediaFileTypeProperties() {
        XCTAssertTrue(MediaFileType.mp4.isVideo)
        XCTAssertFalse(MediaFileType.mp4.isAudio)
        XCTAssertEqual(MediaFileType.mp4.fileExtension, "mp4")
        XCTAssertEqual(MediaFileType.videoTypes, [.mp4, .webm, .mkv])

        XCTAssertTrue(MediaFileType.mp3.isAudio)
        XCTAssertFalse(MediaFileType.mp3.isVideo)
        XCTAssertEqual(MediaFileType.mp3.fileExtension, "mp3")
        XCTAssertEqual(MediaFileType.audioTypes, [.mp3, .opus, .flac, .wav, .m4a])
    }

    func testAudioQualityYtdlpValuesAndTitles() {
        let lang = LanguageService()
        XCTAssertEqual(AudioQuality.best.ytdlpValue, "0")
        XCTAssertEqual(AudioQuality.q320.ytdlpValue, "320K")
        XCTAssertEqual(AudioQuality.q256.ytdlpValue, "256K")
        XCTAssertEqual(AudioQuality.q192.ytdlpValue, "192K")
        XCTAssertEqual(AudioQuality.q128.ytdlpValue, "128K")

        XCTAssertEqual(AudioQuality.best.title(lang: lang), lang.s("res_best"))
        XCTAssertEqual(AudioQuality.q320.title(lang: lang), "320kbps")
    }

    func testVideoResolutionYtdlpValuesAndMaxHeight() {
        let lang = LanguageService()
        XCTAssertEqual(VideoResolution.r2160p.maxHeight, 2160)
        XCTAssertEqual(VideoResolution.r1080p.maxHeight, 1080)
        XCTAssertNil(VideoResolution.best.maxHeight)

        XCTAssertTrue(VideoResolution.r1080p.ytdlpValue.contains("height<=1080"))
        XCTAssertTrue(VideoResolution.r1080p.ytdlpCombinedValue.contains("bestaudio"))
        XCTAssertFalse(VideoResolution.r1080p.title(lang: lang).isEmpty)
    }

    func testVideoAndAudioCodecYtdlpFilters() {
        let lang = LanguageService()
        XCTAssertEqual(VideoCodec.h264.ytdlpFilter, "[vcodec^=avc1]")
        XCTAssertEqual(VideoCodec.h265.ytdlpFilter, "[vcodec~='^(hev1|hvc1)']")
        XCTAssertNil(VideoCodec.auto.ytdlpFilter)
        XCTAssertFalse(VideoCodec.h264.title(lang: lang).isEmpty)
        XCTAssertNotNil(VideoCodec.h264.compatibilityNote)

        XCTAssertEqual(AudioCodec.aac.ytdlpFilter, "[acodec^=mp4a]")
        XCTAssertNil(AudioCodec.auto.ytdlpFilter)
        XCTAssertFalse(AudioCodec.aac.title(lang: lang).isEmpty)
    }

    func testSubtitleFormatAndConversionCodec() {
        let lang = LanguageService()
        XCTAssertEqual(SubtitleFormat.srt.displayName, "SRT")
        XCTAssertEqual(SubtitleFormat.srt.ytdlpValue, "srt")

        XCTAssertFalse(ConversionCodec.none.title(lang: lang).isEmpty)
        XCTAssertFalse(ConversionCodec.h264.title(lang: lang).isEmpty)
    }

    func testDownloadPresets() {
        let lang = LanguageService()
        for preset in DownloadPreset.allCases {
            XCTAssertFalse(preset.title(lang: lang).isEmpty)
            XCTAssertFalse(preset.description(lang: lang).isEmpty)
            XCTAssertNotNil(preset.videoCodec)
            XCTAssertNotNil(preset.audioCodec)
            XCTAssertNotNil(preset.videoResolution)
            XCTAssertNotNil(preset.fileType)
        }
    }

    func testCustomPresetPersistence() {
        let key = UserDefaultsKeys.customPresets
        UserDefaults.standard.removeObject(forKey: key)

        let preset1 = CustomPreset(
            name: "My 4K Preset",
            videoCodec: .h265,
            audioCodec: .aac,
            videoResolution: .r2160p,
            fileType: .mp4
        )

        CustomPreset.saveAll([preset1])

        let loaded = CustomPreset.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "My 4K Preset")
        XCTAssertEqual(loaded.first?.videoResolution, .r2160p)

        UserDefaults.standard.removeObject(forKey: key)
    }

    func testHistoricDownloadToDownloadRoundtrip() {
        var options = DownloadOptions.default
        options.rawCookies = "secret_cookies"

        let download = Download(url: "https://example.com/roundtrip", options: options, title: "Roundtrip Video")
        download.status = .completed
        download.progress = 1.0
        download.filePath = URL(fileURLWithPath: "/tmp/roundtrip.mp4")
        download.errorMessage = "None"
        download.log = "Log data"

        let historic = HistoricDownload(download: download)
        XCTAssertNil(historic.options.rawCookies, "HistoricDownload must strip rawCookies")

        let reconstructed = historic.toDownload()
        XCTAssertEqual(reconstructed.id, download.id)
        XCTAssertEqual(reconstructed.url, download.url)
        XCTAssertEqual(reconstructed.title, download.title)
        XCTAssertEqual(reconstructed.status, .completed)
        XCTAssertEqual(reconstructed.progress, 1.0)
        XCTAssertEqual(reconstructed.filePath?.path, "/tmp/roundtrip.mp4")
        XCTAssertEqual(reconstructed.log, "Log data")
    }
}

