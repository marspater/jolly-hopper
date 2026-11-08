import Foundation
import os
import SiphonCore

enum ScratchDirectoryPolicy {
    static let directoryPrefix = "siphon_scratch_"

    static func makeURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
    }

    static func isOwned(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let root = fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent().path == root.path else { return false }
        return hasScratchName(candidate)
    }

    /// Hidden temp files written beside media (conversions, cover art, GIF
    /// re-encodes, decryption). They share the media's volume for an atomic
    /// replace, so they cannot live in the scratch directory.
    static let siblingTempPrefix = ".siphon-tmp-"

    static func siblingTempURL(beside file: URL, extension ext: String) -> URL {
        let name = siblingTempPrefix + UUID().uuidString
        return file.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }

    /// Sibling temp names, including those of builds before `siblingTempPrefix`.
    static func isSiblingTempName(_ name: String) -> Bool {
        for prefix in [siblingTempPrefix, ".converted-", "thumb_temp_", "decrypted_"] where name.hasPrefix(prefix) {
            return UUID(uuidString: String(name.dropFirst(prefix.count).prefix(36))) != nil
        }
        // Older GIF re-encodes: ".<UUID>.mp4.partial"
        return name.hasPrefix(".") && name.hasSuffix(".mp4.partial")
            && UUID(uuidString: String(name.dropFirst().prefix(36))) != nil
    }

    private static let sweptSaveFolders = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Removes sibling temp files a dead run left in `folder`. It runs when a job
    /// starts there, at most once per folder per launch: the app already writes
    /// to that folder, so the sweep adds no file-access prompt.
    @discardableResult
    static func purgeAbandonedSiblingTemps(
        in folder: URL,
        minimumAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        // ponytail: top level of the save folder only; playlist subfolders keep
        // theirs until a job saves into them directly.
        guard sweptSaveFolders.withLock({ $0.insert(folder.standardizedFileURL.path).inserted }) else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        var removed: [URL] = []
        for file in entries where isSiblingTempName(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  now.timeIntervalSince(values.contentModificationDate ?? .distantFuture) >= minimumAge else { continue }
            do {
                try fileManager.removeItem(at: file)
                removed.append(file)
            } catch {
                let message = "Could not remove abandoned temporary file: \(error.localizedDescription)"
                Task { @MainActor in LoggerService.shared.log(message, level: .warning) }
            }
        }
        return removed
    }

    private static func hasScratchName(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(directoryPrefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(directoryPrefix.count))) != nil
    }

    /// Per-run artifacts in the temporary folder: download scratch and update staging.
    private static let temporaryArtifactPrefixes = [directoryPrefix, "Siphon_Install_", "Siphon_Update_"]

    static func hasTemporaryArtifactName(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return temporaryArtifactPrefixes.contains { prefix in
            name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count).prefix(36))) != nil
        }
    }

    /// Removes scratch and update staging left by runs that died before teardown
    /// (crash, force quit). `keeping` names the directories restored jobs still own. A directory touched
    /// within `minimumAge` is kept too: it may belong to another running Siphon
    /// (a QA copy or the test host) that shares this temporary directory.
    @discardableResult
    static func purgeAbandoned(
        keeping kept: Set<String>,
        in root: URL = FileManager.default.temporaryDirectory,
        minimumAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        // ponytail: liveness is by age only; add a per-process owner marker if
        // concurrent Siphon instances with long silent downloads become real.
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return [] }
        var removed: [URL] = []
        for directory in entries where hasTemporaryArtifactName(directory) && !kept.contains(directory.lastPathComponent) {
            // A running download keeps writing its .part file, which the
            // directory's own date does not reflect.
            let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            let lastTouched = ([directory] + children)
                .compactMap { try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate }
                .max() ?? .distantPast
            guard now.timeIntervalSince(lastTouched) >= minimumAge else { continue }
            do {
                try fileManager.removeItem(at: directory)
                removed.append(directory)
            } catch {
                let message = "Could not remove abandoned scratch directory: \(error.localizedDescription)"
                Task { @MainActor in LoggerService.shared.log(message, level: .warning) }
            }
        }
        return removed
    }
}

@MainActor
class Download: ObservableObject, Identifiable {
    let id: UUID
    let url: String
    let createdAt: Date
    var options: DownloadOptions
    // Queue-selected name, separate from the user's explicit filename.
    var resolvedOutputBaseName: String?
    var outputBaseName: String { resolvedOutputBaseName ?? requestedBaseName }
    var requestedBaseName: String { Self.distinctBaseName(options.customFilename ?? displayTitle, url: url) }
    // Owned by this job; retained across pause/resume, never shared by filename.
    var scratchDirectory: URL?

    @Published var title: String
    @Published var duration: String?
    @Published var thumbnailURL: URL?
    @Published var status: DownloadStatus
    @Published var progress: Double
    @Published var speed: String?
    @Published var eta: String?
    @Published var filePaths: [URL] = []
    /// Files this job's own attempt finished in its save folder, with their
    /// file system numbers. Persisted with paused and recovered jobs so a
    /// resume after relaunch reuses them; once the file is replaced, its number
    /// changes and a file with the same name is a collision again.
    var ownedOutputFiles: [URL: Int] = [:]

    nonisolated static func encodeOwnedOutputFiles(_ files: [URL: Int]) -> [String: Int]? {
        files.isEmpty ? nil : Dictionary(uniqueKeysWithValues: files.map { ($0.key.path, $0.value) })
    }

    nonisolated static func decodeOwnedOutputFiles(_ files: [String: Int]?) -> [URL: Int] {
        Dictionary(uniqueKeysWithValues: (files ?? [:]).map { (URL(fileURLWithPath: $0.key), $0.value) })
    }
    var hasPlayableOutput: Bool {
        !filePaths.isEmpty && (status == .completed || (status == .failed && hasPartialFailure))
    }
    var primaryFilePath: URL? {
        filePaths.first
    }
    /// Reads the disk. Rows cache the result instead of calling this from
    /// `body`, which reruns on every progress tick of any download.
    var primaryFileExistsOnDisk: Bool? {
        primaryFilePath.map { FileManager.default.fileExists(atPath: $0.path) }
    }
    var filePathStrings: [String] {
        if filePaths.isEmpty { return [] }
        if filePaths.count == 1 { return [filePaths[0].path] }
        return filePaths.map { $0.path }
    }

    @Published var requiresAdvancedArgumentsReview = false
    @Published var hasPartialFailure = false
    @Published var errorMessage: String?
    @Published var log: String = ""
    @Published var mediaInfo: MediaInfo?
    @Published var diagnostics: DownloadDiagnostics = DownloadDiagnostics()

    let sourceDomain: String

    var displayProgress: String {
        let safeProgress: Double = {
            if progress.isNaN { return 0.0 }
            if progress.isInfinite { return progress > 0 ? 1.0 : 0.0 }
            return max(0.0, min(1.0, progress))
        }()
        let percentage = Int(safeProgress * 100)
        if let speed = speed, let eta = eta {
            return "\(percentage)% • \(speed) • \(eta)"
        }
        return "\(percentage)%"
    }

    static let fetchingPlaceholder = "___FETCHING___"

    // Bolt Performance Optimization: Pre-compile static UUID regex and optimize fallback title derivation with single-pass character replacement without NSString bridging.
    nonisolated private static let uuidFallbackRegex = try? NSRegularExpression(pattern: "^[a-f0-9\\-]{36}$", options: .caseInsensitive)

    static func deriveFallbackTitle(from urlString: String, sourceDomain: String) -> String {
        if let url = URL(string: urlString) {
            let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if let last = pathComponents.last, last.count > 1 {
                let isOnlyDigits = last.allSatisfy { $0.isNumber }
                let isUUID: Bool = {
                    guard let regex = uuidFallbackRegex else { return false }
                    return regex.firstMatch(in: last, options: [], range: NSRange(location: 0, length: last.utf16.count)) != nil
                }()
                if !isOnlyDigits && !isUUID {
                    let baseName = URL(fileURLWithPath: last).deletingPathExtension().lastPathComponent
                    var spaceSeparated = ""
                    spaceSeparated.reserveCapacity(baseName.utf8.count)
                    for char in baseName {
                        if char == "-" || char == "_" || char == "+" {
                            spaceSeparated.append(" ")
                        } else {
                            spaceSeparated.append(char)
                        }
                    }
                    let stripped = spaceSeparated.trimmingCharacters(in: .whitespaces)
                    if stripped.count >= 2 {
                        return stripped.capitalized
                    }
                }
            }
        }
        if !sourceDomain.isEmpty && sourceDomain.lowercased() != "web" {
            return "\(sourceDomain) Video"
        }
        return urlString
    }

    /// A name with nothing a filename can keep (BoyfriendTV allows a "."
    /// title) sanitizes to the shared fallback, so unrelated videos collide
    /// and report File Exists. Name those by the URL's video ID: the number after "video", else the first numeric
    /// path component, else an `id`/`v`/`video_id` query value.
    static func distinctBaseName(_ name: String, url: String) -> String {
        guard YtdlpService.sanitizedFilenameOrNil(name) == nil else { return name }
        let components = URLComponents(string: url)
        // www and language subdomains (es.site.com) serve the same video.
        var hostLabels = components?.host?.lowercased().split(separator: ".") ?? []
        if hostLabels.count > 2, let first = hostLabels.first, first == "www" || first.count == 2 {
            hostLabels.removeFirst()
        }
        let baseHost = hostLabels.joined(separator: ".")
        let sourceDomain = extractSourceDomain(from: baseHost.isEmpty ? url : "https://\(baseHost)")
        let pathParts = components?.url?.pathComponents ?? []
        let isNumeric: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        // /album/123/video/456: the number after "video" beats the first number.
        let videoID = zip(pathParts, pathParts.dropFirst()).first(where: { $0.0.lowercased().hasPrefix("video") && isNumeric($0.1) })?.1
            ?? pathParts.first(where: isNumeric)
            ?? components?.queryItems?.first(where: { ["id", "v", "video_id"].contains($0.name.lowercased()) && $0.value?.isEmpty == false })?.value
        if let videoID {
            return "\(sourceDomain) \(videoID)"
        }
        return deriveFallbackTitle(from: url, sourceDomain: sourceDomain)
    }

    var displayTitle: String {
        if title.isEmpty || title == Self.fetchingPlaceholder {
            if let custom = options.customFilename, !custom.isEmpty {
                return custom
            }
            return Self.deriveFallbackTitle(from: url, sourceDomain: sourceDomain)
        }
        return title
    }

    // Bolt Performance Optimization: Extract source domain once during initialization to avoid repeated URL parsing and regex evaluations during SwiftUI render passes.
    // Short-circuits domain checks without allocating intermediate `"." + domain` strings on the heap.
    static func extractSourceDomain(from url: String) -> String {
        guard let urlObj = URL(string: url), let host = urlObj.host?.lowercased() else {
            return "Web"
        }
        let matchesDomain: (String) -> Bool = { domain in
            host == domain || (host.hasSuffix(domain) && host.dropLast(domain.count).hasSuffix("."))
        }

        if matchesDomain("youtube.com") || matchesDomain("youtu.be") {
            return "YouTube"
        } else if matchesDomain("twitter.com") || matchesDomain("x.com") {
            return "X (Twitter)"
        } else if matchesDomain("instagram.com") {
            return "Instagram"
        } else if matchesDomain("tiktok.com") {
            return "TikTok"
        } else if matchesDomain("vimeo.com") {
            return "Vimeo"
        } else if matchesDomain("reddit.com") {
            return "Reddit"
        } else if matchesDomain("facebook.com") || matchesDomain("fb.watch") {
            return "Facebook"
        } else if matchesDomain("twitch.tv") {
            return "Twitch"
        } else if matchesDomain("soundcloud.com") {
            return "SoundCloud"
        } else if matchesDomain("dailymotion.com") {
            return "Dailymotion"
        }

        let cleaned = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard let first = cleaned.first else { return cleaned }
        return String(first).uppercased() + cleaned.dropFirst()
    }

    func formatSubtitle(lang: LanguageService) -> String {
        var parts: [String] = [sourceDomain]

        if options.fileType.isVideo {
            if let height = diagnostics.resolvedHeight {
                parts.append("\(height)p")
            } else if let res = options.videoResolution, res != .best, res != .worst {
                parts.append(res.rawValue.replacingOccurrences(of: "r", with: ""))
            } else if let diagRes = diagnostics.resolution, !diagRes.isEmpty {
                parts.append(diagRes)
            } else if let h = mediaInfo?.maxFormatHeight {
                parts.append("\(h)p")
            }
            if let codec = options.videoCodec, codec != .auto {
                parts.append(codec.rawValue.uppercased())
            }
            if let hdr = diagnostics.hdrSummary ?? mediaInfo?.firstHDRSummary {
                parts.append(hdr)
            }
        } else {
            if let quality = options.audioQuality, quality != .best {
                parts.append(quality.rawValue)
            }
            if let codec = options.audioCodec, codec != .auto {
                let codecName = codec.rawValue.uppercased()
                if codecName != options.fileType.rawValue.uppercased() {
                    parts.append(codecName)
                }
            }
        }

        parts.append(options.fileType.rawValue)

        if let dur = duration, !dur.isEmpty {
            parts.append(dur)
        }

        if options.downloadSubtitles {
            let count = options.subtitleLanguages.count
            let localizedCount = count == 1 ? lang.s("subtitles_selected_one") : String(format: lang.s("subtitles_selected"), count)
            if let format = options.subtitleFormat {
                parts.append("\(localizedCount) (\(format.displayName))")
            } else {
                parts.append(localizedCount)
            }
        }

        return parts.joined(separator: " • ")
    }

    enum ErrorActionType: Equatable {
        case fixInSettings
        case retry
        case changeFolder
        case noAction
    }

    struct ErrorUXInfo {
        let headline: String
        let description: String
        let actionType: ErrorActionType
        /// Unsanitized log text. Rows build this on every redraw, while the
        /// sanitized copy is needed only when the details are shown or copied.
        private let unsanitizedError: String
        var rawError: String { LoggerService.sanitizeDiagnosticText(unsanitizedError) }

        init(headline: String, description: String, actionType: ErrorActionType, rawError: String) {
            self.headline = headline
            self.description = description
            self.actionType = actionType
            self.unsanitizedError = rawError
        }
    }

    func errorUXInfo(lang: LanguageService) -> ErrorUXInfo? {
        guard let error = errorMessage ?? (status == .failed ? lang.s("generic_error_desc") : nil) else {
            return nil
        }

        let lower = error.lowercased()
        // The details box shows only the first lines, so yt-dlp's own error goes on top.
        let terminalError = log.range(of: "ERROR:", options: .backwards).map {
            log[log.lineRange(for: $0)].trimmingCharacters(in: .newlines)
        }
        let rawError = log.isEmpty ? error : terminalError.map { "\($0)\n\n\(log)" } ?? log

        // Partial jobs retain finished files and remain actionable for retry.
        if hasPartialFailure || status == .completed {
            return ErrorUXInfo(
                headline: lang.s("some_items_failed"),
                description: error,
                actionType: .retry,
                rawError: rawError
            )
        }

        let isYouTube = url.lowercased().contains("youtube.com") || url.lowercased().contains("youtu.be")
        let isYouTubeSignIn = isYouTube && lower.contains("sign in to confirm")

        // Missing dependency, not an unavailable video (its text says "not found").
        if lower.contains("yt-dlp executable not found") {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: error,
                actionType: .fixInSettings,
                rawError: rawError
            )
        }
        if lower.contains("cloudflare") || lower.contains("anti-bot") || lower.contains("captcha") || lower.contains("challenge") || isYouTubeSignIn {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: isYouTubeSignIn ? lang.s("youtube_auth_required") : lang.s("anti_bot_desc"),
                actionType: isYouTubeSignIn ? .fixInSettings : .retry,
                rawError: rawError
            )
        } else if error == lang.s("site_sign_in_required") {
            // Settings can't fix this one: the user signs in (Safari or Siphon's window), then retries.
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: lang.s("site_sign_in_required_desc"),
                actionType: .retry,
                rawError: rawError
            )
        } else if error == lang.s("access_denied") {
            // Checked before the cookie wording below: a 403 is often not a sign-in problem.
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: lang.s("access_denied_desc"),
                actionType: .retry,
                rawError: rawError
            )
        } else if lower.contains("sign in") || lower.contains("login") || lower.contains("cookies") {
            let desc = isYouTube ? lang.s("youtube_auth_required") : lang.s("login_required_desc")
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: desc,
                actionType: .fixInSettings,
                rawError: rawError
            )
        } else if lower.contains("drm") {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: lang.s("drm_protected_desc"),
                actionType: .noAction,
                rawError: rawError
            )
        } else if lower.contains("unavailable") || lower.contains("private") || lower.contains("removed") || lower.contains("404") || lower.contains("not found") {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: lang.s("video_unavailable_desc"),
                actionType: .retry,
                rawError: rawError
            )
        } else if lower.contains("no space left") || lower.contains("disk full") || lower.contains("disk space") {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: lang.s("disk_full_desc"),
                actionType: .changeFolder,
                rawError: rawError
            )
        } else if lower.contains("permission denied") {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: lang.s("permission_denied_desc"),
                actionType: .changeFolder,
                rawError: rawError
            )
        } else if lower.contains("timed out") || lower.contains("timeout") || lower.contains("connection") {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: lang.s("network_timeout_desc"),
                actionType: .retry,
                rawError: rawError
            )
        } else if lower.contains("unsupported url") {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: lang.s("unsupported_url_desc"),
                actionType: .noAction,
                rawError: rawError
            )
        } else {
            return ErrorUXInfo(
                headline: lang.s("couldnt_download"),
                description: error.count > 60 ? lang.s("generic_error_desc") : error,
                actionType: .retry,
                rawError: rawError
            )
        }
    }

    init(url: String, options: DownloadOptions, title: String = "___FETCHING___", id: UUID = UUID(), createdAt: Date = Date(), titleIsDecoded: Bool = false) {
        self.id = id
        self.url = url
        self.sourceDomain = Download.extractSourceDomain(from: url)
        self.createdAt = createdAt
        self.options = options
        self.title = titleIsDecoded ? title : title.decodingHTMLEntities()
        self.status = .queued
        self.progress = 0
    }
}

enum DownloadStatus: String, Codable {
    case fetching = "fetching"
    case queued = "queued"
    case downloading = "downloading"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
    case stopped = "stopped"
    case paused = "paused"
    case fileExists = "file_exists"

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if let status = Self(rawValue: value) {
            self = status
            return
        }

        switch value {
        case "Bilgi Alınıyor": self = .fetching
        case "Kuyrukta": self = .queued
        case "İndiriliyor": self = .downloading
        case "İşleniyor": self = .processing
        case "Tamamlandı": self = .completed
        case "Hata": self = .failed
        case "Durduruldu": self = .stopped
        case "Duraklatıldı": self = .paused
        case "Dosya Mevcut": self = .fileExists
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown DownloadStatus value: \(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

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

struct HistoricDownload: Codable, Identifiable {
    static let maxLogCharacters = 8_000

    let id: UUID
    let url: String
    var title: String
    var filePaths: [String]
    let downloadDate: Date
    let fileType: MediaFileType
    let status: DownloadStatus
    let thumbnailURL: URL?
    let duration: String?
    let errorMessage: String?
    let log: String
    let progress: Double
    let scratchDirectoryPath: String?
    let browserCookieSource: String?
    let requiresAdvancedArgumentsReview: Bool?
    let hasPartialFailure: Bool?
    let resolvedOutputBaseName: String?
    let ownedOutputFiles: [String: Int]?
    let options: DownloadOptions

    enum CodingKeys: String, CodingKey {
        case resolvedOutputBaseName, id, url, title, filePath, filePaths, downloadDate, fileType, status, thumbnailURL, duration, errorMessage, log, progress, scratchDirectoryPath, browserCookieSource, requiresAdvancedArgumentsReview, hasPartialFailure, ownedOutputFiles, options
    }

    @MainActor
    init(download: Download) {
        self.resolvedOutputBaseName = download.resolvedOutputBaseName
        self.id = download.id
        self.url = download.url
        self.title = download.displayTitle
        self.filePaths = download.filePathStrings
        self.downloadDate = download.createdAt
        self.fileType = download.options.fileType
        self.status = download.status
        self.thumbnailURL = download.thumbnailURL
        self.duration = download.duration
        self.errorMessage = download.errorMessage.map {
            LoggerService.sanitizeLogContentForExport(
                LoggerService.sanitizeDiagnosticText($0)
            )
        }
        // History lives in UserDefaults and is rewritten whole on every save;
        // 500 full 50k-character logs would make each write ~25 MB.
        self.log = LoggerService.sanitizeLogContentForExport(
            LoggerService.sanitizeDiagnosticText(String(download.log.suffix(Self.maxLogCharacters)))
        )
        self.progress = download.progress
        self.scratchDirectoryPath = download.status == .paused || download.status == .fileExists
            ? download.scratchDirectory.flatMap {
                ScratchDirectoryPolicy.isOwned($0) ? $0.path : nil
            }
            : nil
        self.ownedOutputFiles = download.status == .paused
            ? Download.encodeOwnedOutputFiles(download.ownedOutputFiles)
            : nil
        switch download.status {
        case .paused, .failed, .stopped, .fileExists:
            // Browser family/source is non-secret retry context. Preserve it for
            // states that can be resumed or retried after a clean restart while
            // raw cookies and raw User-Agent remain ephemeral.
            self.browserCookieSource = AppState.normalizedBrowserCookieSource(
                download.options.browserCookieSource
            )
        default:
            self.browserCookieSource = nil
        }
        self.requiresAdvancedArgumentsReview = download.status != .completed && (download.requiresAdvancedArgumentsReview ||
            download.options.additionalArguments?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        self.hasPartialFailure = download.hasPartialFailure
        var sanitizedOptions = download.options
        sanitizedOptions.rawCookies = nil
        sanitizedOptions.rawUserAgent = nil
        sanitizedOptions.additionalArguments = nil
        sanitizedOptions.browserCookieSource = nil
        self.options = sanitizedOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resolvedOutputBaseName = try container.decodeIfPresent(String.self, forKey: .resolvedOutputBaseName)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decode(String.self, forKey: .title)
        self.downloadDate = try container.decode(Date.self, forKey: .downloadDate)
        self.fileType = try container.decode(MediaFileType.self, forKey: .fileType)
        self.status = try container.decode(DownloadStatus.self, forKey: .status)
        self.thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        self.duration = try container.decodeIfPresent(String.self, forKey: .duration)
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.log = try container.decode(String.self, forKey: .log)
        self.progress = try container.decode(Double.self, forKey: .progress)
        self.scratchDirectoryPath = try container.decodeIfPresent(String.self, forKey: .scratchDirectoryPath)
        self.browserCookieSource = try container.decodeIfPresent(String.self, forKey: .browserCookieSource)
        self.requiresAdvancedArgumentsReview = try container.decodeIfPresent(Bool.self, forKey: .requiresAdvancedArgumentsReview)
        self.hasPartialFailure = try container.decodeIfPresent(Bool.self, forKey: .hasPartialFailure)
        self.ownedOutputFiles = try container.decodeIfPresent([String: Int].self, forKey: .ownedOutputFiles)
        self.options = try container.decode(DownloadOptions.self, forKey: .options)

        // Legacy deserialization fallback: read single filePath only if filePaths is not present
        if let paths = try container.decodeIfPresent([String].self, forKey: .filePaths), !paths.isEmpty {
            self.filePaths = paths
        } else if let single = try container.decodeIfPresent(String.self, forKey: .filePath) {
            self.filePaths = [single]
        } else {
            self.filePaths = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeMetadata(to: &container)
        try encodeStateAndProgress(to: &container)
        try container.encode(options, forKey: .options)
    }

    private func encodeMetadata(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(resolvedOutputBaseName, forKey: .resolvedOutputBaseName)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(filePaths, forKey: .filePaths)
        try container.encode(downloadDate, forKey: .downloadDate)
        try container.encode(fileType, forKey: .fileType)
        try container.encodeIfPresent(scratchDirectoryPath, forKey: .scratchDirectoryPath)
        try container.encodeIfPresent(browserCookieSource, forKey: .browserCookieSource)
        try container.encodeIfPresent(requiresAdvancedArgumentsReview, forKey: .requiresAdvancedArgumentsReview)
        try container.encodeIfPresent(hasPartialFailure, forKey: .hasPartialFailure)
        try container.encodeIfPresent(ownedOutputFiles, forKey: .ownedOutputFiles)
        try container.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try container.encodeIfPresent(duration, forKey: .duration)
    }

    private func encodeStateAndProgress(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(log, forKey: .log)
        try container.encode(progress, forKey: .progress)
    }

    // Helper to convert back to Download object for UI
    @MainActor
    func toDownload() -> Download {
        var restoredOptions = self.options
        restoredOptions.browserCookieSource = AppState.normalizedBrowserCookieSource(self.browserCookieSource)
        let download = Download(
            url: self.url,
            options: restoredOptions,
            title: self.title,
            id: self.id,
            createdAt: self.downloadDate,
            titleIsDecoded: true
        )
        download.resolvedOutputBaseName = self.resolvedOutputBaseName.map(YtdlpService.sanitizeFilename)
        download.requiresAdvancedArgumentsReview = self.requiresAdvancedArgumentsReview ?? false
        download.hasPartialFailure = self.hasPartialFailure ?? (self.status == .completed && self.errorMessage != nil)
        let restoredStatus = download.hasPartialFailure && self.status == .completed ? DownloadStatus.failed : self.status
        // Review only holds back jobs that would run on their own. Failed,
        // stopped and file-exists jobs keep their state; retry is gated on review.
        switch restoredStatus {
        case .queued, .fetching, .downloading, .processing:
            download.status = download.requiresAdvancedArgumentsReview ? .paused : restoredStatus
        default:
            download.status = restoredStatus
        }
        download.progress = self.progress
        if let path = self.scratchDirectoryPath {
            let scratchDirectory = URL(fileURLWithPath: path)
            if ScratchDirectoryPolicy.isOwned(scratchDirectory),
               FileManager.default.fileExists(atPath: scratchDirectory.path) {
                download.scratchDirectory = scratchDirectory
            }
        }
        download.thumbnailURL = self.thumbnailURL
        download.duration = self.duration
        download.errorMessage = self.errorMessage
        download.log = self.log
        download.ownedOutputFiles = Download.decodeOwnedOutputFiles(self.ownedOutputFiles)
        if self.filePaths.isEmpty {
            download.filePaths = []
        } else if self.filePaths.count == 1 {
            download.filePaths = [URL(fileURLWithPath: self.filePaths[0])]
        } else {
            download.filePaths = self.filePaths.map { URL(fileURLWithPath: $0) }
        }
        return download
    }
}

// MARK: - Download URL Validation & Parsing
