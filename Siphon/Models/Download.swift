import Foundation
import os

@MainActor
class Download: ObservableObject, Identifiable {
    let id: UUID
    let url: String
    let createdAt: Date
    var options: DownloadOptions
    
    @Published var title: String
    @Published var duration: String?
    @Published var thumbnailURL: URL?
    @Published var status: DownloadStatus
    @Published var progress: Double
    @Published var speed: String?
    @Published var eta: String?
    @Published var filePath: URL?
    @Published var errorMessage: String?
    @Published var log: String = ""
    @Published var mediaInfo: MediaInfo? = nil
    
    var displayProgress: String {
        let percentage = Int(progress * 100)
        if let speed = speed, let eta = eta {
            return "\(percentage)% • \(speed) • \(eta)"
        }
        return "\(percentage)%"
    }
    
    init(url: String, options: DownloadOptions, title: String = "___FETCHING___", id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
        self.options = options
        self.title = title
        self.status = .queued
        self.progress = 0
    }
}


enum DownloadStatus: String, Codable {
    case fetching = "Bilgi Alınıyor"
    case queued = "Kuyrukta"
    case downloading = "İndiriliyor"
    case processing = "İşleniyor"
    case completed = "Tamamlandı"
    case failed = "Hata"
    case stopped = "Durduruldu"
    case paused = "Duraklatıldı"
    case fileExists = "Dosya Mevcut"
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .fetching: return lang.s("fetching")
        case .queued: return lang.s("queued")
        case .downloading: return lang.s("downloading")
        case .processing: return lang.s("processing")
        case .completed: return lang.s("completed")
        case .failed: return lang.s("failed")
        case .stopped: return lang.s("stopped")
        case .paused: return lang.s("paused")
        case .fileExists: return lang.s("file_exists_status")
        }
    }
    
    var color: String {
        switch self {
        case .queued: return "orange"
        case .fetching: return "blue"
        case .downloading: return "blue"
        case .processing: return "purple"
        case .paused: return "yellow"
        case .completed: return "green"
        case .failed: return "red"
        case .stopped: return "gray"
        case .fileExists: return "orange"
        }
    }
}


struct DownloadOptions: Codable {
    var saveFolder: URL
    var fileType: MediaFileType
    var videoFormat: VideoFormat?
    var audioFormat: AudioFormat?
    var videoResolution: VideoResolution?
    var audioQuality: AudioQuality?
    var downloadSubtitles: Bool
    var subtitleLanguages: [String]
    var subtitleFormat: SubtitleFormat?
    var embedSubtitles: Bool
    var downloadThumbnail: Bool
    var embedThumbnail: Bool
    var embedMetadata: Bool
    var splitChapters: Bool
    var sponsorBlock: Bool
    var timeFrameStart: String?
    var timeFrameEnd: String?
    var customFilename: String?
    var videoCodec: VideoCodec?
    var audioCodec: AudioCodec?
    var conversionCodec: ConversionCodec?
    var forceOverwrite: Bool?
    var rawCookies: String?
    var selectedFormatId: String?
    
    static var `default`: DownloadOptions {
        let saveFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        return DownloadOptions(
            saveFolder: saveFolderURL,
            fileType: .mp4,
            downloadSubtitles: false,
            subtitleLanguages: ["en"],
            subtitleFormat: .srt,
            embedSubtitles: false,
            downloadThumbnail: false,
            embedThumbnail: true,
            embedMetadata: true,
            splitChapters: false,
            sponsorBlock: false,
            conversionCodec: ConversionCodec.none,
            forceOverwrite: false,
            rawCookies: nil,
            selectedFormatId: nil
        )
    }
}


enum MediaFileType: String, Codable, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case webm = "WebM"
    case mkv = "MKV"
    case mp3 = "MP3"
    case opus = "Opus"
    case flac = "FLAC"
    case wav = "WAV"
    case m4a = "M4A"
    
    var id: String { rawValue }
    
    var isVideo: Bool {
        switch self {
        case .mp4, .webm, .mkv: return true
        default: return false
        }
    }
    
    var isAudio: Bool {
        !isVideo
    }
    
    var fileExtension: String {
        rawValue.lowercased()
    }
    
    static var videoTypes: [MediaFileType] {
        [.mp4, .webm, .mkv]
    }
    
    static var audioTypes: [MediaFileType] {
        [.mp3, .opus, .flac, .wav, .m4a]
    }
}


enum AudioQuality: String, Codable, CaseIterable, Identifiable {
    case best
    case q320 = "320kbps"
    case q256 = "256kbps"
    case q192 = "192kbps"
    case q128 = "128kbps"
    
    var id: String { rawValue }
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .best: return lang.s("res_best")
        default: return rawValue
        }
    }
    
    var ytdlpValue: String {
        switch self {
        case .best: return "0"
        case .q320: return "320K"
        case .q256: return "256K"
        case .q192: return "192K"
        case .q128: return "128K"
        }
    }
}


struct VideoFormat: Codable, Identifiable, Hashable {
    let id: String
    let ext: String
    let resolution: String?
    let fps: Double?
    let vcodec: String?
    let filesize: Int64?
    
    var displayName: String {
        var parts: [String] = []
        if let res = resolution { parts.append(res) }
        if let fps = fps { parts.append("\(Int(fps))fps") }
        if let codec = vcodec { parts.append(codec) }
        return parts.isEmpty ? id : parts.joined(separator: " • ")
    }
}


struct AudioFormat: Codable, Identifiable, Hashable {
    let id: String
    let ext: String
    let abr: Int?
    let acodec: String?
    let filesize: Int64?
    
    var displayName: String {
        var parts: [String] = []
        if let abr = abr { parts.append("\(abr)kbps") }
        if let codec = acodec { parts.append(codec) }
        return parts.isEmpty ? id : parts.joined(separator: " • ")
    }
}


enum VideoResolution: String, Codable, CaseIterable, Identifiable {
    case best
    case r2160p
    case r1440p
    case r1080p
    case r720p
    case r480p
    case r360p
    case r240p
    case worst
    
    var id: String { rawValue }
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .best: return lang.s("res_best")
        case .r2160p: return "2160p (4K)"
        case .r1440p: return "1440p (2K)"
        case .r1080p: return "1080p (Full HD)"
        case .r720p: return "720p (HD)"
        case .r480p: return "480p"
        case .r360p: return "360p"
        case .r240p: return "240p"
        case .worst: return lang.s("res_worst")
        }
    }
    
    var ytdlpValue: String {
        switch self {
        case .best: return "bestvideo"
        case .r2160p: return "bestvideo[height<=2160]"
        case .r1440p: return "bestvideo[height<=1440]"
        case .r1080p: return "bestvideo[height<=1080]"
        case .r720p: return "bestvideo[height<=720]"
        case .r480p: return "bestvideo[height<=480]"
        case .r360p: return "bestvideo[height<=360]"
        case .r240p: return "bestvideo[height<=240]"
        case .worst: return "worstvideo"
        }
    }
    
    var ytdlpCombinedValue: String {
        switch self {
        case .best: return "bestvideo*+bestaudio/best"
        case .r2160p: return "bestvideo*[height<=2160]+bestaudio/best[height<=2160]/best"
        case .r1440p: return "bestvideo*[height<=1440]+bestaudio/best[height<=1440]/best"
        case .r1080p: return "bestvideo*[height<=1080]+bestaudio/best[height<=1080]/best"
        case .r720p: return "bestvideo*[height<=720]+bestaudio/best[height<=720]/best"
        case .r480p: return "bestvideo*[height<=480]+bestaudio/best[height<=480]/best"
        case .r360p: return "bestvideo*[height<=360]+bestaudio/best[height<=360]/best"
        case .r240p: return "bestvideo*[height<=240]+bestaudio/best[height<=240]/best"
        case .worst: return "worstvideo*+worstaudio/worst"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .r2160p: return 2160
        case .r1440p: return 1440
        case .r1080p: return 1080
        case .r720p: return 720
        case .r480p: return 480
        case .r360p: return 360
        case .r240p: return 240
        default: return nil
        }
    }
}


enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case auto = "auto"
    case h264 = "h264"
    case h265 = "h265"
    case vp9 = "vp9"
    case av1 = "av1"
    
    var id: String { rawValue }
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .auto: return "Best Available"
        case .h264: return "H.264 (AVC)"
        case .h265: return "H.265 (HEVC)"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        }
    }
    
    var ytdlpFilter: String? {
        switch self {
        case .auto: return nil
        case .h264: return "[vcodec^=avc1]"
        case .h265: return "[vcodec~='^(hev1|hvc1)']"
        case .vp9: return "[vcodec^=vp9]"
        case .av1: return "[vcodec^=av01]"
        }
    }
    
    var compatibilityNote: String? {
        switch self {
        case .h264: return "Best compatibility with all devices"
        case .h265: return "Good compression, limited browser support"
        case .vp9: return "Good for 1440p+, wide support"
        case .av1: return "Best compression, requires modern hardware"
        case .auto: return nil
        }
    }
}


enum ConversionCodec: String, Codable, CaseIterable, Identifiable {
    case none = "none"
    case h264 = "h264"
    case h265 = "h265"
    case vp9 = "vp9"
    case av1 = "av1"
    
    var id: String { rawValue }
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .none: return "None (Do not convert)"
        case .h264: return "Convert to H.264"
        case .h265: return "Convert to HEVC"
        case .vp9: return "Convert to VP9"
        case .av1: return "Convert to AV1"
        }
    }
}


enum AudioCodec: String, Codable, CaseIterable, Identifiable {
    case auto = "auto"
    case aac = "aac"
    case opus = "opus"
    case mp3 = "mp3"
    case flac = "flac"
    
    var id: String { rawValue }
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .auto: return lang.s("codec_auto")
        case .aac: return "AAC (M4A)"
        case .opus: return "Opus"
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        }
    }
    
    var ytdlpFilter: String? {
        switch self {
        case .auto: return nil
        case .aac: return "[acodec^=mp4a]"
        case .opus: return "[acodec^=opus]"
        case .mp3: return "[acodec^=mp3]"
        case .flac: return "[acodec^=flac]"
        }
    }
}


enum SubtitleFormat: String, Codable, CaseIterable, Identifiable {
    case srt = "srt"
    case vtt = "vtt"
    case ass = "ass"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .srt: return "SRT"
        case .vtt: return "VTT (WebVTT)"
        case .ass: return "ASS (Advanced)"
        }
    }
    
    var ytdlpValue: String {
        rawValue
    }
}


enum DownloadPreset: String, Codable, CaseIterable, Identifiable {
    case bestQuality = "best_quality"
    case maxCompatibility = "max_compatibility"
    case smallestSize = "smallest_size"
    case audioOnly = "audio_only"
    
    var id: String { rawValue }
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .bestQuality: return lang.s("preset_best_quality")
        case .maxCompatibility: return lang.s("preset_max_compatibility")
        case .smallestSize: return lang.s("preset_smallest_size")
        case .audioOnly: return lang.s("preset_audio_only")
        }
    }
    
    func description(lang: LanguageService) -> String {
        switch self {
        case .bestQuality: return lang.s("preset_best_quality_desc")
        case .maxCompatibility: return lang.s("preset_max_compatibility_desc")
        case .smallestSize: return lang.s("preset_smallest_size_desc")
        case .audioOnly: return lang.s("preset_audio_only_desc")
        }
    }
    
    var videoCodec: VideoCodec {
        switch self {
        case .bestQuality: return .auto
        case .maxCompatibility: return .h264
        case .smallestSize: return .av1
        case .audioOnly: return .auto
        }
    }
    
    var audioCodec: AudioCodec {
        switch self {
        case .bestQuality: return .auto
        case .maxCompatibility: return .aac
        case .smallestSize: return .opus
        case .audioOnly: return .aac
        }
    }
    
    var videoResolution: VideoResolution {
        switch self {
        case .bestQuality: return .best
        case .maxCompatibility: return .r1080p
        case .smallestSize: return .r720p
        case .audioOnly: return .worst
        }
    }
    
    var fileType: MediaFileType {
        switch self {
        case .bestQuality: return .mp4
        case .maxCompatibility: return .mp4
        case .smallestSize: return .mp4
        case .audioOnly: return .m4a
        }
    }
}


struct CustomPreset: Codable, Identifiable, Equatable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.siphon", category: "CustomPreset")

    let id: UUID
    var name: String
    var videoCodec: VideoCodec
    var audioCodec: AudioCodec
    var videoResolution: VideoResolution
    var fileType: MediaFileType
    var downloadSubtitles: Bool?
    var subtitleLanguage: String?
    var subtitleFormat: SubtitleFormat?
    var sponsorBlock: Bool?

    var splitChapters: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id, name, videoCodec, audioCodec, videoResolution, fileType, subtitleLanguage, subtitleFormat, sponsorBlock, splitChapters
        case downloadSubtitles = "embedSubtitles"
    }
    
    init(name: String, videoCodec: VideoCodec, audioCodec: AudioCodec, videoResolution: VideoResolution, fileType: MediaFileType, downloadSubtitles: Bool = false, subtitleLanguage: String = "", subtitleFormat: SubtitleFormat = .srt, sponsorBlock: Bool = false, splitChapters: Bool = false) {
        self.id = UUID()
        self.name = name
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.videoResolution = videoResolution
        self.fileType = fileType
        self.downloadSubtitles = downloadSubtitles
        self.subtitleLanguage = subtitleLanguage
        self.subtitleFormat = subtitleFormat
        self.sponsorBlock = sponsorBlock
        self.splitChapters = splitChapters
    }
    
    static func loadAll() -> [CustomPreset] {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.customPresets) else {
            return []
        }
        do {
            return try JSONDecoder().decode([CustomPreset].self, from: data)
        } catch {
            logger.error("Failed to decode custom presets: \(error.localizedDescription)")
            // If data is corrupted or incompatible, we return empty list to prevent crash
            return []
        }
    }
    
    static func saveAll(_ presets: [CustomPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.customPresets)
        }
    }
}





struct MediaInfo: Codable {
    let id: String
    let title: String
    let description: String?
    let thumbnail: String?
    let duration: Double?
    let uploader: String?
    let uploadDate: String?
    let viewCount: Int?
    let likeCount: Int?
    let formats: [MediaFormat]?
    let subtitles: [String: [SubtitleInfo]]?
    let automaticCaptions: [String: [SubtitleInfo]]?
    let chapters: [ChapterInfo]?
    let playlist: String?
    let playlistIndex: Int?
    let playlistCount: Int?
    let webpageUrl: String?
    let originalUrl: String?
    let formatProtocol: String?
    let manifestUrl: String?
    
    init(
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
        formatProtocol: String? = nil,
        manifestUrl: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
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
        self.formatProtocol = formatProtocol
        self.manifestUrl = manifestUrl
    }
    
    var durationString: String? {
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
    
    var thumbnailURL: URL? {
        if let thumbnail = thumbnail, !thumbnail.isEmpty {
            let lower = thumbnail.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                return URL(string: thumbnail)
            }
        }
        
        if id.count == 11 {
            return URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
        }
        
        return nil
    }

    var isFragmented: Bool {
        if let proto = formatProtocol?.lowercased() {
            if proto.contains("m3u8") || proto.contains("dash") || proto.contains("fragment") || proto.contains("ism") {
                return true
            }
        }
        if let manifest = manifestUrl?.lowercased() {
            if manifest.contains(".m3u8") || manifest.contains(".mpd") || manifest.contains("/manifest") {
                return true
            }
        }
        return false
    }

    func resolveSelectedFormats(options: DownloadOptions) -> [MediaFormat] {
        guard let formats = formats, !formats.isEmpty else { return [] }
        
        // 1. If explicit selectedFormatId is specified (can be combined like "137+140"):
        if let customId = options.selectedFormatId, !customId.isEmpty {
            let ids = customId.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            return formats.filter { ids.contains($0.formatId) }
        }
        
        // 2. If audio-only download:
        if options.fileType.isAudio {
            let audioFormats = formats.filter { $0.isAudioOnly || ($0.vcodec == "none" || $0.vcodec == nil) }
            if let requestedAudioCodec = options.audioCodec, requestedAudioCodec != .auto {
                let matching = audioFormats.filter { fmt in
                    guard let acodec = fmt.acodec?.lowercased() else { return false }
                    return acodec.contains(requestedAudioCodec.rawValue.lowercased())
                }
                if let best = matching.max(by: { ($0.abr ?? 0) < ($1.abr ?? 0) }) {
                    return [best]
                }
            }
            if let best = audioFormats.max(by: { ($0.abr ?? 0) < ($1.abr ?? 0) }) {
                return [best]
            }
        }
        
        // 3. Video formats: match resolution and codec if specified
        let maxHeight = options.videoResolution?.maxHeight
        var candidateVideos = formats.filter { !$0.isAudioOnly }
        
        if let maxH = maxHeight {
            let matchingHeight = candidateVideos.filter { fmt in
                if let res = fmt.resolution {
                    let digits = res.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
                    if let lastNum = digits.last, let h = Int(lastNum) {
                        return h <= maxH
                    }
                }
                return true
            }
            if !matchingHeight.isEmpty {
                candidateVideos = matchingHeight
            }
        }
        
        if let requestedCodec = options.videoCodec, requestedCodec != .auto {
            let matchingCodec = candidateVideos.filter { fmt in
                guard let vcodec = fmt.vcodec?.lowercased() else { return false }
                switch requestedCodec {
                case .h264: return vcodec.hasPrefix("avc1") || vcodec.contains("h264")
                case .h265: return vcodec.hasPrefix("hev1") || vcodec.hasPrefix("hvc1") || vcodec.contains("h265") || vcodec.contains("hevc")
                case .vp9: return vcodec.hasPrefix("vp9") || vcodec.contains("vp9")
                case .av1: return vcodec.hasPrefix("av01") || vcodec.contains("av1")
                case .auto: return true
                }
            }
            if !matchingCodec.isEmpty {
                candidateVideos = matchingCodec
            }
        }
        
        if let bestVideo = candidateVideos.first {
            if bestVideo.isVideoOnly {
                let audioFormats = formats.filter { $0.isAudioOnly || ($0.vcodec == "none" || $0.vcodec == nil) }
                if let bestAudio = audioFormats.first {
                    return [bestVideo, bestAudio]
                }
            }
            return [bestVideo]
        }
        
        return []
    }

    func isSelectedFormatFragmented(options: DownloadOptions) -> Bool {
        if isFragmented {
            return true
        }
        
        let resolved = resolveSelectedFormats(options: options)
        if !resolved.isEmpty {
            return resolved.contains(where: { $0.isFragmented })
        }
        
        if let customId = options.selectedFormatId?.lowercased() {
            if customId.contains("dash") || customId.contains("m3u8") || customId.contains("hls") {
                return true
            }
        }
        
        return false
    }

    var resolvedURL: String {
        if let webpage = webpageUrl, !webpage.isEmpty {
            return webpage
        }
        if let original = originalUrl, !original.isEmpty {
            return original
        }
        if id.hasPrefix("http://") || id.hasPrefix("https://") {
            return id
        }
        if id.count == 11 {
            return "https://www.youtube.com/watch?v=\(id)"
        }
        return id
    }
    
    enum CodingKeys: String, CodingKey {
        case id, title, description, thumbnail, duration, uploader, formats, subtitles, chapters, playlist
        case automaticCaptions = "automatic_captions"
        case uploadDate = "upload_date"
        case viewCount = "view_count"
        case likeCount = "like_count"
        case playlistIndex = "playlist_index"
        case playlistCount = "playlist_count"
        case webpageUrl = "webpage_url"
        case originalUrl = "original_url"
        case formatProtocol = "protocol"
        case manifestUrl = "manifest_url"
    }
}

struct MediaFormat: Codable, Identifiable, Hashable {
    var id: String { formatId }
    let formatId: String
    let ext: String
    let resolution: String?
    let fps: Double?
    let vcodec: String?
    let acodec: String?
    let abr: Double?
    let vbr: Double?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let formatNote: String?
    let formatProtocol: String?
    let manifestUrl: String?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case ext, resolution, fps, vcodec, acodec, abr, vbr, filesize
        case filesizeApprox = "filesize_approx"
        case formatNote = "format_note"
        case formatProtocol = "protocol"
        case manifestUrl = "manifest_url"
    }

    var isFragmented: Bool {
        if let proto = formatProtocol?.lowercased() {
            if proto.contains("m3u8") || proto.contains("dash") || proto.contains("fragment") || proto.contains("ism") {
                return true
            }
        }
        if let manifest = manifestUrl?.lowercased() {
            if manifest.contains(".m3u8") || manifest.contains(".mpd") || manifest.contains("/manifest") {
                return true
            }
        }
        return false
    }
    
    var isVideoOnly: Bool {
        acodec == "none" || acodec == nil
    }
    
    var isAudioOnly: Bool {
        vcodec == "none" || vcodec == nil
    }

    var displaySummary: String {
        var parts: [String] = []
        if let res = resolution, !res.isEmpty { parts.append(res) }
        if let fps = fps, fps > 0 { parts.append("\(Int(fps))fps") }
        if let vcodec = vcodec, vcodec != "none" { parts.append(vcodec) }
        if let acodec = acodec, acodec != "none" { parts.append(acodec) }
        if let abr = abr, abr > 0 { parts.append("\(Int(abr))k") }
        if let size = filesize ?? filesizeApprox, size > 0 {
            let mb = Double(size) / (1024.0 * 1024.0)
            parts.append(String(format: "%.1f MB", mb))
        }
        if let note = formatNote, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " • ")
    }
}

struct SubtitleInfo: Codable {
    let ext: String
    let url: String?
    let name: String?
}

struct ChapterInfo: Codable {
    let startTime: Double
    let endTime: Double
    let title: String
    
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case title
    }
}


struct HistoricDownload: Codable, Identifiable {
    let id: UUID
    let url: String
    let title: String
    let filePath: String?
    let downloadDate: Date
    let fileType: MediaFileType
    let status: DownloadStatus
    let thumbnailURL: URL?
    let duration: String?
    let errorMessage: String?
    let log: String
    let progress: Double
    let options: DownloadOptions
    
    @MainActor
    init(download: Download) {
        self.id = download.id
        self.url = download.url
        self.title = download.title
        self.filePath = download.filePath?.path
        self.downloadDate = download.createdAt
        self.fileType = download.options.fileType
        self.status = download.status
        self.thumbnailURL = download.thumbnailURL
        self.duration = download.duration
        self.errorMessage = download.errorMessage
        self.log = download.log
        self.progress = download.progress
        self.options = download.options
    }

    // Helper to convert back to Download object for UI
    @MainActor
    func toDownload() -> Download {
        let download = Download(url: self.url, options: self.options, title: self.title, id: self.id)
        download.status = self.status
        download.progress = self.progress
        download.thumbnailURL = self.thumbnailURL
        download.duration = self.duration
        download.errorMessage = self.errorMessage
        download.log = self.log
        if let path = self.filePath {
            download.filePath = URL(fileURLWithPath: path)
        }
        return download
    }
}
