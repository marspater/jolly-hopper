import XCTest
@testable import Luma

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
}
