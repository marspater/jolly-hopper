//
//  QueueRecoveryStore.swift
//  Siphon
//

import Foundation

public struct QueueRecoveryRecord: Codable, Identifiable, Sendable {
    public static let maxLogCharacters = 8_000

    public let id: UUID
    public let url: String
    public let title: String
    public let createdAt: Date
    public let requiresAdvancedArgumentsReview: Bool?
    public let resolvedOutputBaseName: String?
    public let options: DownloadOptions
    public let status: DownloadStatus
    public let progress: Double
    public let scratchDirectoryPath: String?
    public let ownedOutputFiles: [String: Int]?
    public let browserCookieSource: String?
    public let thumbnailURL: URL?
    public let duration: String?
    public let errorMessage: String?
    public let log: String

    @preconcurrency @MainActor
    public init(download: Download) {
        self.resolvedOutputBaseName = download.resolvedOutputBaseName
        self.id = download.id
        self.url = download.url
        self.title = download.displayTitle
        self.createdAt = download.createdAt

        self.browserCookieSource = SupportedBrowser.normalizedCookieSource(download.options.browserCookieSource)

        self.requiresAdvancedArgumentsReview = download.requiresAdvancedArgumentsReview ||
            download.options.additionalArguments?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        var sanitizedOptions = download.options
        sanitizedOptions.rawCookies = nil
        sanitizedOptions.rawUserAgent = nil
        sanitizedOptions.browserCookieSource = nil
        sanitizedOptions.additionalArguments = nil
        self.options = sanitizedOptions

        self.status = download.status
        self.progress = download.progress
        self.scratchDirectoryPath = download.scratchDirectory.flatMap {
            ScratchDirectoryPolicy.isOwned($0) ? $0.path : nil
        }
        self.ownedOutputFiles = Download.encodeOwnedOutputFiles(download.ownedOutputFiles)
        self.thumbnailURL = download.thumbnailURL
        self.duration = download.duration
        self.errorMessage = download.errorMessage.map {
            LogSanitizer.sanitizeLogContentForExport(LogSanitizer.sanitizeDiagnosticText($0))
        }
        // Recovery rewrites every active job at each 5% of progress, on the main
        // actor. Sanitizing a full 50k-character log costs ~8 ms per job there;
        // the tail is enough context for a restored job.
        self.log = LogSanitizer.sanitizeLogContentForExport(
            LogSanitizer.sanitizeDiagnosticText(String(download.log.suffix(Self.maxLogCharacters)))
        )
    }

    @preconcurrency @MainActor
    public func toDownload() -> Download {
        var restoredOptions = self.options
        restoredOptions.browserCookieSource = SupportedBrowser.normalizedCookieSource(self.browserCookieSource)
        let download = Download(
            url: self.url,
            options: restoredOptions,
            title: self.title,
            id: self.id,
            createdAt: self.createdAt,
            titleIsDecoded: true
        )
        download.resolvedOutputBaseName = self.resolvedOutputBaseName.map(MediaFileRules.sanitizeFilename)
        download.requiresAdvancedArgumentsReview = self.requiresAdvancedArgumentsReview ?? false
        download.status = self.status
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
        return download
    }
}

public struct QueueRecoverySnapshot: Codable, Sendable {
    public let version: Int
    public let timestamp: Date
    public let isCleanShutdown: Bool
    public let jobs: [QueueRecoveryRecord]

    /// Jobs that failed to decode (an unknown value after a downgrade, a
    /// damaged entry). The rest of the snapshot is still restored.
    public private(set) var skippedJobCount = 0

    enum CodingKeys: String, CodingKey {
        case version, timestamp, isCleanShutdown, jobs
    }

    public init(version: Int = 1, timestamp: Date = Date(), isCleanShutdown: Bool = false, jobs: [QueueRecoveryRecord]) {
        self.version = version
        self.timestamp = timestamp
        self.isCleanShutdown = isCleanShutdown
        self.jobs = jobs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.isCleanShutdown = try container.decode(Bool.self, forKey: .isCleanShutdown)
        let entries = try container.decode([LossyRecord].self, forKey: .jobs)
        self.jobs = entries.compactMap(\.record)
        self.skippedJobCount = entries.count - jobs.count
    }

    private struct LossyRecord: Decodable {
        public let record: QueueRecoveryRecord?
        public init(from decoder: Decoder) throws {
            record = try? QueueRecoveryRecord(from: decoder)
        }
    }
}

@preconcurrency @MainActor
public final class QueueRecoveryStore {
    public let fileURL: URL
    private let fileManager: FileManager
    private let log: CoreLogSink
    public private(set) var hasUnsupportedSchemaSnapshot: Bool = false

    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let siphonDir = appSupport.appendingPathComponent("Siphon", isDirectory: true)
        return siphonDir.appendingPathComponent("queue_recovery.json")
    }

    public init(fileURL: URL = QueueRecoveryStore.defaultFileURL, fileManager: FileManager = .default, log: @escaping CoreLogSink = CoreLog.unified) {
        self.log = log
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func persist(activeJobs: [Download]) -> Bool {
        if hasUnsupportedSchemaSnapshot && !activeJobs.isEmpty {
            hasUnsupportedSchemaSnapshot = false
        }
        let records = activeJobs.map { QueueRecoveryRecord(download: $0) }
        let snapshot = QueueRecoverySnapshot(
            version: 1,
            timestamp: Date(),
            isCleanShutdown: false,
            jobs: records
        )
        do {
            try save(snapshot)
            return true
        } catch {
            log("Failed to persist queue recovery state: \(error.localizedDescription)", .error)
            return false
        }
    }

    @discardableResult
    public func markCleanShutdown() -> Bool {
        guard !hasUnsupportedSchemaSnapshot else {
            log("Preserving unsupported queue recovery snapshot; skipping clean shutdown overwrite", .info)
            return true
        }
        let snapshot = QueueRecoverySnapshot(
            version: 1,
            timestamp: Date(),
            isCleanShutdown: true,
            jobs: []
        )
        do {
            try save(snapshot)
            return true
        } catch {
            log("Failed to mark clean shutdown: \(error.localizedDescription)", .error)
            return false
        }
    }

    public func loadInterruptedJobs() -> [Download] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            if let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawVersion = rawJson["version"] as? Int, rawVersion != 1 {
                log("Ignoring queue recovery snapshot with unknown version \(rawVersion)", .warning)
                hasUnsupportedSchemaSnapshot = true
                preserveUnsupportedSnapshot(version: rawVersion)
                return []
            }
            let snapshot = try JSONDecoder().decode(QueueRecoverySnapshot.self, from: data)
            guard snapshot.version == 1 else {
                log("Ignoring queue recovery snapshot with unknown version \(snapshot.version)", .warning)
                hasUnsupportedSchemaSnapshot = true
                preserveUnsupportedSnapshot(version: snapshot.version)
                return []
            }
            if snapshot.skippedJobCount > 0 {
                log("Skipped \(snapshot.skippedJobCount) unreadable queue recovery entries", .warning)
            }
            guard !snapshot.isCleanShutdown && !snapshot.jobs.isEmpty else {
                return []
            }
            return snapshot.jobs.map { $0.toDownload() }
        } catch {
            log("Failed to load queue recovery snapshot: \(error.localizedDescription)", .error)
            preserveUnreadableSnapshot()
            return []
        }
    }

    private func preserveUnsupportedSnapshot(version: Int) {
        let backup = fileURL.appendingPathExtension("unsupported-v\(version)")
        do {
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            try fileManager.copyItem(at: fileURL, to: backup)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        } catch {
            log("Failed to preserve unsupported queue recovery snapshot: \(error.localizedDescription)", .error)
        }
    }

    /// The next persist overwrites the snapshot; keep the unreadable one
    /// beside it so the interrupted jobs are not lost without a trace.
    private func preserveUnreadableSnapshot() {
        let backup = fileURL.appendingPathExtension("corrupt")
        do {
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            try fileManager.moveItem(at: fileURL, to: backup)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        } catch {
            log("Failed to preserve unreadable queue recovery snapshot: \(error.localizedDescription)", .error)
        }
    }

    private func save(_ snapshot: QueueRecoverySnapshot) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
