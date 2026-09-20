//
//  UpdateInstaller.swift
//  Siphon
//

import Foundation
import AppKit

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
    /// Swift owns all lifecycle phases: stage -> mount -> locate -> verify -> backup -> replace -> rollback -> relaunch.
    public func install(
        packageURL: URL,
        expectedChecksum: String? = nil,
        expectedTeamID: String? = nil,
        allowAdHoc: Bool = true
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: packageURL.path) else {
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
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("Siphon_Install_\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            for cleanupURL in [stagingDir, packageURL] where fm.fileExists(atPath: cleanupURL.path) {
                do {
                    try fm.removeItem(at: cleanupURL)
                } catch {
                    Self.log("Updater cleanup failed for \(cleanupURL.lastPathComponent): \(error.localizedDescription)", level: .warning)
                }
            }
        }

        // 3. Extract or mount package to locate .app
        var mountedMountPoint: String? = nil
        defer {
            if let mp = mountedMountPoint {
                do {
                    try unmountDMG(mountPoint: mp)
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
            try fm.copyItem(at: appInMount, to: targetStagedApp)
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
            try fm.copyItem(at: packageURL, to: targetStagedApp)
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

        // 5. Backup current app and perform atomic replacement with verification and rollback
        let currentAppURL = Bundle.main.bundleURL
        try Self.replaceAppBundle(
            currentAppURL: currentAppURL,
            stagedAppURL: stagedAppURL,
            expectedTeamID: expectedTeamID,
            allowAdHoc: allowAdHoc,
            fileManager: fm
        )
    }

    /// Performs an atomic backup, replacement, post-copy bundle verification, and rollback if failed.
    public static func replaceAppBundle(
        currentAppURL: URL,
        stagedAppURL: URL,
        expectedTeamID: String? = nil,
        allowAdHoc: Bool = false,
        fileManager fm: FileManager = .default
    ) throws {
        let backupURL = currentAppURL.deletingLastPathComponent().appendingPathComponent(".Siphon_Backup_\(UUID().uuidString).app")
        var didMoveCurrentToBackup = false

        do {
            try fm.moveItem(at: currentAppURL, to: backupURL)
            didMoveCurrentToBackup = true

            try fm.copyItem(at: stagedAppURL, to: currentAppURL)

            try UpdateVerifier.verifyAppBundle(
                bundleURL: currentAppURL,
                expectedTeamID: expectedTeamID,
                allowAdHoc: allowAdHoc
            )

            if fm.fileExists(atPath: backupURL.path) {
                do {
                    try fm.removeItem(at: backupURL)
                } catch {
                    Self.log("Update installed, but the temporary backup could not be removed: \(error.localizedDescription)", level: .warning)
                }
            }
        } catch {
            let replacementError = error
            var rollbackFailures: [String] = []

            if didMoveCurrentToBackup {
                if fm.fileExists(atPath: currentAppURL.path) {
                    do {
                        try fm.removeItem(at: currentAppURL)
                    } catch {
                        rollbackFailures.append("could not remove failed replacement: \(error.localizedDescription)")
                    }
                }

                if fm.fileExists(atPath: backupURL.path) {
                    do {
                        try fm.moveItem(at: backupURL, to: currentAppURL)
                    } catch {
                        rollbackFailures.append("could not restore backup: \(error.localizedDescription)")
                    }
                } else {
                    rollbackFailures.append("backup bundle was missing")
                }
            }

            if !rollbackFailures.isEmpty {
                throw UpdateInstallError.rollbackFailed(
                    "Replacement failed: \(replacementError.localizedDescription). Rollback errors: \(rollbackFailures.joined(separator: "; "))."
                )
            }

            throw UpdateInstallError.replacementFailed("Failed to replace application: \(replacementError.localizedDescription)")
        }
    }

    // MARK: - Mount & Extraction Helpers

    private func mountDMG(dmgURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.mountFailed("hdiutil attach exited with status \(process.terminationStatus)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
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
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.extractionFailed("ditto extraction exited with status \(process.terminationStatus)")
        }
    }

    public func locateAppBundle(in directory: URL) -> URL? {
        var visited = Set<String>()
        return locateAppBundle(in: directory, depth: 0, visited: &visited)
    }

    private func locateAppBundle(in directory: URL, depth: Int, visited: inout Set<String>) -> URL? {
        guard depth <= 8 else { return nil }

        let candidate = directory.standardizedFileURL
        guard visited.insert(candidate.path).inserted,
              let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return nil
        }

        if candidate.pathExtension.lowercased() == "app" {
            return candidate
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: candidate,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for item in contents where item.pathExtension.lowercased() == "app" {
            if let itemValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               itemValues.isDirectory == true,
               itemValues.isSymbolicLink != true {
                return item.standardizedFileURL
            }
        }

        for item in contents {
            guard let itemValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  itemValues.isDirectory == true,
                  itemValues.isSymbolicLink != true else {
                continue
            }
            if let nested = locateAppBundle(in: item, depth: depth + 1, visited: &visited) {
                return nested
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
