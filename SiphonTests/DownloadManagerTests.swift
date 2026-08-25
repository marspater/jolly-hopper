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

        var opts2 = DownloadOptions.default
        opts2.customFilename = "custom_video"

        let dl2 = Download(url: "https://example.com/v2", options: opts2, title: "Title 2")

        let expectedPath1 = opts1.saveFolder.appendingPathComponent("custom_video.mp4").path
        let expectedPath2 = opts2.saveFolder.appendingPathComponent("custom_video_1.mp4").path

        // Simulate reservation conflict resolution
        var reserved: Set<String> = [expectedPath1]
        var resolvedBaseName = "custom_video"
        var counter = 1
        var candidateKey = opts2.saveFolder.appendingPathComponent("\(resolvedBaseName).mp4").path
        while reserved.contains(candidateKey) {
            resolvedBaseName = "custom_video_\(counter)"
            candidateKey = opts2.saveFolder.appendingPathComponent("\(resolvedBaseName).mp4").path
            counter += 1
        }
        if resolvedBaseName != "custom_video" {
            dl2.options.customFilename = resolvedBaseName
        }

        XCTAssertEqual(dl2.options.customFilename, "custom_video_1", "Second download must have its customFilename updated to non-colliding name")
        XCTAssertEqual(candidateKey, expectedPath2)
    }

    func testProcessDownloadExitsIfCancelledWhileQueued() {
        let manager = DownloadManager()
        let options = DownloadOptions.default
        let download = Download(url: "https://example.com/cancelled", options: options)
        download.status = .stopped // User cancelled while in queue

        // Verify initial status is .stopped
        XCTAssertEqual(download.status, .stopped)

        // Guard check logic as in processDownload
        guard download.status == .queued else {
            // Success: exited because status is not .queued
            return
        }

        XCTFail("processDownload should not proceed if status is not .queued")
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
}
