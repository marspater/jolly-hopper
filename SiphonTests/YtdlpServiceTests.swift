import XCTest
@testable import Siphon

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

        var callCount = 0
        service.mockCommandRunner = { args in
            callCount += 1
            if callCount == 1 {
                // First call: simulate failure of single video fetch
                throw YtdlpError.commandFailed("Simulated single video failure")
            } else {
                // Subsequent calls: return valid playlist JSON
                return validPlaylistJSON
            }
        }

        let mediaInfo = try await service.fetchInfo(url: "https://www.youtube.com/playlist?list=test_playlist_id")

        XCTAssertGreaterThanOrEqual(callCount, 2, "Expected mock to be called at least twice: once for single video, once for playlist fallback")
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

    func testDownloadBlockedArgumentsThrowSecurityViolation() async {
        let blockedTestArgs = ["--exec echo hacked", "--output /tmp/test", "-o /etc/passwd", "--paths /root", "--load-info-json file.json"]

        for blocked in blockedTestArgs {
            var options = DownloadOptions.default
            options.additionalArguments = blocked

            do {
                _ = try await service.download(
                    url: "https://example.com/video",
                    options: options,
                    onProcessCreated: { _ in },
                    onProgress: { _, _, _ in },
                    onOutput: { _ in }
                )
                XCTFail("Expected securityViolation for argument: \(blocked)")
            } catch let error as YtdlpError {
                if case .securityViolation = error {
                    // Expected
                } else {
                    XCTFail("Expected .securityViolation, got: \(error)")
                }
            } catch {
                XCTFail("Expected YtdlpError.securityViolation, got: \(error)")
            }
        }
    }

    func testSpeedLimiterFlagAppendedWhenConfigured() async throws {
        UserDefaults.standard.set(5120, forKey: UserDefaultsKeys.downloadSpeedLimit)
        defer { UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.downloadSpeedLimit) }

        var capturedArgs: [String] = []
        service.mockDownloadRunner = { args in
            capturedArgs = args
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

        XCTAssertTrue(capturedArgs.contains("--limit-rate"))
        if let idx = capturedArgs.firstIndex(of: "--limit-rate") {
            XCTAssertEqual(capturedArgs[idx + 1], "5120K")
        }
    }

    func testCustomFormatIdSelectionFlagAppended() async throws {
        var capturedArgs: [String] = []
        service.mockDownloadRunner = { args in
            capturedArgs = args
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

        XCTAssertTrue(capturedArgs.contains("-f"))
        if let idx = capturedArgs.firstIndex(of: "-f") {
            XCTAssertEqual(capturedArgs[idx + 1], "137+140")
        }
    }

    func testAudioExtractionAndMetadataFlags() async throws {
        var capturedArgs: [String] = []
        service.mockDownloadRunner = { args in
            capturedArgs = args
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

        XCTAssertTrue(capturedArgs.contains("-x"))
        XCTAssertTrue(capturedArgs.contains("--audio-format"))
        XCTAssertTrue(capturedArgs.contains("mp3"))
        XCTAssertTrue(capturedArgs.contains("--embed-thumbnail"))
        XCTAssertTrue(capturedArgs.contains("--embed-metadata"))
    }

    func testThisVidURLNormalizationAndHeaders() async throws {
        var capturedArgs: [String] = []
        service.mockDownloadRunner = { args in
            capturedArgs = args
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
        XCTAssertTrue(capturedArgs.contains(where: { $0.contains("thisvid") || $0.contains("huge-butt5") }))
        XCTAssertTrue(capturedArgs.contains("Referer:https://thisvid.com/"))
        XCTAssertTrue(capturedArgs.contains("Origin:https://thisvid.com"))
    }
}
