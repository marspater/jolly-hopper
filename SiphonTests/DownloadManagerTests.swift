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
}
