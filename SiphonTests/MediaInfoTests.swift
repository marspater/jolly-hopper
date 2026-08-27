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

    // MARK: - MediaFormat videoQualityScore Tests

    func testVideoQualityScore_WithFullProperties_CalculatesCorrectScore() {
        let options = DownloadOptions.default
        let format = MediaFormat(
            formatId: "1080p_60",
            ext: "mp4",
            resolution: "1920x1080",
            fps: 60.0,
            vcodec: "avc1",
            acodec: "mp4a",
            abr: 128.0,
            vbr: 4000.0,
            tbr: 5000.0,
            filesize: 52428800,
            filesizeApprox: 104857600,
            formatNote: "1080p60",
            needsTesting: false
        )

        let score = format.videoQualityScore(options: options)
        XCTAssertEqual(score, 10805110.0, accuracy: 0.001)
    }

    func testVideoQualityScore_BitrateFallbackHierarchy() {
        let options = DownloadOptions.default

        let formatVbr = MediaFormat(
            formatId: "vbr_fmt",
            ext: "mp4",
            resolution: "1280x720",
            abr: 128.0,
            vbr: 2500.0
        )
        XCTAssertEqual(formatVbr.videoQualityScore(options: options), 7202500.0, accuracy: 0.001)

        let formatAbr = MediaFormat(
            formatId: "abr_fmt",
            ext: "mp4",
            resolution: "1280x720",
            abr: 320.0
        )
        XCTAssertEqual(formatAbr.videoQualityScore(options: options), 7200320.0, accuracy: 0.001)

        let formatNoBitrate = MediaFormat(
            formatId: "nobitrate_fmt",
            ext: "mp4",
            resolution: "1280x720"
        )
        XCTAssertEqual(formatNoBitrate.videoQualityScore(options: options), 7200000.0, accuracy: 0.001)
    }

    func testVideoQualityScore_FilesizeFallbackHierarchy() {
        let options = DownloadOptions.default

        let formatApprox = MediaFormat(
            formatId: "approx_fmt",
            ext: "mp4",
            resolution: "1280x720",
            filesizeApprox: 10485760
        )
        XCTAssertEqual(formatApprox.videoQualityScore(options: options), 7200010.0, accuracy: 0.001)

        let formatNoSize = MediaFormat(
            formatId: "nosize_fmt",
            ext: "mp4",
            resolution: "1280x720"
        )
        XCTAssertEqual(formatNoSize.videoQualityScore(options: options), 7200000.0, accuracy: 0.001)
    }

    func testVideoQualityScore_ParsedHeightFallbacks() {
        let options = DownloadOptions.default

        let formatTagNote = MediaFormat(
            formatId: "fmt_note",
            ext: "mp4",
            formatNote: "2160p 4K ULTRA HD"
        )
        XCTAssertEqual(formatTagNote.videoQualityScore(options: options), 21600000.0, accuracy: 0.001)

        let formatKeywordId = MediaFormat(
            formatId: "hd",
            ext: "mp4"
        )
        XCTAssertEqual(formatKeywordId.videoQualityScore(options: options), 10800000.0, accuracy: 0.001)

        let formatUnknown = MediaFormat(
            formatId: "audio_only",
            ext: "m4a"
        )
        XCTAssertEqual(formatUnknown.videoQualityScore(options: options), 0.0, accuracy: 0.001)
    }

    func testVideoQualityScore_NeedsTestingPenalty() {
        let options = DownloadOptions.default

        let formatNeedsTesting = MediaFormat(
            formatId: "test_fmt",
            ext: "mp4",
            resolution: "1920x1080",
            needsTesting: true
        )

        XCTAssertEqual(formatNeedsTesting.videoQualityScore(options: options), 9800000.0, accuracy: 0.001)
    }

    // MARK: - MediaFormat.displaySummary Tests

    func testMediaFormatDisplaySummary_MinimalFormat_ReturnsEmptyString() {
        let format = MediaFormat(formatId: "f1", ext: "mp4")
        XCTAssertEqual(format.displaySummary, "")
    }

    func testMediaFormatDisplaySummary_FullFormat_ReturnsFormattedSummary() {
        let format = MediaFormat(
            formatId: "137",
            ext: "mp4",
            resolution: "1920x1080",
            fps: 60.0,
            vcodec: "avc1.64002a",
            acodec: "mp4a.40.2",
            abr: 128.0,
            filesize: 52428800, // 50.0 MB
            formatNote: "1080p60"
        )
        XCTAssertEqual(format.displaySummary, "1920x1080 • 60fps • avc1.64002a • mp4a.40.2 • 128k • 50.0 MB • 1080p60")
    }

    func testMediaFormatDisplaySummary_IgnoresNoneCodecs() {
        let format = MediaFormat(
            formatId: "137",
            ext: "mp4",
            resolution: "1920x1080",
            fps: 30.0,
            vcodec: "avc1.64002a",
            acodec: "none",
            filesize: 10485760
        )
        XCTAssertEqual(format.displaySummary, "1920x1080 • 30fps • avc1.64002a • 10.0 MB")
    }

    func testMediaFormatDisplaySummary_TbrFallbackWhenAbrNilAndVbrZeroOrNil() {
        let formatWithNilVbr = MediaFormat(
            formatId: "f1",
            ext: "mp4",
            resolution: "1280x720",
            vbr: nil,
            tbr: 1500.0,
            filesize: 15728640
        )
        XCTAssertEqual(formatWithNilVbr.displaySummary, "1280x720 • 1500k • 15.0 MB")

        let formatWithZeroVbr = MediaFormat(
            formatId: "f2",
            ext: "mp4",
            resolution: "1280x720",
            vbr: 0,
            tbr: 1500.0,
            filesize: 15728640
        )
        XCTAssertEqual(formatWithZeroVbr.displaySummary, "1280x720 • 1500k • 15.0 MB")
    }

    func testMediaFormatDisplaySummary_DoesNotUseTbrWhenVbrIsGreaterThanZero() {
        let format = MediaFormat(
            formatId: "f1",
            ext: "mp4",
            resolution: "1280x720",
            vbr: 1200.0,
            tbr: 1500.0,
            filesize: 15728640
        )
        XCTAssertEqual(format.displaySummary, "1280x720 • 15.0 MB")
    }

    func testMediaFormatDisplaySummary_FilesizeApproxFallbackWhenFilesizeNil() {
        let format = MediaFormat(
            formatId: "f1",
            ext: "mp4",
            filesize: nil,
            filesizeApprox: 20971520
        )
        XCTAssertEqual(format.displaySummary, "20.0 MB")
    }

    func testMediaFormatDisplaySummary_FiltersZeroAndNegativeValues() {
        let format = MediaFormat(
            formatId: "f1",
            ext: "mp4",
            resolution: "",
            fps: 0,
            abr: 0,
            filesize: -500,
            formatNote: ""
        )
        XCTAssertEqual(format.displaySummary, "")
    }

    func testResolveSelectedFormats_PrioritizesOriginalAudioTrackOverDubbedAudio() {
        let videoFormat = MediaFormat(
            formatId: "270",
            ext: "mp4",
            resolution: "1920x1080",
            fps: 60,
            vcodec: "avc1.64002a",
            acodec: "none",
            abr: nil,
            vbr: 4500,
            filesize: 50000000,
            filesizeApprox: nil,
            formatNote: "1080p",
            formatProtocol: "https"
        )
        let arabicDubbedAudio = MediaFormat(
            formatId: "140-0",
            ext: "m4a",
            resolution: nil,
            fps: nil,
            vcodec: "none",
            acodec: "mp4a.40.2",
            abr: 135.0,
            vbr: nil,
            filesize: 6000000,
            filesizeApprox: nil,
            formatNote: "Arabic, medium - dubbed",
            formatProtocol: "https",
            language: "ar",
            languagePreference: -1
        )
        let englishOriginalAudio = MediaFormat(
            formatId: "140-23",
            ext: "m4a",
            resolution: nil,
            fps: nil,
            vcodec: "none",
            acodec: "mp4a.40.2",
            abr: 125.0,
            vbr: nil,
            filesize: 5000000,
            filesizeApprox: nil,
            formatNote: "English (US) original (default), medium",
            formatProtocol: "https",
            language: "en-US",
            languagePreference: 10
        )
        let mediaInfo = MediaInfo(
            id: "test1234",
            title: "Multi-Language Test Video",
            formats: [videoFormat, arabicDubbedAudio, englishOriginalAudio]
        )
        let options = DownloadOptions.default
        let resolved = mediaInfo.resolveSelectedFormats(options: options)

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].formatId, "270")
        XCTAssertEqual(resolved[1].formatId, "140-23", "Should select original English audio track (140-23) over higher-bitrate Arabic dubbed audio (140-0)")
    }

    func testResolveSelectedFormats_AudioOnlyPrioritizesOriginalTrack() {
        let arabicDubbedAudio = MediaFormat(
            formatId: "140-0",
            ext: "m4a",
            resolution: nil,
            fps: nil,
            vcodec: "none",
            acodec: "mp4a.40.2",
            abr: 135.0,
            vbr: nil,
            filesize: 6000000,
            filesizeApprox: nil,
            formatNote: "Arabic - dubbed",
            language: "ar",
            languagePreference: -1
        )
        let englishOriginalAudio = MediaFormat(
            formatId: "140-23",
            ext: "m4a",
            resolution: nil,
            fps: nil,
            vcodec: "none",
            acodec: "mp4a.40.2",
            abr: 125.0,
            vbr: nil,
            filesize: 5000000,
            filesizeApprox: nil,
            formatNote: "English original (default)",
            language: "en",
            languagePreference: 10
        )
        let mediaInfo = MediaInfo(
            id: "test1234",
            title: "Audio Only Test",
            formats: [arabicDubbedAudio, englishOriginalAudio]
        )
        var options = DownloadOptions.default
        options.fileType = .m4a
        let resolved = mediaInfo.resolveSelectedFormats(options: options)

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].formatId, "140-23", "Audio-only download should pick original track over dubbed track")
    }
}

