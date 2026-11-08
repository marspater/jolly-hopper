#if DEBUG
import Foundation
import SiphonCore
import SwiftUI

/// In-memory data for SwiftUI previews. Nothing here touches the network or the
/// real defaults domain, and no service is built from `.shared`.
@MainActor
enum PreviewFixtures {
    static let suiteName = "com.marspater.siphon.previews"
    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? UserDefaults() }

    /// Placeholder address for sample downloads; never fetched.
    static let sampleMediaURL: String = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "example.com"
        return components.string ?? ""
    }()

    private static let previewSession = URLSession(configuration: .ephemeral)

    private static func recoveryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SiphonPreview-\(UUID().uuidString)-queue_recovery.json")
    }

    static func manager(downloads: [Download] = []) -> DownloadManager {
        let manager = DownloadManager(
            historyStore: DownloadHistoryStore(userDefaults: defaults),
            queue: DownloadQueue(userDefaults: defaults),
            userDefaults: defaults,
            recoveryFileURL: recoveryFileURL()
        )
        manager.downloads = downloads
        return manager
    }

    static func appState() -> AppState {
        let state = AppState(
            releaseNotesService: ReleaseNotesService(userDefaults: defaults),
            // Its only service is the notification singleton, which fixtures never post through.
            dependencyCoordinator: DependencyUpdateCoordinator()
        )
        state.urlSession = previewSession
        state.didStartLaunchTasks = true
        return state
    }

    static func language() -> LanguageService { LanguageService() }

    static func updateChecker() -> UpdateChecker {
        UpdateChecker(fetchManifestData: { _ in Data() })
    }

    static func logger() -> LoggerService {
        LoggerService(logFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SiphonPreview-\(UUID().uuidString).log"))
    }

    static func download(
        _ status: DownloadStatus,
        title: String = "Sample video",
        progress: Double = 0,
        error: String? = nil,
        thumbnail: URL? = nil
    ) -> Download {
        let item = Download(url: sampleMediaURL, options: .default, title: title, titleIsDecoded: true)
        item.status = status
        item.progress = progress
        item.errorMessage = error
        item.thumbnailURL = thumbnail
        item.duration = "03:12"
        if status == .downloading {
            item.speed = "4.2 MiB/s"
            item.eta = "00:42"
        }
        if status == .completed {
            item.progress = 1
            item.filePaths = [FileManager.default.temporaryDirectory.appendingPathComponent("Sample video.mp4")]
        }
        return item
    }

    /// One download per lifecycle state, labelled for preview variants.
    static var lifecycle: [(String, Download)] {
        [
            ("Queued", download(.queued)),
            ("Extracting", download(.fetching)),
            ("Downloading", download(.downloading, progress: 0.42)),
            ("Paused", download(.paused, progress: 0.42)),
            ("Converting", download(.processing, progress: 0.9)),
            ("Completed", download(.completed)),
            ("Stopped", download(.stopped, progress: 0.2)),
            ("File exists", download(.fileExists))
        ] + errorFamilies.map { ("Failed: \($0.0)", download(.failed, error: $0.1)) }
    }

    static let errorFamilies = [
        ("Missing binary", "yt-dlp executable not found"),
        ("Network", "Unable to download webpage: HTTP Error 503"),
        ("Sign in", "Sign in to confirm you are not a bot"),
        ("Generic", "ERROR: an unknown error occurred")
    ]

    static var mixedQueue: [Download] {
        [download(.downloading, progress: 0.42), download(.processing, progress: 0.9), download(.queued), download(.completed)]
    }

    static var history: [HistoricDownload] {
        [HistoricDownload(download: download(.completed)), HistoricDownload(download: download(.failed, error: "Failed"))]
    }

    static let features = [
        ReleaseFeature(icon: "sparkles", title: "Sample feature", description: "A short description of a sample feature.")
    ]
}

extension View {
    /// Injects fixture environment objects and the AppStorage defaults store.
    @MainActor
    func previewEnvironment(downloads: [Download] = [], appState: AppState? = nil, updateChecker: UpdateChecker? = nil, manager: DownloadManager? = nil) -> some View {
        environmentObject(manager ?? PreviewFixtures.manager(downloads: downloads))
            .environmentObject(appState ?? PreviewFixtures.appState())
            .environmentObject(PreviewFixtures.language())
            .environmentObject(updateChecker ?? PreviewFixtures.updateChecker())
            .defaultAppStorage(PreviewFixtures.defaults)
    }
}
#endif
