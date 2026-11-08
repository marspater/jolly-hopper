import Foundation

// Stored shape and memberwise initializers of the decoded yt-dlp models. Parameter counts
// mirror the JSON fields, so this file is excluded from Codacy in .codacy.yml.
extension MediaInfo {
    public init(
        id: String,
        title: String,
        description: String? = nil,
        thumbnail: String? = nil,
        duration: Double? = nil,
        uploader: String? = nil,
        uploadDate: String? = nil,
        viewCount: Int? = nil,
        likeCount: Int? = nil,
        formats: [MediaFormat]? = nil,
        subtitles: [String: [SubtitleInfo]]? = nil,
        automaticCaptions: [String: [SubtitleInfo]]? = nil,
        chapters: [ChapterInfo]? = nil,
        playlist: String? = nil,
        playlistIndex: Int? = nil,
        playlistCount: Int? = nil,
        webpageUrl: String? = nil,
        originalUrl: String? = nil,
        extractor: String? = nil,
        formatProtocol: String? = nil,
        manifestUrl: String? = nil,
        titleIsDecoded: Bool = false
    ) {
        self.id = id
        self.title = titleIsDecoded ? title : title.decodingHTMLEntities()
        self.description = description?.decodingHTMLEntities()
        self.thumbnail = thumbnail
        self.duration = duration
        self.uploader = uploader
        self.uploadDate = uploadDate
        self.viewCount = viewCount
        self.likeCount = likeCount
        self.formats = formats
        self.subtitles = subtitles
        self.automaticCaptions = automaticCaptions
        self.chapters = chapters
        self.playlist = playlist
        self.playlistIndex = playlistIndex
        self.playlistCount = playlistCount
        self.webpageUrl = webpageUrl
        self.originalUrl = originalUrl
        self.extractor = extractor
        self.formatProtocol = formatProtocol
        self.manifestUrl = manifestUrl

        if let fmts = formats?.filter(\.isDownloadable), !fmts.isEmpty {
            self.maxFormatHeight = fmts.compactMap { $0.parsedHeight }.max()
            self.firstHDRSummary = fmts.first(where: { $0.isHDR })?.hdrSummary
        } else {
            self.maxFormatHeight = nil
            self.firstHDRSummary = nil
        }
    }
}

public struct MediaFormat: Codable, Identifiable, Hashable, Sendable {
    /// yt-dlp uses booleans for known DRM and "maybe" for formats that need probing.
    public enum DRMStatus: Codable, Hashable, Sendable {
        case clear, maybe, protected

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = flag ? .protected : .clear
            } else {
                let value = try container.decode(String.self)
                if value == "maybe" {
                    self = .maybe
                } else if value.isEmpty {
                    self = .clear
                } else {
                    self = .protected
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if self == .maybe {
                try container.encode("maybe")
            } else {
                try container.encode(self == .protected)
            }
        }
    }

    public var id: String { formatId }
    public let formatId: String
    public let ext: String
    public let resolution: String?
    public let fps: Double?
    public let vcodec: String?
    public let acodec: String?
    public let abr: Double?
    public let vbr: Double?
    public let tbr: Double?
    public let filesize: Int64?
    let filesizeApprox: Int64?
    public let formatNote: String?
    public let formatProtocol: String?
    public let manifestUrl: String?
    public let needsTesting: Bool?
    let hasDRM: DRMStatus?
    let isWorking: Bool?
    public let language: String?
    let languagePreference: Int?
    public let preference: Int?
    let sourcePreference: Int?
    let audioChannels: Int?
    public let dynamicRange: String?
    public let colorSpace: String?
    public let bitDepth: Int?
    public let quality: Double?

    public enum CodingKeys: String, CodingKey, Sendable {
        case formatId = "format_id"
        case ext, resolution, fps, vcodec, acodec, abr, vbr, tbr, filesize
        case filesizeApprox = "filesize_approx"
        case formatNote = "format_note"
        case formatProtocol = "protocol"
        case manifestUrl = "manifest_url"
        case needsTesting = "__needs_testing"
        case hasDRM = "has_drm"
        case isWorking = "__working"
        case language
        case languagePreference = "language_preference"
        case preference
        case sourcePreference = "source_preference"
        case audioChannels = "audio_channels"
        case dynamicRange = "dynamic_range"
        case colorSpace = "color_space"
        case bitDepth = "bit_depth"
        case quality
    }

    public init(
        formatId: String,
        ext: String,
        resolution: String? = nil,
        fps: Double? = nil,
        vcodec: String? = nil,
        acodec: String? = nil,
        abr: Double? = nil,
        vbr: Double? = nil,
        tbr: Double? = nil,
        filesize: Int64? = nil,
        filesizeApprox: Int64? = nil,
        formatNote: String? = nil,
        formatProtocol: String? = nil,
        manifestUrl: String? = nil,
        needsTesting: Bool? = nil,
        hasDRM: DRMStatus? = nil,
        isWorking: Bool? = nil,
        language: String? = nil,
        languagePreference: Int? = nil,
        preference: Int? = nil,
        sourcePreference: Int? = nil,
        audioChannels: Int? = nil,
        dynamicRange: String? = nil,
        colorSpace: String? = nil,
        bitDepth: Int? = nil,
        quality: Double? = nil
    ) {
        self.formatId = formatId
        self.ext = ext
        self.resolution = resolution
        self.fps = fps
        self.vcodec = vcodec
        self.acodec = acodec
        self.abr = abr
        self.vbr = vbr
        self.tbr = tbr
        self.filesize = filesize
        self.filesizeApprox = filesizeApprox
        self.formatNote = formatNote
        self.formatProtocol = formatProtocol
        self.manifestUrl = manifestUrl
        self.needsTesting = needsTesting
        self.hasDRM = hasDRM
        self.isWorking = isWorking
        self.language = language
        self.languagePreference = languagePreference
        self.preference = preference
        self.sourcePreference = sourcePreference
        self.audioChannels = audioChannels
        self.dynamicRange = dynamicRange
        self.colorSpace = colorSpace
        self.bitDepth = bitDepth
        self.quality = quality
    }
}
