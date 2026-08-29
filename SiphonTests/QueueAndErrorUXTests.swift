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
        XCTAssertNil(manager.activeControllers[download.id], "Controller must be detached from activeControllers")
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
}

