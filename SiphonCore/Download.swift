import Foundation
import os
import Combine

public enum ScratchDirectoryPolicy: Sendable {
    public static let directoryPrefix = "siphon_scratch_"

    public static func makeURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
    }

    private static let ownerMarkerName = ".siphon-owner-pid"

    /// Records the owning process so another Siphon's launch sweep leaves a live run alone.
    public static func markOwner(_ directory: URL, pid: Int32 = getpid()) {
        try? String(pid).write(to: directory.appendingPathComponent(ownerMarkerName), atomically: true, encoding: .utf8)
    }

    static func hasLiveOwner(_ directory: URL) -> Bool {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(ownerMarkerName), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        // EPERM means the process exists but belongs to another user.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public static func isOwned(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let root = fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent().path == root.path else { return false }
        return hasScratchName(candidate)
    }

    /// Hidden temp files written beside media (conversions, cover art, GIF
    /// re-encodes, decryption). They share the media's volume for an atomic
    /// replace, so they cannot live in the scratch directory.
    public static let siblingTempPrefix = ".siphon-tmp-"

    public static func siblingTempURL(beside file: URL, extension ext: String) -> URL {
        let name = siblingTempPrefix + UUID().uuidString
        return file.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }

    /// Sibling temp names, including those of builds before `siblingTempPrefix`.
    public static func isSiblingTempName(_ name: String) -> Bool {
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
    public static func purgeAbandonedSiblingTemps(
        in folder: URL,
        minimumAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default,
        log: CoreLogSink = CoreLog.unified
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
                log(message, .warning)
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

    public static func hasTemporaryArtifactName(_ url: URL) -> Bool {
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
    public static func purgeAbandoned(
        keeping kept: Set<String>,
        in root: URL = FileManager.default.temporaryDirectory,
        minimumAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default,
        log: CoreLogSink = CoreLog.unified
    ) -> [URL] {
        // Liveness: a running owner (pid marker) wins; otherwise recursive mtime age.
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return [] }
        var removed: [URL] = []
        for directory in entries where hasTemporaryArtifactName(directory) && !kept.contains(directory.lastPathComponent) {
            if hasLiveOwner(directory) { continue }
            // A running download keeps writing its .part file, which the
            // directory's own date does not reflect.
            let children = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys)?.compactMap { $0 as? URL } ?? []
            let lastTouched = ([directory] + children)
                .compactMap { try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate }
                .max() ?? .distantPast
            guard now.timeIntervalSince(lastTouched) >= minimumAge else { continue }
            do {
                try fileManager.removeItem(at: directory)
                removed.append(directory)
            } catch {
                let message = "Could not remove abandoned scratch directory: \(error.localizedDescription)"
                log(message, .warning)
            }
        }
        return removed
    }
}

@preconcurrency @MainActor
public class Download: ObservableObject, Identifiable {
    public let id: UUID
    public let url: String
    public let createdAt: Date
    public var options: DownloadOptions
    // Queue-selected name, separate from the user's explicit filename.
    public var resolvedOutputBaseName: String?
    public var outputBaseName: String { resolvedOutputBaseName ?? requestedBaseName }
    public var requestedBaseName: String { Self.distinctBaseName(options.customFilename ?? displayTitle, url: url) }
    // Owned by this job; retained across pause/resume, never shared by filename.
    public var scratchDirectory: URL?

    @Published public var title: String
    @Published public var duration: String?
    @Published public var thumbnailURL: URL?
    @Published public var status: DownloadStatus
    @Published public var progress: Double
    @Published public var speed: String?
    @Published public var eta: String?
    @Published public var filePaths: [URL] = []
    /// Files this job's own attempt finished in its save folder, with their
    /// file system numbers. Persisted with paused and recovered jobs so a
    /// resume after relaunch reuses them; once the file is replaced, its number
    /// changes and a file with the same name is a collision again.
    public var ownedOutputFiles: [URL: Int] = [:]

    public nonisolated static func encodeOwnedOutputFiles(_ files: [URL: Int]) -> [String: Int]? {
        files.isEmpty ? nil : Dictionary(uniqueKeysWithValues: files.map { ($0.key.path, $0.value) })
    }

    public nonisolated static func decodeOwnedOutputFiles(_ files: [String: Int]?) -> [URL: Int] {
        Dictionary(uniqueKeysWithValues: (files ?? [:]).map { (URL(fileURLWithPath: $0.key), $0.value) })
    }
    public var hasPlayableOutput: Bool {
        !filePaths.isEmpty && (status == .completed || (status == .failed && hasPartialFailure))
    }
    public var primaryFilePath: URL? {
        filePaths.first
    }
    /// Reads the disk. Rows cache the result instead of calling this from
    /// `body`, which reruns on every progress tick of any download.
    public var primaryFileExistsOnDisk: Bool? {
        primaryFilePath.map { FileManager.default.fileExists(atPath: $0.path) }
    }
    public var filePathStrings: [String] {
        if filePaths.isEmpty { return [] }
        if filePaths.count == 1 { return [filePaths[0].path] }
        return filePaths.map { $0.path }
    }

    @Published public var requiresAdvancedArgumentsReview = false
    @Published public var hasPartialFailure = false
    @Published public var errorMessage: String?
    @Published public var log: String = ""
    @Published public var mediaInfo: MediaInfo?
    @Published public var diagnostics: DownloadDiagnostics = DownloadDiagnostics()

    public let sourceDomain: String

    public var displayProgress: String {
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

    public static let fetchingPlaceholder = "___FETCHING___"

    // Bolt Performance Optimization: Pre-compile static UUID regex and optimize fallback title derivation with single-pass character replacement without NSString bridging.
    nonisolated private static let uuidFallbackRegex = try? NSRegularExpression(pattern: "^[a-f0-9\\-]{36}$", options: .caseInsensitive)

    public static func deriveFallbackTitle(from urlString: String, sourceDomain: String) -> String {
        if let title = URL(string: urlString).flatMap(readableLastPathComponent) {
            return title
        }
        if !sourceDomain.isEmpty && sourceDomain.lowercased() != "web" {
            return "\(sourceDomain) Video"
        }
        return urlString
    }

    private static func readableLastPathComponent(of url: URL) -> String? {
        guard let last = url.pathComponents.last(where: { $0 != "/" && !$0.isEmpty }),
              last.count > 1, !isOpaqueIdentifier(last) else { return nil }
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
        return stripped.count >= 2 ? stripped.capitalized : nil
    }

    private static func isOpaqueIdentifier(_ component: String) -> Bool {
        if component.allSatisfy({ $0.isNumber }) { return true }
        guard let regex = uuidFallbackRegex else { return false }
        return regex.firstMatch(in: component, options: [], range: NSRange(location: 0, length: component.utf16.count)) != nil
    }

    /// A name with nothing a filename can keep (BoyfriendTV allows a "."
    /// title) sanitizes to the shared fallback, so unrelated videos collide
    /// and report File Exists. Name those by the URL's video ID: the number after "video", else the first numeric
    /// path component, else an `id`/`v`/`video_id` query value.
    public static func distinctBaseName(_ name: String, url: String) -> String {
        guard MediaFileRules.sanitizedFilenameOrNil(name) == nil else { return name }
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

    public var displayTitle: String {
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
    nonisolated private static let knownSourceDomains: [(name: String, domains: [String])] = [
        ("YouTube", ["youtube.com", "youtu.be"]),
        ("X (Twitter)", ["twitter.com", "x.com"]),
        ("Instagram", ["instagram.com"]),
        ("TikTok", ["tiktok.com"]),
        ("Vimeo", ["vimeo.com"]),
        ("Reddit", ["reddit.com"]),
        ("Facebook", ["facebook.com", "fb.watch"]),
        ("Twitch", ["twitch.tv"]),
        ("SoundCloud", ["soundcloud.com"]),
        ("Dailymotion", ["dailymotion.com"])
    ]

    public static func extractSourceDomain(from url: String) -> String {
        guard let urlObj = URL(string: url), let host = urlObj.host?.lowercased() else {
            return "Web"
        }
        let matchesDomain: (String) -> Bool = { domain in
            host == domain || (host.hasSuffix(domain) && host.dropLast(domain.count).hasSuffix("."))
        }

        if let known = knownSourceDomains.first(where: { $0.domains.contains(where: matchesDomain) }) {
            return known.name
        }

        let cleaned = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard let first = cleaned.first else { return cleaned }
        return String(first).uppercased() + cleaned.dropFirst()
    }

    public init(url: String, options: DownloadOptions, title: String = "___FETCHING___", id: UUID = UUID(), createdAt: Date = Date(), titleIsDecoded: Bool = false) {
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

public enum DownloadStatus: String, Codable, Sendable {
    case fetching = "fetching"
    case queued = "queued"
    case downloading = "downloading"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
    case stopped = "stopped"
    case paused = "paused"
    case fileExists = "file_exists"

    /// Values written by older versions of the app.
    private static let legacyValues: [String: DownloadStatus] = [
        "Bilgi Alınıyor": .fetching,
        "Kuyrukta": .queued,
        "İndiriliyor": .downloading,
        "İşleniyor": .processing,
        "Tamamlandı": .completed,
        "Hata": .failed,
        "Durduruldu": .stopped,
        "Duraklatıldı": .paused,
        "Dosya Mevcut": .fileExists
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let status = Self(rawValue: value) ?? Self.legacyValues[value] else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown DownloadStatus value: \(value)")
        }
        self = status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var color: String {
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

public struct HistoricDownload: Codable, Identifiable, Sendable {
    public static let maxLogCharacters = 8_000

    public let id: UUID
    public let url: String
    public var title: String
    public var filePaths: [String]
    public let downloadDate: Date
    public let fileType: MediaFileType
    public let status: DownloadStatus
    public let thumbnailURL: URL?

    /// Signed or tokenized thumbnail URLs are short-lived credentials; keep them out of history.
    static func persistableThumbnailURL(_ url: URL) -> URL? {
        let sensitive = ["token", "sig", "signature", "key", "auth", "policy", "credential", "expires", "hdnts", "secret", "x-amz-signature", "x-goog-signature"]
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.user != nil || url.password != nil { return nil }
        return items.contains { sensitive.contains($0.name.lowercased()) } ? nil : url
    }
    public let duration: String?
    public let errorMessage: String?
    public let log: String
    public let progress: Double
    public let scratchDirectoryPath: String?
    public let browserCookieSource: String?
    public let requiresAdvancedArgumentsReview: Bool?
    public let hasPartialFailure: Bool?
    public let resolvedOutputBaseName: String?
    public let ownedOutputFiles: [String: Int]?
    public let options: DownloadOptions

    enum CodingKeys: String, CodingKey {
        case resolvedOutputBaseName, id, url, title, filePath, filePaths, downloadDate, fileType, status, thumbnailURL, duration, errorMessage, log, progress, scratchDirectoryPath, browserCookieSource, requiresAdvancedArgumentsReview, hasPartialFailure, ownedOutputFiles, options
    }

    @preconcurrency @MainActor
    public init(download: Download) {
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
            LogSanitizer.sanitizeLogContentForExport(
                LogSanitizer.sanitizeDiagnosticText($0)
            )
        }
        // History lives in UserDefaults and is rewritten whole on every save;
        // 500 full 50k-character logs would make each write ~25 MB.
        self.log = LogSanitizer.sanitizeLogContentForExport(
            LogSanitizer.sanitizeDiagnosticText(String(download.log.suffix(Self.maxLogCharacters)))
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
            self.browserCookieSource = SupportedBrowser.normalizedCookieSource(
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
        try container.encodeIfPresent(thumbnailURL.flatMap(Self.persistableThumbnailURL), forKey: .thumbnailURL)
        try container.encodeIfPresent(duration, forKey: .duration)
    }

    private func encodeStateAndProgress(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(log, forKey: .log)
        try container.encode(progress, forKey: .progress)
    }

    // Helper to convert back to Download object for UI
    @preconcurrency @MainActor
    public func toDownload() -> Download {
        var restoredOptions = self.options
        restoredOptions.browserCookieSource = SupportedBrowser.normalizedCookieSource(self.browserCookieSource)
        let download = Download(
            url: self.url,
            options: restoredOptions,
            title: self.title,
            id: self.id,
            createdAt: self.downloadDate,
            titleIsDecoded: true
        )
        download.resolvedOutputBaseName = self.resolvedOutputBaseName.map(MediaFileRules.sanitizeFilename)
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
