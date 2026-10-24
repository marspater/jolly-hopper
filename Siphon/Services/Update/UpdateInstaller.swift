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
    // Serialize startup pruning with bundle swaps in this process.
    private static let bundleMaintenanceLock = NSLock()

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
        allowAdHoc: Bool = true,
        expectedVersion: String? = nil
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
                    try Self.unmountDMG(mountPoint: mountPoint)
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
                try Self.unmountDMG(mountPoint: mountPoint)
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
                allowAdHoc: allowAdHoc,
                expectedVersion: expectedVersion
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

    /// Returns true once pruning is scheduled; overlapping app instances must exit first.
    @MainActor
    static func pruneRecoveryBackupsOnLaunch() -> Bool {
        guard !NotificationService.isRunningTests,
              let identifier = Bundle.main.bundleIdentifier,
              !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
                  !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
              }) else { return false }
        let appURL = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            do {
                try Self.pruneRecoveryBackups(nextTo: appURL)
            } catch {
                Self.log("Updater backup cleanup failed: \(error.localizedDescription)", level: .warning)
            }
        }
        return true
    }

    static func pruneRecoveryBackups(nextTo appURL: URL, fileManager: FileManager = .default) throws {
        bundleMaintenanceLock.lock()
        defer { bundleMaintenanceLock.unlock() }
        guard let identifier = Bundle(url: appURL)?.bundleIdentifier else { return }
        let prefix = ".Siphon_Backup_"
        let entries = try fileManager.contentsOfDirectory(at: appURL.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
        var backups: [(url: URL, date: Date)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".app"),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  entry.standardizedFileURL != appURL.standardizedFileURL,
                  Bundle(url: entry)?.bundleIdentifier == identifier else { continue }
            backups.append((entry, values.contentModificationDate ?? .distantPast))
        }
        backups.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        for backup in backups.dropFirst() {
            try fileManager.removeItem(at: backup.url)
        }
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
        bundleMaintenanceLock.lock()
        defer { bundleMaintenanceLock.unlock() }
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
                preserveBackup = true
                // Bundle dates otherwise describe the old installation, not retention order.
                do {
                    try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: backupURL.path)
                } catch {
                    Self.log("Could not date the recovery bundle: \(error.localizedDescription)", level: .warning)
                }
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

    private static let hdiutilURL = URL(fileURLWithPath: NSString.path(withComponents: ["/", "usr", "bin", "hdiutil"]))

    private func mountDMG(dmgURL: URL) throws -> String {
        let process = Process()
        process.executableURL = Self.hdiutilURL
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

    /// Detaches update images that a crashed install left mounted. Only images
    /// staged by `UpdateDownloader` in this user's temporary folder match.
    static func detachStaleUpdateImages() {
        let process = Process()
        process.executableURL = Self.hdiutilURL
        process.arguments = ["info", "-plist"]
        process.environment = YtdlpService.createSanitizedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("Siphon_Update_").path
        for mountPoint in staleUpdateMountPoints(hdiutilInfo: data, stagedPrefix: staged) {
            do {
                try unmountDMG(mountPoint: mountPoint)
                log("Detached a stale update disk image left by an interrupted install.", level: .info)
            } catch {
                log("Could not detach stale update disk image: \(error.localizedDescription)", level: .warning)
            }
        }
    }

    static func staleUpdateMountPoints(hdiutilInfo: Data, stagedPrefix: String) -> [String] {
        // hdiutil reports /private/var/...; the temporary directory URL may omit /private.
        func normalized(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path }
        guard let plist = try? PropertyListSerialization.propertyList(from: hdiutilInfo, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        let prefix = normalized(stagedPrefix)
        return images
            .filter { normalized($0["image-path"] as? String ?? "").hasPrefix(prefix) }
            .flatMap { ($0["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String } }
    }

    private static func unmountDMG(mountPoint: String) throws {
        let process = Process()
        process.executableURL = Self.hdiutilURL
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
        process.arguments = ["-xk", "--", zipURL.path, destinationDir.path]
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

    /// Opens the app again only after this process has exited, so the new
    /// instance never reads history or queue recovery state that this
    /// instance's termination is still writing. `prepare` runs only once the
    /// relaunch is armed, right before termination.
    @preconcurrency @MainActor
    public static func restartApp(prepare: @MainActor () -> Void) {
        do {
            try relaunchProcess(appURL: Bundle.main.bundleURL,
                                waitingFor: ProcessInfo.processInfo.processIdentifier).run()
        } catch {
            LoggerService.shared.log("Failed to restart application: \(error.localizedDescription)", level: .error)
            return
        }
        prepare()
        NSApp.terminate(nil)
    }

    /// The system Bourne shell from `<paths.h>`.
    static let relaunchShellURL = URL(fileURLWithPath: _PATH_BSHELL)

    static func relaunchProcess(appURL: URL, waitingFor pid: Int32, shell: URL = relaunchShellURL) -> Process {
        let process = Process()
        process.executableURL = shell
        // Paths and the PID are passed as arguments, never interpolated into the script.
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -n \"$0\"",
                             appURL.path, String(pid)]
        return process
    }
}
