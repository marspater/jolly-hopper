//
//  SecureCookieFile.swift
//  Siphon
//

import Foundation

public enum SecureCookieError: LocalizedError, Sendable {
    case fileNotFound(URL)
    case notARegularFile(URL)
    case insecurePermissions(URL, Int)
    case emptyFile(URL)
    case invalidFormat(URL)
    case creationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Cookie file does not exist at: \(url.path)"
        case .notARegularFile(let url):
            return "Cookie file is not a regular file (possible symlink or directory): \(url.path)"
        case .insecurePermissions(let url, let perm):
            return String(format: "Cookie file at %@ has insecure permissions: 0o%o (must be 0o600 or 0o700)", url.path, perm)
        case .emptyFile(let url):
            return "Cookie file is empty: \(url.path)"
        case .invalidFormat(let url):
            return "Cookie file at \(url.path) does not contain valid Netscape cookie header"
        case .creationFailed(let msg):
            return "Failed to create secure cookie file: \(msg)"
        }
    }
}

/// Owned resource representing a temporary Netscape-formatted cookie file.
/// Provides:
/// - Explicit lifecycle: create -> validate -> use -> cleanup
/// - Guaranteed scoped execution via `scoped(...)`
/// - Best-effort RAII cleanup on `deinit`
public final class SecureCookieFile: @unchecked Sendable {
    public let fileURL: URL
    public var path: String { fileURL.path }

    private let lock = NSLock()
    private var isCleanedUp: Bool = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    deinit {
        cleanup()
    }

    /// Explicitly unlinks the temporary file and marks the resource as cleaned up.
    public func cleanup() {
        lock.lock()
        guard !isCleanedUp else {
            lock.unlock()
            return
        }
        isCleanedUp = true
        lock.unlock()

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            let message = "Failed to remove temporary cookie file: \(error.localizedDescription)"
            Task { @MainActor in
                LoggerService.shared.log(message, level: .error)
            }
        }
    }

    /// Relinquishes ownership so that `deinit` will not delete the file.
    /// Returns the underlying file URL for manual caller management.
    @discardableResult
    public func detach() -> URL {
        lock.lock()
        isCleanedUp = true
        lock.unlock()
        return fileURL
    }

    /// Validates that the cookie file exists, is a regular file with restricted permissions,
    /// and contains a valid Netscape header.
    public func validate() throws {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw SecureCookieError.fileNotFound(fileURL)
        }

        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            throw SecureCookieError.notARegularFile(fileURL)
        }

        if let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue, (perm & 0o077) != 0 {
            // Group and others must have 0 access (e.g. 0o600 or 0o700)
            throw SecureCookieError.insecurePermissions(fileURL, perm)
        }

        guard let fileSize = attrs[.size] as? NSNumber, fileSize.intValue > 0 else {
            throw SecureCookieError.emptyFile(fileURL)
        }

        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw SecureCookieError.fileNotFound(fileURL)
        }
        defer { try? handle.close() }

        let headerData = (try? handle.read(upToCount: 64)) ?? Data()
        guard let headerStr = String(data: headerData, encoding: .utf8),
              headerStr.contains("# Netscape HTTP Cookie File") else {
            throw SecureCookieError.invalidFormat(fileURL)
        }
    }

    // MARK: - Factory & Scoped API

    private struct CookieKey: Hashable {
        let domain: String
        let path: String
        let name: String
    }

    private struct CookieEntry: Hashable {
        let domain: String
        let includeSubdomains: Bool
        let path: String
        let isSecure: Bool
        var expiry: Int
        let name: String
        var value: String
        var isHttpOnly = false

        var netscapeLine: String {
            (isHttpOnly ? "#HttpOnly_" : "") + "\(domain)\t\(includeSubdomains ? "TRUE" : "FALSE")\t\(path)\t\(isSecure ? "TRUE" : "FALSE")\t\(expiry)\t\(name)\t\(value)"
        }
    }

    // Bolt Performance Optimization: Short-circuit control character check using unicodeScalars to return clean tokens as-is without heap allocations while correctly handling combined CRLF (\r\n) grapheme clusters.
    private static func sanitizeCookieToken(_ token: String) -> String {
        guard token.unicodeScalars.contains(where: { $0.value == 0x09 || $0.value == 0x0A || $0.value == 0x0D || $0.value == 0x00 }) else {
            return token
        }
        return String(token.unicodeScalars.filter { $0.value != 0x09 && $0.value != 0x0A && $0.value != 0x0D && $0.value != 0x00 })
    }

    /// Cookies without scope metadata (raw Cookie header, extracted tokens) stay host-only:
    /// they never reach the parent domain or sibling subdomains.
    private static func hostOnlyCookie(
        host: String, name: String, value: String, isSecure: Bool, expiry: Int
    ) -> (key: CookieKey, entry: CookieEntry) {
        let key = CookieKey(domain: host.lowercased(), path: "/", name: name)
        let entry = CookieEntry(
            domain: host,
            includeSubdomains: false,
            path: "/",
            isSecure: isSecure,
            expiry: expiry,
            name: name,
            value: value
        )
        return (key, entry)
    }

    /// Creates and validates a new `SecureCookieFile` with 0o600 permissions.
    public static func create(
        url: String,
        rawCookies: String? = nil,
        additionalCookies: [(name: String, value: String)] = [],
        additionalNetscapeLines: [String] = []
    ) throws -> SecureCookieFile {
        guard let urlObj = URL(string: url), let rawHost = urlObj.host, !rawHost.isEmpty else {
            throw SecureCookieError.creationFailed("Invalid URL or host: \(url)")
        }
        let cleanHost = sanitizeCookieToken(rawHost)
        guard !cleanHost.isEmpty else {
            throw SecureCookieError.creationFailed("Invalid URL or host: \(url)")
        }
        guard let cookiesDir = CookieManager.getSecureTempCookiesDirectory() else {
            throw SecureCookieError.creationFailed("Could not access secure cookies directory")
        }

        let hostOnlyDomain = cleanHost.hasPrefix(".") ? String(cleanHost.dropFirst()) : cleanHost
        let requireSecureTransport = urlObj.scheme?.lowercased() == "https"
        let tempCookiesURL = cookiesDir.appendingPathComponent("siphon_consolidated_cookies_\(UUID().uuidString).txt")
        let defaultExpiry = Int(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970)

        var cookieMap: [CookieKey: CookieEntry] = [:]

        // 1. Process raw cookie header pairs
        if let raw = rawCookies, !raw.isEmpty {
            let pairs = raw.split(separator: ";")
            for pair in pairs {
                let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = sanitizeCookieToken(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
                    let value = sanitizeCookieToken(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    if !key.isEmpty && !value.isEmpty {
                        let hostOnly = Self.hostOnlyCookie(
                    host: hostOnlyDomain, name: key, value: value, isSecure: requireSecureTransport, expiry: defaultExpiry
                )
                cookieMap[hostOnly.key] = hostOnly.entry
                    }
                }
            }
        }

        // 2. Process additional Netscape lines
        // Bolt Performance Optimization: Use `split(separator: "\t", omittingEmptySubsequences: false)` over Substrings
        // to avoid allocating [String] column arrays for every Netscape line.
        for line in additionalNetscapeLines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Netscape HttpOnly cookies are prefixed `#HttpOnly_`; other `#` lines are comments.
            let isHttpOnly = trimmed.hasPrefix("#HttpOnly_")
            if isHttpOnly { trimmed.removeFirst("#HttpOnly_".count) }
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }
            let columns = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
            if columns.count >= 7 {
                let domain = sanitizeCookieToken(String(columns[0]))
                let includeSub = columns[1].uppercased() == "TRUE"
                let path = sanitizeCookieToken(String(columns[2]))
                let isSec = columns[3].uppercased() == "TRUE"
                let exp = Int(columns[4]) ?? defaultExpiry
                let name = sanitizeCookieToken(String(columns[5]))
                let val = sanitizeCookieToken(String(columns[6]))
                if !name.isEmpty && !val.isEmpty {
                    let mapKey = CookieKey(domain: domain.lowercased(), path: path.isEmpty ? "/" : path, name: name)
                    cookieMap[mapKey] = CookieEntry(
                        domain: domain,
                        includeSubdomains: includeSub,
                        path: path.isEmpty ? "/" : path,
                        isSecure: isSec,
                        expiry: exp,
                        name: name,
                        value: val,
                        isHttpOnly: isHttpOnly
                    )
                }
            }
        }

        // 3. Process additionalCookies (e.g. Sucuri or dynamically extracted tokens)
        for cookie in additionalCookies {
            let key = sanitizeCookieToken(cookie.name.trimmingCharacters(in: .whitespacesAndNewlines))
            let value = sanitizeCookieToken(cookie.value.trimmingCharacters(in: .whitespacesAndNewlines))
            if !key.isEmpty && !value.isEmpty {
                let hostOnly = Self.hostOnlyCookie(
                    host: hostOnlyDomain, name: key, value: value, isSecure: requireSecureTransport, expiry: defaultExpiry
                )
                cookieMap[hostOnly.key] = hostOnly.entry
            }
        }

        guard !cookieMap.isEmpty else {
            throw SecureCookieError.creationFailed("No valid cookies found to write")
        }

        let sortedEntries = cookieMap.values.sorted {
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.name < $1.name
        }

        var lines = ["# Netscape HTTP Cookie File"]
        for entry in sortedEntries {
            lines.append(entry.netscapeLine)
        }

        let content = lines.joined(separator: "\n") + "\n"
        guard let data = content.data(using: .utf8) else {
            throw SecureCookieError.creationFailed("Failed to encode cookie content to UTF-8")
        }

        if !FileManager.default.createFile(atPath: tempCookiesURL.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            throw SecureCookieError.creationFailed("Failed to write cookie file with 0o600 permissions at: \(tempCookiesURL.path)")
        }

        let file = SecureCookieFile(fileURL: tempCookiesURL)
        try file.validate()
        return file
    }
}
