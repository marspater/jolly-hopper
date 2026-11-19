@testable import SiphonCore
import Testing

struct MediaInfoAudioSelectionTests {
    @Test @MainActor
    func bestAudioPrefersRealAudioTrackOverUnlabelledMuxedFormat() {
        let info = MediaInfo(id: "test", title: "Muxed", formats: [
            MediaFormat(formatId: "hls-720", ext: "mp4", tbr: 2000),
            MediaFormat(formatId: "v1080", ext: "mp4", resolution: "1080p", vcodec: "avc1", acodec: "none", tbr: 4000),
            MediaFormat(formatId: "a128", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", abr: 128)
        ])
        var options = DownloadOptions.default
        options.fileType = .mkv
        #expect(info.resolveSelectedFormats(options: options).map(\.id) == ["v1080", "a128"])
    }
}

struct MediaInfoDisplayValueTests {
    @Test @MainActor
    func hostileDurationAndRatesDoNotTrap() {
        #expect(MediaInfo(id: "x", title: "t", duration: 1e23).durationString == nil)
        #expect(MediaInfo(id: "x", title: "t", duration: .infinity).durationString == nil)
        #expect(MediaInfo(id: "x", title: "t", duration: .nan).durationString == nil)
        #expect(MediaInfo(id: "x", title: "t", duration: Double(Int.max)).durationString == nil)
        #expect(Double.nan.displayInteger == nil)
        #expect(Double(Int.max).displayInteger == nil)
        #expect(Double(Int.max).nextDown.displayInteger != nil)
        #expect(29.97.displayInteger == 29)
        #expect(MediaInfo(id: "x", title: "t", duration: 3725).durationString == "1:02:05")
        #expect(MediaInfo(id: "x", title: "t", duration: 65.7).durationString == "1:05")

        let summary = MediaFormat(formatId: "f", ext: "mp4", fps: 1e30, tbr: .infinity).displaySummary
        #expect(!summary.contains("fps"))
        #expect(MediaFormat(formatId: "f", ext: "mp4", fps: 29.97, abr: 128).displaySummary.contains("29fps"))
    }
}
