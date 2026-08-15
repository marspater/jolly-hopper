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

    func testMetadataFlagGatingWhenDisabled() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.mockDownloadRunner = { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        }

        var options = DownloadOptions.default
        options.embedMetadata = false

        _ = try await service.download(
            url: "https://example.com/video",
            options: options,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertFalse(capturedArgsBox.value.contains("--embed-metadata"))
        XCTAssertFalse(capturedArgsBox.value.contains("--embed-chapters"))
        XCTAssertTrue(capturedArgsBox.value.contains("--ignore-config"))
    }

    func testLoggerServiceSanitizeURLForLog() {
        let sensitiveURL = "https://example.com/video/12345?token=SECRET123&expires=999999&sig=ABCDEF#section"
        let sanitized = LoggerService.sanitizeURLForLog(sensitiveURL)

        XCTAssertEqual(sanitized, "https://example.com/video/12345")
        XCTAssertFalse(sanitized.contains("token"))
        XCTAssertFalse(sanitized.contains("SECRET123"))
        XCTAssertFalse(sanitized.contains("sig"))
    }

    func testThreadSafeOutputStateCandidateHandling() {
        let state = ThreadSafeOutputState()
        state.addCandidatePath("   \"/tmp/downloaded_video.mp4\"   ")
        state.addCandidatePath("'/tmp/converted_video.mp4'")
        state.addCandidatePath("/tmp/final_video.mp4")

        let candidates = state.getCandidatePaths()
        XCTAssertEqual(candidates, [
            "/tmp/downloaded_video.mp4",
            "/tmp/converted_video.mp4",
            "/tmp/final_video.mp4"
        ])
    }

    func testConcurrentDownloadsWithIdenticalTitlesResolveCorrectly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sessionFolder = tempDir.appendingPathComponent("siphon_concurrent_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionFolder) }

        let fileA = sessionFolder.appendingPathComponent("SameTitle [idA].mp4")
        let fileB = sessionFolder.appendingPathComponent("SameTitle [idB].mp4")
        try "Media Content A".data(using: .utf8)?.write(to: fileA)
        try "Media Content B".data(using: .utf8)?.write(to: fileB)

        let serviceA = YtdlpService()
        serviceA.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        serviceA.mockDownloadRunner = { args in
            return fileA.path
        }

        let serviceB = YtdlpService()
        serviceB.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        serviceB.mockDownloadRunner = { args in
            return fileB.path
        }

        var optionsA = DownloadOptions.default
        optionsA.saveFolder = sessionFolder
        var optionsB = DownloadOptions.default
        optionsB.saveFolder = sessionFolder

        async let resultA = serviceA.download(
            url: "https://example.com/videoA",
            options: optionsA,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        async let resultB = serviceB.download(
            url: "https://example.com/videoB",
            options: optionsB,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let (urlA, urlB) = try await (resultA, resultB)
        XCTAssertEqual(urlA.path, fileA.path)
        XCTAssertEqual(urlB.path, fileB.path)
        XCTAssertNotEqual(urlA.path, urlB.path)
    }

    func testByteSafeStreamBufferSplitUTF8() {
        let buffer = StreamBuffer()

        // "Test ✅ Title\n" in UTF-8 bytes:
        // '✅' is 3 bytes: 0xE2, 0x9C, 0x85
        let text = "Test ✅ Title\n"
        let fullData = text.data(using: .utf8)!

        // Split right inside the 3-byte UTF-8 emoji
        let splitIndex = 7 // Inside the emoji
        let chunk1 = fullData.subdata(in: 0..<splitIndex)
        let chunk2 = fullData.subdata(in: splitIndex..<fullData.count)

        let lines1 = buffer.appendAndExtractLines(chunk1)
        XCTAssertTrue(lines1.isEmpty, "Should not emit lines until newline byte is reached")

        let lines2 = buffer.appendAndExtractLines(chunk2)
        XCTAssertEqual(lines2, ["Test ✅ Title"], "Complete line with split UTF-8 character must decode cleanly")
    }

    func testSanitizeCommandForLog() {
        let args = [
            "/usr/local/bin/yt-dlp",
            "--ignore-config",
            "--cookies",
            "/tmp/siphon_cookie_secret_123.txt",
            "--add-header",
            "Authorization: Bearer SECRET_TOKEN_ABC",
            "--add-header",
            "Referer:https://site.example/page",
            "https://site.example/watch?v=12345&token=SECRET999&sig=ABCDEF#section"
        ]

        let sanitized = LoggerService.sanitizeCommandForLog(args)

        XCTAssertTrue(sanitized.contains("/usr/local/bin/yt-dlp"))
        XCTAssertTrue(sanitized.contains("--ignore-config"))
        XCTAssertTrue(sanitized.contains("--cookies \"<COOKIE_FILE>\""))
        XCTAssertTrue(sanitized.contains("--add-header \"<REDACTED_HEADER>\""))
        XCTAssertTrue(sanitized.contains("https://site.example/watch"))
        XCTAssertFalse(sanitized.contains("siphon_cookie_secret_123"))
        XCTAssertFalse(sanitized.contains("SECRET_TOKEN_ABC"))
        XCTAssertFalse(sanitized.contains("token=SECRET999"))
        XCTAssertFalse(sanitized.contains("sig=ABCDEF"))
    }

    func testMediaExtensionAllowlist() {
        // Supported extensions must pass
        XCTAssertTrue(YtdlpService.isMediaFilePath("/path/to/video.mp4"))
        XCTAssertTrue(YtdlpService.isMediaFilePath("/path/to/video.mkv"))
        XCTAssertTrue(YtdlpService.isMediaFilePath("/path/to/video.webm"))
        XCTAssertTrue(YtdlpService.isMediaFilePath("/path/to/audio.mp3"))
        XCTAssertTrue(YtdlpService.isMediaFilePath("/path/to/audio.m4a"))
        XCTAssertTrue(YtdlpService.isMediaFilePath("/path/to/audio.opus"))
        XCTAssertTrue(YtdlpService.isMediaFilePath("/path/to/audio.flac"))

        // Unsafe or non-media extensions must fail
        XCTAssertFalse(YtdlpService.isMediaFilePath("/path/to/malicious.exe"))
        XCTAssertFalse(YtdlpService.isMediaFilePath("/path/to/installer.dmg"))
        XCTAssertFalse(YtdlpService.isMediaFilePath("/path/to/archive.zip"))
        XCTAssertFalse(YtdlpService.isMediaFilePath("/path/to/document.pdf"))
        XCTAssertFalse(YtdlpService.isMediaFilePath("/path/to/script.js"))
    }

    func testTransactionalInstallRollback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let workFolder = tempDir.appendingPathComponent("tx_install_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }

        let originalBinary = workFolder.appendingPathComponent("bin_target")
        let candidateBinary = workFolder.appendingPathComponent("bin_candidate")

        try "ORIGINAL_WORKING_VERSION".data(using: .utf8)?.write(to: originalBinary)
        try "BROKEN_NEW_VERSION".data(using: .utf8)?.write(to: candidateBinary)

        let service = YtdlpService()

        // Case A: Validation fails -> rollback to original
        let resultFailed = try await service.transactionalInstall(from: candidateBinary, to: originalBinary) { targetURL in
            return false // Simulation of post-validation failure
        }

        XCTAssertFalse(resultFailed)
        let contentAfterRollback = try String(contentsOf: originalBinary, encoding: .utf8)
        XCTAssertEqual(contentAfterRollback, "ORIGINAL_WORKING_VERSION")

        // Case B: Validation succeeds -> replace and delete backup
        let newCandidate = workFolder.appendingPathComponent("bin_candidate_good")
        try "NEW_WORKING_VERSION".data(using: .utf8)?.write(to: newCandidate)

        let resultSuccess = try await service.transactionalInstall(from: newCandidate, to: originalBinary) { targetURL in
            return true // Simulation of validation success
        }

        XCTAssertTrue(resultSuccess)
        let contentAfterSuccess = try String(contentsOf: originalBinary, encoding: .utf8)
        XCTAssertEqual(contentAfterSuccess, "NEW_WORKING_VERSION")
    }

    func testCandidateCollisionDoesNotClaimUnrelatedFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sessionFolder = tempDir.appendingPathComponent("collision_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionFolder) }

        // B.mp4 exists in saveFolder (unrelated user file)
        let unrelatedFile = sessionFolder.appendingPathComponent("B.mp4")
        try "UNRELATED_USER_FILE".data(using: .utf8)?.write(to: unrelatedFile)

        // yt-dlp reported A.mp4 (which was never created / failed during conversion)
        let ghostFile = sessionFolder.appendingPathComponent("A.mp4")

        let state = ThreadSafeOutputState()
        state.addCandidatePath(ghostFile.path)

        let candidates = state.getCandidatePaths()
        let fm = FileManager.default
        var finalURL: URL? = nil
        for candidate in candidates.reversed() {
            let rawURL = candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : sessionFolder.appendingPathComponent(candidate)
            let resolved = rawURL.standardizedFileURL.resolvingSymlinksInPath()
            if fm.fileExists(atPath: resolved.path),
               let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true,
               YtdlpService.isMediaFilePath(resolved.path),
               YtdlpService.isPathContained(targetURL: resolved, inside: sessionFolder) {
                finalURL = resolved
                break
            }
        }

        XCTAssertNil(finalURL, "Resolution must fail when candidate does not exist")
        XCTAssertTrue(fm.fileExists(atPath: unrelatedFile.path), "Unrelated B.mp4 must remain untouched")
        let unrelatedContent = try String(contentsOf: unrelatedFile, encoding: .utf8)
        XCTAssertEqual(unrelatedContent, "UNRELATED_USER_FILE")
    }

    func testSafeContinuationDoubleResumeProtection() async throws {
        let expectation = expectation(description: "Continuation resumes exactly once")
        
        let checkedResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let safeCont = SafeContinuation(continuation)
            
            // First resume succeeds
            safeCont.resume(returning: 42)
            expectation.fulfill()
            
            // Subsequent resumes are ignored and will not crash
            safeCont.resume(returning: 99)
            safeCont.resume(throwing: YtdlpError.downloadFailed("Ignored"))
        }

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(checkedResult, 42)
    }

    func testSanitizeCommandForLogSensitiveCredentials() {
        let args = [
            "yt-dlp",
            "--username", "secret_user@example.com",
            "--password", "MyP@ssw0rd!123",
            "--proxy", "http://user:pass@127.0.0.1:8080",
            "https://site.example/video?auth=SECRET"
        ]

        let sanitized = LoggerService.sanitizeCommandForLog(args)
        XCTAssertTrue(sanitized.contains("--username \"<USERNAME>\""))
        XCTAssertTrue(sanitized.contains("--password \"<PASSWORD>\""))
        XCTAssertTrue(sanitized.contains("--proxy \"<PROXY_REDACTED>\""))
        XCTAssertTrue(sanitized.contains("https://site.example/video"))
        XCTAssertFalse(sanitized.contains("secret_user@example.com"))
        XCTAssertFalse(sanitized.contains("MyP@ssw0rd!123"))
        XCTAssertFalse(sanitized.contains("auth=SECRET"))
    }

    func testCancellationBoxStateManagement() {
        let box = CancellationBox()
        XCTAssertFalse(box.isCancelled)

        box.cancel()
        XCTAssertTrue(box.isCancelled)
    }

    func testSpeedOptimizationAndStreamConcurrencyFlags() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.mockDownloadRunner = { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        }

        // Test A: Direct progressive stream (e.g. ThisVid)
        _ = try await service.download(
            url: "https://thisvid.com/videos/test-progressive-stream",
            options: DownloadOptions.default,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let directArgs = capturedArgsBox.value
        XCTAssertTrue(directArgs.contains("--http-chunk-size"))
        if let idx = directArgs.firstIndex(of: "--http-chunk-size") {
            XCTAssertEqual(directArgs[idx + 1], "10M")
        }
        XCTAssertTrue(directArgs.contains("--throttled-rate"))
        if let idx = directArgs.firstIndex(of: "--throttled-rate") {
            XCTAssertEqual(directArgs[idx + 1], "100K")
        }
        XCTAssertFalse(directArgs.contains("--concurrent-fragments"), "Direct MP4 must not have concurrent-fragments flag")

        // Test B: Generic webpage URL (e.g. YouTube) with metadata-derived isFragmentedStream = true
        var ytOptions = DownloadOptions.default
        ytOptions.isFragmentedStream = true
        _ = try await service.download(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            options: ytOptions,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let ytArgs = capturedArgsBox.value
        XCTAssertTrue(ytArgs.contains("--http-chunk-size"))
        XCTAssertTrue(ytArgs.contains("--throttled-rate"))
        XCTAssertTrue(ytArgs.contains("--concurrent-fragments"))
        if let idx = ytArgs.firstIndex(of: "--concurrent-fragments") {
            XCTAssertEqual(ytArgs[idx + 1], "8")
        }

        // Test C: Direct HLS manifest URL (e.g. BoyfriendTV)
        _ = try await service.download(
            url: "https://www.boyfriend.tv/videos/12345/test-hls-stream",
            options: DownloadOptions.default,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let hlsArgs = capturedArgsBox.value
        XCTAssertTrue(hlsArgs.contains("--http-chunk-size"))
        XCTAssertTrue(hlsArgs.contains("--throttled-rate"))
        XCTAssertTrue(hlsArgs.contains("--concurrent-fragments"))
        if let idx = hlsArgs.firstIndex(of: "--concurrent-fragments") {
            XCTAssertEqual(hlsArgs[idx + 1], "8")
        }
    }

    func testMediaInfoFragmentedStreamDetection() {
        let jsonHLS = """
        {
            "id": "test_video",
            "title": "HLS Video",
            "protocol": "m3u8_native",
            "manifest_url": "https://example.com/master.m3u8"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let infoHLS = try? decoder.decode(MediaInfo.self, from: jsonHLS)
        XCTAssertNotNil(infoHLS)
        XCTAssertTrue(infoHLS?.isFragmented == true)

        let jsonDASH = """
        {
            "id": "test_dash",
            "title": "DASH Video",
            "formats": [
                {
                    "format_id": "137",
                    "ext": "mp4",
                    "protocol": "http_dash_segments"
                }
            ]
        }
        """.data(using: .utf8)!

        let infoDASH = try? decoder.decode(MediaInfo.self, from: jsonDASH)
        XCTAssertNotNil(infoDASH)
        XCTAssertTrue(infoDASH?.isFragmented == true)

        let jsonDirectMP4 = """
        {
            "id": "test_direct",
            "title": "Direct MP4 Video",
            "protocol": "https",
            "formats": [
                {
                    "format_id": "http-1080p",
                    "ext": "mp4",
                    "protocol": "https"
                }
            ]
        }
        """.data(using: .utf8)!

        let infoDirect = try? decoder.decode(MediaInfo.self, from: jsonDirectMP4)
        XCTAssertNotNil(infoDirect)
        XCTAssertFalse(infoDirect?.isFragmented == true)
    }
}
