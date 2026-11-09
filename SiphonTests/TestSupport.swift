import Foundation
import Testing
@testable import Siphon
@testable import SiphonCore

/// Defaults and recovery file that hosted tests use instead of the user's real ones.
enum TestState {
    static let suiteName = "com.marspater.siphon.SiphonTests.state.\(UUID().uuidString)"
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }()
    static let recoveryFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SiphonTests-\(UUID().uuidString)-queue_recovery.json")
}

extension AppState {
    /// Keeps the last-seen version out of the real defaults domain.
    @MainActor
    static func forTesting() -> AppState {
        AppState(
            releaseNotesService: ReleaseNotesService(userDefaults: TestState.defaults),
            dependencyCoordinator: DependencyUpdateCoordinator()
        )
    }
}

extension DownloadManager {
    @MainActor
    static func forTesting(recoveryFileURL: URL = TestState.recoveryFileURL) -> DownloadManager {
        DownloadManager(
            historyStore: DownloadHistoryStore(userDefaults: TestState.defaults),
            queue: DownloadQueue(userDefaults: TestState.defaults),
            userDefaults: TestState.defaults,
            recoveryFileURL: recoveryFileURL
        )
    }
}

@MainActor
struct HostedTestStorageIsolationTests {
    @Test func hostedTestsHaveSeparateBundleIdentityAndPreferences() {
        #expect(Bundle.main.bundleIdentifier == UITestLaunchMode.testBundleIdentifier)

        let key = "isolated-host-only-\(UUID().uuidString)"
        let installedDomainName = "com.marspater.siphon"
        let installedBefore = UserDefaults.standard
            .persistentDomain(forName: installedDomainName)?[key] as? String

        UserDefaults.standard.set("test fixture", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(UserDefaults.standard.string(forKey: key) == "test fixture")
        let installedAfter = UserDefaults.standard
            .persistentDomain(forName: installedDomainName)?[key] as? String
        #expect(installedAfter == installedBefore)
    }

    @Test func hostedRecoveryAndLogsUseSeparateTemporaryDirectory() {
        let root = UITestLaunchMode.isolatedRoot
        #expect(root != nil)
        let recoveryFile = DownloadManager.defaultRecoveryFileURL
        #expect(recoveryFile.standardizedFileURL != QueueRecoveryStore.defaultFileURL.standardizedFileURL)
        #expect(recoveryFile.deletingLastPathComponent().standardizedFileURL == root?.standardizedFileURL)
        #expect(LoggerService.shared.logFileURL.deletingLastPathComponent().standardizedFileURL == root?.standardizedFileURL)
    }
}
