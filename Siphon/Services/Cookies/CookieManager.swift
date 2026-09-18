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

    private nonisolated static func log(_ message: String, level: LoggerService.LogLevel) {
        Task { @MainActor in
            LoggerService.shared.log(message, level: level)
        }
    }

    /// Directory used for temporary cookie files with strict 0o700 folder permissions.
    public nonisolated static func getSecureTempCookiesDirectory() -> URL? {
        let cookiesDir = FileManager.default.temporaryDirectory.appendingPathComponent("siphon_cookies")
        let path = cookiesDir.path
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: path) {
                let values = try cookiesDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    log("Refusing insecure cookie temp path because it is not a real directory.", level: .error)
                    return nil
                }
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            } else {
                try fileManager.createDirectory(
                    at: cookiesDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }

            let attrs = try fileManager.attributesOfItem(atPath: path)
            guard (attrs[.type] as? FileAttributeType) == .typeDirectory else {
                log("Refusing cookie temp path because filesystem attributes do not identify a directory.", level: .error)
                return nil
            }
            if let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue,
               (permissions & 0o077) != 0 {
                log("Refusing cookie temp directory with permissions broader than the current user.", level: .error)
                return nil
            }
            return cookiesDir
        } catch {
            log("Could not prepare secure cookie temp directory: \(error.localizedDescription)", level: .error)
            return nil
        }
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
                    do {
                        try fileManager.removeItem(at: file)
                    } catch {
                        log("Failed to remove orphaned temporary cookie file: \(error.localizedDescription)", level: .warning)
                    }
                }
            }
        }
    }

    /// Convenience instance method for purging orphaned files.
    public func purgeOrphanedFiles() {
        Self.purgeOrphanedTempCookieFiles()
    }
}
