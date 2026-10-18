//
//  CookieManager.swift
//  Siphon
//

import Foundation

/// Cookie temp-directory storage and orphaned file sweeps.
public enum CookieManager {
    private static func log(_ message: String, level: LoggerService.LogLevel) {
        Task { @MainActor in
            LoggerService.shared.log(message, level: level)
        }
    }

    private static var rootDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("siphon_cookies")
    }

    /// Directory used for temporary cookie files with strict 0o700 folder permissions.
    /// The app is unsandboxed, so every Siphon process of this user (installed and dev
    /// builds, other bundle IDs, the test host) shares $TMPDIR. Each process writes only
    /// into its own session directory, so another instance's purge cannot delete its files.
    public static func getSecureTempCookiesDirectory() -> URL? {
        guard let root = secureDirectory(rootDirectory) else { return nil }
        return secureDirectory(root.appendingPathComponent("session-\(getpid())"))
    }

    private static func secureDirectory(_ cookiesDir: URL) -> URL? {
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

    /// Sweeps and removes any orphaned temporary cookie files left behind from crashes or SIGKILL.
    public static func purgeOrphanedTempCookieFiles() {
        let fileManager = FileManager.default
        let root = secureDirectory(rootDirectory)
        let tempDirsToClean: [URL] = [
            FileManager.default.temporaryDirectory,
            root,
            getSecureTempCookiesDirectory()
        ].compactMap { $0 }

        for dir in tempDirsToClean {
            guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let name = file.lastPathComponent
                if name.hasPrefix("siphon_consolidated_cookies_") || name.hasPrefix("siphon_cookies_") || name.hasPrefix("siphon_header_cookies_") {
                    do {
                        try fileManager.removeItem(at: file)
                    } catch {
                        log("Failed to remove orphaned temporary cookie file: \(error.localizedDescription)", level: .warning)
                    }
                }
            }
        }

        // Sessions of Siphon processes that are gone (crash, SIGKILL). A live one belongs
        // to another running instance and is left alone.
        guard let root, let sessions = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for session in sessions {
            let name = session.lastPathComponent
            guard name.hasPrefix("session-"), let pid = pid_t(name.dropFirst("session-".count)),
                  pid > 0, pid != getpid() else { continue }
            // ponytail: liveness is by PID only, so a reused PID keeps a stale session until
            // that process exits; add a launch token to the directory name if that matters.
            if kill(pid, 0) == 0 || errno == EPERM { continue }
            do {
                try fileManager.removeItem(at: session)
            } catch {
                log("Failed to remove orphaned cookie session directory: \(error.localizedDescription)", level: .warning)
            }
        }
    }
}
