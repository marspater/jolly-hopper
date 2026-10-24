import SwiftUI
import CryptoKit
@preconcurrency import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var downloadManager: DownloadManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationService.shared
        NotificationService.shared.setup()
        guard !NotificationService.isRunningTests else { return }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cleanupRecoveryBackups(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        cleanupRecoveryBackups(notification)
    }

    @MainActor @objc private func cleanupRecoveryBackups(_ _: Notification) {
        if UpdateInstaller.pruneRecoveryBackupsOnLaunch() {
            NSWorkspace.shared.notificationCenter.removeObserver(self,
                name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        }
    }

    @MainActor
    func handleApplicationWillTerminate(bypassTestGuard: Bool = false) {
        NSWorkspace.shared.notificationCenter.removeObserver(self,
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        guard bypassTestGuard || !NotificationService.isRunningTests else { return }
        downloadManager?.handleAppTermination()
    }

    func applicationWillTerminate(_: Notification) {
        handleApplicationWillTerminate(bypassTestGuard: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Leave the accessory policy "Start in background" set, or the window has no Dock icon or menu bar.
            sender.setActivationPolicy(.regular)
            for window in sender.windows where window.canBecomeMain {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        NotificationService.shared.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NotificationService.shared.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
}

@main
struct SiphonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var appState = AppState()
    @StateObject private var languageService = LanguageService()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("startInBackground") private var startInBackground: Bool = false
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    @State private var hasAppliedBackgroundMode = false

    init() {
        GeistFontRegistrar.registerFonts()
        CookieManager.purgeOrphanedTempCookieFiles()
        // Before any recovered job can restart against the same partial file.
        if !NotificationService.isRunningTests {
            let support = YtdlpService.getAppSupportDirectory()
            DownloadProcessController.reapOrphanedProcesses(
                executablePaths: ["yt-dlp", "ffmpeg", "ffprobe"].map { support.appendingPathComponent($0) }
                    + ["ffmpeg", "ffprobe"].compactMap { Bundle.main.url(forResource: $0, withExtension: nil) }
            )
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(downloadManager)
                .environmentObject(appState)
                .environmentObject(languageService)
                .environmentObject(updateChecker)
                .onAppear {
                    appDelegate.downloadManager = downloadManager
                    SiphonTheme.applyTheme(theme)
                    applyBackgroundModeIfNeeded()
                }
                .onChange(of: theme) { _, newTheme in
                    SiphonTheme.applyTheme(newTheme)
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 980, height: 620)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(String(format: languageService.s("about_app"), "Siphon")) {
                    PreferencesWindowManager.shared.showPreferencesWindow(
                        languageService: languageService,
                        updateChecker: updateChecker,
                        downloadManager: downloadManager,
                        appState: appState,
                        initialTab: .about
                    )
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(languageService.s("new_download") + "…") {
                    AddDownloadWindowManager.shared.showAddDownloadWindow(downloadManager: downloadManager, appState: appState, languageService: languageService, updateChecker: updateChecker)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button(languageService.s("settings") + "…") {
                    PreferencesWindowManager.shared.showPreferencesWindow(
                        languageService: languageService,
                        updateChecker: updateChecker,
                        downloadManager: downloadManager,
                        appState: appState
                    )
                }
                .keyboardShortcut(",", modifiers: .command)

                if DependencyChecksums.managedYtdlpEnabled {
                    Button(languageService.s("ytdlp_update")) {
                        Task {
                            await appState.updateYtdlp(
                                using: downloadManager.ytdlpService,
                                activeExecutionCount: downloadManager.activeExecutionCount,
                                languageService: languageService
                            )
                        }
                    }
                    .disabled(appState.isUpdatingYtdlp || downloadManager.activeExecutionCount > 0)
                }
            }
        }
    }

    private func applyBackgroundModeIfNeeded() {
        guard !hasAppliedBackgroundMode else { return }
        DispatchQueue.main.async {
            hasAppliedBackgroundMode = true
            if startInBackground {
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows where window.canBecomeMain {
                    window.close()
                }
            } else {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard Self.isAppDeepLink(url) else { return }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard url.host == "download" || url.host == "fast-download" else {
            bringMainWindowsForward()
            return
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let videoUrl = queryItems?.first(where: { $0.name == "url" })?.value
        guard let target = Self.externalDownloadTarget(from: videoUrl) else {
            Self.logRejectedExternalTarget(videoUrl)
            return
        }
        admitExternalDownload(
            target,
            isFastDownload: url.host == "fast-download",
            rawUserAgent: queryItems?.first(where: { $0.name == "ua" })?.value,
            rawBrowserSource: queryItems?.first(where: { $0.name == "browser" })?.value
        )
    }

    private func bringMainWindowsForward() {
        for window in NSApp.windows where window.canBecomeMain {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Schemes are case-insensitive (RFC 3986), and macOS opens `SIPHON://` here too.
    static func isAppDeepLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "siphon"
    }

    /// Syntax check only; the public-network boundary is checked by `admitExternalDownload`.
    static func externalDownloadTarget(from rawValue: String?) -> (raw: String, url: URL)? {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.contains("\r") && !raw.contains("\n") && !raw.contains("\0"),
              let normalized = DownloadURLValidator.normalizedWebURL(raw),
              let url = URL(string: normalized),
              let host = url.host, !host.isEmpty else { return nil }
        return (normalized, url)
    }

    private static func logRejectedExternalTarget(_ rawValue: String?) {
        LoggerService.shared.log(
            "Rejected external download target outside the public network boundary: \(LoggerService.sanitizeURLForLog(rawValue ?? "<missing>"))",
            level: .warning
        )
    }

    private func admitExternalDownload(
        _ target: (raw: String, url: URL),
        isFastDownload: Bool,
        rawUserAgent: String?,
        rawBrowserSource: String?
    ) {
        // Fast downloads each start their own job; interactive links share one sheet.
        let generation = isFastDownload ? nil : appState.beginInteractiveLink()
        // The target policy resolves DNS, which can block for seconds on a slow
        // or unreachable resolver. Keep that off the main actor.
        Task { @MainActor in
            let targetURL = target.url
            let isAllowed = await Task.detached(priority: .userInitiated) {
                ExternalDownloadTargetPolicy.isAllowed(targetURL)
            }.value
            guard isAllowed else {
                Self.logRejectedExternalTarget(target.raw)
                return
            }
            if let generation, !appState.isCurrentInteractiveLink(generation) {
                LoggerService.shared.log("Ignored an external download link superseded by a newer one.", level: .info)
                return
            }
            acceptExternalDownload(
                rawVideoUrl: target.raw,
                targetURL: target.url,
                isFastDownload: isFastDownload,
                rawUserAgent: rawUserAgent,
                rawBrowserSource: rawBrowserSource
            )
        }
    }

    private func acceptExternalDownload(
        rawVideoUrl: String,
        targetURL: URL,
        isFastDownload: Bool,
        rawUserAgent: String?,
        rawBrowserSource: String?
    ) {
        // Never accept browser credential values through a custom URL. The extension
        // sends only a browser identifier; Siphon asks yt-dlp to read that browser's
        // cookie store directly, preserving the browser's original cookie metadata.
        let sanitizedBrowserSource = AppState.normalizedBrowserCookieSource(rawBrowserSource)
        let sanitizedUserAgent: String? = {
            guard let userAgent = rawUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userAgent.isEmpty,
                  userAgent.count <= 1024,
                  !userAgent.contains("\r"),
                  !userAgent.contains("\n"),
                  !userAgent.contains("\0") else { return nil }
            return userAgent
        }()

        if isFastDownload {
            // Hand the session straight to the job. Going through AppState's shared
            // deep-link state would overwrite the session and external-target marker
            // of an Add Download sheet that is still open.
            downloadManager.quickDownload(
                url: rawVideoUrl,
                rawCookies: nil,
                rawUserAgent: sanitizedUserAgent,
                browserCookieSource: sanitizedBrowserSource,
                enforcePublicNetworkBoundary: true
            )
            appState.selectedNavItem = .downloading
            appState.showAddDownloadSheet = false
        } else {
            appState.setBrowserSession(
                for: targetURL,
                rawCookies: nil,
                rawUserAgent: sanitizedUserAgent,
                browserCookieSource: sanitizedBrowserSource
            )
            appState.setExternalTarget(rawVideoUrl)
            appState.urlToDownload = rawVideoUrl
            appState.showAddDownloadSheet = true
        }

        for window in NSApp.windows where window.canBecomeMain {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
