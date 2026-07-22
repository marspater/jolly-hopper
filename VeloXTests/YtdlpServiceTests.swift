import XCTest
@testable import VeloX

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
            "playlist_count": 5
        }
        """

        var callCount = 0
        service.mockCommandRunner = { args in
            callCount += 1
            if callCount == 1 {
                // First call: simulate failure of single video fetch
                throw YtdlpError.commandFailed("Simulated single video failure")
            } else {
                // Second call: return valid playlist JSON
                return validPlaylistJSON
            }
        }

        let mediaInfo = try await service.fetchInfo(url: "https://www.youtube.com/playlist?list=test_playlist_id")

        XCTAssertEqual(callCount, 2, "Expected mock to be called twice: once for single, once for playlist fallback")
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
}
