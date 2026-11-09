//
//  TestEnvironmentIsolation.swift
//  SiphonTests
//

import Foundation
import XCTest
@testable import Siphon
@testable import SiphonCore

/// Principal class of the test bundle (see `INFOPLIST_KEY_NSPrincipalClass`).
///
/// Tests are hosted inside Siphon.app, so `UserDefaults.standard` and the queue
/// recovery file are the user's real app state. Snapshot both before the suite
/// runs, start the suite from a clean state, and restore the snapshot afterwards
/// so running tests never replaces the user's download history or produces a
/// false interrupted-queue prompt on the next launch.
@objc(SiphonTestEnvironmentIsolation)
final class TestEnvironmentIsolation: NSObject, XCTestObservation {
    private struct Snapshot {
        let defaultsDomainName: String?
        let defaultsDomain: [String: Any]?
        let recoveryFileURL: URL
        let recoveryFile: Data?
    }

    // Written once on the main thread before any test runs; read on the main
    // thread when the bundle finishes and again from the process exit hook.
    nonisolated(unsafe) private static var snapshot: Snapshot?

    /// On-disk copy of the user's state, so a crashed or force-stopped run
    /// (no didFinish or atexit) can be repaired by the next run.
    private static let backupURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SiphonTestsStateBackup.plist")

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        let defaults = UserDefaults.standard
        let domainName = Bundle.main.bundleIdentifier
        // XCTest delivers observation callbacks on the main thread.
        let recoveryURL = MainActor.assumeIsolated { QueueRecoveryStore.defaultFileURL }

        // A backup left by an interrupted run holds the user's real state;
        // the live state is that run's test data, so prefer the backup.
        var backup: [String: Any]
        if let data = try? Data(contentsOf: Self.backupURL),
           let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            backup = saved
        } else {
            backup = [:]
            backup["defaultsDomain"] = domainName.flatMap { defaults.persistentDomain(forName: $0) }
            backup["recoveryFile"] = try? Data(contentsOf: recoveryURL)
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
                try data.write(to: Self.backupURL, options: .atomic)
            } catch {
                NSLog("SiphonTests: failed to write app state backup: \(error.localizedDescription)")
            }
        }

        Self.snapshot = Snapshot(
            defaultsDomainName: domainName,
            defaultsDomain: backup["defaultsDomain"] as? [String: Any],
            recoveryFileURL: recoveryURL,
            recoveryFile: backup["recoveryFile"] as? Data
        )

        if let domainName {
            defaults.removePersistentDomain(forName: domainName)
        }

        // Work started by tests (executor teardown, history saves) can still
        // finish after the bundle completes, so restore once more at exit.
        atexit { TestEnvironmentIsolation.restoreSnapshot() }
    }

    /// A teardown block runs while the test can still fail, so the leak fails the
    /// test that made it. The key is cleared so the next test is judged on its own.
    func testCaseWillStart(_ testCase: XCTestCase) {
        nonisolated(unsafe) let test = testCase
        test.addTeardownBlock {
            let leaks = Self.leakedState()
            guard !leaks.isEmpty else { return }
            test.record(XCTIssue(type: .assertionFailure, compactDescription: "Leaked into real app state: " + leaks.joined(separator: ", ")))
            if let domainName = Self.snapshot?.defaultsDomainName {
                UserDefaults.standard.persistentDomain(forName: domainName)?.keys
                    .filter { !Self.ignoredDefaultsKey($0) }
                    .forEach(UserDefaults.standard.removeObject(forKey:))
            }
            if let snapshot = Self.snapshot {
                if let data = snapshot.recoveryFile {
                    try? data.write(to: snapshot.recoveryFileURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: snapshot.recoveryFileURL)
                }
            }
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let leaks = Self.leakedState()
        Self.restoreSnapshot()
        UserDefaults.standard.removePersistentDomain(forName: TestState.suiteName)
        try? FileManager.default.removeItem(at: TestState.recoveryFileURL)
        if !leaks.isEmpty {
            NSLog("SiphonTests: real app state leak: %@", leaks.joined(separator: ", "))
        }
    }

    /// The domain is empty when the suite starts and the recovery file must not change,
    /// so anything different was written by a test or the host app instead of an injected store.
    /// AppKit window state and the host app's own language default appear in every run.
    private static func ignoredDefaultsKey(_ key: String) -> Bool {
        key.hasPrefix("NS") || key == "selectedLanguage"
    }

    private static func leakedState() -> [String] {
        guard let snapshot, let domainName = snapshot.defaultsDomainName else { return [] }
        let leaked = (UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]).keys
            .filter { !ignoredDefaultsKey($0) }
            .sorted()
        var report = leaked.map { "defaults key \($0)" }
        if (try? Data(contentsOf: snapshot.recoveryFileURL)) != snapshot.recoveryFile {
            report.append("queue recovery file")
        }
        return report
    }

    private static func restoreSnapshot() {
        guard let snapshot else { return }

        let defaults = UserDefaults.standard
        if let domainName = snapshot.defaultsDomainName {
            // Rewrite key by key: setPersistentDomain(_:forName:) on the host's
            // own domain updates the in-process cache but is not reliably
            // persisted before the host exits.
            let original = snapshot.defaultsDomain ?? [:]
            let current = defaults.persistentDomain(forName: domainName) ?? [:]
            for key in current.keys where original[key] == nil {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in original {
                defaults.set(value, forKey: key)
            }
            // The host process exits right after the suite, before asynchronous
            // preference writes would otherwise be flushed.
            defaults.synchronize()
        }

        // An unchanged file is left alone, so a normal run never touches the real folder.
        if (try? Data(contentsOf: snapshot.recoveryFileURL)) == snapshot.recoveryFile {
            try? FileManager.default.removeItem(at: backupURL)
            return
        }
        if let data = snapshot.recoveryFile {
            do {
                try data.write(to: snapshot.recoveryFileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.recoveryFileURL.path)
            } catch {
                // Keep the on-disk backup so the next run can retry the restore.
                NSLog("SiphonTests: failed to restore queue recovery file: \(error.localizedDescription)")
                return
            }
        } else {
            try? FileManager.default.removeItem(at: snapshot.recoveryFileURL)
        }
        try? FileManager.default.removeItem(at: backupURL)
    }
}
