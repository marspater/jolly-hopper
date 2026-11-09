import Foundation

/// Pure rules for media extensions and safe output filenames.
public enum MediaFileRules {
    public static let videoMediaExtensions: Set<String> = [
        "mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "ts",
        "mpg", "mpeg", "3gp", "3g2", "ogv", "m2ts", "mts", "f4v"
    ]

    public static let supportedMediaExtensions: Set<String> = videoMediaExtensions.union([
        "mp3", "m4a", "aac", "flac", "wav", "opus", "ogg", "alac", "aiff",
        "aif", "oga", "mka", "m4b", "wma", "weba", "mp2"
    ])

    public static func isMediaFilePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedMediaExtensions.contains(ext)
    }

    public static func resolvedOutputFileExtension(for options: DownloadOptions) -> String {
        Self.compatibleMergeOutputFormat(for: options) ?? options.fileType.fileExtension
    }

    public static func compatibleMergeOutputFormat(for options: DownloadOptions) -> String? {
        guard options.fileType.isVideo else { return nil }
        if let conversionCodec = options.conversionCodec, conversionCodec != .none {
            return convertedContainer(for: conversionCodec, fileType: options.fileType)
        }
        switch options.fileType {
        case .mkv:
            return "mkv"
        case .webm:
            return webmNeedsMatroska(options) ? "mkv" : "webm"
        case .mp4:
            return mp4NeedsMatroska(options) ? "mkv" : "mp4"
        default:
            return nil
        }
    }

    /// WebM accepts only VP8/VP9/AV1 video, so an H.264/HEVC result needs Matroska too.
    private static func convertedContainer(for codec: ConversionCodec, fileType: MediaFileType) -> String {
        codec == .av1 || codec == .vp9 || fileType == .webm ? "mkv" : fileType.fileExtension
    }

    private static func webmNeedsMatroska(_ options: DownloadOptions) -> Bool {
        [VideoCodec.h264, .h265].contains(options.videoCodec ?? .auto) || [AudioCodec.aac, .mp3, .flac].contains(options.audioCodec ?? .auto)
    }

    private static func mp4NeedsMatroska(_ options: DownloadOptions) -> Bool {
        [VideoCodec.vp9, .av1].contains(options.videoCodec ?? .auto) || [AudioCodec.opus, .flac].contains(options.audioCodec ?? .auto)
    }

    private static let invalidFilenameCharacters =
        CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.controlCharacters)

    private static let reservedFilenameNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ".DS_STORE", "DS_STORE"
    ]

    public static func sanitizeFilename(_ filename: String) -> String {
        sanitizedFilenameOrNil(filename) ?? "download"
    }

    public static func sanitizedFilenameOrNil(_ filename: String) -> String? {
        var cleanedScalars: [UnicodeScalar] = []
        cleanedScalars.reserveCapacity(filename.unicodeScalars.count)

        for scalar in filename.unicodeScalars {
            cleanedScalars.append(
                invalidFilenameCharacters.contains(scalar) ? "_" : scalar
            )
        }

        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
        var trimmed = cleaned.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        while trimmed.hasPrefix(".") || trimmed.hasPrefix("-") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if reservedFilenameNames.contains(trimmed.uppercased()) {
            trimmed = "download_\(trimmed)"
        }

        // File systems cap a name at 255 bytes (APFS) or UTF-16 units (HFS+);
        // UTF-8 bytes bound both. The rest is left for a collision suffix, the
        // extension and yt-dlp's `.fNNN`/`.part` intermediates. Whole
        // characters only, so truncation never splits an emoji or accent.
        var byteCount = 0
        trimmed = String(trimmed.prefix { character in
            byteCount += character.utf8.count
            return byteCount <= 200
        }).trimmingCharacters(in: .whitespacesAndNewlines)

        while trimmed.hasSuffix(".") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed.isEmpty ? nil : trimmed
    }
}
