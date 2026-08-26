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
}
