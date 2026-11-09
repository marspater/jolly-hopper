import Foundation
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
