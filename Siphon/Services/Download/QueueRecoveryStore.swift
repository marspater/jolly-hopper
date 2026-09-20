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

        var sanitizedOptions = download.options
        sanitizedOptions.rawCookies = nil
        sanitizedOptions.rawUserAgent = nil
        sanitizedOptions.browserCookieSource = nil
        sanitizedOptions.additionalArguments = nil
        self.options = sanitizedOptions

        self.status = download.status
        self.progress = download.progress
        self.scratchDirectoryPath = download.scratchDirectory?.path
        self.thumbnailURL = download.thumbnailURL
        self.duration = download.duration
        self.errorMessage = download.errorMessage.map {
            LoggerService.sanitizeLogContentForExport(LoggerService.sanitizeDiagnosticText($0))
        }
        self.log = LoggerService.sanitizeLogContentForExport(LoggerService.sanitizeDiagnosticText(download.log))
    }

    @MainActor
    func toDownload() -> Download {
        let download = Download(url: self.url, options: self.options, title: self.title, id: self.id)
        download.status = self.status
        download.progress = self.progress
        if let path = self.scratchDirectoryPath, FileManager.default.fileExists(atPath: path) {
            download.scratchDirectory = URL(fileURLWithPath: path)
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

    func persist(activeJobs: [Download]) {
        let records = activeJobs.map { QueueRecoveryRecord(download: $0) }
        let snapshot = QueueRecoverySnapshot(
            version: 1,
            timestamp: Date(),
            isCleanShutdown: false,
            jobs: records
        )
        save(snapshot)
    }

    func markCleanShutdown() {
        let snapshot = QueueRecoverySnapshot(
            version: 1,
            timestamp: Date(),
            isCleanShutdown: true,
            jobs: []
        )
        save(snapshot)
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

    private func save(_ snapshot: QueueRecoverySnapshot) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LoggerService.shared.log("Failed to persist queue recovery state: \(error.localizedDescription)", level: .error)
        }
    }
}
