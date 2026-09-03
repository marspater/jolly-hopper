import XCTest
@testable import Siphon

@MainActor
final class DownloadManagerTests: XCTestCase {

    func testAddDownload() {
        // Arrange
        let manager = DownloadManager()
        let testUrl = "https://example.com/video"
        let options = DownloadOptions.default

        let initialCount = manager.downloads.count

        // Act
        manager.addDownload(url: testUrl, options: options)

        // Assert
        XCTAssertEqual(manager.downloads.count, initialCount + 1, "Downloads array count should increase by 1")

        guard let addedDownload = manager.downloads.last else {
            XCTFail("Failed to get the added download")
            return
        }

        XCTAssertEqual(addedDownload.url, testUrl, "The added download URL should match the provided URL")
        XCTAssertEqual(addedDownload.status, .queued, "The added download should have .queued status initially")
    }

    func testAddDownloadsBatch() {
        let manager = DownloadManager()
        let urls = [
            "https://example.com/video1",
            "https://example.com/video2",
            "https://example.com/video3"
        ]
        let options = DownloadOptions.default
        let initialCount = manager.downloads.count

        manager.addDownloads(urls: urls, options: options)

        XCTAssertEqual(manager.downloads.count, initialCount + 3)
        XCTAssertEqual(manager.downloads[0].url, "https://example.com/video1")
        XCTAssertEqual(manager.downloads[1].url, "https://example.com/video2")
        XCTAssertEqual(manager.downloads[2].url, "https://example.com/video3")
    }

    func testRetryFailedDownloadsIncludesStoppedDownloads() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        let downloadStopped = Download(url: "https://example.com/stopped", options: options)
        downloadStopped.status = .stopped
        manager.downloads.append(downloadStopped)

        let downloadFailed = Download(url: "https://example.com/failed", options: options)
        downloadFailed.status = .failed
        manager.downloads.append(downloadFailed)

        XCTAssertEqual(manager.failedDownloads.count, 2)

        manager.retryFailedDownloads()

        XCTAssertEqual(downloadStopped.status, .queued)
        XCTAssertEqual(downloadFailed.status, .queued)
    }

    func testLanguageServiceTranslationsForMissingKeys() {
        let lang = LanguageService()
        XCTAssertEqual(lang.s("download_selected"), "Download %d Selected")
        XCTAssertEqual(lang.s("download_new_name"), "Download with new name")
        XCTAssertEqual(lang.s("file_exists_status"), "File Exists")
        XCTAssertEqual(lang.s("playlist_detected"), "Playlist Detected")
    }

    func testCustomFilenameCollisionResolution() async {
        let manager = DownloadManager()
        var opts1 = DownloadOptions.default
        opts1.customFilename = "custom_video"
        opts1.fileType = .mp4

        var opts2 = DownloadOptions.default
        opts2.customFilename = "custom_video"
        opts2.fileType = .mp4

        let dl1 = Download(url: "https://example.com/v1", options: opts1, title: "Title 1")
        let dl2 = Download(url: "https://example.com/v2", options: opts2, title: "Title 2")

        let expectedPath1 = opts1.saveFolder.appendingPathComponent("custom_video.mp4").path
        let expectedPath2 = opts2.saveFolder.appendingPathComponent("custom_video_1.mp4").path

        // Reserve path for dl1 through DownloadManager
        let (name1, path1) = manager.resolveUniqueOutputPath(for: dl1)
        XCTAssertEqual(name1, "custom_video")
        XCTAssertEqual(path1, expectedPath1)
        manager.reserveOutputPath(path1)
        defer { manager.unreserveOutputPath(path1) }

        // Act: Resolve unique output path for dl2 using real production DownloadManager logic
        let (name2, path2) = manager.resolveUniqueOutputPath(for: dl2)

        // Assert: Production method resolved the conflict
        XCTAssertEqual(name2, "custom_video_1", "Second download must have resolved name updated to non-colliding name")
        XCTAssertEqual(path2, expectedPath2)
    }

    func testProcessDownloadExitsIfCancelledWhileQueued() async {
        let manager = DownloadManager()
        let options = DownloadOptions.default
        let download = Download(url: "https://example.com/cancelled", options: options)
        download.status = .stopped // User cancelled while in queue

        // Act: Execute actual processDownload
        await manager.processDownload(download)

        // Assert: Production method respected status != .queued and did not transition to fetching/downloading
        XCTAssertEqual(download.status, .stopped, "processDownload must exit immediately without mutating status when status is not .queued")
    }

    func testNaNProgressGuarding() {
        let computeSafeProgress: (Double) -> Double = { progress in
            progress.isNaN ? 0 : max(0, min(1, progress))
        }

        XCTAssertEqual(computeSafeProgress(Double.nan), 0.0, "NaN progress should evaluate to 0.0")
        XCTAssertEqual(computeSafeProgress(-0.5), 0.0, "Negative progress should be clamped to 0.0")
        XCTAssertEqual(computeSafeProgress(1.5), 1.0, "Progress greater than 1.0 should be clamped to 1.0")
        XCTAssertEqual(computeSafeProgress(0.75), 0.75, "Valid progress between 0.0 and 1.0 should remain unchanged")
    }

    func testRetryDownloadEligibleStatuses() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        let eligibleStatuses: [DownloadStatus] = [.failed, .stopped, .fileExists]

        for status in eligibleStatuses {
            let download = Download(url: "https://example.com/test_\(status)", options: options)
            download.status = status
            download.progress = 0.8
            download.errorMessage = "Failed due to network timeout"
            download.log = "Line 1\nLine 2\nError occurred"

            manager.retryDownload(download)

            XCTAssertEqual(download.status, .queued, "Status should be updated to .queued for status \(status)")
            XCTAssertEqual(download.progress, 0, "Progress should be reset to 0 for status \(status)")
            XCTAssertNil(download.errorMessage, "ErrorMessage should be reset to nil for status \(status)")
            XCTAssertEqual(download.log, "", "Log should be reset to empty string for status \(status)")
        }
    }

    func testRetryDownloadIneligibleStatuses() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        let ineligibleStatuses: [DownloadStatus] = [.downloading, .queued, .completed, .fetching, .processing]

        for status in ineligibleStatuses {
            let download = Download(url: "https://example.com/test_\(status)", options: options)
            download.status = status
            download.progress = 0.5
            download.errorMessage = "Some existing message"
            download.log = "Some log content"

            manager.retryDownload(download)

            XCTAssertEqual(download.status, status, "Status should remain unchanged for ineligible status \(status)")
            XCTAssertEqual(download.progress, 0.5, "Progress should remain unchanged for ineligible status \(status)")
            XCTAssertEqual(download.errorMessage, "Some existing message", "ErrorMessage should remain unchanged for ineligible status \(status)")
            XCTAssertEqual(download.log, "Some log content", "Log should remain unchanged for ineligible status \(status)")
        }
    }

    func testLoadHistoryMarksActiveDownloadsAsStopped() {
        let userDefaultsKey = UserDefaultsKeys.downloadHistory
        let options = DownloadOptions.default
        let activeDownload = Download(url: "https://example.com/active", options: options)
        activeDownload.status = .downloading

        let historic = HistoricDownload(download: activeDownload)
        if let encoded = try? JSONEncoder().encode([historic]) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }

        let manager = DownloadManager()
        manager.loadHistory()

        XCTAssertEqual(manager.downloads.count, 1)
        guard let restored = manager.downloads.first else {
            XCTFail("Restored download missing")
            return
        }

        XCTAssertEqual(restored.status, .stopped, "Active downloads should be reset to stopped on relaunch")
        XCTAssertEqual(manager.failedDownloads.count, 1, "Stopped downloads should be tracked in failedDownloads")

        // Clean up
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    func testProcessDownloadAbortsIfCancelledDuringFetchInfo() async {
        let manager = DownloadManager()
        manager.ytdlpService.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")

        let fetchStartedExpectation = expectation(description: "Fetch info started")
        let fetchCompletedExpectation = expectation(description: "Fetch info completed")

        let mockJSON = """
        {
            "id": "test_cancel_id",
            "title": "Fetched Title Should Not Be Set",
            "duration": 60.0
        }
        """

        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            fetchStartedExpectation.fulfill()
            // Simulate delay during network fetch
            try? await Task.sleep(nanoseconds: 100_000_000)
            fetchCompletedExpectation.fulfill()
            return mockJSON
        })

        let download = Download(url: "https://example.com/cancel-test", options: DownloadOptions.default)
        manager.downloads.append(download)

        // Trigger processing
        let processTask = Task {
            await manager.processDownload(download)
        }

        // Wait for fetchInfo to begin
        await fulfillment(of: [fetchStartedExpectation], timeout: 1.0)

        // Simulate user cancellation while in fetching state
        manager.stopDownload(download)

        // Wait for fetchInfo completion in mock
        await fulfillment(of: [fetchCompletedExpectation], timeout: 1.0)
        await processTask.value

        // Assert download title was NOT updated and status remains .stopped
        XCTAssertEqual(download.status, .stopped, "Status should remain stopped")
        XCTAssertEqual(download.title, "___FETCHING___", "Title should not be overwritten with fetched title after cancellation")
    }

    func testProcessDownloadHandlesYtdlpErrorCases() async {
        let manager = DownloadManager()
        let languageService = LanguageService()
        manager.languageService = languageService
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dummyYtdlp = tempDir.appendingPathComponent("yt-dlp")
        let dummyFfmpeg = tempDir.appendingPathComponent("ffmpeg")
        FileManager.default.createFile(atPath: dummyYtdlp.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: dummyFfmpeg.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        manager.ytdlpService.ytdlpPath = dummyYtdlp
        manager.ytdlpService.ffmpegPath = dummyFfmpeg

        let mockJSON = """
        {
            "id": "test_error_id",
            "title": "Error Video Test",
            "duration": 60.0
        }
        """

        // Test Cloudflare blocked error mapping
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(
            mockCommand: { _ in mockJSON },
            mockDownload: { _ in
                throw YtdlpError.cloudflareBlocked
            }
        )

        let dl1 = Download(url: "https://example.com/cf-test", options: DownloadOptions.default)
        await manager.processDownload(dl1)
        XCTAssertEqual(dl1.status, .failed)
        XCTAssertEqual(dl1.errorMessage, languageService.s("cloudflare_blocked"))

        // Test DRM protected error mapping
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(
            mockCommand: { _ in mockJSON },
            mockDownload: { _ in
                throw YtdlpError.downloadFailed("ERROR: This video is protected by DRM encryption")
            }
        )

        let dl2 = Download(url: "https://example.com/drm-test", options: DownloadOptions.default)
        await manager.processDownload(dl2)
        XCTAssertEqual(dl2.status, .failed)
        XCTAssertEqual(dl2.errorMessage, languageService.s("drm_protected"))

        // Test Disk full error mapping
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(
            mockCommand: { _ in mockJSON },
            mockDownload: { _ in
                throw YtdlpError.downloadFailed("ERROR: No space left on device")
            }
        )

        let dl3 = Download(url: "https://example.com/disk-test", options: DownloadOptions.default)
        await manager.processDownload(dl3)
        XCTAssertEqual(dl3.status, .failed)
        XCTAssertEqual(dl3.errorMessage, languageService.s("disk_full"))

        // Test Permission denied error mapping
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(
            mockCommand: { _ in mockJSON },
            mockDownload: { _ in
                throw YtdlpError.downloadFailed("ERROR: Permission denied writing to disk")
            }
        )

        let dl4 = Download(url: "https://example.com/perm-test", options: DownloadOptions.default)
        await manager.processDownload(dl4)
        XCTAssertEqual(dl4.status, .failed)
        XCTAssertEqual(dl4.errorMessage, languageService.s("permission_denied"))

        // Test Private video / Login required error mapping
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(
            mockCommand: { _ in mockJSON },
            mockDownload: { _ in
                throw YtdlpError.downloadFailed("ERROR: Private video. Sign in if you've been granted access")
            }
        )

        let dl5 = Download(url: "https://example.com/private-test", options: DownloadOptions.default)
        await manager.processDownload(dl5)
        XCTAssertEqual(dl5.status, .failed)
        XCTAssertEqual(dl5.errorMessage, languageService.s("login_required"))
    }

    func testLoadHistoryCorruptedDataGracefullyHandled() {
        let userDefaultsKey = UserDefaultsKeys.downloadHistory
        UserDefaults.standard.set("corrupted_non_json_data".data(using: .utf8)!, forKey: userDefaultsKey)

        let manager = DownloadManager()
        manager.loadHistory()

        // Should not crash and should leave downloads empty
        XCTAssertEqual(manager.downloads.count, 0)

        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    func testCustomPresetLoadCorruptedDataGracefullyHandled() {
        let userDefaultsKey = UserDefaultsKeys.customPresets
        UserDefaults.standard.set("corrupted_data".data(using: .utf8)!, forKey: userDefaultsKey)

        let presets = CustomPreset.loadAll()
        XCTAssertEqual(presets.count, 0, "Corrupted presets should return empty list without crash")

        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    func testRetryDownloadResetsForceOverwriteFlag() {
        let manager = DownloadManager()
        var options = DownloadOptions.default
        options.forceOverwrite = true

        let dlFailed = Download(url: "https://example.com/fail", options: options)
        dlFailed.status = .failed
        manager.downloads.append(dlFailed)

        manager.retryDownload(dlFailed)
        XCTAssertFalse(dlFailed.options.forceOverwrite == true)
        XCTAssertEqual(dlFailed.status, .queued)

        let dlStopped = Download(url: "https://example.com/stop", options: options)
        dlStopped.status = .stopped
        manager.downloads.append(dlStopped)

        manager.retryDownload(dlStopped)
        XCTAssertFalse(dlStopped.options.forceOverwrite == true)
        XCTAssertEqual(dlStopped.status, .queued)

        let dlExists = Download(url: "https://example.com/exists", options: options)
        dlExists.status = .fileExists
        manager.downloads.append(dlExists)

        manager.retryDownload(dlExists)
        XCTAssertFalse(dlExists.options.forceOverwrite == true)
        XCTAssertEqual(dlExists.status, .queued)
    }

    func testClearHistoryPrunesVisibleFinishedDownloads() {
        let manager = DownloadManager()

        let dlCompleted = Download(url: "https://example.com/1", options: .default)
        dlCompleted.status = .completed

        let dlFailed = Download(url: "https://example.com/2", options: .default)
        dlFailed.status = .failed

        let dlStopped = Download(url: "https://example.com/3", options: .default)
        dlStopped.status = .stopped

        let dlQueued = Download(url: "https://example.com/4", options: .default)
        dlQueued.status = .queued

        manager.downloads = [dlCompleted, dlFailed, dlStopped, dlQueued]
        manager.clearHistory()

        XCTAssertEqual(manager.downloads.count, 1)
        XCTAssertEqual(manager.downloads.first?.id, dlQueued.id)
        XCTAssertEqual(manager.completedDownloads.count, 0)
        XCTAssertEqual(manager.failedDownloads.count, 0)
    }

    func testResumeWithNewNameUsesCleanSequentialSuffix() {
        let manager = DownloadManager()
        let dl = Download(url: "https://example.com/vid", options: .default, title: "My Video")
        dl.status = .fileExists

        manager.resumeWithNewName(dl)

        XCTAssertEqual(dl.options.customFilename, "My Video (1)")
        XCTAssertFalse(dl.options.forceOverwrite == true)
        XCTAssertEqual(dl.status, .queued)
    }

    func testDownloadProcessControllerAtomicStartupAndCancellation() {
        let controller = DownloadProcessController()
        XCTAssertFalse(controller.isCancelled)

        controller.cancel()
        XCTAssertTrue(controller.isCancelled)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/echo")
        proc.arguments = ["hello"]

        XCTAssertThrowsError(try controller.start(proc))
        XCTAssertFalse(proc.isRunning)
    }

    func testShouldCleanupTemporaryFiles() {
        XCTAssertTrue(DownloadManager.shouldCleanupTemporaryFiles(for: .stopped))
        XCTAssertTrue(DownloadManager.shouldCleanupTemporaryFiles(for: .failed))

        XCTAssertFalse(DownloadManager.shouldCleanupTemporaryFiles(for: .queued))
        XCTAssertFalse(DownloadManager.shouldCleanupTemporaryFiles(for: .downloading))
        XCTAssertFalse(DownloadManager.shouldCleanupTemporaryFiles(for: .completed))
        XCTAssertFalse(DownloadManager.shouldCleanupTemporaryFiles(for: .fetching))
        XCTAssertFalse(DownloadManager.shouldCleanupTemporaryFiles(for: .processing))
        XCTAssertFalse(DownloadManager.shouldCleanupTemporaryFiles(for: .paused))
        XCTAssertFalse(DownloadManager.shouldCleanupTemporaryFiles(for: .fileExists))
    }

    func testExtractVideoId() {
        XCTAssertEqual(
            DownloadManager.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
        XCTAssertEqual(
            DownloadManager.extractVideoId(from: "https://youtu.be/dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
        XCTAssertEqual(
            DownloadManager.extractVideoId(from: "invalid_url"),
            "invalid_url"
        )
    }

    func testIsTemporaryFileName() {
        XCTAssertTrue(DownloadManager.isTemporaryFileName("video.mp4.part"))
        XCTAssertTrue(DownloadManager.isTemporaryFileName("video.mp4.ytdl"))
        XCTAssertTrue(DownloadManager.isTemporaryFileName("video.mp4.temp"))
        XCTAssertTrue(DownloadManager.isTemporaryFileName("video.mp4.tmp"))
        XCTAssertTrue(DownloadManager.isTemporaryFileName("video.f137.part"))
        XCTAssertTrue(DownloadManager.isTemporaryFileName("video.f140.ytdl"))

        XCTAssertFalse(DownloadManager.isTemporaryFileName("video.mp4"))
        XCTAssertFalse(DownloadManager.isTemporaryFileName("video.m4a"))
        XCTAssertFalse(DownloadManager.isTemporaryFileName("video.part.mp4"))
    }

    func testIsMatchingTemporaryFile() {
        let rawBaseName = "My Great Video"
        let sanitizedBaseName = "My_Great_Video"
        let videoId = "dQw4w9WgXcQ"

        // Matches prefix (raw base name) and temp extension
        XCTAssertTrue(
            DownloadManager.isMatchingTemporaryFile(
                fileName: "My Great Video.f137.part",
                rawBaseName: rawBaseName,
                sanitizedBaseName: sanitizedBaseName,
                videoId: videoId
            )
        )

        // Matches prefix (sanitized base name) and temp extension
        XCTAssertTrue(
            DownloadManager.isMatchingTemporaryFile(
                fileName: "My_Great_Video.f140.ytdl",
                rawBaseName: rawBaseName,
                sanitizedBaseName: sanitizedBaseName,
                videoId: videoId
            )
        )

        // Matches video ID and temp extension
        XCTAssertTrue(
            DownloadManager.isMatchingTemporaryFile(
                fileName: "some_other_title_dQw4w9WgXcQ.temp",
                rawBaseName: rawBaseName,
                sanitizedBaseName: sanitizedBaseName,
                videoId: videoId
            )
        )

        // Does not match prefix or video ID
        XCTAssertFalse(
            DownloadManager.isMatchingTemporaryFile(
                fileName: "Unrelated_Video.part",
                rawBaseName: rawBaseName,
                sanitizedBaseName: sanitizedBaseName,
                videoId: videoId
            )
        )

        // Matches prefix but is NOT a temporary file
        XCTAssertFalse(
            DownloadManager.isMatchingTemporaryFile(
                fileName: "My_Great_Video.mp4",
                rawBaseName: rawBaseName,
                sanitizedBaseName: sanitizedBaseName,
                videoId: videoId
            )
        )
    }

    func testMenuDownloadVideo() {
        let manager = DownloadManager()
        let testUrl = "https://example.com/video_menu"
        let initialCount = manager.downloads.count

        manager.menuDownload(url: testUrl, type: "video", quality: "1080")

        XCTAssertEqual(manager.downloads.count, initialCount + 1)
        guard let download = manager.downloads.last else {
            XCTFail("Failed to find added download")
            return
        }

        XCTAssertEqual(download.url, testUrl)
        XCTAssertEqual(download.options.fileType, .mp4)
        XCTAssertEqual(download.options.videoResolution, .r1080p)
        XCTAssertEqual(download.options.videoCodec, .auto)
        XCTAssertEqual(download.options.audioCodec, .auto)
        XCTAssertTrue(download.options.sponsorBlock)
        XCTAssertTrue(download.options.embedThumbnail)
        XCTAssertTrue(download.options.embedMetadata)
    }

    func testMenuDownloadAudio() {
        let manager = DownloadManager()
        let testUrl = "https://example.com/audio_menu"
        let initialCount = manager.downloads.count

        manager.menuDownload(url: testUrl, type: "audio", quality: "best")

        XCTAssertEqual(manager.downloads.count, initialCount + 1)
        guard let download = manager.downloads.last else {
            XCTFail("Failed to find added download")
            return
        }

        XCTAssertEqual(download.url, testUrl)
        XCTAssertEqual(download.options.fileType, .m4a)
        XCTAssertEqual(download.options.videoCodec, .none)
        XCTAssertEqual(download.options.audioCodec, .auto)
        XCTAssertEqual(download.options.audioQuality, .best)
    }

    // MARK: - Initialize Tests

    func testInitializeVersionFetchingAndAssignment() async {
        let manager = DownloadManager()
        let languageService = LanguageService()

        manager.ytdlpService.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let expectedVersion = "2025.02.20"
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            return expectedVersion
        })

        await manager.initialize(languageService: languageService)

        XCTAssertEqual(manager.ytdlpVersion, expectedVersion)
    }

    func testInitializeLoadsHistoryAndResetsActiveStatuses() async {
        let manager = DownloadManager()
        let languageService = LanguageService()

        let historyKey = UserDefaultsKeys.downloadHistory
        defer { UserDefaults.standard.removeObject(forKey: historyKey) }

        let download = Download(url: "https://example.com/init_history", options: .default)
        download.status = .downloading
        let historic = HistoricDownload(download: download)

        if let data = try? JSONEncoder().encode([historic]) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }

        await manager.initialize(languageService: languageService)

        XCTAssertEqual(manager.history.count, 1)
        XCTAssertEqual(manager.downloads.count, 1)
        XCTAssertEqual(manager.downloads.first?.status, .stopped, "Active download from history should be converted to .stopped during initialize")
    }

    func testInitializeWhatsNewDisplayWhenVersionChanges() async {
        let manager = DownloadManager()
        let languageService = LanguageService()

        let lastSeenKey = UserDefaultsKeys.lastSeenVersion
        defer { UserDefaults.standard.removeObject(forKey: lastSeenKey) }

        // Set last seen version to older version
        UserDefaults.standard.set("0.0.1", forKey: lastSeenKey)

        await manager.initialize(languageService: languageService)

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.2.0"
        XCTAssertTrue(manager.showWhatsNew)
        XCTAssertEqual(UserDefaults.standard.string(forKey: lastSeenKey), currentVersion)

        // Run initialize again with current version already stored -> showWhatsNew should remain false on fresh instance
        let manager2 = DownloadManager()
        await manager2.initialize(languageService: languageService)
        XCTAssertFalse(manager2.showWhatsNew)
    }

    func testQueueSlotAccountingDoesNotExceedMaxConcurrentDownloads() async {
        let manager = DownloadManager()
        let maxSlots = UserDefaults.standard.integer(forKey: UserDefaultsKeys.maxConcurrentDownloads)
        let limit = maxSlots > 0 ? maxSlots : 3

        let d1 = Download(url: "https://example.com/1", options: .default)
        let d2 = Download(url: "https://example.com/2", options: .default)
        let d3 = Download(url: "https://example.com/3", options: .default)
        let d4 = Download(url: "https://example.com/4", options: .default)
        let d5 = Download(url: "https://example.com/5", options: .default)

        manager.downloads = [d1, d2, d3, d4, d5]

        // Trigger queue processing multiple times synchronously
        manager.processQueue()
        manager.processQueue()
        manager.processQueue()

        // Count active tasks and reserved slots
        let activeCount = manager.activeTasks.count
        XCTAssertLessThanOrEqual(activeCount, limit, "Active tasks must never exceed the concurrency limit")

        manager.shutdown()
    }

    func testStatusCountsAccurateCalculation() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        let d1 = Download(url: "https://example.com/1", options: options)
        d1.status = .downloading

        let d2 = Download(url: "https://example.com/2", options: options)
        d2.status = .fetching

        let d3 = Download(url: "https://example.com/3", options: options)
        d3.status = .processing

        let d4 = Download(url: "https://example.com/4", options: options)
        d4.status = .queued

        let d5 = Download(url: "https://example.com/5", options: options)
        d5.status = .completed

        let d6 = Download(url: "https://example.com/6", options: options)
        d6.status = .failed

        let d7 = Download(url: "https://example.com/7", options: options)
        d7.status = .stopped

        let d8 = Download(url: "https://example.com/8", options: options)
        d8.status = .paused

        manager.downloads = [d1, d2, d3, d4, d5, d6, d7, d8]

        XCTAssertEqual(manager.downloadingCount, 3, "downloadingCount should include downloading, fetching, and processing")
        XCTAssertEqual(manager.queuedCount, 1, "queuedCount should include queued downloads")
        XCTAssertEqual(manager.completedCount, 1, "completedCount should include completed downloads")
        XCTAssertEqual(manager.failedCount, 2, "failedCount should include failed and stopped downloads")
    }
}
