import Foundation
import SiphonCore

/// `--siphon-ui-test-root <dir>` redirects state to a temporary directory for UI tests.
/// Debug builds only: in Release `root` is always nil and the argument is not compiled in.
enum UITestLaunchMode {
    #if DEBUG
    static let root: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--siphon-ui-test-root"), index + 1 < arguments.count else { return nil }
        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            // Carrying on would run the UI test against the user's real state.
            fatalError("UI test root is unusable: \(error)")
        }
        return root
    }()
    #else
    static let root: URL? = nil
    #endif

    static var isActive: Bool { root != nil }

    /// A suite file under the root; nil outside this mode.
    nonisolated(unsafe) static let defaults: UserDefaults? = root.flatMap {
        UserDefaults(suiteName: $0.appendingPathComponent("defaults").path)
    }

    /// The store for preferences: the suite in this mode, otherwise `.standard`.
    static var storage: UserDefaults { defaults ?? .standard }

    /// Adds the jobs in `<root>/queue_seed.json`, an array of `{"url", "title", "status"}`.
    @MainActor
    static func seedQueue(in manager: DownloadManager) {
        struct SeedJob: Decodable {
            let url: String
            let title: String
            let status: DownloadStatus
        }
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("queue_seed.json")) else { return }
        do {
            for job in try JSONDecoder().decode([SeedJob].self, from: data) {
                let download = Download(url: job.url, options: .default, title: job.title, titleIsDecoded: true)
                download.status = job.status
                manager.downloads.append(download)
            }
        } catch {
            LoggerService.shared.log("Invalid UI test queue seed: \(error.localizedDescription)", level: .error)
        }
    }

    @MainActor
    static func makeDownloadManager() -> DownloadManager {
        guard let root, let defaults else { return DownloadManager() }
        return DownloadManager(
            historyStore: DownloadHistoryStore(userDefaults: defaults),
            queue: DownloadQueue(userDefaults: defaults),
            userDefaults: defaults,
            recoveryFileURL: root.appendingPathComponent("queue_recovery.json")
        )
    }

    @MainActor
    static func makeAppState() -> AppState {
        guard let defaults else { return AppState() }
        return AppState(
            releaseNotesService: ReleaseNotesService(userDefaults: defaults),
            dependencyCoordinator: DependencyUpdateCoordinator(notificationService: nil)
        )
    }
}
