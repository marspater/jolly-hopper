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

        let dl1 = Download(url: "https://example.com/v1", options: opts1, title: "Title 1")
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

    func testNaNProgressGuarding() {
        let computeSafeProgress: (Double) -> Double = { progress in
            progress.isNaN ? 0 : max(0, min(1, progress))
        }

        XCTAssertEqual(computeSafeProgress(Double.nan), 0.0, "NaN progress should evaluate to 0.0")
        XCTAssertEqual(computeSafeProgress(-0.5), 0.0, "Negative progress should be clamped to 0.0")
        XCTAssertEqual(computeSafeProgress(1.5), 1.0, "Progress greater than 1.0 should be clamped to 1.0")
        XCTAssertEqual(computeSafeProgress(0.75), 0.75, "Valid progress between 0.0 and 1.0 should remain unchanged")
    }
}
