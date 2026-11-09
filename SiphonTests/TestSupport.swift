import Foundation
@testable import Siphon

/// Defaults and recovery file that hosted tests use instead of the user's real ones.
enum TestState {
    static let suiteName = "com.marspater.siphon.SiphonTests.state"
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }()
    static let recoveryFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SiphonTests-\(UUID().uuidString)-queue_recovery.json")
}

extension DownloadManager {
    @MainActor
    static func forTesting() -> DownloadManager {
        DownloadManager(
            historyStore: DownloadHistoryStore(userDefaults: TestState.defaults),
            queue: DownloadQueue(userDefaults: TestState.defaults),
            userDefaults: TestState.defaults,
            recoveryFileURL: TestState.recoveryFileURL
        )
    }
}
