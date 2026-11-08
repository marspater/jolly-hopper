import Foundation
import os

public enum HDRAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case preserveHDR = "preserve_hdr"
    case convertToSDR = "convert_to_sdr"

    public var id: String { rawValue }

}

public struct DownloadDiagnostics: Codable, Hashable, Sendable {
    public var pid: Int32?
    public var ytdlpVersion: String?
    public var ffmpegVersion: String?
    public var extractor: String?
    public var formatId: String?
    public var videoCodec: String?
    public var audioCodec: String?
    public var container: String?
    public var resolution: String?
    /// Height of the format actually selected, shown in the row instead of the requested ceiling.
    public var resolvedHeight: Int?
    public var fps: Double?
    public var dynamicRange: String?
    public var colorSpace: String?
    public var bitDepth: Int?
    public var httpRetries: Int = 0
    public var peakSpeed: String?
    public var duration: String?
    public var exitStatus: String?
    public var commandLine: String?
    public var timestamp: Date = Date()

    public init() {}

    public var hdrSummary: String? {
        var tags: [String] = []
        if let rangeName = dynamicRange, !rangeName.isEmpty && rangeName.lowercased() != "sdr" {
            tags.append(rangeName.uppercased())
        }
        if let depth = bitDepth, depth >= 10 {
            tags.append("\(depth)-bit")
        }
        if let spaceName = colorSpace, !spaceName.isEmpty {
            tags.append(spaceName.uppercased())
        }
        return tags.isEmpty ? nil : tags.joined(separator: " • ")
    }
}

public struct CustomPresetSubtitles: Equatable, Sendable {
    public var downloadSubtitles: Bool
    public var subtitleLanguage: String
    public var subtitleFormat: SubtitleFormat

    public init(downloadSubtitles: Bool = false, subtitleLanguage: String = "", subtitleFormat: SubtitleFormat = .srt) {
        self.downloadSubtitles = downloadSubtitles
        self.subtitleLanguage = subtitleLanguage
        self.subtitleFormat = subtitleFormat
    }
}

public struct CustomPresetConfiguration: Equatable, Sendable {
    public var name: String
    public var videoCodec: VideoCodec
    public var audioCodec: AudioCodec
    public var videoResolution: VideoResolution
    public var fileType: MediaFileType
    public var downloadSubtitles: Bool = false
    public var subtitleLanguage: String = ""
    public var subtitleFormat: SubtitleFormat = .srt
    public var sponsorBlock: Bool = false
    public var splitChapters: Bool = false

    public init(
        name: String,
        videoCodec: VideoCodec,
        audioCodec: AudioCodec,
        videoResolution: VideoResolution,
        fileType: MediaFileType,
        subtitles: CustomPresetSubtitles = CustomPresetSubtitles(),
        sponsorBlock: Bool = false,
        splitChapters: Bool = false
    ) {
        self.name = name
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.videoResolution = videoResolution
        self.fileType = fileType
        self.downloadSubtitles = subtitles.downloadSubtitles
        self.subtitleLanguage = subtitles.subtitleLanguage
        self.subtitleFormat = subtitles.subtitleFormat
        self.sponsorBlock = sponsorBlock
        self.splitChapters = splitChapters
    }
}

public struct CustomPreset: Codable, Identifiable, Equatable, Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.siphon", category: "CustomPreset")

    public let id: UUID
    public var name: String
    public var videoCodec: VideoCodec
    public var audioCodec: AudioCodec
    public var videoResolution: VideoResolution
    public var fileType: MediaFileType
    public var downloadSubtitles: Bool?
    public var subtitleLanguage: String?
    public var subtitleFormat: SubtitleFormat?
    public var sponsorBlock: Bool?

    public var splitChapters: Bool?

    public enum CodingKeys: String, CodingKey, Sendable {
        case id, name, videoCodec, audioCodec, videoResolution, fileType, subtitleLanguage, subtitleFormat, sponsorBlock, splitChapters
        case downloadSubtitles = "embedSubtitles"
    }

    public init(configuration: CustomPresetConfiguration) {
        self.id = UUID()
        self.name = configuration.name
        self.videoCodec = configuration.videoCodec
        self.audioCodec = configuration.audioCodec
        self.videoResolution = configuration.videoResolution
        self.fileType = configuration.fileType
        self.downloadSubtitles = configuration.downloadSubtitles
        self.subtitleLanguage = configuration.subtitleLanguage
        self.subtitleFormat = configuration.subtitleFormat
        self.sponsorBlock = configuration.sponsorBlock
        self.splitChapters = configuration.splitChapters
    }

    public static func loadAll(from userDefaults: UserDefaults = .standard) -> [CustomPreset] {
        guard let data = userDefaults.data(forKey: UserDefaultsKeys.customPresets) else {
            return []
        }

        guard let presets = try? JSONDecoder().decode([CustomPreset].self, from: data) else {
            logger.error("Failed to decode custom presets from UserDefaults")
            return []
        }

        return presets
    }

    /// The preset selected in Preferences, if it still exists.
    public static func selected(in userDefaults: UserDefaults = .standard) -> CustomPreset? {
        guard let id = UUID(uuidString: userDefaults.string(forKey: UserDefaultsKeys.selectedCustomPresetId) ?? "") else { return nil }
        return loadAll(from: userDefaults).first { $0.id == id }
    }

    public static func saveAll(_ presets: [CustomPreset], to userDefaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(presets)
            userDefaults.set(data, forKey: UserDefaultsKeys.customPresets)
        } catch {
            logger.error("Failed to encode custom presets: \(error.localizedDescription)")
        }
    }
}

public enum DownloadURLValidationResult: Equatable, Sendable {
    case valid(url: URL, original: String)
    case empty
    case invalidScheme
    case malformed
}

public struct DownloadURLValidator: Sendable {
    public static func validate(_ input: String) -> DownloadURLValidationResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var normalized = trimmed
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            if (normalized.contains(".") || normalized.hasPrefix("[")) && !normalized.contains(" ") {
                normalized = "https://" + normalized
            } else {
                return .malformed
            }
        }
        normalized = normalizedWebURL(normalized) ?? normalized

        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              host.contains(".") || host.contains(":") else {
            return .malformed
        }

        return .valid(url: url, original: normalized)
    }

    /// `raw` with its HTTP(S) scheme lowercased, or nil for any other scheme.
    /// Schemes are case-insensitive, but yt-dlp extractor patterns match lowercase only.
    public static func normalizedWebURL(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        guard let scheme = ["https", "http"].first(where: { lowered.hasPrefix($0 + "://") }) else { return nil }
        return scheme + raw.dropFirst(scheme.count)
    }

    public static func extractURLs(from text: String) -> [String] {
        // Bolt Performance Optimization: Use `split(whereSeparator: \.isNewline)` lazy Substring iteration
        // to avoid allocating intermediate String arrays for line splitting, trimming, and filtering.
        return text.split(whereSeparator: \.isNewline).compactMap { lineSlice in
            let trimmed = lineSlice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if case .valid(_, let original) = validate(trimmed) {
                return original
            }
            return nil
        }
    }
}
