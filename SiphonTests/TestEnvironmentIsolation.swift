//
//  TestEnvironmentIsolation.swift
//  SiphonTests
//

import Foundation
import XCTest
@testable import Siphon
@testable import SiphonCore

/// Principal class of the hosted test bundle. Unlike the old snapshot/restore
/// observer, this class never reads or writes the installed app's preferences or
/// recovery file. Xcode's TestDebug/TestRelease configurations build the host
/// with a different bundle identifier from the installed Siphon application.
@objc(SiphonTestEnvironmentIsolation)
final class TestEnvironmentIsolation: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        let expectedIdentifier = UITestLaunchMode.testBundleIdentifier
        precondition(
            Bundle.main.bundleIdentifier == expectedIdentifier,
            "Hosted Siphon tests must use TestDebug/TestRelease. Refusing to run under the installed app's bundle identity."
        )

        let recoveryURL = MainActor.assumeIsolated { DownloadManager.defaultRecoveryFileURL }
        let productionURL = MainActor.assumeIsolated { QueueRecoveryStore.defaultFileURL }
        precondition(
            recoveryURL.standardizedFileURL != productionURL.standardizedFileURL,
            "Hosted test queue recovery would overwrite the installed app's recovery state."
        )
        precondition(
            UITestLaunchMode.isolatedRoot != nil,
            "Hosted XCTest requires an isolated temporary recovery directory."
        )
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        // The test host has its own app identity, so this cannot touch the
        // installed Siphon's UserDefaults domain. Keep the old interrupted-run
        // backup on disk, if present: an older test run might need recovery.
        UserDefaults.standard.removePersistentDomain(forName: UITestLaunchMode.testBundleIdentifier)
        TestState.defaults.removePersistentDomain(forName: TestState.suiteName)
        try? FileManager.default.removeItem(at: TestState.recoveryFileURL)
    }
}
