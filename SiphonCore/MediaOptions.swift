import Foundation

public enum MediaFileType: String, Codable, CaseIterable, Identifiable, Sendable {
    case mp4 = "MP4"
    case webm = "WebM"
    case mkv = "MKV"
    case mp3 = "MP3"
    case opus = "Opus"
    case flac = "FLAC"
    case wav = "WAV"
    case m4a = "M4A"

    public var id: String { rawValue }

    public var isVideo: Bool {
        switch self {
        case .mp4, .webm, .mkv: return true
        default: return false
        }
    }

    public var isAudio: Bool {
        !isVideo
    }

    public var fileExtension: String {
        rawValue.lowercased()
    }

    public static var videoTypes: [MediaFileType] {
        [.mp4, .webm, .mkv]
    }

    public static var audioTypes: [MediaFileType] {
        [.mp3, .opus, .flac, .wav, .m4a]
    }
}

public enum AudioQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case best
    case q320 = "320kbps"
    case q256 = "256kbps"
    case q192 = "192kbps"
    case q128 = "128kbps"

    public var id: String { rawValue }

    public var ytdlpValue: String {
        switch self {
        case .best: return "0"
        case .q320: return "320K"
        case .q256: return "256K"
        case .q192: return "192K"
        case .q128: return "128K"
        }
    }
}

public struct VideoFormat: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let ext: String
    public let resolution: String?
    public let fps: Double?
    public let vcodec: String?
    public let filesize: Int64?

    public var displayName: String {
        var parts: [String] = []
        if let res = resolution { parts.append(res) }
        if let fps = fps { parts.append("\(Int(fps))fps") }
        if let codec = vcodec { parts.append(codec) }
        return parts.isEmpty ? id : parts.joined(separator: " • ")
    }
}

public struct AudioFormat: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let ext: String
    public let abr: Int?
    public let acodec: String?
    public let filesize: Int64?

    public var displayName: String {
        var parts: [String] = []
        if let abr = abr { parts.append("\(abr)kbps") }
        if let codec = acodec { parts.append(codec) }
        return parts.isEmpty ? id : parts.joined(separator: " • ")
    }
}

public enum VideoResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case best
    case r2160p
    case r1440p
    case r1080p
    case r720p
    case r480p
    case r360p
    case r240p
    case worst

    public var id: String { rawValue }

    public var ytdlpValue: String {
        switch self {
        case .best: return "bestvideo*+bestaudio/best"
        case .r2160p: return "bestvideo[height<=2160]"
        case .r1440p: return "bestvideo[height<=1440]"
        case .r1080p: return "bestvideo[height<=1080]"
        case .r720p: return "bestvideo[height<=720]"
        case .r480p: return "bestvideo[height<=480]"
        case .r360p: return "bestvideo[height<=360]"
        case .r240p: return "bestvideo[height<=240]"
        case .worst: return "worstvideo*+worstaudio/worst"
        }
    }

    public var maxHeight: Int? {
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

public enum ResolutionFallbackPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case strictCeiling
    case allowHigher

    public var id: String { rawValue }

}

public enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case h264
    case h265
    case vp9
    case av1

    public var id: String { rawValue }

}

public enum ConversionCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case h264
    case h265
    case vp9
    case av1

    public var id: String { rawValue }

    /// ffprobe's `codec_name` for the target codec.
    public var ffprobeCodecName: String? {
        switch self {
        case .none: return nil
        case .h264: return "h264"
        case .h265: return "hevc"
        case .vp9: return "vp9"
        case .av1: return "av1"
        }
    }
}

public enum AudioCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case aac
    case opus
    case mp3
    case flac

    public var id: String { rawValue }

    /// Whether a yt-dlp `acodec` value is this codec. Most sources report AAC as "mp4a.40.2".
    public func matches(acodec: String) -> Bool {
        let lowered = acodec.lowercased()
        return self == .aac ? (lowered.hasPrefix("mp4a") || lowered.contains("aac")) : lowered.contains(rawValue)
    }
}

public enum SubtitleFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case srt
    case vtt
    case ass

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .srt: return "SRT"
        case .vtt: return "VTT (WebVTT)"
        case .ass: return "ASS (Advanced)"
        }
    }

    public var ytdlpValue: String {
        rawValue
    }
}

public enum DownloadPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case bestQuality = "best_quality"
    case maxCompatibility = "max_compatibility"
    case smallestSize = "smallest_size"
    case audioOnly = "audio_only"

    public var id: String { rawValue }

    public var videoCodec: VideoCodec {
        switch self {
        case .bestQuality: return .auto
        case .maxCompatibility: return .h264
        case .smallestSize: return .av1
        case .audioOnly: return .auto
        }
    }

    public var audioCodec: AudioCodec {
        switch self {
        case .bestQuality: return .auto
        case .maxCompatibility: return .aac
        case .smallestSize: return .opus
        case .audioOnly: return .aac
        }
    }

    public var videoResolution: VideoResolution {
        switch self {
        case .bestQuality: return .best
        case .maxCompatibility: return .r1080p
        case .smallestSize: return .r720p
        case .audioOnly: return .worst
        }
    }

    public var fileType: MediaFileType {
        switch self {
        case .bestQuality: return .mp4
        case .maxCompatibility: return .mp4
        case .smallestSize: return .mp4
        case .audioOnly: return .m4a
        }
    }
}
