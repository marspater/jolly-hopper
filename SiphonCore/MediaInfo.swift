import Foundation

public struct MediaInfo: Codable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let thumbnail: String?
    public let duration: Double?
    public let uploader: String?
    public let uploadDate: String?
    public let viewCount: Int?
    public let likeCount: Int?
    public let formats: [MediaFormat]?
    public let subtitles: [String: [SubtitleInfo]]?
    public let automaticCaptions: [String: [SubtitleInfo]]?
    public let chapters: [ChapterInfo]?
    public let playlist: String?
    public let playlistIndex: Int?
    public let playlistCount: Int?
    public let webpageUrl: String?
    public let originalUrl: String?
    public let extractor: String?
    public let formatProtocol: String?
    public let manifestUrl: String?

    // Bolt Performance Optimization: Pre-calculate max format height and HDR summary once upon initialization
    // to prevent repetitive O(N) format array iterations and string parsing during SwiftUI view redraws.
    public let maxFormatHeight: Int?
    public let firstHDRSummary: String?

    // In-memory only (not in CodingKeys): the exact yt-dlp JSON this info was
    // decoded from, so the download can skip a second extraction.
    public var rawJSON: Data?
    public var fetchedAt: Date?

    public enum CodingKeys: String, CodingKey, Sendable {
        case id
        case title
        case description
        case thumbnail
        case duration
        case uploader
        case uploadDate = "upload_date"
        case viewCount = "view_count"
        case likeCount = "like_count"
        case formats
        case subtitles
        case automaticCaptions = "automatic_captions"
        case chapters
        case playlist
        case playlistIndex = "playlist_index"
        case playlistCount = "playlist_count"
        case webpageUrl = "webpage_url"
        case originalUrl = "original_url"
        case extractor
        case extractorKey = "extractor_key"
        case formatProtocol = "protocol"
        case manifestUrl = "manifest_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.title = rawTitle.decodingHTMLEntities()
        self.description = (try container.decodeIfPresent(String.self, forKey: .description))?.decodingHTMLEntities()
        self.thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        self.uploader = try container.decodeIfPresent(String.self, forKey: .uploader)
        self.uploadDate = try container.decodeIfPresent(String.self, forKey: .uploadDate)
        self.viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        self.likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount)
        self.formats = try container.decodeIfPresent([MediaFormat].self, forKey: .formats)
        self.subtitles = try container.decodeIfPresent([String: [SubtitleInfo]].self, forKey: .subtitles)
        self.automaticCaptions = try container.decodeIfPresent([String: [SubtitleInfo]].self, forKey: .automaticCaptions)
        self.chapters = try container.decodeIfPresent([ChapterInfo].self, forKey: .chapters)
        self.playlist = try container.decodeIfPresent(String.self, forKey: .playlist)
        self.playlistIndex = try container.decodeIfPresent(Int.self, forKey: .playlistIndex)
        self.playlistCount = try container.decodeIfPresent(Int.self, forKey: .playlistCount)
        self.webpageUrl = try container.decodeIfPresent(String.self, forKey: .webpageUrl)
        self.originalUrl = try container.decodeIfPresent(String.self, forKey: .originalUrl)
        self.extractor = try container.decodeIfPresent(String.self, forKey: .extractor) ?? container.decodeIfPresent(String.self, forKey: .extractorKey)
        self.formatProtocol = try container.decodeIfPresent(String.self, forKey: .formatProtocol)
        self.manifestUrl = try container.decodeIfPresent(String.self, forKey: .manifestUrl)

        if let fmts = self.formats?.filter(\.isDownloadable), !fmts.isEmpty {
            self.maxFormatHeight = fmts.compactMap { $0.parsedHeight }.max()
            self.firstHDRSummary = fmts.first(where: { $0.isHDR })?.hdrSummary
        } else {
            self.maxFormatHeight = nil
            self.firstHDRSummary = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeBasicMetadata(to: &container)
        try encodeMediaContent(to: &container)
        try encodeNetworkDetails(to: &container)
    }

    private func encodeBasicMetadata(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(uploader, forKey: .uploader)
        try container.encodeIfPresent(uploadDate, forKey: .uploadDate)
        try container.encodeIfPresent(viewCount, forKey: .viewCount)
        try container.encodeIfPresent(likeCount, forKey: .likeCount)
    }

    private func encodeMediaContent(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(formats, forKey: .formats)
        try container.encodeIfPresent(subtitles, forKey: .subtitles)
        try container.encodeIfPresent(automaticCaptions, forKey: .automaticCaptions)
        try container.encodeIfPresent(chapters, forKey: .chapters)
        try container.encodeIfPresent(playlist, forKey: .playlist)
        try container.encodeIfPresent(playlistIndex, forKey: .playlistIndex)
        try container.encodeIfPresent(playlistCount, forKey: .playlistCount)
    }

    private func encodeNetworkDetails(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(webpageUrl, forKey: .webpageUrl)
        try container.encodeIfPresent(originalUrl, forKey: .originalUrl)
        try container.encodeIfPresent(extractor, forKey: .extractor)
        try container.encodeIfPresent(formatProtocol, forKey: .formatProtocol)
        try container.encodeIfPresent(manifestUrl, forKey: .manifestUrl)
    }
}

extension MediaInfo {
    public func prunedForCompletion() -> MediaInfo {
        return MediaInfo(
            id: self.id,
            title: self.title,
            description: nil,
            thumbnail: self.thumbnail,
            duration: self.duration,
            uploader: self.uploader,
            uploadDate: self.uploadDate,
            viewCount: self.viewCount,
            likeCount: self.likeCount,
            formats: nil,
            subtitles: nil,
            automaticCaptions: nil,
            chapters: nil,
            playlist: self.playlist,
            playlistIndex: self.playlistIndex,
            playlistCount: self.playlistCount,
            webpageUrl: self.webpageUrl,
            originalUrl: self.originalUrl,
            extractor: self.extractor,
            formatProtocol: nil,
            manifestUrl: nil,
            titleIsDecoded: true
        )
    }

    public var durationString: String? {
        guard let duration = duration else { return nil }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private var isYouTubeVideo: Bool {
        guard id.utf8.count == 11,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return false }
        if let extractor = extractor?.lowercased(), extractor == "youtube" || extractor.hasPrefix("youtube:") { return true }
        return [webpageUrl, originalUrl].compactMap { $0 }.contains { value in
            guard let host = URL(string: value)?.host?.lowercased() else { return false }
            return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
        }
    }

    public var thumbnailURL: URL? {
        if let thumbnail = thumbnail, !thumbnail.isEmpty {
            let lower = thumbnail.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                return URL(string: thumbnail)
            }
        }

        if isYouTubeVideo {
            return URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
        }

        return nil
    }

    public var isFragmented: Bool {
        if let proto = formatProtocol?.lowercased(),
           proto.contains("m3u8") || proto.contains("dash") || proto.contains("fragment") || proto.contains("ism") {
            return true
        }
        if let manifest = manifestUrl?.lowercased(),
           manifest.contains(".m3u8") || manifest.contains(".mpd") || manifest.contains("/manifest") {
            return true
        }
        return false
    }

    public var downloadableFormats: [MediaFormat] {
        (formats ?? []).filter(\.isDownloadable)
    }

    public func resolveSelectedFormats(options: DownloadOptions) -> [MediaFormat] {
        let formats = downloadableFormats
        guard !formats.isEmpty else { return [] }

        // Bolt Performance Optimization: Lazily filter and sort audio formats at most once across resolution branches
        var cachedBestAudio: MediaFormat??
        let getBestAudio: () -> MediaFormat? = {
            if let cached = cachedBestAudio {
                return cached
            }
            // acodec "none" excludes storyboards (vcodec and acodec both "none"), which carry no audio.
            let audioFormats = formats.filter {
                ($0.isAudioOnly || $0.vcodec == "none" || $0.vcodec == nil) && $0.acodec != "none"
            }
            let sorted = audioFormats.sorted { MediaFormat.compareAudioFormats($0, $1, options: options) }
            let best = sorted.first
            cachedBestAudio = best
            return best
        }

        // 1. If explicit selectedFormatId is specified (can be single like "137" or combined like "137+140"):
        if let customId = options.selectedFormatId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customId.isEmpty,
           let matched = resolveCustomFormatSelection(customId: customId, in: formats, options: options, getBestAudio: getBestAudio) {
            return matched
        }

        // 2. If audio-only download:
        if options.fileType.isAudio, let best = getBestAudio() {
            return [best]
        }

        // 3. Video formats: filter by hard constraints (codec & resolution), then rank deterministically
        let candidateVideos = formats.filter { !$0.isAudioOnly }
        let sortedVideos = rankCandidateVideos(candidateVideos, options: options)

        if let bestVideo = sortedVideos.first {
            if bestVideo.isVideoOnly, let bestAudio = getBestAudio() {
                return [bestVideo, bestAudio]
            }
            return [bestVideo]
        }

        return []
    }

    private func resolveCustomFormatSelection(
        customId: String,
        in formats: [MediaFormat],
        options: DownloadOptions,
        getBestAudio: () -> MediaFormat?
    ) -> [MediaFormat]? {
        // Bolt Performance Optimization: Use Substring `split` to avoid allocating intermediate String arrays.
        let ids = customId.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let matched = ids.compactMap { id in formats.first(where: { $0.formatId == id }) }
        guard matched.count == ids.count, !matched.isEmpty else { return nil }

        if matched.count == 2 {
            return isValidDualFormatPair(matched) ? matched : nil
        }
        if matched.count == 1 {
            return resolveSingleCustomFormat(matched[0], options: options, getBestAudio: getBestAudio)
        }
        return nil
    }

    private func isValidDualFormatPair(_ matched: [MediaFormat]) -> Bool {
        let hasVideo = matched.contains(where: { !$0.isAudioOnly })
        let hasAudio = matched.contains(where: { $0.isAudioOnly || $0.vcodec == "none" || $0.vcodec == nil })
        return hasVideo && hasAudio
    }

    private func resolveSingleCustomFormat(
        _ single: MediaFormat,
        options: DownloadOptions,
        getBestAudio: () -> MediaFormat?
    ) -> [MediaFormat] {
        if single.isVideoOnly, options.fileType.isVideo, let bestAudio = getBestAudio() {
            return [single, bestAudio]
        }
        return [single]
    }

    private func rankCandidateVideos(_ candidateVideos: [MediaFormat], options: DownloadOptions) -> [MediaFormat] {
        if options.videoResolution == .worst {
            // Lowest known height first (unknown heights last), then lowest bitrate;
            // a requested codec still wins.
            return candidateVideos.sorted { first, second in
                let firstRank = first.videoRank(options: options)
                let secondRank = second.videoRank(options: options)
                if firstRank.matchesCodec != secondRank.matchesCodec { return firstRank.matchesCodec }
                if (first.parsedHeight == nil) != (second.parsedHeight == nil) { return first.parsedHeight != nil }
                if firstRank.height != secondRank.height { return firstRank.height < secondRank.height }
                return firstRank.bitrate < secondRank.bitrate
            }
        }
        let eligibleVideos = candidateVideos.filter { video in
            guard let maxH = options.videoResolution?.maxHeight else { return true }
            if let height = video.parsedHeight {
                return height <= maxH
            }
            return false
        }
        if !eligibleVideos.isEmpty {
            return eligibleVideos.sorted { MediaFormat.compareVideoFormats($0, $1, options: options) }
        } else if options.resolutionFallbackPolicy == .allowHigher {
            // User explicitly configured policy to allow higher resolution exceeding ceiling
            return candidateVideos.sorted { MediaFormat.compareVideoFormats($0, $1, options: options) }
        } else {
            // Strict ceiling (default): When no format with known height <= ceiling exists,
            // permit candidates with unknown/unspecified height (uncertain), but strictly reject formats with known height > ceiling
            let unknownHeightVideos = candidateVideos.filter { $0.parsedHeight == nil }
            return unknownHeightVideos.sorted { MediaFormat.compareVideoFormats($0, $1, options: options) }
        }
    }

    public func formatResolutionExceedsCeiling(options: DownloadOptions) -> ResolutionCeilingCheck {
        guard let maxH = options.videoResolution?.maxHeight, options.fileType.isVideo else {
            return ResolutionCeilingCheck(exceeded: false, requestedHeight: nil, actualHeight: nil)
        }
        let selected = resolveSelectedFormats(options: options)
        let actualHeight = selected.first(where: { !$0.isAudioOnly })?.parsedHeight
        let exceeded = actualHeight.map { $0 > maxH } ?? false
        return ResolutionCeilingCheck(exceeded: exceeded, requestedHeight: maxH, actualHeight: actualHeight)
    }

    public func isSelectedFormatFragmented(options: DownloadOptions) -> Bool {
        let resolved = resolveSelectedFormats(options: options)
        if !resolved.isEmpty {
            return resolved.contains(where: { $0.isFragmented })
        }

        if let customId = options.selectedFormatId?.lowercased(),
           customId.contains("dash") || customId.contains("m3u8") || customId.contains("hls") {
            return true
        }

        return isFragmented
    }

    public var resolvedURL: String {
        if let webpage = webpageUrl, !webpage.isEmpty {
            return webpage
        }
        if let original = originalUrl, !original.isEmpty {
            return original
        }
        if id.hasPrefix("http://") || id.hasPrefix("https://") {
            return id
        }
        if isYouTubeVideo {
            return "https://www.youtube.com/watch?v=\(id)"
        }
        return id
    }
}

public struct ResolutionCeilingCheck: Sendable {
    public let exceeded: Bool
    public let requestedHeight: Int?
    public let actualHeight: Int?
}
