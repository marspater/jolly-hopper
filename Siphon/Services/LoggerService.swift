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

    // Bolt Performance Optimization: Reuse static compiled regexes to prevent compilation overhead on every log entry
    private static let urlSanitizeRegex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [])
    private static let redactionRegexes: [(NSRegularExpression, String)] = [
        (#"(?i)bearer\s+[A-Za-z0-9\-_\.]+"#, "Bearer <REDACTED>"),
        (#"(?i)authorization:\s*[^\r\n]+"#, "Authorization: <REDACTED>"),
        (#"(?i)cookie:\s*[^\r\n]+"#, "Cookie: <REDACTED>"),
        (#"(?i)(token|api_key|password|pass|secret|auth|signature|sig|access_token)=([A-Za-z0-9\-_%]+)"#, "$1=<REDACTED>")
    ].compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        return (regex, template)
    }
    
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
            "--http-header": "\"<REDACTED_HEADER>\"",
            "-H": "\"<REDACTED_HEADER>\"",
            "--username": "\"<USERNAME>\"",
            "-u": "\"<USERNAME>\"",
            "--password": "\"<PASSWORD>\"",
            "-p": "\"<PASSWORD>\"",
            "--video-password": "\"<PASSWORD>\"",
            "--ap-username": "\"<USERNAME>\"",
            "--ap-password": "\"<PASSWORD>\"",
            "--token": "\"<TOKEN>\"",
            "--api-key": "\"<API_KEY>\"",
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

            // Check --flag=value syntax
            var handledInline = false
            for (flag, placeholder) in sensitiveValueFlags {
                if arg.hasPrefix(flag + "=") {
                    sanitizedArgs.append("\(flag)=\(placeholder)")
                    handledInline = true
                    break
                }
            }
            if handledInline { continue }

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
        
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.logFileURL = appSupport.appendingPathComponent("siphon_debug.log")
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
        }
        
        loadInitialLogs()
    }
    
    private func loadInitialLogs() {
        let fileURL = logFileURL
        let maxEntries = maxLogEntries
        Task.detached {
            guard let handle = FileHandle(forReadingAtPath: fileURL.path) else { return }
            defer { try? handle.close() }
            
            let fileSize = (try? handle.seekToEnd()) ?? 0
            guard fileSize > 0 else { return }

            let readSize = min(fileSize, 256 * 1024)
            let seekPos = fileSize - readSize
            try? handle.seek(toOffset: seekPos)
            let data = handle.readData(ofLength: Int(readSize))
            guard !data.isEmpty else { return }

            let initialLogs = Self.extractTailLines(from: data, maxEntries: maxEntries)
            await MainActor.run {
                self.logs = initialLogs
            }
        }
    }

    nonisolated private static func extractTailLines(from data: Data, maxEntries: Int) -> [String] {
        guard !data.isEmpty else { return [] }
        var lineStarts: [Int] = [0]
        for (i, byte) in data.enumerated() {
            if byte == 0x0A && i + 1 < data.count {
                lineStarts.append(i + 1)
            }
        }

        let neededStarts = lineStarts.suffix(maxEntries + 1)
        var result: [String] = []
        result.reserveCapacity(min(maxEntries, neededStarts.count))

        for idx in neededStarts {
            let nextNewline = data[idx...].firstIndex(of: 0x0A) ?? data.endIndex
            if idx < nextNewline {
                let slice = data[idx..<nextNewline]
                let line = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    result.append(line)
                }
            }
        }
        return Array(result.suffix(maxEntries))
    }

    nonisolated static func sanitizeDiagnosticText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        // 1. Sanitize URLs (strip query strings, fragments, credentials)
        if let urlRegex = urlSanitizeRegex {
            let nsString = result as NSString
            let matches = urlRegex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let urlStr = nsString.substring(with: match.range)
                let sanitizedURL = sanitizeURLForLog(urlStr)
                if let swiftRange = Range(match.range, in: result) {
                    result.replaceSubrange(swiftRange, with: sanitizedURL)
                }
            }
        }

        // 2. Redact Bearer / API tokens and credentials
        for (regex, replacement) in redactionRegexes {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: replacement)
        }

        return result
    }

    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = Self.dateFormatter.string(from: Date())
        let sanitizedMessage = Self.sanitizeDiagnosticText(message)
        let entry = "[\(timestamp)] [\(level.rawValue)] \(sanitizedMessage)"
        
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
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
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
            let data = handle.readData(ofLength: Int(readSize))
            guard !data.isEmpty else { return }

            let lines = extractTailLines(from: data, maxEntries: maxEntries)
            guard !lines.isEmpty else { return }
            let trimmed = lines.joined(separator: "\n") + "\n"
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
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case command = "CMD"
    }
}
