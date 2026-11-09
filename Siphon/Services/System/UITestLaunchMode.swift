import AppKit
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

    /// AppKit saves window and split-view geometry straight to the standard domain, and
    /// SwiftUI gives every scene an autosave name, so a suite cannot redirect those writes.
    static func disableAppKitAutosave() {
        #if DEBUG
        guard isActive else { return }
        let setFrameName: @convention(block) (NSWindow, NSWindow.FrameAutosaveName) -> Bool = { _, _ in true }
        let saveFrame: @convention(block) (NSWindow, NSWindow.FrameAutosaveName) -> Void = { _, _ in
            // Intentionally empty: the frame must not be saved in this mode.
        }
        let setSplitName: @convention(block) (NSSplitView, NSSplitView.AutosaveName?) -> Void = { _, _ in
            // Intentionally empty: without a name the divider positions are not saved.
        }
        replace(#selector(NSWindow.setFrameAutosaveName(_:)), on: NSWindow.self, with: setFrameName)
        replace(#selector(NSWindow.saveFrame(usingName:)), on: NSWindow.self, with: saveFrame)
        replace(#selector(setter: NSSplitView.autosaveName), on: NSSplitView.self, with: setSplitName)
        #endif
    }

    #if DEBUG
    private static func replace(_ selector: Selector, on type: AnyClass, with block: Any) {
        guard let method = class_getInstanceMethod(type, selector) else {
            fatalError("UI test mode cannot stop autosave: \(selector) is missing")
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
    #endif

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
                let download = Download(url: job.url, options: DownloadOptions.defaultFromPreferences(userDefaults: storage), title: job.title, titleIsDecoded: true)
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
        // Without a saved folder, options fall back to the real ~/Downloads.
        defaults.register(defaults: [UserDefaultsKeys.defaultSaveFolder: root.path])
        let manager = DownloadManager(
            historyStore: DownloadHistoryStore(userDefaults: defaults),
            queue: DownloadQueue(userDefaults: defaults),
            userDefaults: defaults,
            recoveryFileURL: root.appendingPathComponent("queue_recovery.json")
        )
        manager.ytdlpService.updateYtdlpHandler = { DependencyChecksums.ytdlpVersion }
        return manager
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
