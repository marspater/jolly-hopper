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
