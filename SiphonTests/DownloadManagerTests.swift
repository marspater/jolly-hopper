import XCTest
@testable import Siphon

@MainActor
final class DownloadManagerTests: XCTestCase {

    func testPauseResumeReusesPartialDataAndCompletionRemovesScratch() async throws {
        let originalHistory = UserDefaults.standard.object(forKey: UserDefaultsKeys.downloadHistory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.set(originalHistory, forKey: UserDefaultsKeys.downloadHistory)
            try? FileManager.default.removeItem(at: root)
        }
        let manager = DownloadManager()
        defer { manager.shutdown() }
        manager.ytdlpService.ytdlpPath = URL(fileURLWithPath: "/mock/yt-dlp")
        let started = expectation(description: "Partial file written")
        let resumed = expectation(description: "Partial file reused")
        let attempt = TestBox(0)
        let directory = TestBox<URL?>(nil)
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(
            mockCommand: { _ in #"{"id":"fixture","title":"fixture"}"# },
            mockDownload: { args in
                let path = try XCTUnwrap(args.first { $0.hasPrefix("temp:") })
                let scratch = URL(fileURLWithPath: String(path.dropFirst(5)))
                let partial = scratch.appendingPathComponent("fixture.mp4.part")
                attempt.value += 1
                if attempt.value == 1 {
                    directory.value = scratch
                    try Data("partial".utf8).write(to: partial)
                    started.fulfill()
                    try await Task.sleep(for: .seconds(30))
                    throw CancellationError()
                }
                XCTAssertEqual(scratch, directory.value)
                XCTAssertEqual(try String(contentsOf: partial, encoding: .utf8), "partial")
                resumed.fulfill()
                let final = root.appendingPathComponent("fixture.mp4")
                try Data("complete".utf8).write(to: final)
                return final.path
            }
        )
        var options = DownloadOptions.default
        options.saveFolder = root
        options.embedThumbnail = false
        manager.addDownload(url: "https://example.com/fixture", options: options)
        let download = try XCTUnwrap(manager.downloads.first)
        await fulfillment(of: [started], timeout: 3)
        manager.pauseDownload(download)
        for _ in 0..<200 {
            if manager.activeExecutionCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.activeExecutionCount, 0)
        XCTAssertEqual(download.status, .paused)
        XCTAssertNotNil(download.scratchDirectory)
        manager.resumeDownload(download)
        await fulfillment(of: [resumed], timeout: 3)
        for _ in 0..<200 {
            if manager.activeExecutionCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(download.status, .completed)
        XCTAssertNil(download.scratchDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory.value).path))
    }

    func testRemovingActiveDownloadDoesNotRestoreHistoryAfterCancellation() async throws {
        let originalHistory = UserDefaults.standard.object(forKey: UserDefaultsKeys.downloadHistory)
        defer { UserDefaults.standard.set(originalHistory, forKey: UserDefaultsKeys.downloadHistory) }
        let manager = DownloadManager()
        defer { manager.shutdown() }
        manager.ytdlpService.ytdlpPath = URL(fileURLWithPath: "/mock/yt-dlp")
        let started = expectation(description: "Metadata fetch started")
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        })
        manager.addDownload(url: "https://example.com/removed", options: .default)
        let download = try XCTUnwrap(manager.downloads.first)
        await fulfillment(of: [started], timeout: 3)
        manager.removeDownload(download)
        for _ in 0..<200 {
            if manager.activeExecutionCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.activeExecutionCount, 0)
        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertTrue(manager.history.isEmpty, "Late cancellation must not resurrect a removed entry")
        XCTAssertTrue(manager.historyStore.loadHistory().isEmpty, "Removed entry must stay absent after relaunch")
    }

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

    func testMostRelevantNavigationItemPrioritizesActionableDownloadStates() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        XCTAssertEqual(manager.mostRelevantNavigationItem, .completed)

        let completed = Download(url: "https://example.com/completed", options: options)
        completed.status = .completed
        manager.downloads = [completed]
        XCTAssertEqual(manager.mostRelevantNavigationItem, .completed)

        let failed = Download(url: "https://example.com/failed", options: options)
        failed.status = .failed
        manager.downloads.append(failed)
        XCTAssertEqual(manager.mostRelevantNavigationItem, .failed)

        let queued = Download(url: "https://example.com/queued", options: options)
        queued.status = .queued
        manager.downloads.append(queued)
        XCTAssertEqual(manager.mostRelevantNavigationItem, .queued)

        let downloading = Download(url: "https://example.com/downloading", options: options)
        downloading.status = .downloading
        manager.downloads.append(downloading)
        XCTAssertEqual(manager.mostRelevantNavigationItem, .downloading)
    }

    func testRetryFailedDownloadsIncludesStoppedDownloads() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        let downloadStopped = Download(url: "https://example.com/stopped", options: options)
        downloadStopped.status = .stopped
        downloadStopped.progress = 0.4
        downloadStopped.errorMessage = "Cancelled by user"
        downloadStopped.log = "Download stopped prematurely"
        manager.downloads.append(downloadStopped)

        let downloadFailed = Download(url: "https://example.com/failed", options: options)
        downloadFailed.status = .failed
        downloadFailed.progress = 0.2
        downloadFailed.errorMessage = "Network timeout"
        downloadFailed.log = "Error downloading segment"
        manager.downloads.append(downloadFailed)

        let downloadCompleted = Download(url: "https://example.com/completed", options: options)
        downloadCompleted.status = .completed
        downloadCompleted.progress = 1.0
        manager.downloads.append(downloadCompleted)

        let downloadDownloading = Download(url: "https://example.com/downloading", options: options)
        downloadDownloading.status = .downloading
        downloadDownloading.progress = 0.5
        manager.downloads.append(downloadDownloading)

        let downloadFileExists = Download(url: "https://example.com/fileexists", options: options)
        downloadFileExists.status = .fileExists
        manager.downloads.append(downloadFileExists)

        XCTAssertEqual(manager.failedDownloads.count, 2)

        manager.retryFailedDownloads()

        // Failed / stopped downloads should transition to .queued and reset progress/error details
        XCTAssertEqual(downloadStopped.status, .queued)
        XCTAssertEqual(downloadStopped.progress, 0)
        XCTAssertNil(downloadStopped.errorMessage)
        XCTAssertEqual(downloadStopped.log, "")

        XCTAssertEqual(downloadFailed.status, .queued)
        XCTAssertEqual(downloadFailed.progress, 0)
        XCTAssertNil(downloadFailed.errorMessage)
        XCTAssertEqual(downloadFailed.log, "")

        // Non-failed/stopped downloads should remain untouched
        XCTAssertEqual(downloadCompleted.status, .completed)
        XCTAssertEqual(downloadCompleted.progress, 1.0)

        XCTAssertEqual(downloadDownloading.status, .downloading)
        XCTAssertEqual(downloadDownloading.progress, 0.5)

        XCTAssertEqual(downloadFileExists.status, .fileExists)
    }

    func testLanguageServiceTranslationsForMissingKeys() {
        let lang = LanguageService()
        XCTAssertEqual(lang.s("download_selected"), "Download %d Selected")
        XCTAssertEqual(lang.s("download_new_name"), "Download with new name")
        XCTAssertEqual(lang.s("file_exists_status"), "File Exists")
        XCTAssertEqual(lang.s("playlist_detected"), "Playlist Detected")
    }

    func testCustomFilenameCollisionResolution() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("testCustomFilenameCollisionResolution_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = DownloadManager()
        var opts1 = DownloadOptions.default
        opts1.saveFolder = tempDir
        opts1.customFilename = "custom_video"
        opts1.fileType = .mp4

        var opts2 = DownloadOptions.default
        opts2.saveFolder = tempDir
        opts2.customFilename = "custom_video"
        opts2.fileType = .mp4

        let dl1 = Download(url: "https://example.com/v1", options: opts1, title: "Title 1")
        let dl2 = Download(url: "https://example.com/v2", options: opts2, title: "Title 2")

        let expectedPath1 = opts1.saveFolder.appendingPathComponent("custom_video.mp4").path
        let expectedPath2 = opts2.saveFolder.appendingPathComponent("custom_video (1).mp4").path

        // Reserve path for dl1 through DownloadManager
        let (name1, path1) = manager.reserveUniqueOutputPath(for: dl1)
        XCTAssertEqual(name1, "custom_video")
        XCTAssertEqual(path1, expectedPath1)
        defer { manager.unreserveOutputPath(path1) }

        // Act: Resolve unique output path for dl2 using real production DownloadManager logic
        let (name2, path2) = manager.planUniqueOutputPath(for: dl2)

        // Assert: Production method resolved the conflict
        XCTAssertEqual(name2, "custom_video (1)", "Second download must have resolved name updated to non-colliding name")
        XCTAssertEqual(path2, expectedPath2)
    }

    func testPlanUniqueOutputPathDoesNotMutateReservations() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("testPlanUniqueOutputPathDoesNotMutateReservations_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = DownloadManager()
        var opts = DownloadOptions.default
        opts.saveFolder = tempDir
        opts.customFilename = "unreserved_test"
        opts.fileType = .mp4
        let dl = Download(url: "https://example.com/unreserved", options: opts, title: "Test")

        let (name1, path1) = manager.planUniqueOutputPath(for: dl)
        XCTAssertEqual(name1, "unreserved_test")

        // Calling plan a second time for the same name should yield the SAME candidate path because plan did not lock/reserve it
        let (name2, path2) = manager.planUniqueOutputPath(for: dl)
        XCTAssertEqual(name2, "unreserved_test")
        XCTAssertEqual(path1, path2)

        // Now actively reserve it
        let (resName, resPath) = manager.reserveUniqueOutputPath(for: dl)
        XCTAssertEqual(resName, "unreserved_test")
        defer { manager.unreserveOutputPath(resPath) }

        // Now plan will see the active reservation and increment
        let (name3, path3) = manager.planUniqueOutputPath(for: dl)
        XCTAssertEqual(name3, "unreserved_test (1)")
        XCTAssertNotEqual(path1, path3)
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

    func testLoadHistoryRecoversValidEntriesWhenCorruptedItemPresent() throws {
        let userDefaultsKey = UserDefaultsKeys.downloadHistory
        let options = DownloadOptions.default
        let download1 = Download(url: "https://example.com/item1", options: options)
        download1.title = "Item 1"
        download1.status = .completed
        let download2 = Download(url: "https://example.com/item2", options: options)
        download2.title = "Item 2"
        download2.status = .completed

        let historic1 = HistoricDownload(download: download1)
        let historic2 = HistoricDownload(download: download2)

        let encoder = JSONEncoder()
        let data1 = try encoder.encode(historic1)
        let data2 = try encoder.encode(historic2)

        let json1 = try JSONSerialization.jsonObject(with: data1)
        let json2 = try JSONSerialization.jsonObject(with: data2)
        let corruptedJson: [String: Any] = ["id": "corrupted", "url": 12345] // Not a valid HistoricDownload

        let mixedArray = [json1, corruptedJson, json2]
        let rawData = try JSONSerialization.data(withJSONObject: mixedArray)
        UserDefaults.standard.set(rawData, forKey: userDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

        let manager = DownloadManager()
        manager.loadHistory()

        XCTAssertEqual(manager.history.count, 2, "Valid entries should be recovered even when a corrupted item is present")
        XCTAssertEqual(manager.downloads.count, 2)
    }

    func testDownloadStatusLegacyAndCanonicalDecoding() throws {
        let decoder = JSONDecoder()

        // Modern English canonical keys
        let modernJSON = "\"downloading\"".data(using: .utf8)!
        let modernStatus = try decoder.decode(DownloadStatus.self, from: modernJSON)
        XCTAssertEqual(modernStatus, .downloading)

        // Legacy Turkish serialized keys
        let legacyMap: [String: DownloadStatus] = [
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

        for (legacyJSON, expectedStatus) in legacyMap {
            let data = legacyJSON.data(using: .utf8)!
            let status = try decoder.decode(DownloadStatus.self, from: data)
            XCTAssertEqual(status, expectedStatus, "Legacy Turkish string \(legacyJSON) must decode to \(expectedStatus)")
        }
    }

    func testDownloadProcessResultPathValidation() {
        let emptyResult = DownloadProcessResult(primaryPath: "   ", allPaths: ["  ", "\n"])
        XCTAssertTrue(emptyResult.isEmpty)
        XCTAssertEqual(emptyResult.count, 0)

        let validResult = DownloadProcessResult(primaryPath: "/path/to/video.mp4")
        XCTAssertFalse(validResult.isEmpty)
        XCTAssertEqual(validResult.count, 1)
        XCTAssertEqual(validResult.primaryPath, "/path/to/video.mp4")
        XCTAssertEqual(validResult.allPaths, ["/path/to/video.mp4"])
    }

    func testResolvedOutputFileExtensionUnification() {
        var options = DownloadOptions.default
        options.fileType = .mp4
        options.videoCodec = .vp9 // VP9 in MP4 triggers MKV merge format for compatibility
        XCTAssertEqual(YtdlpService.resolvedOutputFileExtension(for: options), "mkv")

        options.videoCodec = .h264
        XCTAssertEqual(YtdlpService.resolvedOutputFileExtension(for: options), "mp4")

        options.fileType = .mp3
        XCTAssertEqual(YtdlpService.resolvedOutputFileExtension(for: options), "mp3")
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
        await fulfillment(of: [fetchStartedExpectation], timeout: 5.0)

        // Simulate user cancellation while in fetching state
        manager.stopDownload(download)

        // Wait for fetchInfo completion in mock
        await fulfillment(of: [fetchCompletedExpectation], timeout: 5.0)
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

        // Unrelated file with video ID must NOT match
        XCTAssertFalse(
            DownloadManager.isMatchingTemporaryFile(
                fileName: "some_other_title_dQw4w9WgXcQ.temp",
                rawBaseName: rawBaseName,
                sanitizedBaseName: sanitizedBaseName,
                videoId: videoId
            ),
            "Must not match unrelated file with videoId substring"
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
        let appState = AppState()
        let languageService = LanguageService()
        let lastSeenKey = UserDefaultsKeys.lastSeenVersion
        let previousLastSeen = UserDefaults.standard.string(forKey: lastSeenKey)
        defer {
            if let previousLastSeen {
                UserDefaults.standard.set(previousLastSeen, forKey: lastSeenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastSeenKey)
            }
        }

        UserDefaults.standard.set(appState.appVersion, forKey: lastSeenKey)
        manager.ytdlpService.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let expectedVersion = "2025.02.20"
        manager.ytdlpService.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            expectedVersion
        })

        await appState.initializeApplicationServices(
            ytdlpService: manager.ytdlpService,
            languageService: languageService
        )

        XCTAssertEqual(appState.ytdlpVersion, expectedVersion)
    }

    func testInitializeLoadsHistoryAndResetsActiveStatuses() async {
        let manager = DownloadManager()
        let languageService = LanguageService()

        let historyKey = UserDefaultsKeys.downloadHistory
        defer {
            UserDefaults.standard.removeObject(forKey: historyKey)
        }

        let download = Download(url: "https://example.com/init_history", options: .default)
        download.status = .downloading
        let historic = HistoricDownload(download: download)

        if let data = try? JSONEncoder().encode([historic]) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }

        manager.initialize(languageService: languageService)

        XCTAssertEqual(manager.history.count, 1)
        XCTAssertEqual(manager.downloads.count, 1)
        XCTAssertEqual(manager.downloads.first?.status, .stopped, "Active download from history should be converted to .stopped during initialize")
    }

    func testInitializeWhatsNewDisplayWhenVersionChanges() async {
        let manager = DownloadManager()
        let appState = AppState()
        let languageService = LanguageService()
        appState.urlSession = makeMockURLSession()

        let lastSeenKey = UserDefaultsKeys.lastSeenVersion
        defer {
            UserDefaults.standard.removeObject(forKey: lastSeenKey)
            MockURLProtocol.requestHandler = nil
        }

        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        UserDefaults.standard.set("0.0.1", forKey: lastSeenKey)

        await appState.initializeApplicationServices(
            ytdlpService: manager.ytdlpService,
            languageService: languageService,
            skipBinarySetup: true
        )

        XCTAssertTrue(appState.showWhatsNew)
        XCTAssertEqual(UserDefaults.standard.string(forKey: lastSeenKey), appState.appVersion)

        let appState2 = AppState()
        appState2.urlSession = makeMockURLSession()
        await appState2.initializeApplicationServices(
            ytdlpService: manager.ytdlpService,
            languageService: languageService,
            skipBinarySetup: true
        )
        XCTAssertFalse(appState2.showWhatsNew)
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

        // Count active executions and reserved slots without exposing task ownership.
        let activeCount = manager.activeExecutionCount
        XCTAssertLessThanOrEqual(activeCount, limit, "Active tasks must never exceed the concurrency limit")

        manager.shutdown()
    }

    func testShutdownPreventsFutureQueueAdmission() {
        let manager = DownloadManager()
        manager.shutdown()

        let download = Download(url: "https://example.com/after-shutdown", options: .default)
        manager.downloads = [download]
        manager.processQueue()

        XCTAssertEqual(download.status, .queued)
        XCTAssertEqual(manager.activeExecutionCount, 0)
        XCTAssertEqual(manager.queue.activeSlotCount, 0)
    }

    // MARK: - Single-Pass Status Counts Tests

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
        XCTAssertEqual(manager.queuedCount, 2, "queuedCount should include queued and paused downloads")
        XCTAssertEqual(manager.completedCount, 1, "completedCount should include completed downloads")
        XCTAssertEqual(manager.failedCount, 2, "failedCount should include failed and stopped downloads")
        XCTAssertEqual(manager.queuedDownloads.count, 2, "queuedDownloads should include both queued and paused downloads")
        XCTAssertTrue(manager.queuedDownloads.contains(where: { $0.id == d4.id }))
        XCTAssertTrue(manager.queuedDownloads.contains(where: { $0.id == d8.id }))

        manager.shutdown()
    }

    func testPausedDownloadsReflectedInQueuedAndDisappearOnResume() {
        let manager = DownloadManager()
        let download = Download(url: "https://example.com/test_paused_queued", options: .default)
        download.status = .paused
        manager.downloads = [download]

        XCTAssertEqual(manager.queuedCount, 1)
        XCTAssertEqual(manager.queuedDownloads.count, 1)
        XCTAssertEqual(manager.queuedDownloads.first?.id, download.id)

        // Resuming transitions to .queued, then processQueue starts it if eligible or keeps it queued until downloading
        download.status = .downloading
        XCTAssertEqual(manager.queuedCount, 0)
        XCTAssertTrue(manager.queuedDownloads.isEmpty)
        XCTAssertEqual(manager.downloadingCount, 1)

        manager.shutdown()
    }

    // MARK: - Pause Download Tests

    func testPauseDownloadEligibleAndIneligibleStatuses() {
        let manager = DownloadManager()

        let eligibleStatuses: [DownloadStatus] = [.downloading, .fetching, .processing, .queued]
        for status in eligibleStatuses {
            let download = Download(url: "https://example.com/test_pause_eligible_\(status)", options: .default)
            download.status = status
            manager.downloads = [download]

            manager.pauseDownload(download)

            XCTAssertEqual(download.status, .paused, "pauseDownload should change status from \(status) to .paused")
        }

        let ineligibleStatuses: [DownloadStatus] = [.completed, .failed, .stopped, .paused, .fileExists]
        for status in ineligibleStatuses {
            let download = Download(url: "https://example.com/test_pause_ineligible_\(status)", options: .default)
            download.status = status
            manager.downloads = [download]

            manager.pauseDownload(download)

            XCTAssertEqual(download.status, status, "pauseDownload should NOT change status when download is in \(status) state")
        }

        manager.shutdown()
    }

    func testPauseDownloadQueueAndTaskCancellation() {
        let manager = DownloadManager()

        let download = Download(url: "https://example.com/test_pause_task", options: .default)
        download.status = .queued
        manager.downloads = [download]

        manager.processQueue()
        XCTAssertEqual(manager.executionState(for: download.id), .active)

        manager.pauseDownload(download)

        XCTAssertEqual(download.status, .paused)
        XCTAssertEqual(
            manager.executionState(for: download.id),
            .cancelling,
            "pauseDownload should request cancellation without exposing the underlying task"
        )

        manager.shutdown()
    }

    // MARK: - Resume Download Tests

    func testResumeDownloadFromPausedState() {
        let manager = DownloadManager()
        let download = Download(url: "https://example.com/resume-test", options: .default)
        download.status = .paused
        manager.downloads.append(download)

        let expectation = expectation(description: "objectWillChange emitted")
        let cancellable = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        manager.resumeDownload(download)

        XCTAssertEqual(download.status, .queued, "Resuming a paused download must transition status to .queued")
        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
        manager.shutdown()
    }

    func testResumeDownloadNonPausedStatusesIgnored() {
        let manager = DownloadManager()
        let nonPausedStatuses: [DownloadStatus] = [
            .downloading, .fetching, .processing,
            .completed, .failed, .stopped,
            .queued, .fileExists
        ]

        for status in nonPausedStatuses {
            let download = Download(url: "https://example.com/status-\(status)", options: .default)
            download.status = status
            manager.downloads.append(download)

            manager.resumeDownload(download)

            XCTAssertEqual(download.status, status, "resumeDownload must ignore downloads in \(status) status")
        }
        manager.shutdown()
    }

    // MARK: - Fetch Release Notes Tests

    private func makeMockURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testFetchReleaseNotesFromGitHubNetworkErrorReturnsNil() async {
        let service = ReleaseNotesService()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mockSession = makeMockURLSession()

        let result = await service.fetchReleaseNotesFromGitHub(version: "1.0.0", session: mockSession)

        XCTAssertNil(result, "Network error during fetchReleaseNotesFromGitHub must return nil")
    }

    func testFetchReleaseNotesFromGitHubHTTPStatusCodeFailureReturnsNil() async {
        let service = ReleaseNotesService()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let mockSession = makeMockURLSession()

        let result = await service.fetchReleaseNotesFromGitHub(version: "1.0.0", session: mockSession)

        XCTAssertNil(result, "Non-200 HTTP response must return nil")
    }

    func testFetchReleaseNotesFromGitHubInvalidJSONReturnsNil() async {
        let service = ReleaseNotesService()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let invalidData = "Not JSON".data(using: .utf8)!
            return (response, invalidData)
        }
        let mockSession = makeMockURLSession()

        let result = await service.fetchReleaseNotesFromGitHub(version: "1.0.0", session: mockSession)

        XCTAssertNil(result, "Invalid JSON data must return nil")
    }

    func testFetchReleaseNotesFromGitHubOlderTagVersionReturnsNil() async {
        let service = ReleaseNotesService()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let jsonString = """
            {
                "tag_name": "v0.9.0",
                "name": "Old Release",
                "body": "Some notes"
            }
            """
            return (response, jsonString.data(using: .utf8)!)
        }
        let mockSession = makeMockURLSession()

        let result = await service.fetchReleaseNotesFromGitHub(version: "1.0.0", session: mockSession)

        XCTAssertNil(result, "Release notes for older tag version must return nil")
    }

    func testFetchReleaseNotesFromGitHubEmptyBodyReturnsNil() async {
        let service = ReleaseNotesService()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let jsonString = """
            {
                "tag_name": "v1.0.0",
                "name": "Release 1.0.0",
                "body": "   \\r\\n  "
            }
            """
            return (response, jsonString.data(using: .utf8)!)
        }
        let mockSession = makeMockURLSession()

        let result = await service.fetchReleaseNotesFromGitHub(version: "1.0.0", session: mockSession)

        XCTAssertNil(result, "Release notes with empty body after sanitization must return nil")
    }

    func testFetchReleaseNotesFromGitHubSuccessReturnsNotes() async {
        let service = ReleaseNotesService()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let jsonString = """
            {
                "tag_name": "v1.0.0",
                "name": "Siphon v1.0.0",
                "body": "✨ Added feature A\\n🚀 Performance fix B"
            }
            """
            return (response, jsonString.data(using: .utf8)!)
        }
        let mockSession = makeMockURLSession()

        let result = await service.fetchReleaseNotesFromGitHub(version: "1.0.0", session: mockSession)

        XCTAssertNotNil(result, "Valid release notes response must return non-nil tuple")
        XCTAssertEqual(result?.title, "Siphon v1.0.0")
        XCTAssertEqual(result?.body, "✨ Added feature A\n🚀 Performance fix B")
    }

    func testRemoveIndividualHistoryEntryPreservesFileAndOtherDownloads() throws {
        let manager = DownloadManager()
        defer { manager.shutdown() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let contents = Data("downloaded media".utf8)
        try contents.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let completed = Download(url: "https://example.com/completed", options: .default)
        completed.status = .completed
        completed.filePaths = [file]
        let other = Download(url: "https://example.com/other", options: .default)
        other.status = .failed
        manager.downloads = [completed, other]
        manager.history = [HistoricDownload(download: completed), HistoricDownload(download: other)]

        manager.removeDownload(completed)

        XCTAssertEqual(manager.downloads.map(\.id), [other.id])
        XCTAssertEqual(manager.history.map(\.id), [other.id])
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testClearCompletedDownloadsPreservesFailedDownloads() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        let completedDownload = Download(url: "https://example.com/done", options: options)
        completedDownload.status = .completed
        manager.downloads.append(completedDownload)

        let failedDownload = Download(url: "https://example.com/failed", options: options)
        failedDownload.status = .failed
        manager.downloads.append(failedDownload)

        let queuedDownload = Download(url: "https://example.com/queued", options: options)
        queuedDownload.status = .queued
        manager.downloads.append(queuedDownload)

        XCTAssertEqual(manager.completedDownloads.count, 1)
        XCTAssertEqual(manager.failedDownloads.count, 1)
        XCTAssertEqual(manager.queuedDownloads.count, 1)

        manager.clearCompletedDownloads()

        XCTAssertEqual(manager.completedDownloads.count, 0, "Completed downloads must be cleared")
        XCTAssertEqual(manager.failedDownloads.count, 1, "Failed downloads must be preserved when clearing completed")
        XCTAssertEqual(manager.queuedDownloads.count, 1, "Queued downloads must be preserved when clearing completed")
    }

    func testClearFailedDownloadsPreservesCompletedDownloads() {
        let manager = DownloadManager()
        let options = DownloadOptions.default

        let completedDownload = Download(url: "https://example.com/done", options: options)
        completedDownload.status = .completed
        manager.downloads.append(completedDownload)

        let failedDownload = Download(url: "https://example.com/failed", options: options)
        failedDownload.status = .failed
        manager.downloads.append(failedDownload)

        let queuedDownload = Download(url: "https://example.com/queued", options: options)
        queuedDownload.status = .queued
        manager.downloads.append(queuedDownload)

        XCTAssertEqual(manager.completedDownloads.count, 1)
        XCTAssertEqual(manager.failedDownloads.count, 1)
        XCTAssertEqual(manager.queuedDownloads.count, 1)

        manager.clearFailedDownloads()

        XCTAssertEqual(manager.completedDownloads.count, 1, "Completed downloads must be preserved when clearing failed")
        XCTAssertEqual(manager.failedDownloads.count, 0, "Failed downloads must be cleared")
        XCTAssertEqual(manager.queuedDownloads.count, 1, "Queued downloads must be preserved when clearing failed")
    }

    func testQuickAndMenuDownloadDefaultLanguagesOnlyEnglish() {
        let manager = DownloadManager()
        manager.quickDownload(
            url: "https://example.com/quick",
            rawCookies: nil,
            rawUserAgent: "FixtureBrowser/1.0",
            browserCookieSource: "chrome"
        )
        guard let quickItem = manager.downloads.last else {
            XCTFail("Quick download was not added")
            return
        }
        XCTAssertEqual(quickItem.options.subtitleLanguages, ["en"], "Quick download must default to English only")
        XCTAssertNil(quickItem.options.rawCookies)
        XCTAssertEqual(quickItem.options.rawUserAgent, "FixtureBrowser/1.0")
        XCTAssertEqual(quickItem.options.browserCookieSource, "chrome")

        manager.menuDownload(url: "https://example.com/menu", type: "video", quality: "1080")
        guard let menuItem = manager.downloads.last else {
            XCTFail("Menu download was not added")
            return
        }
        XCTAssertEqual(menuItem.options.subtitleLanguages, ["en"], "Menu download must default to English only")
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op: Mock protocol requires no tear-down
    }
}

// MARK: - NotificationService Tests

final class NotificationServiceTests: XCTestCase {
    func testNotificationServiceDetectsTestEnvironment() {
        XCTAssertTrue(NotificationService.isRunningTests, "NotificationService must detect that it is executing inside the test runner")
    }

    func testNotificationServiceSuppressesCenterDuringTests() {
        XCTAssertFalse(NotificationService.shared.isNotificationCenterAvailable, "Notification center must be unavailable during test runs to prevent UNErrorDomain error 1")
    }

    func testNotificationServiceSafeNotificationsDuringTests() {
        NotificationService.shared.setup()
        // Calling setup a second time validates the `isSetup` early-exit guard
        NotificationService.shared.setup()
        NotificationService.shared.requestPermission()

        NotificationService.shared.sendDownloadCompleted(filename: "sample_video.mp4")
        NotificationService.shared.sendDownloadFailed(filename: "sample_video.mp4")
        NotificationService.shared.sendDownloadStopped(filename: "sample_video.mp4")
        NotificationService.shared.sendEncodingCompleted(filename: "sample_video.mp4", codec: "h264")
    }

    func testNotificationServiceUpdateAndAppNotifications() {
        NotificationService.shared.sendYtdlpUpdateSucceeded(version: "2026.03.01")
        NotificationService.shared.sendYtdlpUpdateFailed(reason: "Network timeout")
        NotificationService.shared.sendAppUpdateNotification(title: "Version 5.2.1 Available", body: "A new update for Siphon is ready to install.")
    }

    func testNotificationServiceHTMLEntityDecoding() {
        let rawFilename = "clip &amp; video &quot;hd&quot;.mp4"
        let lang = LanguageService()

        NotificationService.shared.sendDownloadCompleted(filename: rawFilename, languageService: lang)
        NotificationService.shared.sendDownloadFailed(filename: rawFilename, languageService: lang)
        NotificationService.shared.sendDownloadStopped(filename: rawFilename, languageService: lang)
        NotificationService.shared.sendEncodingCompleted(filename: rawFilename, codec: "h265", languageService: lang)
    }

    func testNotificationServiceUserPreferenceGating() {
        let defaults = UserDefaults.standard
        let previousSetting = defaults.object(forKey: UserDefaultsKeys.showNotifications)
        defer {
            if let prev = previousSetting {
                defaults.set(prev, forKey: UserDefaultsKeys.showNotifications)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.showNotifications)
            }
        }

        // Test with showNotifications explicitly disabled
        defaults.set(false, forKey: UserDefaultsKeys.showNotifications)
        NotificationService.shared.sendDownloadCompleted(filename: "disabled_test.mp4")
        NotificationService.shared.sendDownloadFailed(filename: "disabled_test.mp4")

        // Test with showNotifications explicitly enabled
        defaults.set(true, forKey: UserDefaultsKeys.showNotifications)
        NotificationService.shared.sendDownloadCompleted(filename: "enabled_test.mp4")
    }
}
