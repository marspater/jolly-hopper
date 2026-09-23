//
//  TestEnvironmentIsolation.swift
//  SiphonTests
//

import Foundation
import XCTest
@testable import Siphon

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

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        let defaults = UserDefaults.standard
        let domainName = Bundle.main.bundleIdentifier
        // XCTest delivers observation callbacks on the main thread.
        let recoveryURL = MainActor.assumeIsolated { QueueRecoveryStore.defaultFileURL }

        Self.snapshot = Snapshot(
            defaultsDomainName: domainName,
            defaultsDomain: domainName.flatMap { defaults.persistentDomain(forName: $0) },
            recoveryFileURL: recoveryURL,
            recoveryFile: try? Data(contentsOf: recoveryURL)
        )

        if let domainName {
            defaults.removePersistentDomain(forName: domainName)
        }
        try? FileManager.default.removeItem(at: recoveryURL)

        // Work started by tests (executor teardown, history saves) can still
        // finish after the bundle completes, so restore once more at exit.
        atexit { TestEnvironmentIsolation.restoreSnapshot() }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        Self.restoreSnapshot()
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

        if let data = snapshot.recoveryFile {
            do {
                try data.write(to: snapshot.recoveryFileURL, options: .atomic)
            } catch {
                NSLog("SiphonTests: failed to restore queue recovery file: \(error.localizedDescription)")
            }
        } else {
            try? FileManager.default.removeItem(at: snapshot.recoveryFileURL)
        }
    }
}
