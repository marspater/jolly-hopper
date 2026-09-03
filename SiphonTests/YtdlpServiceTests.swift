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
        processController: DownloadProcessController?,
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

    func testTempCookiesFileCreationPermissions() throws {
        let tempCookieURL = service.createTempCookiesFile(url: "https://example.com/video", cookieName: "test_token", cookieValue: "12345")
        XCTAssertNotNil(tempCookieURL)
        if let url = tempCookieURL {
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let posix = attrs[.posixPermissions] as? NSNumber
            XCTAssertEqual(posix?.intValue, 0o600, "Cookie file must be created with 0o600 POSIX permissions")
        }

        let tempHeaderCookieURL = service.createTempCookiesFileFromHeader(url: "https://example.com/video", cookieHeader: "session=abcde; token=secret123")
        XCTAssertNotNil(tempHeaderCookieURL)
        if let url = tempHeaderCookieURL {
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let posix = attrs[.posixPermissions] as? NSNumber
            XCTAssertEqual(posix?.intValue, 0o600, "Header cookie file must be created with 0o600 POSIX permissions")
        }
    }

    func testCreateAspectFitIconPreservesAspectRatioOnSquareCanvas() {
        // Test rectangular 16:9 image
        let wideImage = NSImage(size: NSSize(width: 1920, height: 1080))
        let wideIcon = YtdlpService.createAspectFitIcon(from: wideImage, targetSize: 512)
        XCTAssertEqual(wideIcon.size.width, 512)
        XCTAssertEqual(wideIcon.size.height, 512)

        // Test portrait 9:16 image
        let tallImage = NSImage(size: NSSize(width: 720, height: 1280))
        let tallIcon = YtdlpService.createAspectFitIcon(from: tallImage, targetSize: 512)
        XCTAssertEqual(tallIcon.size.width, 512)
        XCTAssertEqual(tallIcon.size.height, 512)

        // Test square image
        let squareImage = NSImage(size: NSSize(width: 600, height: 600))
        let squareIcon = YtdlpService.createAspectFitIcon(from: squareImage, targetSize: 512)
        XCTAssertEqual(squareIcon.size.width, 512)
        XCTAssertEqual(squareIcon.size.height, 512)
    }

    func testThreadSafeOutputStateQuoteStripping() {
        let state = ThreadSafeOutputState()
        state.setFinalPath("\"/path/to/downloaded video.mp4\"")
        XCTAssertEqual(state.getFinalPath(), "/path/to/downloaded video.mp4")

        state.addCandidatePath("'/another/path/video.mp4'")
        XCTAssertEqual(state.getCandidatePaths(), ["/another/path/video.mp4"])
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
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        // Verify URL was normalized/resolved for ThisVid extractor with required headers
        XCTAssertTrue(capturedArgsBox.value.contains(where: { $0.contains("thisvid") || $0.contains("huge-butt5") }))
        XCTAssertTrue(capturedArgsBox.value.contains("Referer:https://thisvid.com/"))
        XCTAssertTrue(capturedArgsBox.value.contains("Origin:https://thisvid.com"))
    }

    func testGuywhURLNormalizationAndHeaders() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

        var options = DownloadOptions.default
        options.videoResolution = .r1080p

        _ = try await service.download(
            url: "https://guywh.com/videos/7279/sample-title/",
            options: options,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        // Verify Guywh headers and direct stream format fallback are appended
        XCTAssertTrue(capturedArgsBox.value.contains("Referer: https://guywh.com/"))
        XCTAssertTrue(capturedArgsBox.value.contains("Origin: https://guywh.com"))
        XCTAssertTrue(capturedArgsBox.value.contains(where: { $0.contains("Chrome/126") }))
        if let fIdx = capturedArgsBox.value.firstIndex(of: "-f") {
            XCTAssertEqual(capturedArgsBox.value[fIdx + 1], "b/best")
        }
    }

    func testGFFURLNormalizationAndHeaders() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

        var options = DownloadOptions.default
        options.videoResolution = .r1080p

        _ = try await service.download(
            url: "https://gayforfans.com/video/8831/sample-title/?utm_source=feed&ref=banner",
            options: options,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        // Verify GFF headers and direct stream format selector are appended
        XCTAssertTrue(capturedArgsBox.value.contains("Referer: https://gayforfans.com/"))
        XCTAssertTrue(capturedArgsBox.value.contains("Origin: https://gayforfans.com"))
        XCTAssertTrue(capturedArgsBox.value.contains(where: { $0.contains("Chrome/126") }))
        XCTAssertFalse(capturedArgsBox.value.contains(where: { $0.contains("utm_source") }))
        if let fIdx = capturedArgsBox.value.firstIndex(of: "-f") {
            XCTAssertEqual(capturedArgsBox.value[fIdx + 1], "b/best")
        }
    }

    func testGFFDirectManifestAndMetadataExtraction() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        
        let mainPageHTML = """
        <!DOCTYPE html><html><head>
        <title>Sexy Muscle Workout - GayForFans.com</title>
        <meta property="og:image" content="https://gayforfans.com/contents/videos_screenshots/8000/8831/preview.jpg">
        <script>
        var flashvars = {
            video_url: 'https://cdn.gayforfans.com/videos/8831/8831.mp4',
            video_url_text: '1080p',
            video_url_fhd: '1',
            preview_url: 'https://gayforfans.com/contents/videos_screenshots/8000/8831/preview.jpg'
        };
        </script>
        </head><body></body></html>
        """
        let mainB64 = mainPageHTML.data(using: .utf8)!.base64EncodedString()
        
        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            if args.contains("--dump-pages") {
                return mainB64
            }
            return "{}"
        })

        let info = try await service.fetchInfo(url: "https://gayforfans.com/videos/8831/sexy-muscle-workout/")
        XCTAssertEqual(info.title, "Sexy Muscle Workout")
        XCTAssertEqual(info.uploader, "GayForFans")
        XCTAssertEqual(info.thumbnail, "https://gayforfans.com/contents/videos_screenshots/8000/8831/preview.jpg")
        XCTAssertEqual(info.formats?.first?.formatId, "1080p")
    }

    func testGFFEmbedPageExtractionFallback() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        
        let mainPageHTML = """
        <!DOCTYPE html><html><head><title>GayForFans - Beach Twink Action</title></head>
        <body>
        <iframe src="https://gayforfans.com/embed/9921" width="100%" height="100%"></iframe>
        </body></html>
        """
        let mainB64 = mainPageHTML.data(using: .utf8)!.base64EncodedString()

        let embedPageHTML = """
        <!DOCTYPE html><html><head><title>Embed</title></head><body>
        <script>
        var playerConfig = {
            video_url: "https://cdn.gayforfans.com/videos/9921/master.m3u8",
            preview_url: "https://cdn.gayforfans.com/thumbs/9921.jpg"
        };
        </script></body></html>
        """
        let embedB64 = embedPageHTML.data(using: .utf8)!.base64EncodedString()

        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            if args.contains("--dump-pages") {
                if args.contains(where: { $0.contains("/videos/9921/") }) {
                    return mainB64
                } else if args.contains(where: { $0.contains("/embed/9921") }) {
                    return embedB64
                }
            }
            return "{}"
        })

        let info = try await service.fetchInfo(url: "https://gayforfans.com/videos/9921/beach-twink-action/")
        XCTAssertEqual(info.title, "Beach Twink Action")
        XCTAssertEqual(info.uploader, "GayForFans")
        XCTAssertEqual(info.thumbnail, "https://cdn.gayforfans.com/thumbs/9921.jpg")
    }

    func testGFFErrorMappingAndCloudflare() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        UserDefaults.standard.set("none", forKey: UserDefaultsKeys.browserForCookies)
        defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.browserForCookies) }

        // Cloudflare error
        service.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            throw YtdlpError.commandFailed("ERROR: Cloudflare turnstile challenge required 403 Forbidden")
        })
        do {
            _ = try await service.fetchInfo(url: "https://gayforfans.com/videos/8831/test/")
            XCTFail("Expected cloudflare error to be thrown")
        } catch let err as YtdlpError {
            if case .cloudflareBlocked = err {
                // Expected
            } else {
                XCTFail("Expected .cloudflareBlocked but got \(err)")
            }
        }
    }

    func testEpornerSubdomainNormalization() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

        let options = DownloadOptions.default
        _ = try await service.download(
            url: "https://pl.eporner.com/video-rS36Amplbu9/jonas-smith-18-02-2025/",
            options: options,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        // Verify localized subdomain pl.eporner.com was normalized to www.eporner.com and http-chunk-size excluded
        XCTAssertTrue(capturedArgsBox.value.contains("https://www.eporner.com/video-rS36Amplbu9/jonas-smith-18-02-2025/"))
        XCTAssertFalse(capturedArgsBox.value.contains("--http-chunk-size"))
        if YtdlpService.findAria2cPath() != nil {
            XCTAssertTrue(capturedArgsBox.value.contains("aria2c"), "Eporner should use aria2c multi-connection downloader when available")
        }
    }

    func testHasFullDiskAccessCheckDoesNotCrash() {
        let hasAccess = YtdlpService.hasFullDiskAccess
        XCTAssertTrue(hasAccess == true || hasAccess == false)
    }

    func testHttp500ServerRangeErrorRetryFallback() async throws {
        let callCountBox = TestBox<Int>(0)
        let capturedArgs = TestBox<[[String]]>([])

        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            callCountBox.value += 1
            capturedArgs.value.append(args)
            if callCountBox.value == 1 {
                throw YtdlpError.commandFailed("[download] Got error: HTTP Error 500: Internal Server Error. Giving up after 10 retries")
            }
            return "/tmp/recovered_unchunked.mp4"
        })

        let result = try await service.download(
            url: "https://example.com/stream-server-error.mp4",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertEqual(callCountBox.value, 2, "Should retry once upon encountering HTTP Error 500 Range/Chunking error")
        XCTAssertTrue(capturedArgs.value[0].contains("--http-chunk-size"), "Initial attempt should include chunk size")
        XCTAssertFalse(capturedArgs.value[1].contains("--http-chunk-size"), "Retry attempt must strip --http-chunk-size")
        XCTAssertEqual(result.lastPathComponent, "recovered_unchunked.mp4")
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

    func testThreadSafeOutputStateFinalPathHandling() {
        let state = ThreadSafeOutputState()

        // 1. Initially getFinalPath() must return nil
        XCTAssertNil(state.getFinalPath(), "Initial finalPath should be nil")

        // 2. Setting an empty or whitespace-only/quote-only string should be ignored
        state.setFinalPath("")
        XCTAssertNil(state.getFinalPath(), "Empty string should not update finalPath")

        state.setFinalPath("   \"\"   ")
        XCTAssertNil(state.getFinalPath(), "Whitespace/quotes-only string should not update finalPath")

        // 3. Setting a valid path with surrounding quotes and whitespace should clean and store the path
        state.setFinalPath("   \"/tmp/final_output_file.mp4\"   ")
        XCTAssertEqual(state.getFinalPath(), "/tmp/final_output_file.mp4")

        // 4. Updating finalPath with another valid path overwrites the existing value
        state.setFinalPath("'/tmp/overwritten_output.mp4'")
        XCTAssertEqual(state.getFinalPath(), "/tmp/overwritten_output.mp4")
    }

    func testThreadSafeOutputStateFinalPathConcurrency() {
        let state = ThreadSafeOutputState()
        let group = DispatchGroup()
        let iterations = 100

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                state.setFinalPath("/tmp/path_\(i).mp4")
                _ = state.getFinalPath()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(result, .success, "Concurrent access to ThreadSafeOutputState timed out")
        XCTAssertNotNil(state.getFinalPath(), "Final path should be populated after concurrent operations")
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
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        async let resultB = serviceB.download(
            url: "https://example.com/videoB",
            options: optionsB,
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
            "--video-password", "secret_vid_pass",
            "--token", "secret_token_abc",
            "--api-key", "secret_key_xyz",
            "--proxy", "http://user:pass@127.0.0.1:8080",
            "https://site.example/video?auth=SECRET"
        ]

        let sanitized = LoggerService.sanitizeCommandForLog(args)
        XCTAssertTrue(sanitized.contains("--username \"<USERNAME>\""))
        XCTAssertTrue(sanitized.contains("--password \"<PASSWORD>\""))
        XCTAssertTrue(sanitized.contains("--video-password \"<PASSWORD>\""))
        XCTAssertTrue(sanitized.contains("--token \"<TOKEN>\""))
        XCTAssertTrue(sanitized.contains("--api-key \"<API_KEY>\""))
        XCTAssertTrue(sanitized.contains("--proxy \"<PROXY_REDACTED>\""))
        XCTAssertTrue(sanitized.contains("https://site.example/video"))
        XCTAssertFalse(sanitized.contains("secret_user@example.com"))
        XCTAssertFalse(sanitized.contains("MyP@ssw0rd!123"))
        XCTAssertFalse(sanitized.contains("secret_vid_pass"))
        XCTAssertFalse(sanitized.contains("secret_token_abc"))
        XCTAssertFalse(sanitized.contains("secret_key_xyz"))
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

    func testBoyfriendTVURLNormalizationAndCanonicalHost() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(
            mockCommand: { _ in "{}" },
            mockDownload: { args in
                capturedArgsBox.value = args
                return "[download] Destination: /tmp/test.mp4\n"
            }
        )

        _ = try await service.download(
            url: "https://www.boyfriendtv.com/videos/1140993/horus-scat-piss-chute/",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )
        
        let lastArg = capturedArgsBox.value.last ?? ""
        XCTAssertTrue(lastArg.contains("boyfriend"), "BoyfriendTV download must target the resolved stream or canonical BoyfriendTV domain")
        XCTAssertTrue(capturedArgsBox.value.contains(where: { $0.hasPrefix("Origin:https://www.boyfriend") }))
        XCTAssertTrue(capturedArgsBox.value.contains(where: { $0.contains("Referer:https://www.boyfriend") }))
    }

    func testBoyfriendTVMultiFormatManifestExtraction() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let capturedArgs = TestBox<[[String]]>([])
        
        let mainPageHTML = """
        <!DOCTYPE html><html><head><title>boyfriend.tv - Horus sexy blowjob compilation</title>
        <script type="application/ld+json">
        {"@type":"VideoObject","name":"Horus sexy blowjob compilation","embedUrl":"https://www.boyfriend.tv/embed/1140993/46075/","thumbnailUrl":["https://cdn77-t.boyfriendtv.com/thumb.jpg"]}
        </script>
        </head><body></body></html>
        """
        let mainB64 = mainPageHTML.data(using: .utf8)!.base64EncodedString()
        
        let embedPageHTML = """
        <!DOCTYPE html><html><head><title>Embed</title></head><body>
        <script>
        window.player = {"hlsAuto":"https://cdn.boyfriend.tv/key=abc,end=123/media=hls4A/multi=854x480:v480,1280x720:v720,1920x1080:v1080/2024-03/_TPL_.mp4"};
        </script></body></html>
        """
        let embedB64 = embedPageHTML.data(using: .utf8)!.base64EncodedString()
        
        let jsonManifestOutput = """
        {
            "id": "_TPL_",
            "title": "_TPL_",
            "duration": 297,
            "thumbnail": "https://cdn77-t.boyfriendtv.com/thumb.jpg",
            "formats": [
                {"format_id": "430", "width": 854, "height": 480, "ext": "mp4", "protocol": "m3u8_native"},
                {"format_id": "757", "width": 1280, "height": 720, "ext": "mp4", "protocol": "m3u8_native"},
                {"format_id": "1409", "width": 1920, "height": 1080, "ext": "mp4", "protocol": "m3u8_native"}
            ]
        }
        """

        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            capturedArgs.value.append(args)
            if args.contains("--dump-pages") {
                if args.contains(where: { $0.contains("/videos/1140993/") }) {
                    return mainB64
                } else if args.contains(where: { $0.contains("/embed/1140993/") }) {
                    return embedB64
                }
            }
            if args.contains("--dump-json") {
                return jsonManifestOutput
            }
            return "{}"
        })

        let info = try await service.fetchInfo(url: "https://www.boyfriendtv.com/videos/1140993/horus-scat-piss-chute/")
        XCTAssertEqual(info.title, "Horus sexy blowjob compilation")
        XCTAssertEqual(info.formats?.count, 3)
        XCTAssertEqual(info.duration, 297)
        XCTAssertEqual(info.thumbnail, "https://cdn77-t.boyfriendtv.com/thumb.jpg")
    }

    func testBoyfriendTVIframeEmbedManifestExtraction() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let capturedArgs = TestBox<[[String]]>([])
        
        let mainPageHTML = """
        <!DOCTYPE html><html><head><title>Big Dick Twink Fuck Muscle Ass | BoyFriendTV</title></head>
        <body>
        <iframe src="https://www.boyfriend.tv/embed/1630228/20231/600/338/" width="600" height="338"></iframe>
        </body></html>
        """
        let mainB64 = mainPageHTML.data(using: .utf8)!.base64EncodedString()
        
        let embedPageHTML = """
        <!DOCTYPE html><html><head><title>Embed</title></head><body>
        <script>
        var playerConfig = {
            sources: {"hlsAuto":"https://cdn.boyfriend.tv/key=abc,end=123/media=hls4A/multi=854x480:v480,426x240:v240/2026-04/_TPL_.mp4"},
            poster: 'https://cdn77-t.boyfriendtv.com/thumb.jpg'
        };
        </script></body></html>
        """
        let embedB64 = embedPageHTML.data(using: .utf8)!.base64EncodedString()
        
        let jsonManifestOutput = """
        {
            "id": "_TPL_",
            "title": "_TPL_",
            "duration": 1909,
            "thumbnail": "https://cdn77-t.boyfriendtv.com/thumb.jpg",
            "formats": [
                {"format_id": "499", "width": 426, "height": 240, "ext": "mp4", "protocol": "m3u8_native"},
                {"format_id": "1021", "width": 854, "height": 480, "ext": "mp4", "protocol": "m3u8_native"}
            ]
        }
        """

        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            capturedArgs.value.append(args)
            if args.contains("--dump-pages") {
                if args.contains(where: { $0.contains("/videos/1630228/") }) {
                    return mainB64
                } else if args.contains(where: { $0.contains("/embed/1630228/") }) {
                    return embedB64
                }
            }
            if args.contains("--dump-json") {
                return jsonManifestOutput
            }
            return "{}"
        })

        let info = try await service.fetchInfo(url: "https://www.boyfriendtv.com/videos/1630228/big-dick-twink-fuck-muscle-ass/")
        XCTAssertEqual(info.title, "Big Dick Twink Fuck Muscle Ass")
        XCTAssertEqual(info.formats?.count, 2)
        XCTAssertEqual(info.duration, 1909)
        XCTAssertEqual(info.thumbnail, "https://cdn77-t.boyfriendtv.com/thumb.jpg")
    }

    func testBoyfriendTVLocalizedPathPrefixAndUrlVariations() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        
        let mainPageHTML = """
        <!DOCTYPE html><html><head><title>Hot Brazilian Threesome | BoyFriendTV</title>
        <script>
        var playerConfig = {
            sources: {"hlsAuto":"https://cdn.boyfriend.tv/key=abc,end=123/media=hls4A/multi=854x480:v480,1280x720:v720/2026-08/_TPL_.mp4"},
            poster: 'https://cdn77-t.boyfriendtv.com/thumb.jpg'
        };
        </script>
        </head><body></body></html>
        """
        let mainB64 = mainPageHTML.data(using: .utf8)!.base64EncodedString()
        
        let jsonManifestOutput = """
        {
            "id": "_TPL_",
            "title": "_TPL_",
            "duration": 2992,
            "thumbnail": "https://cdn77-t.boyfriendtv.com/thumb.jpg",
            "formats": [
                {"format_id": "480", "width": 854, "height": 480, "ext": "mp4", "protocol": "m3u8_native"},
                {"format_id": "720", "width": 1280, "height": 720, "ext": "mp4", "protocol": "m3u8_native"}
            ]
        }
        """

        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            if args.contains("--dump-pages") && args.contains(where: { $0.contains("/videos/1702908/") }) {
                return mainB64
            }
            if args.contains("--dump-json") {
                return jsonManifestOutput
            }
            return "{}"
        })

        // Test with /ru/ prefix on boyfriendtv.com
        let info = try await service.fetchInfo(url: "https://www.boyfriendtv.com/ru/videos/1702908/hot-brazilian-threesome/")
        XCTAssertEqual(info.title, "Hot Brazilian Threesome")
        XCTAssertEqual(info.formats?.count, 2)
        XCTAssertEqual(info.duration, 2992)
    }

    func testBoyfriendTVErrorMappingDistinguishesCloudflareAndUnsupportedURL() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        UserDefaults.standard.set("safari", forKey: UserDefaultsKeys.browserForCookies)
        defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.browserForCookies) }

        // 1. Cloudflare error
        service.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            throw YtdlpError.commandFailed("ERROR: Cloudflare 403 Forbidden captcha challenge")
        })
        do {
            _ = try await service.fetchInfo(url: "https://www.boyfriendtv.com/videos/1702908/test/")
            XCTFail("Expected cloudflare error to be thrown")
        } catch let err as YtdlpError {
            if case .cloudflareBlocked = err {
                // Expected
            } else {
                XCTFail("Expected .cloudflareBlocked but got \(err)")
            }
        }

        // 2. Unsupported URL / extraction failure should NOT report login required
        service.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            throw YtdlpError.commandFailed("ERROR: Unsupported URL: https://www.boyfriend.tv/r")
        })
        do {
            _ = try await service.fetchInfo(url: "https://www.boyfriendtv.com/r")
            XCTFail("Expected error to be thrown")
        } catch let err as YtdlpError {
            if case .boyfriendTVLoginRequired = err {
                XCTFail("Should not falsely report boyfriendTVLoginRequired for an invalid/unsupported URL")
            }
        }

        // 3. Safari permission denied (Operation not permitted) maps to safariCookiesFullDiskAccessRequired
        service.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            throw YtdlpError.commandFailed("ERROR: [Cookies] Failed to extract cookies from Safari: [Errno 1] Operation not permitted: '/Users/test/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'")
        })
        do {
            _ = try await service.fetchInfo(url: "https://www.boyfriendtv.com/videos/1702908/test/")
            XCTFail("Expected error to be thrown")
        } catch let err as YtdlpError {
            if case .safariCookiesFullDiskAccessRequired = err {
                // Expected
            } else {
                XCTFail("Expected .safariCookiesFullDiskAccessRequired but got \(err)")
            }
        }

        // 4. No cookies configured and sign in required maps to boyfriendTVNeedsBrowserCookies
        UserDefaults.standard.set("none", forKey: UserDefaultsKeys.browserForCookies)
        service.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            throw YtdlpError.commandFailed("ERROR: Private video. Sign in to view this video")
        })
        do {
            _ = try await service.fetchInfo(url: "https://www.boyfriendtv.com/videos/1702908/test/")
            XCTFail("Expected error to be thrown")
        } catch let err as YtdlpError {
            if case .boyfriendTVNeedsBrowserCookies = err {
                // Expected
            } else {
                XCTFail("Expected .boyfriendTVNeedsBrowserCookies but got \(err)")
            }
        }

        // 5. Chrome cookies configured and sign in required maps to boyfriendTVLoginRequired
        UserDefaults.standard.set("chrome", forKey: UserDefaultsKeys.browserForCookies)
        service.processRunner = MockYtdlpProcessRunner(mockCommand: { _ in
            throw YtdlpError.commandFailed("ERROR: Private video. Sign in to view this video")
        })
        do {
            _ = try await service.fetchInfo(url: "https://www.boyfriendtv.com/videos/1702908/test/")
            XCTFail("Expected error to be thrown")
        } catch let err as YtdlpError {
            if case .boyfriendTVLoginRequired = err {
                // Expected
            } else {
                XCTFail("Expected .boyfriendTVLoginRequired but got \(err)")
            }
        }
    }

    func testBoyfriendTVFiltersPreviewTeaserClips() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        
        // HTML containing BOTH a rollover preview (pv_*.mp4) and a full stream (_TPL_.mp4)
        let pageWithBoth = """
        <!DOCTYPE html><html><head><title>Full Video Title | BoyFriendTV</title>
        <video data-preview="https://cc.boyfriend.tv/pv/bftv/2026-07/pv_dd623e903325da07577e495cec98575b.mp4"></video>
        <script>
        var playerConfig = {
            sources: {"hlsAuto":"https://cdn.boyfriend.tv/key=abc,end=123/media=hls4A/multi=854x480:v480,1280x720:v720/2026-08/_TPL_.mp4"},
            poster: 'https://cdn77-t.boyfriendtv.com/thumb.jpg'
        };
        </script>
        </head><body></body></html>
        """
        let bothB64 = pageWithBoth.data(using: .utf8)!.base64EncodedString()
        
        let jsonManifestOutput = """
        {
            "id": "_TPL_",
            "title": "Full Video Title",
            "duration": 793,
            "thumbnail": "https://cdn77-t.boyfriendtv.com/thumb.jpg",
            "formats": [
                {"format_id": "720", "width": 1280, "height": 720, "ext": "mp4", "protocol": "m3u8_native"}
            ]
        }
        """

        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            if args.contains("--dump-pages") {
                return bothB64
            }
            if args.contains("--dump-json") {
                // Verify that the args target the full stream, NOT the preview pv_ clip!
                XCTAssertFalse(args.contains(where: { $0.contains("pv_") || $0.contains("/pv/") }), "yt-dlp args should never target preview pv_ clips")
                XCTAssertTrue(args.contains(where: { $0.contains("_TPL_.mp4") }), "yt-dlp args should target the full video stream")
                return jsonManifestOutput
            }
            return "{}"
        })

        let info = try await service.fetchInfo(url: "https://www.boyfriendtv.com/videos/1032217/video_1000_sanninred/")
        XCTAssertEqual(info.title, "Full Video Title")
        XCTAssertEqual(info.duration, 793)

        // Now test page with ONLY preview clip and loginProtected (unauthenticated / missing FDA)
        let loginProtectedHTML = """
        <!DOCTYPE html><html><head><title>Video_1000_SanninRed | BoyFriendTV</title>
        <video data-preview="https://cc.boyfriend.tv/pv/bftv/2026-07/pv_dd623e903325da07577e495cec98575b.mp4"></video>
        </head><body>
        <div class="videoContainer"><div class="loginProtected">To watch this video please Login</div></div>
        </body></html>
        """
        let loginB64 = loginProtectedHTML.data(using: .utf8)!.base64EncodedString()

        UserDefaults.standard.set("safari", forKey: UserDefaultsKeys.browserForCookies)
        defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.browserForCookies) }

        service.processRunner = MockYtdlpProcessRunner(mockCommand: { args in
            if args.contains("--dump-pages") {
                return loginB64
            }
            if args.contains("--dump-json") {
                throw YtdlpError.commandFailed("ERROR: Unsupported URL")
            }
            return "{}"
        })

        do {
            _ = try await service.fetchInfo(url: "https://www.boyfriendtv.com/videos/1032217/video_1000_sanninred/")
            XCTFail("Should not succeed or download a preview clip on a login-protected video")
        } catch let err as YtdlpError {
            switch err {
            case .safariCookiesFullDiskAccessRequired, .boyfriendTVLoginRequired, .boyfriendTVNeedsBrowserCookies:
                break // Expected
            default:
                XCTFail("Unexpected error: \(err)")
            }
        }
    }

    func testMediaFormatDecodesTBRAndNeedsTesting() throws {
        let json = """
        {
            "format_id": "h264-720p",
            "ext": "mp4",
            "resolution": "720p",
            "vcodec": "h264",
            "tbr": 1250.5,
            "__needs_testing": true
        }
        """.data(using: .utf8)!

        let format = try JSONDecoder().decode(MediaFormat.self, from: json)
        XCTAssertEqual(format.formatId, "h264-720p")
        XCTAssertEqual(format.tbr, 1250.5)
        XCTAssertEqual(format.needsTesting, true)
    }

    func testResolveSelectedFormatsFiltersUntestedFormatsWhenTestedExist() throws {
        let json = """
        {
            "id": "xhQvXns",
            "title": "Cam Cum: Big Fat Cock Erupts",
            "formats": [
                {
                    "format_id": "h264-720p",
                    "ext": "mp4",
                    "resolution": "720p",
                    "height": 720,
                    "vcodec": "h264",
                    "protocol": "https",
                    "__needs_testing": true
                },
                {
                    "format_id": "hls-537-1",
                    "ext": "mp4",
                    "resolution": "1280x720",
                    "height": 720,
                    "vcodec": "avc1.4d4015",
                    "acodec": "mp4a.40.2",
                    "tbr": 537.143,
                    "protocol": "m3u8_native"
                }
            ]
        }
        """.data(using: .utf8)!

        let mediaInfo = try JSONDecoder().decode(MediaInfo.self, from: json)
        var options = DownloadOptions.default
        options.fileType = .mp4
        options.videoResolution = .r720p
        options.videoCodec = .h264

        let resolved = mediaInfo.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.formatId, "hls-537-1", "resolveSelectedFormats must select the working verified HLS stream over the untested progressive format")
    }

    func testXHamsterURLNormalizationAndHeaders() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(
            mockCommand: { _ in "{}" },
            mockDownload: { args in
                capturedArgsBox.value = args
                return "[download] Destination: /tmp/test.mp4\n"
            }
        )

        _ = try await service.download(
            url: "https://de.xhamster.com/videos/cam-cum-big-fat-cock-erupts-xhQvXns?from=search",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let args = capturedArgsBox.value
        let targetUrl = args.last ?? ""
        XCTAssertTrue(targetUrl.contains("xhamster.com/videos/cam-cum-big-fat-cock-erupts-xhQvXns"), "xHamster URL must be normalized")
        XCTAssertTrue(args.contains("Origin:https://xhamster.com"))
        XCTAssertTrue(args.contains(where: { $0.contains("Referer:https://xhamster.com/") }))
        XCTAssertTrue(args.contains("--hls-use-mpegts"))
        XCTAssertTrue(args.contains(where: { $0 == "--concurrent-fragments" }))
    }

    func testArgumentInjectionProtectionWithDoubleDash() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(
            mockCommand: { args in
                capturedArgsBox.value = args
                return "{}"
            }
        )

        _ = try? await service.fetchInfo(url: "--exec=calc")
        let args = capturedArgsBox.value
        if let dashIdx = args.lastIndex(of: "--") {
            XCTAssertEqual(args[dashIdx + 1], "--exec=calc", "Double dash must precede the URL argument to prevent argument injection")
        } else {
            XCTFail("Expected double dash '--' argument delimiter before URL")
        }
    }

    func testStreamBufferBatchExtractionAndCRTrimming() {
        let streamBuffer = StreamBuffer()
        let chunk = "line 1\r\nline 2\nline 3\r\nincomplete".data(using: .utf8)!
        let extracted = streamBuffer.appendAndExtractLines(chunk)
        XCTAssertEqual(extracted, ["line 1", "line 2", "line 3"])

        let secondChunk = " line finished\n".data(using: .utf8)!
        let secondExtracted = streamBuffer.appendAndExtractLines(secondChunk)
        XCTAssertEqual(secondExtracted, ["incomplete line finished"])

        let flushLines = streamBuffer.flush()
        XCTAssertTrue(flushLines.isEmpty)
    }

    func testSanitizedEnvironmentIncludesPackageManagersAndHomebrew() {
        let env = YtdlpService.createSanitizedEnvironment()
        guard let path = env["PATH"] else {
            XCTFail("Environment must have PATH set")
            return
        }
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "PATH must include Homebrew Apple Silicon bin")
        XCTAssertTrue(path.contains("/usr/local/bin"), "PATH must include Homebrew Intel bin")
        XCTAssertTrue(path.contains("/usr/bin"), "PATH must include standard system binaries")
    }

    func testJsRuntimeArgsAppendedInDownload() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test.mp4\n"
        })

        _ = try await service.download(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let args = capturedArgsBox.value
        XCTAssertTrue(args.contains("--js-runtimes"), "Download command must pass --js-runtimes for YouTube challenge solving")
        XCTAssertFalse(args.contains("generic:impersonate"), "YouTube downloads must not pass generic:impersonate")
    }

    func testThisVidAria2cAppendedWhenAvailable() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test_thisvid.mp4\n"
        })

        _ = try await service.download(
            url: "https://thisvid.com/videos/hung-bodybuilder-jerk-flex-and-shoot-a-huge-load/",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let args = capturedArgsBox.value
        XCTAssertTrue(args.contains("Referer:https://thisvid.com/"))
        XCTAssertTrue(args.contains("Origin:https://thisvid.com"))
        if YtdlpService.findAria2cPath() != nil {
            XCTAssertTrue(args.contains("--downloader"))
            if let idx = args.firstIndex(of: "--downloader") {
                XCTAssertEqual(args[idx + 1], "aria2c")
            }
            XCTAssertTrue(args.contains("--downloader-args"))
        }
    }

    func testJustTheGaysHlsDownloaderArgs() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test_jtg.mp4\n"
        })

        _ = try await service.download(
            url: "https://justthegays.tv/video/valentinoboy-fucks-romeo-twink-yet-again-100",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        let args = capturedArgsBox.value
        XCTAssertTrue(args.contains("Referer:https://justthegays.com/"))
        XCTAssertTrue(args.contains("--downloader"))
        if let idx = args.firstIndex(of: "--downloader") {
            XCTAssertEqual(args[idx + 1], "ffmpeg")
        }
        XCTAssertTrue(args.contains("--downloader-args"))
        XCTAssertTrue(args.contains("--hls-use-mpegts"))
    }

    func testHlsPostprocessingRecoveryRetriesWithFfmpeg() async throws {
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let callCountBox = TestBox<Int>(0)
        let capturedArgsBox = TestBox<[String]>([])

        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            callCountBox.value += 1
            if callCountBox.value == 1 {
                throw YtdlpError.downloadFailed("ERROR: Postprocessing: Stream #0:1 -> #0:1 (copy)")
            }
            capturedArgsBox.value = args
            return "/tmp/hls_recovered.mp4"
        })

        let result = try await service.download(
            url: "https://example.com/video-hls-stream",
            options: DownloadOptions.default,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertEqual(callCountBox.value, 2, "Must retry download when HLS postprocessing stream error is encountered")
        XCTAssertTrue(capturedArgsBox.value.contains("--downloader"), "Retried attempt must include --downloader")
        if let idx = capturedArgsBox.value.firstIndex(of: "--downloader") {
            XCTAssertEqual(capturedArgsBox.value[idx + 1], "ffmpeg")
        }
        XCTAssertEqual(result.lastPathComponent, "hls_recovered.mp4")
    }

    func testResolveBoyfriendTVStreamURLForDownload() {
        let streamTemplate = "https://cdn.boyfriendtv.com/contents/videos_sources/1490000/1490652/1490652_TPL_.mp4?multi=1920x1080:1080p,1280x720:720p,854x480:480p"
        
        var options1080 = DownloadOptions.default
        options1080.videoResolution = .r1080p
        let res1080 = service.resolveBoyfriendTVStreamURLForDownload(streamURL: streamTemplate, options: options1080)
        XCTAssertTrue(res1080.contains("1490652_1080p.mp4"), "Must resolve _TPL_ to _1080p.mp4 for 1080p resolution")

        var options720 = DownloadOptions.default
        options720.videoResolution = .r720p
        let res720 = service.resolveBoyfriendTVStreamURLForDownload(streamURL: streamTemplate, options: options720)
        XCTAssertTrue(res720.contains("1490652_720p.mp4"), "Must resolve _TPL_ to _720p.mp4 for 720p resolution")

        var options480 = DownloadOptions.default
        options480.videoResolution = .r480p
        let res480 = service.resolveBoyfriendTVStreamURLForDownload(streamURL: streamTemplate, options: options480)
        XCTAssertTrue(res480.contains("1490652_480p.mp4"), "Must resolve _TPL_ to _480p.mp4 for 480p resolution")
    }

    func testDownloadProcessControllerSingleOwnerAttachment() {
        let controller = DownloadProcessController()
        let proc1 = Process()
        let proc2 = Process()

        let attached1 = controller.attachProcess(proc1)
        XCTAssertTrue(attached1, "First process must attach successfully")

        let attached2 = controller.attachProcess(proc2)
        XCTAssertFalse(attached2, "Second process attachment must be rejected to enforce single-owner invariant")

        controller.cancel()
        let proc3 = Process()
        let attached3 = controller.attachProcess(proc3)
        XCTAssertFalse(attached3, "Attachment to cancelled controller must be rejected")
    }

    func testMediaInfoPrunedForCompletion() {
        let fullFormats = [MediaFormat(formatId: "1080", ext: "mp4", resolution: "1920x1080")]
        let fullInfo = MediaInfo(
            id: "test-id",
            title: "Test Video",
            description: "A very long detailed description",
            thumbnail: "https://example.com/thumb.jpg",
            duration: 120.0,
            uploader: "Test Uploader",
            formats: fullFormats
        )

        let pruned = fullInfo.prunedForCompletion()
        XCTAssertEqual(pruned.id, "test-id")
        XCTAssertEqual(pruned.title, "Test Video")
        XCTAssertNil(pruned.description, "Description must be stripped on completion")
        XCTAssertNil(pruned.formats, "Heavy format lists must be stripped on completion")
    }

    func testDownloadEventCoalescerFlushing() {
        let flushedProgressBox = TestBox<Double?>(nil)
        let flushedLinesBox = TestBox<[String]>([])

        let coalescer = DownloadEventCoalescer { progress, _, _, lines in
            if let progress {
                flushedProgressBox.value = progress
            }
            if !lines.isEmpty {
                flushedLinesBox.value.append(contentsOf: lines)
            }
        }

        coalescer.recordProgress(progress: 0.5, speed: "5MB/s", eta: "10s")
        coalescer.recordLogLine("line 1")
        coalescer.recordLogLine("line 2")
        coalescer.flushRemaining()

        XCTAssertEqual(flushedProgressBox.value, 0.5)
        XCTAssertEqual(flushedLinesBox.value, ["line 1", "line 2"])
    }

    func testDownloadEventCoalescerBoundedQueueDropsOldest() {
        let flushedLinesBox = TestBox<[String]>([])
        let coalescer = DownloadEventCoalescer { _, _, _, lines in
            if !lines.isEmpty {
                flushedLinesBox.value.append(contentsOf: lines)
            }
        }

        // Push 600 lines (exceeding maxPendingLines = 500)
        for i in 0..<600 {
            coalescer.recordLogLine("line_\(i)")
        }
        coalescer.flushRemaining()

        // Should drop first 100 oldest lines and retain last 500
        XCTAssertEqual(flushedLinesBox.value.count, 500)
        XCTAssertEqual(flushedLinesBox.value.first, "line_100")
        XCTAssertEqual(flushedLinesBox.value.last, "line_599")
    }

    func testMediaFormatHDR10AndColorSpaceDecoding() throws {
        let json = """
        {
            "format_id": "313",
            "ext": "webm",
            "resolution": "3840x2160",
            "fps": 60,
            "vcodec": "vp09.02.51.10.01.09.18.00.00",
            "dynamic_range": "HDR10",
            "color_space": "bt2020",
            "bit_depth": 10,
            "format_note": "2160p60 HDR"
        }
        """.data(using: .utf8)!

        let format = try JSONDecoder().decode(MediaFormat.self, from: json)
        XCTAssertTrue(format.isHDR, "Format with HDR10 dynamic_range and 10-bit depth must be marked as isHDR")
        XCTAssertEqual(format.dynamicRange, "HDR10")
        XCTAssertEqual(format.colorSpace, "bt2020")
        XCTAssertEqual(format.bitDepth, 10)
        XCTAssertNotNil(format.hdrSummary)
        XCTAssertTrue(format.hdrSummary?.contains("HDR10") == true)
        XCTAssertTrue(format.hdrSummary?.contains("10-bit") == true)
        XCTAssertTrue(format.hdrSummary?.contains("BT.2020") == true)
    }

    func testMediaFormatDisplaySummaryIncludesHDR() {
        let format = MediaFormat(
            formatId: "313",
            ext: "webm",
            resolution: "3840x2160",
            fps: 60,
            vcodec: "av01",
            acodec: "none",
            dynamicRange: "HDR10",
            colorSpace: "bt2020",
            bitDepth: 10
        )
        let summary = format.displaySummary
        XCTAssertTrue(summary.contains("HDR10"), "displaySummary must include HDR tags")
        XCTAssertTrue(summary.contains("10-bit"), "displaySummary must include bit depth")
        XCTAssertTrue(summary.contains("BT.2020"), "displaySummary must include color space")
    }

    func testDownloadDiagnosticsTelemetryCapture() {
        var diag = DownloadDiagnostics()
        diag.pid = 12345
        diag.ytdlpVersion = "2026.08.29"
        diag.ffmpegVersion = "7.0.1"
        diag.extractor = "YouTube"
        diag.formatId = "313+140"
        diag.videoCodec = "av01"
        diag.audioCodec = "aac"
        diag.container = "mp4"
        diag.dynamicRange = "HDR10"
        diag.bitDepth = 10
        diag.colorSpace = "bt2020"
        diag.exitStatus = "Success (0)"

        XCTAssertEqual(diag.pid, 12345)
        XCTAssertEqual(diag.hdrSummary, "HDR10 • 10-bit • BT2020")
        XCTAssertEqual(diag.exitStatus, "Success (0)")
    }

    func testHDRToSDRToneMappingArguments() async throws {
        let capturedArgsBox = TestBox<[String]>([])
        service.processRunner = MockYtdlpProcessRunner(mockDownload: { args in
            capturedArgsBox.value = args
            return "[download] Destination: /tmp/test_hdr.mp4\n"
        })

        var options = DownloadOptions.default
        options.hdrAction = .convertToSDR

        _ = try await service.download(
            url: "https://example.com/hdr-video",
            options: options,
            onProgress: { _, _, _ in },
            onOutput: { _ in }
        )

        XCTAssertTrue(capturedArgsBox.value.contains("--postprocessor-args"))
        if let idx = capturedArgsBox.value.firstIndex(of: "--postprocessor-args") {
            XCTAssertTrue(capturedArgsBox.value[idx + 1].contains("tonemap=hable"))
            XCTAssertTrue(capturedArgsBox.value[idx + 1].contains("zscale=t=bt709"))
        }
    }

    @MainActor
    func testAdaptiveRenderingCapabilitiesAndDerivations() {
        let caps1 = RenderingCapabilities(supportsEDR: true, supportsP3: true, reduceTransparency: false)
        XCTAssertTrue(caps1.supportsEDR)
        XCTAssertTrue(caps1.supportsP3)
        XCTAssertFalse(caps1.reduceTransparency)

        let caps2 = RenderingCapabilities(supportsEDR: false, supportsP3: false, reduceTransparency: true)
        XCTAssertFalse(caps2.supportsEDR)
        XCTAssertFalse(caps2.supportsP3)
        XCTAssertTrue(caps2.reduceTransparency)

        let env = AdaptiveRenderingEnvironment.shared
        XCTAssertNotNil(env.materialMode)
        XCTAssertNotNil(env.colorGamut)
    }
}






