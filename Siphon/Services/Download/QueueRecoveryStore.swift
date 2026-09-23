//
//  QueueRecoveryStore.swift
//  Siphon
//

import Foundation

struct QueueRecoveryRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let url: String
    let title: String
    let createdAt: Date
    let options: DownloadOptions
    let status: DownloadStatus
    let progress: Double
    let scratchDirectoryPath: String?
    let browserCookieSource: String?
    let thumbnailURL: URL?
    let duration: String?
    let errorMessage: String?
    let log: String

    @MainActor
    init(download: Download) {
        self.id = download.id
        self.url = download.url
        self.title = download.displayTitle
        self.createdAt = download.createdAt

        self.browserCookieSource = AppState.normalizedBrowserCookieSource(download.options.browserCookieSource)

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
        self.thumbnailURL = download.thumbnailURL
        self.duration = download.duration
        self.errorMessage = download.errorMessage.map {
            LoggerService.sanitizeLogContentForExport(LoggerService.sanitizeDiagnosticText($0))
        }
        self.log = LoggerService.sanitizeLogContentForExport(LoggerService.sanitizeDiagnosticText(download.log))
    }

    @MainActor
    func toDownload() -> Download {
        var restoredOptions = self.options
        restoredOptions.browserCookieSource = AppState.normalizedBrowserCookieSource(self.browserCookieSource)
        let download = Download(
            url: self.url,
            options: restoredOptions,
            title: self.title,
            id: self.id,
            createdAt: self.createdAt
        )
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
        return download
    }
}

struct QueueRecoverySnapshot: Codable, Sendable {
    let version: Int
    let timestamp: Date
    let isCleanShutdown: Bool
    let jobs: [QueueRecoveryRecord]

    init(version: Int = 1, timestamp: Date = Date(), isCleanShutdown: Bool = false, jobs: [QueueRecoveryRecord]) {
        self.version = version
        self.timestamp = timestamp
        self.isCleanShutdown = isCleanShutdown
        self.jobs = jobs
    }
}

@MainActor
final class QueueRecoveryStore {
    let fileURL: URL
    private let fileManager: FileManager

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let siphonDir = appSupport.appendingPathComponent("Siphon", isDirectory: true)
        return siphonDir.appendingPathComponent("queue_recovery.json")
    }

    init(fileURL: URL = QueueRecoveryStore.defaultFileURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    @discardableResult
    func persist(activeJobs: [Download]) -> Bool {
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
            LoggerService.shared.log("Failed to persist queue recovery state: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    @discardableResult
    func markCleanShutdown() -> Bool {
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
            LoggerService.shared.log("Failed to mark clean shutdown: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    func loadInterruptedJobs() -> [Download] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(QueueRecoverySnapshot.self, from: data)
            guard !snapshot.isCleanShutdown && !snapshot.jobs.isEmpty else {
                return []
            }
            return snapshot.jobs.map { $0.toDownload() }
        } catch {
            LoggerService.shared.log("Failed to load queue recovery snapshot: \(error.localizedDescription)", level: .warning)
            return []
        }
    }

    func clearRecoveryState() {
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func save(_ snapshot: QueueRecoverySnapshot) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
