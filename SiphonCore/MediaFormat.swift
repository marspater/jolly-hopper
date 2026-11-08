import Foundation

extension MediaFormat {
    public var isKnownDRM: Bool { hasDRM == .protected }
    public var isDownloadable: Bool { !isKnownDRM && isWorking != false }

    public var isHDR: Bool {
        if let rangeName = dynamicRange?.lowercased(), !rangeName.isEmpty && rangeName != "sdr" {
            return true
        }
        if let bitDepth = bitDepth, bitDepth > 8 {
            return true
        }
        if let spaceName = colorSpace?.lowercased(), spaceName.contains("2020") || spaceName.contains("hdr") {
            return true
        }
        let note = (formatNote ?? "").lowercased()
        return note.contains("hdr") || note.contains("hlg") || note.contains("dv") || note.contains("10bit") || note.contains("10-bit")
    }

    public var hdrSummary: String? {
        var tags: [String] = []
        if let rangeName = dynamicRange, !rangeName.isEmpty && rangeName.lowercased() != "sdr" {
            tags.append(rangeName.uppercased())
        } else if (formatNote ?? "").localizedCaseInsensitiveContains("hdr") {
            tags.append("HDR")
        } else if (formatNote ?? "").localizedCaseInsensitiveContains("hlg") {
            tags.append("HLG")
        } else if (formatNote ?? "").localizedCaseInsensitiveContains("dolby") || (formatNote ?? "").localizedCaseInsensitiveContains("dv") {
            tags.append("Dolby Vision")
        }

        if let depth = bitDepth, depth >= 10 {
            tags.append("\(depth)-bit")
        } else if (formatNote ?? "").localizedCaseInsensitiveContains("10bit") || (formatNote ?? "").localizedCaseInsensitiveContains("10-bit") {
            tags.append("10-bit")
        }

        if let spaceName = colorSpace, spaceName.lowercased().contains("2020") {
            tags.append("BT.2020")
        }

        return tags.isEmpty ? nil : tags.joined(separator: " • ")
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

    private static let resolutionHeightRegex = try? NSRegularExpression(
        pattern: #"(?:([0-9]+)\s*[x×]\s*([0-9]+)|([0-9]+)\s*p)"#, options: .caseInsensitive)

    /// For "WxH" this is the short side, as in YouTube's quality labels and yt-dlp's `-S res`,
    /// so a portrait 1080x1920 format counts as 1080p against the resolution ceiling.
    public var parsedHeight: Int? {
        if let res = resolution {
            if let match = Self.resolutionHeightRegex?.firstMatch(in: res, range: NSRange(res.startIndex..., in: res)) {
                let numbers = (1...3).compactMap { group in
                    Range(match.range(at: group), in: res).flatMap { Int(res[$0]) }
                }
                if let height = numbers.min(), height > 0 {
                    return height
                }
            }
            if let height = Int(res.trimmingCharacters(in: .whitespacesAndNewlines)), height > 0 {
                return height
            }
        }

        let note = formatNote ?? ""
        let fid = formatId

        func check(_ pattern: String) -> Bool {
            note.range(of: pattern, options: .caseInsensitive) != nil ||
            fid.range(of: pattern, options: .caseInsensitive) != nil
        }

        if check("2160p") { return 2160 }
        if check("1440p") { return 1440 }
        if check("1080p") { return 1080 }
        if check("720p") { return 720 }
        if check("480p") { return 480 }
        if check("360p") { return 360 }
        if check("240p") { return 240 }

        let lowerId = fid.lowercased()
        if lowerId == "hq" || lowerId == "hd" || lowerId == "source" || lowerId == "original" || lowerId == "best-mp4" || lowerId == "source-mp4" {
            return 1080
        }
        return nil
    }

    // MARK: - Deterministic Format Ranking & Selection

    public struct AudioRank: Sendable {
        let langPref: Int
        let matchesCodec: Bool
        public let quality: Double
        let isAAC: Bool
        public let preference: Int
        let tested: Bool
        public let bitrate: Double
        let channels: Int
    }

    func audioRank(options: DownloadOptions) -> AudioRank {
        let matchesCodec: Bool = {
            guard let req = options.audioCodec, req != .auto else { return true }
            guard let acodec else { return false }
            return req.matches(acodec: acodec)
        }()
        // yt-dlp treats a missing language_preference as -1 (neutral). YouTube reports -1 for every
        // track of a single-language video and a higher value only for the original track, so the
        // value is meaningful only relative to other tracks.
        let isDubbedByNote = (formatNote ?? "").lowercased().contains("dubbed")
        let lPref = languagePreference ?? (isDubbedByNote ? -10 : -1)
        let pref = preference ?? (sourcePreference ?? 0)
        let bitrateValue = abr ?? (tbr ?? 0.0)
        let channelCount = audioChannels ?? 2
        let isTested = (needsTesting != true)
        let codecName = acodec?.lowercased() ?? ""
        return AudioRank(
            langPref: lPref,
            matchesCodec: matchesCodec,
            quality: quality.flatMap { $0.isFinite ? $0 : nil } ?? -1,
            isAAC: codecName.hasPrefix("mp4a") || codecName == "aac",
            preference: pref,
            tested: isTested,
            bitrate: bitrateValue.isFinite ? bitrateValue : 0,
            channels: channelCount
        )
    }

    /// The result when two ranks differ, or nil when the next ranking step decides.
    private static func prefer(_ first: Bool, over second: Bool) -> Bool? {
        first == second ? nil : first
    }

    private static func higher<Value: Comparable>(_ first: Value, _ second: Value) -> Bool? {
        first == second ? nil : first > second
    }

    static func compareAudioFormats(_ first: MediaFormat, _ second: MediaFormat, options: DownloadOptions) -> Bool {
        let firstRank = first.audioRank(options: options)
        let secondRank = second.audioRank(options: options)
        // MP4 and M4A under auto codec prefer AAC, which the container carries without re-encoding.
        let isAutoCodec = options.audioCodec == nil || options.audioCodec == .auto
        let prefersAAC = (options.fileType == .mp4 || options.fileType == .m4a) && isAutoCodec
        let steps: [Bool?] = [
            higher(firstRank.langPref, secondRank.langPref), // The original track outranks dubbed or descriptive tracks.
            prefer(firstRank.matchesCodec, over: secondRank.matchesCodec),
            higher(firstRank.quality, secondRank.quality), // yt-dlp's default sort; demotes DRC and HLS fallback audio.
            prefersAAC ? prefer(firstRank.isAAC, over: secondRank.isAAC) : nil,
            higher(firstRank.preference, secondRank.preference),
            prefer(firstRank.tested, over: secondRank.tested),
            higher(firstRank.bitrate, secondRank.bitrate)
        ]
        return steps.lazy.compactMap { $0 }.first ?? (firstRank.channels > secondRank.channels)
    }

    public struct VideoRank: Sendable {
        let matchesCodec: Bool
        let meetsResolution: Bool
        public let height: Int
        let isAppleNativeCodec: Bool
        let tested: Bool
        public let bitrate: Double
        public let fps: Double
        public let size: Int64
    }

    private struct CodecMarkers: Sendable {
        let prefixes: [String]
        let substrings: [String]

        func match(_ codec: String) -> Bool {
            prefixes.contains { codec.hasPrefix($0) } || substrings.contains { codec.contains($0) }
        }
    }

    private static let videoCodecMarkers: [VideoCodec: CodecMarkers] = [
        .h264: CodecMarkers(prefixes: ["avc1"], substrings: ["h264"]),
        .h265: CodecMarkers(prefixes: ["hev1", "hvc1"], substrings: ["h265", "hevc"]),
        .vp9: CodecMarkers(prefixes: ["vp9"], substrings: ["vp9"]),
        .av1: CodecMarkers(prefixes: ["av01"], substrings: ["av1"])
    ]

    private func codecMatches(_ codec: VideoCodec) -> Bool {
        guard let name = vcodec?.lowercased(), let markers = Self.videoCodecMarkers[codec] else { return false }
        return markers.match(name)
    }

    private func matchesRequestedCodec(_ requested: VideoCodec?) -> Bool {
        guard let requested, requested != .auto else { return true }
        return codecMatches(requested)
    }

    func videoRank(options: DownloadOptions) -> VideoRank {
        let matchesCodec = matchesRequestedCodec(options.videoCodec)
        let heightValue = parsedHeight ?? 0
        let maxHeight = options.videoResolution?.maxHeight
        let meetsRes = maxHeight.map { heightValue <= $0 } ?? true
        let isAppleNative = codecMatches(.h264) || codecMatches(.h265)
        let bitrateValue = tbr ?? (vbr ?? (abr ?? 0.0))
        let fpsValue = fps ?? 0.0
        let isTested = (needsTesting != true)
        let sizeValue = filesize ?? (filesizeApprox ?? 0)
        return VideoRank(
            matchesCodec: matchesCodec,
            meetsResolution: meetsRes,
            height: heightValue,
            isAppleNativeCodec: isAppleNative,
            tested: isTested,
            bitrate: bitrateValue.isFinite ? bitrateValue : 0,
            fps: fpsValue.isFinite ? fpsValue : 0,
            size: sizeValue
        )
    }

    public static func compareVideoFormats(_ first: MediaFormat, _ second: MediaFormat, options: DownloadOptions) -> Bool {
        let firstRank = first.videoRank(options: options)
        let secondRank = second.videoRank(options: options)
        // MP4 under auto codec prefers H.264/HEVC for QuickTime and Finder QuickLook compatibility.
        let prefersAppleNative = options.fileType == .mp4 && (options.videoCodec == nil || options.videoCodec == .auto)
        let steps: [Bool?] = [
            prefer(firstRank.matchesCodec, over: secondRank.matchesCodec),
            prefer(firstRank.meetsResolution, over: secondRank.meetsResolution),
            heightStep(firstRank, secondRank),
            prefersAppleNative ? prefer(firstRank.isAppleNativeCodec, over: secondRank.isAppleNativeCodec) : nil,
            prefer(firstRank.tested, over: secondRank.tested),
            higher(firstRank.bitrate, secondRank.bitrate),
            higher(firstRank.fps, secondRank.fps)
        ]
        return steps.lazy.compactMap { $0 }.first ?? (firstRank.size > secondRank.size)
    }

    /// When every format exceeds the ceiling, the lowest one wins; otherwise the highest.
    private static func heightStep(_ firstRank: VideoRank, _ secondRank: VideoRank) -> Bool? {
        guard firstRank.height != secondRank.height else { return nil }
        return firstRank.meetsResolution ? firstRank.height > secondRank.height : firstRank.height < secondRank.height
    }

    public var isVideoOnly: Bool {
        if acodec == "none" { return true }
        if let note = formatNote?.lowercased(), note.contains("video only") {
            return true
        }
        return false
    }

    public var isAudioOnly: Bool {
        if vcodec == "none" { return true }
        let lowerExt = ext.lowercased()
        if lowerExt == "m4a" || lowerExt == "mp3" || lowerExt == "opus" || lowerExt == "flac" || lowerExt == "aac" || lowerExt == "wav" {
            return true
        }
        if let note = formatNote?.lowercased(), note.contains("audio only") {
            return true
        }
        return false
    }

    public var displaySummary: String {
        var parts: [String] = []
        if let res = resolution, !res.isEmpty { parts.append(res) }
        if let fps = fps, fps > 0 { parts.append("\(Int(fps))fps") }
        if let vcodec = vcodec, vcodec != "none" { parts.append(vcodec) }
        if let acodec = acodec, acodec != "none" { parts.append(acodec) }
        if let lang = language, !lang.isEmpty { parts.append("[\(lang)]") }
        if let abr = abr, abr > 0 {
            parts.append("\(Int(abr))k")
        } else if let tbr = tbr, tbr > 0, vbr == nil || vbr == 0 {
            parts.append("\(Int(tbr))k")
        }
        if let size = filesize ?? filesizeApprox, size > 0 {
            let megabytes = Double(size) / (1024.0 * 1024.0)
            parts.append(String(format: "%.1f MB", megabytes))
        }
        if let hdr = hdrSummary { parts.append(hdr) }
        if let note = formatNote, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " • ")
    }
}

public struct SubtitleInfo: Codable, Sendable {
    public let ext: String
    public let url: String?
    public let name: String?
}

public struct ChapterInfo: Codable, Sendable {
    public let startTime: Double
    let endTime: Double
    public let title: String

    public enum CodingKeys: String, CodingKey, Sendable {
        case startTime = "start_time"
        case endTime = "end_time"
        case title
    }
}
