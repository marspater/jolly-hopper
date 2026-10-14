//
//  UpdateInstaller.swift
//  Siphon
//

import Foundation
import AppKit
import Darwin

public enum UpdateInstallError: LocalizedError, Sendable {
    case packageNotFound(URL)
    case mountFailed(String)
    case unmountFailed(String)
    case appNotFoundInPackage
    case extractionFailed(String)
    case verificationFailed(String)
    case replacementFailed(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .packageNotFound(let url):
            return "Downloaded package not found at: \(url.path)"
        case .mountFailed(let msg):
            return "Failed to mount disk image: \(msg)"
        case .unmountFailed(let msg):
            return "Failed to unmount disk image: \(msg)"
        case .appNotFoundInPackage:
            return "No .app bundle found inside downloaded package"
        case .extractionFailed(let msg):
            return "Failed to extract package: \(msg)"
        case .verificationFailed(let msg):
            return "Verification failed for staged app: \(msg)"
        case .replacementFailed(let msg):
            return "Failed to replace application bundle: \(msg)"
        case .rollbackFailed(let msg):
            return "Rollback failed after installation error: \(msg)"
        }
    }
}

public final class UpdateInstaller: Sendable {
    public init() {
        // Intentionally empty initializer for class instantiation (swift:S1186)
    }

    private static func log(_ message: String, level: LoggerService.LogLevel) {
        Task { @MainActor in
            LoggerService.shared.log(message, level: level)
        }
    }

    /// Installs a downloaded package file (.dmg, .zip, or .app) into the running application bundle location.
    /// Swift owns staging, verification, atomic exchange, rollback, and relaunch.
    public func install(
        packageURL: URL,
        expectedChecksum: String? = nil,
        expectedTeamID: String? = nil,
        allowAdHoc: Bool = true
    ) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw UpdateInstallError.packageNotFound(packageURL)
        }

        // Ad-hoc/open-source releases have no Developer ID identity to pin.
        // In that mode the package digest is the mandatory trust anchor.
        if allowAdHoc && expectedTeamID == nil {
            guard let checksum = expectedChecksum, !checksum.isEmpty else {
                throw UpdateInstallError.verificationFailed(
                    "Ad-hoc updates require a pinned SHA-256 checksum."
                )
            }
        }

        // 1. Verify SHA-256 of package if expected checksum was provided
        if let checksum = expectedChecksum, !checksum.isEmpty {
            do {
                try UpdateVerifier.verifySHA256(fileURL: packageURL, expectedChecksum: checksum)
            } catch {
                throw UpdateInstallError.verificationFailed("Package checksum verification failed: \(error.localizedDescription)")
            }
        }

        // 2. Prepare staging directory
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("Siphon_Install_\(UUID().uuidString)")
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            for cleanupURL in [stagingDir, packageURL] where fileManager.fileExists(atPath: cleanupURL.path) {
                do {
                    try fileManager.removeItem(at: cleanupURL)
                } catch {
                    Self.log("Updater cleanup failed for \(cleanupURL.lastPathComponent): \(error.localizedDescription)", level: .warning)
                }
            }
        }

        // 3. Extract or mount package to locate .app
        var mountedMountPoint: String?
        defer {
            if let mountPoint = mountedMountPoint {
                do {
                    try unmountDMG(mountPoint: mountPoint)
                } catch {
                    Self.log("Failed to unmount update disk image during cleanup: \(error.localizedDescription)", level: .warning)
                }
            }
        }

        let stagedAppURL: URL
        let ext = packageURL.pathExtension.lowercased()

        if ext == "dmg" {
            let mountPoint = try mountDMG(dmgURL: packageURL)
            mountedMountPoint = mountPoint
            let mountURL = URL(fileURLWithPath: mountPoint)
            guard let appInMount = locateAppBundle(in: mountURL) else {
                throw UpdateInstallError.appNotFoundInPackage
            }
            // Copy .app out of read-only mount point into writeable staging dir
            let targetStagedApp = stagingDir.appendingPathComponent(appInMount.lastPathComponent)
            try fileManager.copyItem(at: appInMount, to: targetStagedApp)
            stagedAppURL = targetStagedApp

            // Unmount DMG now that it's copied to staging. If it fails, keep the
            // mount point registered so the defer above retries cleanup.
            do {
                try unmountDMG(mountPoint: mountPoint)
                mountedMountPoint = nil
            } catch {
                Self.log("Could not unmount update disk image after staging: \(error.localizedDescription)", level: .warning)
            }
        } else if ext == "zip" {
            try extractZip(zipURL: packageURL, destinationDir: stagingDir)
            guard let appInStaging = locateAppBundle(in: stagingDir) else {
                throw UpdateInstallError.appNotFoundInPackage
            }
            stagedAppURL = appInStaging
        } else if ext == "app" {
            let targetStagedApp = stagingDir.appendingPathComponent(packageURL.lastPathComponent)
            try fileManager.copyItem(at: packageURL, to: targetStagedApp)
            stagedAppURL = targetStagedApp
        } else {
            throw UpdateInstallError.extractionFailed("Unsupported package extension: .\(ext)")
        }

        // 4. Verify staged app bundle
        do {
            try UpdateVerifier.verifyAppBundle(
                bundleURL: stagedAppURL,
                expectedTeamID: expectedTeamID,
                allowAdHoc: allowAdHoc
            )
        } catch {
            throw UpdateInstallError.verificationFailed(error.localizedDescription)
        }

        // 5. Prepare a verified sibling and atomically exchange it with the current app.
        let currentAppURL = Bundle.main.bundleURL
        try Self.replaceAppBundle(
            currentAppURL: currentAppURL,
            stagedAppURL: stagedAppURL,
            expectedTeamID: expectedTeamID,
            allowAdHoc: allowAdHoc,
            fileManager: fileManager
        )
    }

    /// Copies and verifies a complete sibling before atomically exchanging the
    /// two names. At interruption the installed path contains the old or new
    /// complete bundle; the other bundle remains at the sibling backup path.
    public static func replaceAppBundle(
        currentAppURL: URL,
        stagedAppURL: URL,
        expectedTeamID: String? = nil,
        allowAdHoc: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        try replaceVerifiedAppBundle(currentAppURL: currentAppURL, stagedAppURL: stagedAppURL, fileManager: fileManager,
                                     retainBackup: currentAppURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL) { bundleURL in
            try UpdateVerifier.verifyAppBundle(
                bundleURL: bundleURL,
                expectedTeamID: expectedTeamID,
                allowAdHoc: allowAdHoc
            )
        }
    }

    /// Internal seams allow filesystem/verification failure tests without
    /// weakening the production verifier or requiring signed fixture apps.
    static func replaceVerifiedAppBundle(
        currentAppURL: URL,
        stagedAppURL: URL,
        fileManager: FileManager = .default,
        retainBackup: Bool = false,
        exchange: (URL, URL) throws -> Void = exchangeAppBundles,
        verify: (URL) throws -> Void
    ) throws {
        let backupURL = currentAppURL.deletingLastPathComponent().appendingPathComponent(".Siphon_Backup_\(UUID().uuidString).app")
        var exchanged = false
        var preserveBackup = false
        defer {
            if !preserveBackup && fileManager.fileExists(atPath: backupURL.path) {
                do {
                    try fileManager.removeItem(at: backupURL)
                } catch {
                    Self.log("Updater could not remove temporary bundle \(backupURL.lastPathComponent): \(error.localizedDescription)", level: .warning)
                }
            }
        }

        do {
            // Copy on the destination filesystem, leaving the installed app
            // intact throughout staging and verification.
            try fileManager.copyItem(at: stagedAppURL, to: backupURL)
            try verify(backupURL)
            try exchange(currentAppURL, backupURL)
            exchanged = true
            try verify(currentAppURL)
            if retainBackup {
                // ponytail: keep one recovery bundle per update; prune on a later launch if disk use warrants it.
                preserveBackup = true
                Self.log("Previous app bundle retained for restart/recovery at \(backupURL.path).", level: .info)
            }
        } catch {
            let replacementError = error
            if exchanged {
                do {
                    // Rollback is also a single exchange, never delete+move.
                    try exchange(currentAppURL, backupURL)
                } catch {
                    preserveBackup = true
                    throw UpdateInstallError.rollbackFailed(
                        "Replacement failed: \(replacementError.localizedDescription). Rollback failed: \(error.localizedDescription). Original bundle retained at \(backupURL.path)."
                    )
                }
            }
            throw UpdateInstallError.replacementFailed("Failed to replace application: \(replacementError.localizedDescription)")
        }
    }

    static func exchangeAppBundles(_ currentAppURL: URL, _ replacementURL: URL) throws {
        let result = currentAppURL.withUnsafeFileSystemRepresentation { currentPath in
            replacementURL.withUnsafeFileSystemRepresentation { replacementPath in
                renameatx_np(AT_FDCWD, currentPath, AT_FDCWD, replacementPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: - Mount & Extraction Helpers

    private func mountDMG(dmgURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]
        process.environment = YtdlpService.createSanitizedEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Read before waiting: a child blocked on a full pipe never exits.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.mountFailed("hdiutil attach exited with status \(process.terminationStatus)")
        }

        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    return mountPoint
                }
            }
        }

        // Fallback text parsing if plist did not contain mount-point
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.split(whereSeparator: \.isNewline)
            for line in lines {
                if let match = line.range(of: "/Volumes/.*", options: .regularExpression) {
                    return String(line[match]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        throw UpdateInstallError.mountFailed("Could not determine mount point from hdiutil output")
    }

    private func unmountDMG(mountPoint: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-force"]
        process.environment = YtdlpService.createSanitizedEnvironment()
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let details = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let details, !details.isEmpty {
                throw UpdateInstallError.unmountFailed(details)
            }
            throw UpdateInstallError.unmountFailed("hdiutil detach exited with status \(process.terminationStatus)")
        }
    }

    private func extractZip(zipURL: URL, destinationDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, destinationDir.path]
        process.environment = YtdlpService.createSanitizedEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.extractionFailed("ditto extraction exited with status \(process.terminationStatus)")
        }
    }

    /// Finds the Siphon bundle by identifier, not the first `.app`: a package may
    /// also carry other apps (an uninstaller, a helper).
    public func locateAppBundle(in directory: URL, bundleID: String = UpdateVerifier.siphonBundleID) -> URL? {
        var visited = Set<String>()
        return locateAppBundle(in: directory, bundleID: bundleID, depth: 0, visited: &visited)
    }

    private static func isApp(_ app: URL, withBundleID bundleID: String) -> Bool {
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return UpdateVerifier.bundleIDsMatch(plist?["CFBundleIdentifier"] as? String, bundleID)
    }

    private func locateAppBundle(in directory: URL, bundleID: String, depth: Int, visited: inout Set<String>) -> URL? {
        guard depth <= 8 else { return nil }

        let candidate = directory.standardizedFileURL
        guard visited.insert(candidate.path).inserted, isDirectoryBundle(candidate) else {
            return nil
        }

        if candidate.pathExtension.lowercased() == "app" {
            return Self.isApp(candidate, withBundleID: bundleID) ? candidate : nil
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: candidate,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        if let matchingApp = findAppInContents(contents, bundleID: bundleID) {
            return matchingApp
        }

        for item in contents where isDirectoryBundle(item) {
            if let nested = locateAppBundle(in: item, bundleID: bundleID, depth: depth + 1, visited: &visited) {
                return nested
            }
        }
        return nil
    }

    private func isDirectoryBundle(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func findAppInContents(_ contents: [URL], bundleID: String) -> URL? {
        for item in contents where item.pathExtension.lowercased() == "app" {
            if isDirectoryBundle(item), Self.isApp(item, withBundleID: bundleID) {
                return item.standardizedFileURL
            }
        }
        return nil
    }

    // MARK: - Relaunch

    @MainActor
    public static func restartApp() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    LoggerService.shared.log("Failed to restart application: \(error.localizedDescription)", level: .error)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
