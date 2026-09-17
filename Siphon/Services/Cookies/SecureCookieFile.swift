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

        try? FileManager.default.removeItem(at: fileURL)
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
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw SecureCookieError.fileNotFound(fileURL)
        }

        let attrs = try fm.attributesOfItem(atPath: fileURL.path)
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            throw SecureCookieError.notARegularFile(fileURL)
        }

        if let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue {
            // Group and others must have 0 access (e.g. 0o600 or 0o700)
            if (perm & 0o077) != 0 {
                throw SecureCookieError.insecurePermissions(fileURL, perm)
            }
        }

        guard let fileSize = attrs[.size] as? NSNumber, fileSize.intValue > 0 else {
            throw SecureCookieError.emptyFile(fileURL)
        }

        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw SecureCookieError.fileNotFound(fileURL)
        }
        defer { try? handle.close() }

        let headerData = handle.readData(ofLength: 64)
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

        var netscapeLine: String {
            "\(domain)\t\(includeSubdomains ? "TRUE" : "FALSE")\t\(path)\t\(isSecure ? "TRUE" : "FALSE")\t\(expiry)\t\(name)\t\(value)"
        }
    }

    private static func sanitizeCookieToken(_ token: String) -> String {
        return token.replacingOccurrences(of: "\t", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\0", with: "")
    }

    /// Creates and validates a new `SecureCookieFile` with 0o600 permissions.
    public static func create(
        url: String,
        rawCookies: String? = nil,
        additionalCookies: [(name: String, value: String)] = [],
        additionalNetscapeLines: [String] = []
    ) throws -> SecureCookieFile {
        guard let urlObj = URL(string: url), let host = urlObj.host, !host.isEmpty else {
            throw SecureCookieError.creationFailed("Invalid URL or host: \(url)")
        }
        guard let cookiesDir = CookieManager.getSecureTempCookiesDirectory() else {
            throw SecureCookieError.creationFailed("Could not access secure cookies directory")
        }

        let defaultDomain = host.hasPrefix(".") ? host : ".\(host)"
        let tempCookiesURL = cookiesDir.appendingPathComponent("siphon_consolidated_cookies_\(UUID().uuidString).txt")
        let defaultExpiry = Int(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970)

        var domains: [String] = [defaultDomain]
        let lowerHost = host.lowercased()
        if lowerHost.hasPrefix("www.") {
            domains.append(".\(lowerHost.dropFirst(4))")
        }
        var seenDomains = Set<String>()
        let uniqueDomains = domains.filter { seenDomains.insert($0).inserted }

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
                        for d in uniqueDomains {
                            let mapKey = CookieKey(domain: d.lowercased(), path: "/", name: key)
                            cookieMap[mapKey] = CookieEntry(
                                domain: d,
                                includeSubdomains: true,
                                path: "/",
                                isSecure: false,
                                expiry: defaultExpiry,
                                name: key,
                                value: value
                            )
                        }
                    }
                }
            }
        }

        // 2. Process additional Netscape lines
        for line in additionalNetscapeLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }
            let columns = trimmed.components(separatedBy: "\t")
            if columns.count >= 7 {
                let domain = sanitizeCookieToken(columns[0])
                let includeSub = columns[1].uppercased() == "TRUE"
                let path = sanitizeCookieToken(columns[2])
                let isSec = columns[3].uppercased() == "TRUE"
                let exp = Int(columns[4]) ?? defaultExpiry
                let name = sanitizeCookieToken(columns[5])
                let val = sanitizeCookieToken(columns[6])
                if !name.isEmpty && !val.isEmpty {
                    let mapKey = CookieKey(domain: domain.lowercased(), path: path.isEmpty ? "/" : path, name: name)
                    cookieMap[mapKey] = CookieEntry(
                        domain: domain,
                        includeSubdomains: includeSub,
                        path: path.isEmpty ? "/" : path,
                        isSecure: isSec,
                        expiry: exp,
                        name: name,
                        value: val
                    )
                }
            }
        }

        // 3. Process additionalCookies (e.g. Sucuri or dynamically extracted tokens)
        for cookie in additionalCookies {
            let key = sanitizeCookieToken(cookie.name.trimmingCharacters(in: .whitespacesAndNewlines))
            let value = sanitizeCookieToken(cookie.value.trimmingCharacters(in: .whitespacesAndNewlines))
            if !key.isEmpty && !value.isEmpty {
                let mapKey = CookieKey(domain: defaultDomain.lowercased(), path: "/", name: key)
                cookieMap[mapKey] = CookieEntry(
                    domain: defaultDomain,
                    includeSubdomains: true,
                    path: "/",
                    isSecure: false,
                    expiry: defaultExpiry,
                    name: key,
                    value: value
                )
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

    /// Scoped block execution guaranteeing file cleanup on completion, error, or cancellation.
    public static func scoped<T: Sendable>(
        url: String,
        rawCookies: String? = nil,
        additionalCookies: [(name: String, value: String)] = [],
        additionalNetscapeLines: [String] = [],
        _ body: (SecureCookieFile) async throws -> T
    ) async throws -> T {
        let cookieFile = try create(
            url: url,
            rawCookies: rawCookies,
            additionalCookies: additionalCookies,
            additionalNetscapeLines: additionalNetscapeLines
        )
        defer {
            cookieFile.cleanup()
        }
        return try await body(cookieFile)
    }
}
