import XCTest
@testable import Siphon

final class TestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
final class YtdlpServiceTests: XCTestCase {

    var service: YtdlpService!

    override func setUp() {
        super.setUp()
        service = YtdlpService()
        // Setup mock paths so we don't throw notFound initially, except when testing for it.
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        service.ffmpegPath = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        service.ffprobePath = URL(fileURLWithPath: "/usr/local/bin/ffprobe")
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    func testFetchInfoSuccess() async throws {
        // 🎯 What: Test that fetchInfo correctly parses valid JSON into a MediaInfo object for a single video.
        let expectedJSON = """
        {
            "id": "test_video_id",
            "title": "Test Video Title",
            "description": "This is a test description",
            "duration": 120.0,
            "uploader": "Test Uploader"
        }
        """

        service.mockCommandRunner = { args in
            return expectedJSON
        }

        let mediaInfo = try await service.fetchInfo(url: "https://www.youtube.com/watch?v=test_video_id")

        XCTAssertEqual(mediaInfo.id, "test_video_id")
        XCTAssertEqual(mediaInfo.title, "Test Video Title")
        XCTAssertEqual(mediaInfo.description, "This is a test description")
        XCTAssertEqual(mediaInfo.duration, 120.0)
        XCTAssertEqual(mediaInfo.uploader, "Test Uploader")
    }

    func testFetchInfoPlaylistFallback() async throws {
        // 🎯 What: Test that if single video fetch fails but the URL contains /playlist, it falls back to fetchPlaylistSummaryInfo.
        let validPlaylistJSON = """
        {
            "id": "test_playlist_id",
            "title": "Test Playlist",
            "uploader": "Playlist Uploader",
            "playlist_count": 5,
            "playlist": "test_playlist_id"
        }
        """

        let callCountBox = TestBox(0)
        service.mockCommandRunner = { args in
            callCountBox.value += 1
            if callCountBox.value == 1 {
                // First call: simulate failure of single video fetch
                throw YtdlpError.commandFailed("Simulated single video failure")
            } else {
                // Subsequent calls: return valid playlist JSON
                return validPlaylistJSON
            }
        }

        let mediaInfo = try await service.fetchInfo(url: "https://www.youtube.com/playlist?list=test_playlist_id")

        XCTAssertGreaterThanOrEqual(callCountBox.value, 2, "Expected mock to be called at least twice: once for single video, once for playlist fallback")
        XCTAssertEqual(mediaInfo.id, "test_playlist_id")
        XCTAssertEqual(mediaInfo.title, "Test Playlist")
        XCTAssertEqual(mediaInfo.playlistCount, 5)
        XCTAssertEqual(mediaInfo.playlist, "test_playlist_id", "Playlist ID should be mapped to playlist property")
    }

    func testFetchInfoParseError() async throws {
        // 🎯 What: Test that invalid JSON response throws a parseError.
        let invalidJSON = "This is not valid JSON"

        service.mockCommandRunner = { args in
            return invalidJSON
        }

        do {
            _ = try await service.fetchInfo(url: "https://www.youtube.com/watch?v=test_video_id")
            XCTFail("Expected fetchInfo to throw an error")
        } catch YtdlpError.parseError {
            // Expected
        } catch {
            XCTFail("Expected YtdlpError.parseError, but got: \(error)")
        }
    }

    func testFetchInfoYtdlpNotFound() async throws {
        // 🎯 What: Test that if ytdlpPath is nil, it throws notFound error immediately.
        service.ytdlpPath = nil

        do {
            _ = try await service.fetchInfo(url: "https://www.youtube.com/watch?v=test_video_id")
            XCTFail("Expected fetchInfo to throw an error")
        } catch YtdlpError.notFound {
            // Expected
        } catch {
            XCTFail("Expected YtdlpError.notFound, but got: \(error)")
        }
    }

    func testVerifySHA256CryptographicValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("sha256_test_\(UUID().uuidString).bin")
        let testContent = "Siphon Secure Media Downloader Test Content".data(using: .utf8)!
        try testContent.write(to: testFile)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Expected SHA-256 for testContent
        let expectedHash = "cadd1db9485d4657d4a9084d308ae8eb6fb3086d9ce295f3134b598f028bdc0d"

        // 1. Valid hash match
        XCTAssertTrue(YtdlpService.verifySHA256(fileURL: testFile, expectedHash: expectedHash))
        XCTAssertTrue(YtdlpService.verifySHA256(fileURL: testFile, expectedHash: expectedHash.uppercased()))

        // 2. Tampered content (1 byte modified)
        var tamperedContent = testContent
        tamperedContent[0] ^= 0xFF
        let tamperedFile = tempDir.appendingPathComponent("sha256_tampered_\(UUID().uuidString).bin")
        try tamperedContent.write(to: tamperedFile)
        defer { try? FileManager.default.removeItem(at: tamperedFile) }

        XCTAssertFalse(YtdlpService.verifySHA256(fileURL: tamperedFile, expectedHash: expectedHash))

        // 3. Non-existent file
        let nonExistentFile = tempDir.appendingPathComponent("non_existent_\(UUID().uuidString).bin")
        XCTAssertFalse(YtdlpService.verifySHA256(fileURL: nonExistentFile, expectedHash: expectedHash))
    }

    func testPathContainmentSecurityValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sandboxFolder = tempDir.appendingPathComponent("siphon_containment_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxFolder) }

        // 1. Valid child file
        let validChild = sandboxFolder.appendingPathComponent("media.mp4")
        XCTAssertTrue(YtdlpService.isPathContained(targetURL: validChild, inside: sandboxFolder))

        // 2. Valid nested child
        let validNested = sandboxFolder.appendingPathComponent("subfolder/media.mp4")
        XCTAssertTrue(YtdlpService.isPathContained(targetURL: validNested, inside: sandboxFolder))

        // 3. Directory traversal attempt
        let outsideTarget = sandboxFolder.appendingPathComponent("../../evil.mp4")
        XCTAssertFalse(YtdlpService.isPathContained(targetURL: outsideTarget, inside: sandboxFolder))

        // 4. Absolute path to system directory
        let systemPath = URL(fileURLWithPath: "/etc/passwd")
        XCTAssertFalse(YtdlpService.isPathContained(targetURL: systemPath, inside: sandboxFolder))

        // 5. Symlink escaping designated directory
        let outsideFile = tempDir.appendingPathComponent("outside_\(UUID().uuidString).txt")
        try "outside".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let symlinkInSandbox = sandboxFolder.appendingPathComponent("symlink_escape.mp4")
        try? FileManager.default.createSymbolicLink(at: symlinkInSandbox, withDestinationURL: outsideFile)

        XCTAssertFalse(YtdlpService.isPathContained(targetURL: symlinkInSandbox, inside: sandboxFolder))
    }

    func testPurgeOrphanedTempCookieFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let staleCookieFile = tempDir.appendingPathComponent("siphon_cookies_test_purge.txt")
        let staleHeaderCookieFile = tempDir.appendingPathComponent("siphon_header_cookies_test_purge.txt")
        let regularFile = tempDir.appendingPathComponent("siphon_regular_file.txt")

        try "test".write(to: staleCookieFile, atomically: true, encoding: .utf8)
        try "test".write(to: staleHeaderCookieFile, atomically: true, encoding: .utf8)
        try "test".write(to: regularFile, atomically: true, encoding: .utf8)

        YtdlpService.purgeOrphanedTempCookieFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleCookieFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleHeaderCookieFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: regularFile.path))

        try? FileManager.default.removeItem(at: regularFile)
    }

    func testSpeedLimiterFlagAppendedWhenConfigured() async throws {
        UserDefaults.standard.set(5120, forKey: UserDefaultsKeys.downloadSpeedLimit)
        defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.downloadSpeedLimit) }

        let capturedArgsBox = TestBox<[String]>([])
        service.mockDownloadRunner = { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        }

        let options = DownloadOptions.default
        _ = try await service.download(
            url: "https://example.com/video",
            options: options,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertTrue(capturedArgsBox.value.contains("--limit-rate"))
        if let idx = capturedArgsBox.value.firstIndex(of: "--limit-rate") {
            XCTAssertEqual(capturedArgsBox.value[idx + 1], "5120K")
        }
    }

    func testCustomFormatIdSelectionFlagAppended() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.mockDownloadRunner = { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        }

        var options = DownloadOptions.default
        options.selectedFormatId = "137+140"

        _ = try await service.download(
            url: "https://example.com/video",
            options: options,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertTrue(capturedArgsBox.value.contains("-f"))
        if let idx = capturedArgsBox.value.firstIndex(of: "-f") {
            XCTAssertEqual(capturedArgsBox.value[idx + 1], "137+140")
        }
    }

    func testAudioExtractionAndMetadataFlags() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.mockDownloadRunner = { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp3\n"
        }

        var options = DownloadOptions.default
        options.fileType = .mp3
        options.embedThumbnail = true
        options.embedMetadata = true

        _ = try await service.download(
            url: "https://example.com/audio",
            options: options,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertTrue(capturedArgsBox.value.contains("-x"))
        XCTAssertTrue(capturedArgsBox.value.contains("--audio-format"))
        XCTAssertTrue(capturedArgsBox.value.contains("mp3"))
        XCTAssertTrue(capturedArgsBox.value.contains("--embed-thumbnail"))
        XCTAssertTrue(capturedArgsBox.value.contains("--embed-metadata"))
    }

    func testThisVidURLNormalizationAndHeaders() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.mockDownloadRunner = { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        }

        var options = DownloadOptions.default
        options.videoResolution = .r1080p

        _ = try await service.download(
            url: "https://thisvid.com/playlist/461301/video/huge-butt5/",
            options: options,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        // Verify URL was normalized/resolved for ThisVid extractor with required headers
        XCTAssertTrue(capturedArgsBox.value.contains(where: { $0.contains("thisvid") || $0.contains("huge-butt5") }))
        XCTAssertTrue(capturedArgsBox.value.contains("Referer:https://thisvid.com/"))
        XCTAssertTrue(capturedArgsBox.value.contains("Origin:https://thisvid.com"))
    }
}
