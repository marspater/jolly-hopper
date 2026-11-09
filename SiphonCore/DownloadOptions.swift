import Foundation

public struct DownloadOptions: Codable, Sendable {
    public var saveFolder: URL
    public var fileType: MediaFileType
    public var videoFormat: VideoFormat?
    public var audioFormat: AudioFormat?
    public var videoResolution: VideoResolution?
    public var audioQuality: AudioQuality?
    public var downloadSubtitles: Bool = false
    public var subtitleLanguages: [String] = ["en"]
    public var subtitleFormat: SubtitleFormat? = .srt
    public var embedSubtitles: Bool = false
    public var downloadThumbnail: Bool = false
    public var embedThumbnail: Bool = true
    public var embedMetadata: Bool = true
    public var splitChapters: Bool = false
    public var sponsorBlock: Bool = false
    public var timeFrameStart: String?
    public var timeFrameEnd: String?
    public var customFilename: String?
    public var videoCodec: VideoCodec?
    public var audioCodec: AudioCodec?
    public var conversionCodec: ConversionCodec?
    public var forceOverwrite: Bool? = false
    public var rawCookies: String?
    public var rawUserAgent: String?
    public var browserCookieSource: String?
    public var selectedFormatId: String?
    public var hdrAction: HDRAction? = .preserveHDR
    public var resolutionFallbackPolicy: ResolutionFallbackPolicy? = .strictCeiling
    public var additionalArguments: String?
    public var enforcePublicNetworkBoundary: Bool = false

    public enum CodingKeys: String, CodingKey, Sendable {
        case saveFolder
        case fileType
        case videoFormat
        case audioFormat
        case videoResolution
        case audioQuality
        case downloadSubtitles
        case subtitleLanguages
        case subtitleFormat
        case embedSubtitles
        case downloadThumbnail
        case embedThumbnail
        case embedMetadata
        case splitChapters
        case sponsorBlock
        case timeFrameStart
        case timeFrameEnd
        case customFilename
        case videoCodec
        case audioCodec
        case conversionCodec
        case forceOverwrite
        case selectedFormatId
        case hdrAction
        case resolutionFallbackPolicy
        case additionalArguments
        case enforcePublicNetworkBoundary
    }

    public init(saveFolder: URL, fileType: MediaFileType) {
        self.saveFolder = saveFolder
        self.fileType = fileType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.saveFolder = try container.decode(URL.self, forKey: .saveFolder)
        self.fileType = try container.decode(MediaFileType.self, forKey: .fileType)
        self.videoFormat = try container.decodeIfPresent(VideoFormat.self, forKey: .videoFormat)
        self.audioFormat = try container.decodeIfPresent(AudioFormat.self, forKey: .audioFormat)
        self.videoResolution = try container.decodeIfPresent(VideoResolution.self, forKey: .videoResolution)
        self.audioQuality = try container.decodeIfPresent(AudioQuality.self, forKey: .audioQuality)
        self.downloadSubtitles = try container.decodeIfPresent(Bool.self, forKey: .downloadSubtitles) ?? false
        self.subtitleLanguages = try container.decodeIfPresent([String].self, forKey: .subtitleLanguages) ?? ["en"]
        self.subtitleFormat = try container.decodeIfPresent(SubtitleFormat.self, forKey: .subtitleFormat)
        self.embedSubtitles = try container.decodeIfPresent(Bool.self, forKey: .embedSubtitles) ?? false
        self.downloadThumbnail = try container.decodeIfPresent(Bool.self, forKey: .downloadThumbnail) ?? false
        self.embedThumbnail = try container.decodeIfPresent(Bool.self, forKey: .embedThumbnail) ?? true
        self.embedMetadata = try container.decodeIfPresent(Bool.self, forKey: .embedMetadata) ?? true
        self.splitChapters = try container.decodeIfPresent(Bool.self, forKey: .splitChapters) ?? false
        self.sponsorBlock = try container.decodeIfPresent(Bool.self, forKey: .sponsorBlock) ?? false
        self.timeFrameStart = try container.decodeIfPresent(String.self, forKey: .timeFrameStart)
        self.timeFrameEnd = try container.decodeIfPresent(String.self, forKey: .timeFrameEnd)
        self.customFilename = try container.decodeIfPresent(String.self, forKey: .customFilename)
        self.videoCodec = try container.decodeIfPresent(VideoCodec.self, forKey: .videoCodec)
        self.audioCodec = try container.decodeIfPresent(AudioCodec.self, forKey: .audioCodec)
        self.conversionCodec = try container.decodeIfPresent(ConversionCodec.self, forKey: .conversionCodec)
        self.forceOverwrite = try container.decodeIfPresent(Bool.self, forKey: .forceOverwrite)
        self.rawCookies = nil // Ephemeral only, never loaded from persistent history/json
        self.rawUserAgent = nil // Ephemeral browser identity, never persisted
        self.browserCookieSource = nil // Ephemeral browser cookie source, never persisted
        self.selectedFormatId = try container.decodeIfPresent(String.self, forKey: .selectedFormatId)
        self.hdrAction = try container.decodeIfPresent(HDRAction.self, forKey: .hdrAction) ?? .preserveHDR
        self.resolutionFallbackPolicy = try container.decodeIfPresent(ResolutionFallbackPolicy.self, forKey: .resolutionFallbackPolicy) ?? .strictCeiling
        self.additionalArguments = try container.decodeIfPresent(String.self, forKey: .additionalArguments)
        self.enforcePublicNetworkBoundary = try container.decodeIfPresent(Bool.self, forKey: .enforcePublicNetworkBoundary) ?? false
    }

    public static var defaultOptions: DownloadOptions {
        let saveFolderURL: URL
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonTestDownloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
            saveFolderURL = testDir
        } else {
            saveFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        }
        var options = DownloadOptions(saveFolder: saveFolderURL, fileType: .mp4)
        options.downloadSubtitles = false
        options.subtitleLanguages = ["en"]
        options.subtitleFormat = .srt
        options.embedSubtitles = false
        options.downloadThumbnail = false
        options.embedThumbnail = true
        options.embedMetadata = true
        options.splitChapters = false
        options.sponsorBlock = false
        options.conversionCodec = ConversionCodec.none
        options.forceOverwrite = false
        options.rawCookies = nil
        options.rawUserAgent = nil
        options.browserCookieSource = nil
        options.selectedFormatId = nil
        return options
    }

    @inlinable
    public static var standard: DownloadOptions {
        defaultOptions
    }

    @inlinable
    public static var `default`: DownloadOptions { // NOSONAR
        defaultOptions
    }

    /// The parts of a custom preset that Preferences does not mirror into its
    /// format defaults: subtitles, chapter splitting and SponsorBlock.
    public mutating func applyCustomPresetExtras(_ preset: CustomPreset) {
        // An "embed:" language prefix embeds; otherwise subtitles are a separate file.
        let rawLanguage = preset.subtitleLanguage ?? ""
        let language = rawLanguage.replacingOccurrences(of: "embed:", with: "")
        downloadSubtitles = preset.downloadSubtitles ?? false
        subtitleLanguages = [language.isEmpty ? "en" : language]
        subtitleFormat = preset.subtitleFormat ?? .srt
        embedSubtitles = downloadSubtitles && rawLanguage.hasPrefix("embed:")
        splitChapters = preset.splitChapters ?? false
        sponsorBlock = preset.sponsorBlock ?? false
    }

    /// Selecting a custom preset in Preferences writes only its format choices
    /// into the defaults, so the rest of the selected preset is applied here.
    public static func defaultFromPreferences(userDefaults: UserDefaults = .standard, applyingSelectedCustomPreset: Bool = true) -> DownloadOptions {
        let saveFolderURL = preferredSaveFolder(userDefaults: userDefaults)

        let fileTypeStr = userDefaults.string(forKey: UserDefaultsKeys.defaultFileType) ?? "mp4"
        let fileType = MediaFileType.allCases.first(where: { $0.rawValue.lowercased() == fileTypeStr.lowercased() }) ?? .mp4

        let resStr = userDefaults.string(forKey: UserDefaultsKeys.defaultVideoResolution) ?? "r1080p"
        let resolution = VideoResolution(rawValue: resStr) ?? .r1080p

        let vcodecStr = userDefaults.string(forKey: UserDefaultsKeys.defaultVideoCodec) ?? "h264"
        let videoCodec = VideoCodec(rawValue: vcodecStr)

        let acodecStr = userDefaults.string(forKey: UserDefaultsKeys.defaultAudioCodec) ?? "aac"
        let audioCodec = AudioCodec(rawValue: acodecStr)

        let embedThumb = userDefaults.object(forKey: UserDefaultsKeys.embedThumbnail) != nil ? userDefaults.bool(forKey: UserDefaultsKeys.embedThumbnail) : true
        let embedMeta = userDefaults.object(forKey: UserDefaultsKeys.embedMetadata) != nil ? userDefaults.bool(forKey: UserDefaultsKeys.embedMetadata) : true
        let sponsorBlock = userDefaults.bool(forKey: UserDefaultsKeys.sponsorBlock)
        let extraArgs = userDefaults.string(forKey: UserDefaultsKeys.defaultAdditionalArguments)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let fallbackPolicyStr = userDefaults.string(forKey: UserDefaultsKeys.resolutionFallbackPolicy) ?? ResolutionFallbackPolicy.strictCeiling.rawValue
        let fallbackPolicy = ResolutionFallbackPolicy(rawValue: fallbackPolicyStr) ?? .strictCeiling

        var options = DownloadOptions(saveFolder: saveFolderURL, fileType: fileType)
        options.videoResolution = fileType.isVideo ? resolution : nil
        options.audioQuality = fileType.isAudio ? .best : nil
        options.downloadSubtitles = false
        options.subtitleLanguages = ["en"]
        options.subtitleFormat = .srt
        options.embedSubtitles = false
        options.downloadThumbnail = false
        options.embedThumbnail = embedThumb
        options.embedMetadata = embedMeta
        options.splitChapters = false
        options.sponsorBlock = sponsorBlock
        options.videoCodec = videoCodec
        options.audioCodec = audioCodec
        options.conversionCodec = ConversionCodec.none
        options.forceOverwrite = false
        options.rawCookies = nil
        options.rawUserAgent = nil
        options.browserCookieSource = nil
        options.selectedFormatId = nil
        options.hdrAction = .preserveHDR
        options.resolutionFallbackPolicy = fallbackPolicy
        options.additionalArguments = (extraArgs?.isEmpty ?? true) ? nil : extraArgs
        if applyingSelectedCustomPreset, let preset = CustomPreset.selected(in: userDefaults) {
            options.applyCustomPresetExtras(preset)
        }
        return options
    }

    private static func preferredSaveFolder(userDefaults: UserDefaults) -> URL {
        let defaultPath = userDefaults.string(forKey: UserDefaultsKeys.defaultSaveFolder) ?? ""
        if !defaultPath.isEmpty && FileManager.default.fileExists(atPath: defaultPath) {
            return URL(fileURLWithPath: defaultPath)
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonTestDownloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
            return testDir
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }
}
