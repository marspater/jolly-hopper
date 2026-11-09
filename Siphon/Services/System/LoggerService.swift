import Foundation
import os
import SiphonCore
import SwiftUI

@MainActor
class LoggerService: ObservableObject {
    static let shared = LoggerService()

    @Published var logs: [String] = []
    let logFileURL: URL
    private let maxLogEntries = 1000
    private var logGeneration = 0
    private(set) var initialLogLoadTask: Task<Void, Never>?
    private let fileQueue = DispatchQueue(label: "com.siphon.loggerQueue", qos: .utility)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    nonisolated static func sanitizeURLForLog(_ urlString: String) -> String {
        LogSanitizer.sanitizeURLForLog(urlString)
    }

    nonisolated static func sanitizeCommandForLog(_ args: [String]) -> String {
        LogSanitizer.sanitizeCommandForLog(args)
    }

    init(logFileURL: URL? = nil, initialLogReader: (@Sendable () async -> [String])? = nil) {
        // The unit tests run inside Siphon.app, so keep their fixture output
        // out of the user's real debug log.
        let logDirectory = NotificationService.isRunningTests
            ? UITestLaunchMode.root ?? FileManager.default.temporaryDirectory.appendingPathComponent("SiphonTestLogs", isDirectory: true)
            : URL.applicationSupportDirectory.appendingPathComponent("Siphon")

        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.logFileURL = logFileURL ?? logDirectory.appendingPathComponent("siphon_debug.log")
        if FileManager.default.fileExists(atPath: self.logFileURL.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.logFileURL.path)
        }

        loadInitialLogs(reader: initialLogReader)
    }

    private func loadInitialLogs(reader: (@Sendable () async -> [String])?) {
        let fileURL = logFileURL
        let maxEntries = maxLogEntries
        let generation = logGeneration
        initialLogLoadTask = Task.detached {
            let initialLogs: [String]
            if let reader {
                initialLogs = await reader()
            } else {
                guard let handle = FileHandle(forReadingAtPath: fileURL.path) else { return }
                defer { try? handle.close() }

                let fileSize = (try? handle.seekToEnd()) ?? 0
                guard fileSize > 0 else { return }

                let readSize = min(fileSize, 256 * 1024)
                let seekPos = fileSize - readSize
                try? handle.seek(toOffset: seekPos)
                guard let data = try? handle.read(upToCount: Int(readSize)), !data.isEmpty else { return }

                initialLogs = Self.extractTailLines(from: data, maxEntries: maxEntries, discardFirstLine: seekPos > 0)
            }
            await MainActor.run {
                guard self.logGeneration == generation else { return }
                // Entries logged during launch are already in the file tail;
                // replacing them would only keep what was on disk at read time.
                let persisted = Set(initialLogs)
                let merged = initialLogs + self.logs.filter { !persisted.contains($0) }
                self.logs = Array(merged.suffix(maxEntries))
            }
        }
    }

    nonisolated static func extractTailLines(from data: Data, maxEntries: Int, discardFirstLine: Bool = false) -> [String] {
        LogSanitizer.extractTailLines(from: data, maxEntries: maxEntries, discardFirstLine: discardFirstLine)
    }

    nonisolated static func sanitizeDiagnosticText(_ text: String) -> String {
        LogSanitizer.sanitizeDiagnosticText(text)
    }

    func log(_ message: String, level: LogLevel = .info, category: LogCategory = .general) {
        let timestamp = Self.dateFormatter.string(from: Date())
        let sanitizedMessage = Self.sanitizeDiagnosticText(message)
        let entry = "[\(timestamp)] [\(level.rawValue)] \(sanitizedMessage)"

        // Public so Console and `log stream` show the text. Sanitized text can still carry a
        // host and path, so never pass the raw message to this sink.
        Logger(subsystem: "com.marspater.siphon", category: category.rawValue)
            .log(level: level.osLogType, "\(sanitizedMessage, privacy: .public)")

        // Bolt Performance Optimization: Amortize O(N) array element shifts during high-frequency logging
        // by batch-trimming oldest entries when the buffer exceeds maxLogEntries + 50 instead of shifting on every single log call.
        logs.append(entry)
        if logs.count > maxLogEntries + 50 {
            logs.removeFirst(logs.count - maxLogEntries)
        }

        let fileURL = logFileURL
        let maxEntries = maxLogEntries
        fileQueue.async {
            Self.appendToLogFile(entry + "\n", at: fileURL, maxEntries: maxEntries)
        }
    }

    nonisolated private static func appendToLogFile(_ string: String, at logFileURL: URL, maxEntries: Int) {
        guard let data = string.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
               let size = attrs[.size] as? Int64, size > 2 * 1024 * 1024 {
                trimLogFile(at: logFileURL, maxEntries: maxEntries)
            }
            // The throwing APIs matter here: the legacy write(_:) raises an
            // Objective-C exception on a full disk, which terminates the app.
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? fileHandle.close() }
                do {
                    try fileHandle.seekToEnd()
                    try fileHandle.write(contentsOf: data)
                } catch {
                    NSLog("Siphon could not write its debug log: %@", error.localizedDescription)
                }
            }
        } else {
            if !FileManager.default.createFile(atPath: logFileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) {
                try? data.write(to: logFileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
            }
        }
    }

    nonisolated private static func trimLogFile(at logFileURL: URL, maxEntries: Int) {
        autoreleasepool {
            guard let handle = FileHandle(forReadingAtPath: logFileURL.path) else { return }
            defer { try? handle.close() }

            let fileSize = (try? handle.seekToEnd()) ?? 0
            guard fileSize > 0 else { return }

            let readSize = min(fileSize, 256 * 1024)
            let seekPos = fileSize - readSize
            try? handle.seek(toOffset: seekPos)
            guard let data = try? handle.read(upToCount: Int(readSize)), !data.isEmpty else { return }

            let lines = extractTailLines(from: data, maxEntries: maxEntries, discardFirstLine: seekPos > 0)
            guard !lines.isEmpty else { return }
            let trimmed = lines.joined(separator: "\n") + "\n"
            if let trimmedData = trimmed.data(using: .utf8),
               !FileManager.default.createFile(atPath: logFileURL.path, contents: trimmedData, attributes: [.posixPermissions: 0o600]) {
                try? trimmed.write(to: logFileURL, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
            }
        }
    }

    func clearLogs() {
        logGeneration += 1
        logs.removeAll()
        let fileURL = logFileURL
        fileQueue.async {
            if !FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) {
                try? "".write(to: fileURL, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        }
        log("Logs cleared", level: .info)
    }

    nonisolated static func sanitizedDiagnosticExport(_ text: String) -> String {
        sanitizeLogContentForExport(sanitizeDiagnosticText(text))
    }

    nonisolated static func sanitizeLogContentForExport(_ content: String) -> String {
        LogSanitizer.sanitizeLogContentForExport(content)
    }

    func exportLogs() async throws -> URL {
        let fileURL = logFileURL

        // Serialize the export behind pending file writes. log() updates the
        // in-memory array immediately but persists on fileQueue, so reading the
        // file without draining that queue can export a stale snapshot.
        await withCheckedContinuation { continuation in
            fileQueue.async {
                continuation.resume()
            }
        }

        return try await Task.detached(priority: .userInitiated) { [fileURL] () -> URL in
            let fileManager = FileManager.default
            // One fixed name: each export replaces the last instead of
            // leaving another copy of the log in the temporary folder.
            let exportFilename = "Siphon_Exported_Logs.log"
            let exportURL = (UITestLaunchMode.root ?? fileManager.temporaryDirectory).appendingPathComponent(exportFilename)

            let rawData: Data
            if let handle = try? FileHandle(forReadingFrom: fileURL) {
                defer { try? handle.close() }
                rawData = (try? handle.readToEnd()) ?? Data()
            } else {
                rawData = (try? Data(contentsOf: fileURL)) ?? Data()
            }

            let rawContent = String(decoding: rawData, as: UTF8.self)
            let sanitized = Self.sanitizeLogContentForExport(rawContent)
            guard let data = sanitized.data(using: .utf8) else {
                throw NSError(domain: "LoggerService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode sanitized logs"])
            }

            if !fileManager.createFile(atPath: exportURL.path, contents: data, attributes: [.posixPermissions: 0o600]) {
                try sanitized.write(to: exportURL, atomically: true, encoding: .utf8)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exportURL.path)
            }

            return exportURL
        }.value
    }

    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case command = "CMD"

        fileprivate var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info, .command: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }

    /// Hands log lines from SiphonCore to the app's logger.
    nonisolated static let coreSink: CoreLogSink = { message, level in
        let mapped: LogLevel
        if level == .error {
            mapped = .error
        } else if level == .warning {
            mapped = .warning
        } else {
            mapped = .info
        }
        Task { @MainActor in LoggerService.shared.log(message, level: mapped) }
    }

    enum LogCategory: String {
        case downloads, network, subprocess, update, recovery, general
        case interface = "ui"
    }
}
