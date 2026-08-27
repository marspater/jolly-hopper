import Foundation
import SwiftUI

@MainActor
class LoggerService: ObservableObject {
    static let shared = LoggerService()
    
    @Published var logs: [String] = []
    private let logFileURL: URL
    private let maxLogEntries = 1000
    private let fileQueue = DispatchQueue(label: "com.siphon.loggerQueue", qos: .utility)
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    nonisolated static func sanitizeURLForLog(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        components?.user = nil
        components?.password = nil
        return components?.string ?? "\(url.scheme ?? "https")://\(url.host ?? "unknown")"
    }

    nonisolated static func sanitizeCommandForLog(_ args: [String]) -> String {
        var sanitizedArgs: [String] = []
        var skipNextForRedaction: String? = nil

        let sensitiveValueFlags: [String: String] = [
            "--cookies": "\"<COOKIE_FILE>\"",
            "--cookies-from-browser": "\"<BROWSER>\"",
            "--add-header": "\"<REDACTED_HEADER>\"",
            "--header": "\"<REDACTED_HEADER>\"",
            "--username": "\"<USERNAME>\"",
            "-u": "\"<USERNAME>\"",
            "--password": "\"<PASSWORD>\"",
            "-p": "\"<PASSWORD>\"",
            "--proxy": "\"<PROXY_REDACTED>\""
        ]

        for arg in args {
            if let redactionPlaceholder = skipNextForRedaction {
                sanitizedArgs.append(redactionPlaceholder)
                skipNextForRedaction = nil
                continue
            }

            if let placeholder = sensitiveValueFlags[arg] {
                sanitizedArgs.append(arg)
                skipNextForRedaction = placeholder
                continue
            }

            if arg.hasPrefix("http://") || arg.hasPrefix("https://") {
                let sanitized = sanitizeURLForLog(arg)
                sanitizedArgs.append(sanitized.contains(" ") ? "\"\(sanitized)\"" : sanitized)
                continue
            }

            if arg.contains(" ") {
                sanitizedArgs.append("\"\(arg)\"")
            } else {
                sanitizedArgs.append(arg)
            }
        }

        if let pending = skipNextForRedaction {
            sanitizedArgs.append(pending)
        }

        return sanitizedArgs.joined(separator: " ")
    }

    private init() {
        let appSupport = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("Siphon")
        
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.logFileURL = appSupport.appendingPathComponent("siphon_debug.log")
        
        loadInitialLogs()
    }
    
    private func loadInitialLogs() {
        let fileURL = logFileURL
        let maxEntries = maxLogEntries
        Task.detached {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let initialLogs = Array(lines.suffix(maxEntries))
            await MainActor.run {
                self.logs = initialLogs
            }
        }
    }
    
    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = Self.dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(level.rawValue)] \(message)"
        
        logs.append(entry)
        if logs.count > maxLogEntries {
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
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                try? fileHandle.close()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }
    
    nonisolated private static func trimLogFile(at logFileURL: URL, maxEntries: Int) {
        autoreleasepool {
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let trimmed = lines.suffix(maxEntries).joined(separator: "\n") + "\n"
            try? trimmed.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }
    
    func clearLogs() {
        logs.removeAll()
        let fileURL = logFileURL
        fileQueue.async {
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        log("Logs cleared", level: .info)
    }
    
    func exportLogs() -> URL {
        return logFileURL
    }
    
    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case command = "CMD"
    }
}
