//
//  CookieManager.swift
//  Siphon
//

import Foundation

/// Actor coordinator for cookie file storage and orphaned file sweeps.
/// Does not strongly retain cookie file instances to prevent accidental lifetime extension.
public actor CookieManager {
    public static let shared = CookieManager()

    public init() {}

    /// Directory used for temporary cookie files with strict 0o700 folder permissions.
    public nonisolated static func getSecureTempCookiesDirectory() -> URL? {
        let cookiesDir = FileManager.default.temporaryDirectory.appendingPathComponent("siphon_cookies")
        let path = cookiesDir.path
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            do {
                try fileManager.createDirectory(at: cookiesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                return nil
            }
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        return cookiesDir
    }

    /// Creates and returns an isolated SecureCookieFile.
    public func createSecureCookieFile(
        url: String,
        rawCookies: String? = nil,
        additionalCookies: [(name: String, value: String)] = [],
        additionalNetscapeLines: [String] = []
    ) throws -> SecureCookieFile {
        return try SecureCookieFile.create(
            url: url,
            rawCookies: rawCookies,
            additionalCookies: additionalCookies,
            additionalNetscapeLines: additionalNetscapeLines
        )
    }

    /// Sweeps and removes any orphaned temporary cookie files left behind from crashes or SIGKILL.
    public nonisolated static func purgeOrphanedTempCookieFiles() {
        let fileManager = FileManager.default
        let tempDirsToClean: [URL] = [
            FileManager.default.temporaryDirectory,
            getSecureTempCookiesDirectory()
        ].compactMap { $0 }

        for dir in tempDirsToClean {
            guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let name = file.lastPathComponent
                if name.hasPrefix("siphon_consolidated_cookies_") || name.hasPrefix("siphon_cookies_") {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }

    /// Convenience instance method for purging orphaned files.
    public func purgeOrphanedFiles() {
        Self.purgeOrphanedTempCookieFiles()
    }
}
