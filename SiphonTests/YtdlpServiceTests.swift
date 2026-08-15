import XCTest
@testable import Siphon

final class TestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class MockYtdlpProcessRunner: YtdlpProcessRunning, @unchecked Sendable {
    var mockCommand: (@Sendable ([String]) async throws -> String)?
    var mockDownload: (@Sendable ([String]) async throws -> String)?

    init(
        mockCommand: (@Sendable ([String]) async throws -> String)? = nil,
        mockDownload: (@Sendable ([String]) async throws -> String)? = nil
    ) {
        self.mockCommand = mockCommand
        self.mockDownload = mockDownload
    }

    func runCommand(_ args: [String]) async throws -> String {
        if let mock = mockCommand {
            return try await mock(args)
        }
        return ""
    }

    func runDownloadProcess(
        args: [String],
        saveFolder: URL,
        isCancelled: (@Sendable () -> Bool)?,
        onProcessCreated: @escaping @Sendable (Process) -> Void,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        if let mock = mockDownload {
            return try await mock(args)
        }
        return ""
    }
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

        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            return expectedJSON
        })

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
        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            callCountBox.value += 1
            if args.contains("--flat-playlist") {
                return validPlaylistJSON
            } else {
                throw YtdlpError.commandFailed("Single video extraction failed")
            }
        })

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

        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            return "invalid json response"
        })

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
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

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
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

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
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp3\n"
        })

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
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

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
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

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
        serviceA.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return fileA.path
        })

        let serviceB = YtdlpService()
        serviceB.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        serviceB.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return fileB.path
        })

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
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

        // Test A: Generic direct progressive stream (e.g. standard CDN / web host) -> universal 10M chunking + 16K buffer, no throttled-rate re-extraction overhead, no fragment concurrency
        _ = try await service.download(
            url: "https://example.com/videos/test-progressive-stream.mp4",
            options: DownloadOptions.default,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let genericArgs = capturedArgsBox.value
        XCTAssertTrue(genericArgs.contains("--http-chunk-size"), "All downloads receive 10M chunking baseline")
        if let idx = genericArgs.firstIndex(of: "--http-chunk-size") {
            XCTAssertEqual(genericArgs[idx + 1], "10M")
        }
        XCTAssertTrue(genericArgs.contains("--buffer-size"), "All downloads receive 16K buffer baseline")
        if let idx = genericArgs.firstIndex(of: "--buffer-size") {
            XCTAssertEqual(genericArgs[idx + 1], "16K")
        }
        XCTAssertFalse(genericArgs.contains("--throttled-rate"), "Generic progressive stream must not force throttled rate re-extraction")
        XCTAssertFalse(genericArgs.contains("--concurrent-fragments"), "Direct MP4 must not have concurrent-fragments flag")

        // Test B: Known rate-limited single-stream CDN (e.g. ThisVid) -> targeted 10MB chunking & throttled-rate recovery
        _ = try await service.download(
            url: "https://thisvid.com/videos/test-rate-limited-stream",
            options: DownloadOptions.default,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let thisVidArgs = capturedArgsBox.value
        XCTAssertTrue(thisVidArgs.contains("--http-chunk-size"), "ThisVid direct stream should receive 10MB chunking to defeat server rate limits")
        XCTAssertTrue(thisVidArgs.contains("--buffer-size"), "ThisVid receives 16K buffer baseline")
        XCTAssertTrue(thisVidArgs.contains("--throttled-rate"), "ThisVid direct stream should receive throttled rate recovery")
        XCTAssertFalse(thisVidArgs.contains("--concurrent-fragments"), "ThisVid direct MP4 must not have concurrent-fragments flag")

        // Test C: Mixed MediaInfo with both direct MP4 and DASH formats
        let mixedFormats = [
            MediaFormat(formatId: "http-1080p", ext: "mp4", resolution: "1920x1080", fps: 60, vcodec: "avc1.64002a", acodec: "mp4a.40.2", abr: 128, vbr: 4000, filesize: 50000000, filesizeApprox: nil, formatNote: "Direct MP4", formatProtocol: "https", manifestUrl: nil),
            MediaFormat(formatId: "137", ext: "mp4", resolution: "1920x1080", fps: 60, vcodec: "avc1.64002a", acodec: "none", abr: nil, vbr: 4000, filesize: 45000000, filesizeApprox: nil, formatNote: "1080p DASH", formatProtocol: "http_dash_segments", manifestUrl: nil),
            MediaFormat(formatId: "140", ext: "m4a", resolution: nil, fps: nil, vcodec: "none", acodec: "mp4a.40.2", abr: 128, vbr: nil, filesize: 5000000, filesizeApprox: nil, formatNote: "DASH Audio", formatProtocol: "http_dash_segments", manifestUrl: nil)
        ]

        let mixedInfo = MediaInfo(
            id: "dQw4w9WgXcQ",
            title: "Mixed Video Stream",
            formats: mixedFormats,
            webpageUrl: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )

        // C1: User selects direct progressive MP4 -> YouTube chunking + buffer + throttled rate, but NO concurrent-fragments
        var directOptions = DownloadOptions.default
        directOptions.selectedFormatId = "http-1080p"
        _ = try await service.download(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            options: directOptions,
            mediaInfo: mixedInfo,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let selectedDirectArgs = capturedArgsBox.value
        XCTAssertTrue(selectedDirectArgs.contains("--http-chunk-size"), "YouTube streams require 10MB chunking")
        XCTAssertTrue(selectedDirectArgs.contains("--buffer-size"), "YouTube receives 16K buffer")
        XCTAssertTrue(selectedDirectArgs.contains("--throttled-rate"), "YouTube streams require throttled rate recovery")
        XCTAssertFalse(selectedDirectArgs.contains("--concurrent-fragments"), "Direct MP4 format must not have concurrent-fragments even when DASH exists on same page")

        // C2: User selects DASH format combination -> YouTube chunking + CONCURRENCY 8
        var dashOptions = DownloadOptions.default
        dashOptions.selectedFormatId = "137+140"
        _ = try await service.download(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            options: dashOptions,
            mediaInfo: mixedInfo,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let selectedDashArgs = capturedArgsBox.value
        XCTAssertTrue(selectedDashArgs.contains("--http-chunk-size"))
        XCTAssertTrue(selectedDashArgs.contains("--buffer-size"))
        XCTAssertTrue(selectedDashArgs.contains("--throttled-rate"))
        XCTAssertTrue(selectedDashArgs.contains("--concurrent-fragments"))
        if let idx = selectedDashArgs.firstIndex(of: "--concurrent-fragments") {
            XCTAssertEqual(selectedDashArgs[idx + 1], "8")
        }

        // Test D: Direct HLS manifest URL (e.g. BoyfriendTV)
        _ = try await service.download(
            url: "https://www.boyfriend.tv/videos/12345/test-hls-stream",
            options: DownloadOptions.default,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let hlsArgs = capturedArgsBox.value
        XCTAssertTrue(hlsArgs.contains("--concurrent-fragments"))
        if let idx = hlsArgs.firstIndex(of: "--concurrent-fragments") {
            XCTAssertEqual(hlsArgs[idx + 1], "8")
        }
    }

    func testRangeErrorRetryFallback() async throws {
        let callCountBox = TestBox<Int>(0)
        let capturedArgs = TestBox<[[String]]>([])

        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            callCountBox.value += 1
            capturedArgs.value.append(args)
            if callCountBox.value == 1 {
                throw YtdlpError.commandFailed("ERROR: The server does not support ranges. Range header not supported.")
            }
            return "/tmp/unchunked_download.mp4"
        })

        let result = try await service.download(
            url: "https://example.com/legacy-server-no-range.mp4",
            options: DownloadOptions.default,
            onProcessCreated: { _ in },
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertEqual(callCountBox.value, 2, "Should retry once upon encountering Range error")
        XCTAssertTrue(capturedArgs.value[0].contains("--http-chunk-size"), "Initial attempt should include chunk size")
        XCTAssertFalse(capturedArgs.value[1].contains("--http-chunk-size"), "Retry attempt must strip --http-chunk-size")
        XCTAssertEqual(result.lastPathComponent, "unchunked_download.mp4")
    }

    func testSelectedFormatLevelFragmentDetection() {
        let directFormat = MediaFormat(formatId: "http-1080p", ext: "mp4", resolution: "1920x1080", fps: 60, vcodec: "avc1.64002a", acodec: "mp4a.40.2", abr: 128, vbr: 4000, filesize: 50000000, filesizeApprox: nil, formatNote: nil, formatProtocol: "https", manifestUrl: nil)
        let dashVideo = MediaFormat(formatId: "137", ext: "mp4", resolution: "1920x1080", fps: 60, vcodec: "avc1.64002a", acodec: "none", abr: nil, vbr: 4000, filesize: 45000000, filesizeApprox: nil, formatNote: nil, formatProtocol: "http_dash_segments", manifestUrl: nil)
        let dashAudio = MediaFormat(formatId: "140", ext: "m4a", resolution: nil, fps: nil, vcodec: "none", acodec: "mp4a.40.2", abr: 128, vbr: nil, filesize: 5000000, filesizeApprox: nil, formatNote: nil, formatProtocol: "http_dash_segments", manifestUrl: nil)

        let mediaInfo = MediaInfo(
            id: "test_vid",
            title: "Test Video",
            formats: [directFormat, dashVideo, dashAudio]
        )

        // 1. Overall MediaInfo without top-level protocol is not blindly fragmented
        XCTAssertFalse(mediaInfo.isFragmented)

        // 2. Direct format selected
        var directOpts = DownloadOptions.default
        directOpts.selectedFormatId = "http-1080p"
        XCTAssertFalse(mediaInfo.isSelectedFormatFragmented(options: directOpts))

        // 3. DASH format selected
        var dashOpts = DownloadOptions.default
        dashOpts.selectedFormatId = "137+140"
        XCTAssertTrue(mediaInfo.isSelectedFormatFragmented(options: dashOpts))
    }

    func testFormatSelectionPrefersHighestQualityDirectStream() {
        let f480 = MediaFormat(formatId: "direct-480p", ext: "mp4", resolution: "854x480", fps: 30, vcodec: "avc1", acodec: "mp4a", abr: 96, vbr: 1000, filesize: 10000000, filesizeApprox: nil, formatNote: "480p", formatProtocol: "https", manifestUrl: nil)
        let f720 = MediaFormat(formatId: "direct-720p", ext: "mp4", resolution: "1280x720", fps: 30, vcodec: "avc1", acodec: "mp4a", abr: 128, vbr: 2500, filesize: 25000000, filesizeApprox: nil, formatNote: "720p", formatProtocol: "https", manifestUrl: nil)
        let f1080 = MediaFormat(formatId: "direct-1080p", ext: "mp4", resolution: "1920x1080", fps: 60, vcodec: "avc1", acodec: "mp4a", abr: 192, vbr: 5000, filesize: 50000000, filesizeApprox: nil, formatNote: "1080p", formatProtocol: "https", manifestUrl: nil)

        let mediaInfo = MediaInfo(
            id: "vid_test",
            title: "Multi Quality Video",
            formats: [f480, f1080, f720]
        )

        let options = DownloadOptions.default
        let resolved = mediaInfo.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.formatId, "direct-1080p", "Best-quality policy must deterministically select the highest resolution direct format")
    }

    func testFormatSelectionPairsDASHVideoAndAudio() {
        let dash1080 = MediaFormat(formatId: "137", ext: "mp4", resolution: "1920x1080", fps: 60, vcodec: "avc1", acodec: "none", abr: nil, vbr: 4500, filesize: 45000000, filesizeApprox: nil, formatNote: "1080p", formatProtocol: "http_dash_segments", manifestUrl: nil)
        let dashAudio128 = MediaFormat(formatId: "140", ext: "m4a", resolution: nil, fps: nil, vcodec: "none", acodec: "mp4a", abr: 128, vbr: nil, filesize: 5000000, filesizeApprox: nil, formatNote: "Medium audio", formatProtocol: "http_dash_segments", manifestUrl: nil)
        let dashAudio256 = MediaFormat(formatId: "141", ext: "m4a", resolution: nil, fps: nil, vcodec: "none", acodec: "mp4a", abr: 256, vbr: nil, filesize: 10000000, filesizeApprox: nil, formatNote: "High audio", formatProtocol: "http_dash_segments", manifestUrl: nil)

        let mediaInfo = MediaInfo(
            id: "dash_vid",
            title: "DASH Video",
            formats: [dash1080, dashAudio128, dashAudio256]
        )

        let options = DownloadOptions.default
        let resolved = mediaInfo.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].formatId, "137")
        XCTAssertEqual(resolved[1].formatId, "141", "Must pair with the highest bitrate matching audio stream")
    }

    func testFormatSelectionCodecMismatchFallback() {
        let h264Video = MediaFormat(formatId: "h264_1080", ext: "mp4", resolution: "1920x1080", fps: 30, vcodec: "avc1.64002a", acodec: "mp4a", abr: 128, vbr: 3000, filesize: 30000000, filesizeApprox: nil, formatNote: nil, formatProtocol: "https", manifestUrl: nil)
        let mediaInfo = MediaInfo(
            id: "codec_test",
            title: "Codec Fallback",
            formats: [h264Video]
        )

        var options = DownloadOptions.default
        options.videoCodec = .av1 // User requested AV1, but only H264 is available

        let resolved = mediaInfo.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.formatId, "h264_1080", "Must fall back gracefully to available high-quality format when preferred codec is absent")
    }

    func testProcessExitNonZeroThrowsErrorEvenIfFileExists() async {
        let service = YtdlpService(processRunner: MockYtdlpProcessRunner(mockDownload: { _ in
            throw YtdlpError.downloadFailed("ffmpeg conversion crashed")
        }))

        do {
            _ = try await service.download(
                url: "https://example.com/test",
                options: DownloadOptions.default,
                onProcessCreated: { _ in },
                onProgress: { _, _, _ in },
                onOutput: { _ in }
            )
            XCTFail("Non-zero/error exit must not succeed")
        } catch {
            XCTAssertTrue(error is YtdlpError)
        }
    }

    func testOrderingInvariantExplicitCodecOverridesHigherResolution() {
        let av1_1080 = MediaFormat(formatId: "av01_1080", ext: "mp4", resolution: "1920x1080", fps: 60, vcodec: "av01.0.08M.08", acodec: "mp4a", abr: 128, vbr: 5000, filesize: 50000000, filesizeApprox: nil, formatNote: "1080p AV1", formatProtocol: "https", manifestUrl: nil)
        let h264_720 = MediaFormat(formatId: "h264_720", ext: "mp4", resolution: "1280x720", fps: 30, vcodec: "avc1.64002a", acodec: "mp4a", abr: 128, vbr: 2500, filesize: 25000000, filesizeApprox: nil, formatNote: "720p H264", formatProtocol: "https", manifestUrl: nil)

        let mediaInfo = MediaInfo(
            id: "codec_priority",
            title: "Codec Priority Video",
            formats: [av1_1080, h264_720]
        )

        var options = DownloadOptions.default
        options.videoCodec = .h264 // Explicit request for H264

        let resolved = mediaInfo.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.formatId, "h264_720", "Explicit codec request must be strictly satisfied before maximizing quality")
    }

    func testOrderingInvariantVideoOnlyWithAudioVsCombined() {
        let videoOnly1080 = MediaFormat(formatId: "137", ext: "mp4", resolution: "1920x1080", fps: 60, vcodec: "avc1.64002a", acodec: "none", abr: nil, vbr: 4000, filesize: 40000000, filesizeApprox: nil, formatNote: "1080p video-only", formatProtocol: "http_dash_segments", manifestUrl: nil)
        let audio140 = MediaFormat(formatId: "140", ext: "m4a", resolution: nil, fps: nil, vcodec: "none", acodec: "mp4a.40.2", abr: 128, vbr: nil, filesize: 5000000, filesizeApprox: nil, formatNote: "Audio", formatProtocol: "http_dash_segments", manifestUrl: nil)
        let combined720 = MediaFormat(formatId: "22", ext: "mp4", resolution: "1280x720", fps: 30, vcodec: "avc1.64001f", acodec: "mp4a.40.2", abr: 128, vbr: 2000, filesize: 20000000, filesizeApprox: nil, formatNote: "720p combined", formatProtocol: "https", manifestUrl: nil)

        let mediaInfo = MediaInfo(
            id: "split_vs_combined",
            title: "Split vs Combined",
            formats: [combined720, videoOnly1080, audio140]
        )

        let options = DownloadOptions.default
        let resolved = mediaInfo.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].formatId, "137")
        XCTAssertEqual(resolved[1].formatId, "140", "1080p video-only + audio must rank higher than 720p combined")
    }

    func testRealThisVidExtractedMetadataFixtureSelection() {
        let jsonFixture = """
        {
            "id": "8504533",
            "title": "Muscle boy jerks off his big cock and cums huge",
            "formats": [
                {
                    "format_id": "240p",
                    "resolution": "240p",
                    "ext": "mp4",
                    "protocol": "https"
                },
                {
                    "format_id": "HQ",
                    "ext": "mp4",
                    "protocol": "https"
                }
            ],
            "webpage_url": "https://thisvid.com/videos/muscle-boy-jerks-off-his-big-cock-and-cums-huge/"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let mediaInfo = try? decoder.decode(MediaInfo.self, from: jsonFixture)
        XCTAssertNotNil(mediaInfo)

        let options = DownloadOptions.default
        let resolved = mediaInfo!.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.formatId, "HQ", "Default selection on ThisVid metadata must select the HQ source stream over 240p")
        XCTAssertFalse(mediaInfo!.isSelectedFormatFragmented(options: options), "HQ progressive stream must not be treated as fragmented")
    }
}
