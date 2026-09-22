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

    // Bolt Performance Optimization: Pre-compile regular expressions to eliminate
    // regex compilation and allocation overhead on every log and diagnostic text call.
    nonisolated private static let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [])
    nonisolated private static let redactionRegexes: [(NSRegularExpression, String)] = [
        (#"(?i)bearer\s+[A-Za-z0-9\-_\.]+"#, "Bearer <REDACTED>"),
        (#"(?i)authorization:\s*[^\r\n]+"#, "Authorization: <REDACTED>"),
        (#"(?i)cookie:\s*[^\r\n]+"#, "Cookie: <REDACTED>"),
        (#"(?i)set-cookie:\s*[^\r\n]+"#, "Set-Cookie: <REDACTED>"),
        (#"(?i)(x-[a-z0-9\-]*api-key|x-[a-z0-9\-]*token|x-[a-z0-9\-]*auth[a-z0-9\-]*):\s*[^\r\n]+"#, "$1: <REDACTED>"),
        (#"(?i)(token|api_key|password|pass|secret|auth|signature|sig|access_token|session|sessionid|sess|jwt|key|apikey|private_key|client_secret|pcode|oauth_token)=([^\s&"'<>]+)"#, "$1=<REDACTED>"),
        (#"(?i)("|\')(token|api_key|password|pass|secret|auth|signature|sig|access_token|session|sessionid|sess|jwt|key|apikey|private_key|client_secret|pcode|oauth_token)("|\')\s*:\s*("|\')[^"']+\1"#, "$1$2$3: $4<REDACTED>$1")
    ].compactMap { pattern, replacement in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        return (regex, replacement)
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
            "--add-headers": "\"<REDACTED_HEADER>\"",
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
            "--proxy": "\"<PROXY_REDACTED>\"",
            "--ffmpeg-location": "\"<LOCATION_REDACTED>\"",
            "--netrc-cmd": "\"<COMMAND_REDACTED>\"",
            "--exec": "\"<EXEC_REDACTED>\"",
            "--postprocessor-args": "\"<ARGS_REDACTED>\"",
            "--downloader-args": "\"<ARGS_REDACTED>\"",
            "--external-downloader-args": "\"<ARGS_REDACTED>\""
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

    nonisolated static func extractTailLines(from data: Data, maxEntries: Int) -> [String] {
        guard !data.isEmpty else { return [] }
        let count = data.count
        var lineStarts: [Int] = [0]
        for i in 0..<count {
            if data[i] == 0x0A && i + 1 < count {
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
        if let urlRegex = Self.urlRegex {
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

        // 2. Redact Bearer / API tokens and credentials using pre-compiled regexes
        for (regex, replacement) in Self.redactionRegexes {
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
            let data = handle.readData(ofLength: Int(readSize))
            guard !data.isEmpty else { return }

            let lines = extractTailLines(from: data, maxEntries: maxEntries)
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
    
    nonisolated static func sanitizeLogContentForExport(_ content: String) -> String {
        var sanitized = content
        
        // 1. Redact Bearer / Basic / Token authorization headers
        let authRegex = try? NSRegularExpression(pattern: "(?i)(Authorization:\\s*(?:Bearer|Basic|Token)\\s+)[A-Za-z0-9._~+/=-]+", options: [])
        if let regex = authRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "$1<REDACTED_AUTH>")
        }
        
        // 2. Redact cookie headers or cookie parameter lines
        let cookieHeaderRegex = try? NSRegularExpression(pattern: "(?i)(Cookie:\\s*)[^\r\n]+", options: [])
        if let regex = cookieHeaderRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "$1<REDACTED_COOKIES>")
        }
        
        // 3. Redact common query secrets in URLs
        let secretQueryRegex = try? NSRegularExpression(pattern: "(?i)([?&](?:token|auth|key|api_key|password|secret|sig|signature)=)[^&\\s\\r\\n]+", options: [])
        if let regex = secretQueryRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "$1<REDACTED>")
        }
        
        // 4. Redact username from /Users/<username>/
        let homeDirRegex = try? NSRegularExpression(pattern: "/Users/([a-zA-Z0-9._-]+)/", options: [])
        if let regex = homeDirRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "/Users/<USER>/")
        }
        
        return sanitized
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
            let fm = FileManager.default
            let exportFilename = "Siphon_Exported_Logs_\(Int(Date().timeIntervalSince1970)).log"
            let exportURL = fm.temporaryDirectory.appendingPathComponent(exportFilename)

            let rawContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let sanitized = Self.sanitizeLogContentForExport(rawContent)
            guard let data = sanitized.data(using: .utf8) else {
                throw NSError(domain: "LoggerService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode sanitized logs"])
            }

            if !fm.createFile(atPath: exportURL.path, contents: data, attributes: [.posixPermissions: 0o600]) {
                try sanitized.write(to: exportURL, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exportURL.path)
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
    }
}
