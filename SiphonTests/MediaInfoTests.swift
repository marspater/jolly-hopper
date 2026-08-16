import XCTest
@testable import Siphon

final class MediaInfoTests: XCTestCase {

    // Helper function to create a minimal MediaInfo with a specific duration
    private func createMediaInfo(duration: Double?) -> MediaInfo {
        return MediaInfo(
            id: "test_id",
            title: "Test Title",
            description: nil,
            thumbnail: nil,
            duration: duration,
            uploader: nil,
            uploadDate: nil,
            viewCount: nil,
            likeCount: nil,
            formats: nil,
            subtitles: nil,
            automaticCaptions: nil,
            chapters: nil,
            playlist: nil,
            playlistIndex: nil,
            playlistCount: nil
        )
    }

    func testDurationString_NilDuration_ReturnsNil() {
        let info = createMediaInfo(duration: nil)
        XCTAssertNil(info.durationString)
    }

    func testDurationString_ZeroSeconds_ReturnsZeroMinutesZeroSeconds() {
        let info = createMediaInfo(duration: 0)
        XCTAssertEqual(info.durationString, "0:00")
    }

    func testDurationString_UnderOneMinute_ReturnsOnlyMinutesAndSeconds() {
        let info = createMediaInfo(duration: 45)
        XCTAssertEqual(info.durationString, "0:45")
    }

    func testDurationString_ExactlyOneMinute_ReturnsOneMinuteZeroSeconds() {
        let info = createMediaInfo(duration: 60)
        XCTAssertEqual(info.durationString, "1:00")
    }

    func testDurationString_OverOneMinuteUnderOneHour_ReturnsMinutesAndSeconds() {
        let info = createMediaInfo(duration: 90)
        XCTAssertEqual(info.durationString, "1:30")

        let info2 = createMediaInfo(duration: 3599)
        XCTAssertEqual(info2.durationString, "59:59")
    }

    func testDurationString_ExactlyOneHour_ReturnsOneHourZeroMinutesZeroSeconds() {
        let info = createMediaInfo(duration: 3600)
        XCTAssertEqual(info.durationString, "1:00:00")
    }

    func testDurationString_OverOneHour_ReturnsHoursMinutesAndSeconds() {
        let info = createMediaInfo(duration: 3665)
        XCTAssertEqual(info.durationString, "1:01:05")

        let info2 = createMediaInfo(duration: 7325)
        XCTAssertEqual(info2.durationString, "2:02:05")
    }

    func testDurationString_FractionalSeconds_TruncatesFraction() {
        let info = createMediaInfo(duration: 59.9)
        XCTAssertEqual(info.durationString, "0:59")
    }

    func testResolvedURL_WithWebpageUrl_ReturnsWebpageUrl() {
        let info = MediaInfo(id: "12345", title: "SoundCloud Track", webpageUrl: "https://soundcloud.com/artist/track")
        XCTAssertEqual(info.resolvedURL, "https://soundcloud.com/artist/track")
    }

    func testResolvedURL_WithOriginalUrl_ReturnsOriginalUrl() {
        let info = MediaInfo(id: "12345", title: "Vimeo Video", originalUrl: "https://vimeo.com/12345")
        XCTAssertEqual(info.resolvedURL, "https://vimeo.com/12345")
    }

    func testResolvedURL_WithFullHttpId_ReturnsId() {
        let info = MediaInfo(id: "https://example.com/video.mp4", title: "Direct Stream")
        XCTAssertEqual(info.resolvedURL, "https://example.com/video.mp4")
    }

    func testResolvedURL_WithYouTube11CharId_ReturnsYouTubeUrl() {
        let info = MediaInfo(id: "dQw4w9WgXcQ", title: "YouTube Video")
        XCTAssertEqual(info.resolvedURL, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testMediaInfoDecoding_WithWebpageUrl_DecodesSuccessfully() throws {
        let json = """
        {
            "id": "abc123xyz",
            "title": "Bilibili Video",
            "webpage_url": "https://www.bilibili.com/video/BV1xx411c7mD"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MediaInfo.self, from: json)
        XCTAssertEqual(decoded.id, "abc123xyz")
        XCTAssertEqual(decoded.title, "Bilibili Video")
        XCTAssertEqual(decoded.webpageUrl, "https://www.bilibili.com/video/BV1xx411c7mD")
        XCTAssertEqual(decoded.resolvedURL, "https://www.bilibili.com/video/BV1xx411c7mD")
    }

    func testDecodingHTMLEntities() {
        let input = "Riped stud fucks Sam Ledger&#039;s pussy pt.1"
        XCTAssertEqual(input.decodingHTMLEntities(), "Riped stud fucks Sam Ledger's pussy pt.1")

        let input2 = "Tom &amp; Jerry &#39;The Movie&#39; &quot;Special&quot; &#x27;HD&#x27; &lt;1080p&gt;"
        XCTAssertEqual(input2.decodingHTMLEntities(), "Tom & Jerry 'The Movie' \"Special\" 'HD' <1080p>")

        let input3 = "No entities here"
        XCTAssertEqual(input3.decodingHTMLEntities(), "No entities here")
    }

    func testMediaInfoTitleDecodingHTMLEntities() throws {
        let json = """
        {
            "id": "1689702",
            "title": "Riped stud fucks Sam Ledger&#039;s pussy pt.1"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MediaInfo.self, from: json)
        XCTAssertEqual(decoded.title, "Riped stud fucks Sam Ledger's pussy pt.1")
    }
}
