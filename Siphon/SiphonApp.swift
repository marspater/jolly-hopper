import SwiftUI
import CryptoKit
@preconcurrency import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationService.shared
        NotificationService.shared.setup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
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
        NotificationService.shared.setup()
        CookieManager.purgeOrphanedTempCookieFiles()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloadManager)
                .environmentObject(appState)
                .environmentObject(languageService)
                .environmentObject(updateChecker)
                .onAppear {
                    SiphonTheme.applyTheme(theme)
                    setupMenuBarIfNeeded()
                    applyBackgroundModeIfNeeded()
                }
                .onChange(of: theme) { _, newTheme in
                    SiphonTheme.applyTheme(newTheme)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    downloadManager.stopAllDownloads()
                    downloadManager.shutdown()
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
                        initialTab: .about
                    )
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(languageService.s("new_download") + "...") {
                    AddDownloadWindowManager.shared.showAddDownloadWindow(downloadManager: downloadManager, appState: appState, languageService: languageService)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button(languageService.s("settings") + "...") {
                    PreferencesWindowManager.shared.showPreferencesWindow(
                        languageService: languageService,
                        updateChecker: updateChecker,
                        downloadManager: downloadManager
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
                
                Button(languageService.s("ytdlp_update")) {
                    Task {
                        await downloadManager.updateYtdlp()
                    }
                }
                .disabled(downloadManager.isUpdatingYtdlp)
            }
        }
    }
    
    private func setupMenuBarIfNeeded() {
        MenuBarManager.shared.setup(languageService: languageService, downloadManager: downloadManager)
    }
    
    private func applyBackgroundModeIfNeeded() {
        guard !hasAppliedBackgroundMode else { return }
        DispatchQueue.main.async {
            hasAppliedBackgroundMode = true
            if startInBackground {
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows {
                    if window.canBecomeMain {
                        window.close()
                    }
                }
            } else {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }
    
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "siphon" || url.scheme == "luma" else { return }
        
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        guard url.host == "download" || url.host == "fast-download" else {
            for window in NSApp.windows where window.canBecomeMain {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems
        let videoUrl = queryItems?.first(where: { $0.name == "url" })?.value
        let rawCookies = (url.host == "download" || url.host == "fast-download") ? queryItems?.first(where: { $0.name == "cookies" })?.value : nil
        let rawUserAgent = (url.host == "download" || url.host == "fast-download") ? queryItems?.first(where: { $0.name == "ua" })?.value : nil
        
        guard let rawVideoUrl = videoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVideoUrl.isEmpty,
              !rawVideoUrl.contains("\r") && !rawVideoUrl.contains("\n") && !rawVideoUrl.contains("\0"),
              let targetURL = URL(string: rawVideoUrl),
              let host = targetURL.host, !host.isEmpty,
              targetURL.scheme == "http" || targetURL.scheme == "https" else { return }
        
        let sanitizedCookies: String? = {
            guard let cookies = rawCookies, !cookies.isEmpty, cookies.count <= 64 * 1024 else { return nil }
            return cookies.components(separatedBy: CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\t"))).joined()
        }()
        let sanitizedUserAgent: String? = {
            guard let userAgent = rawUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userAgent.isEmpty,
                  userAgent.count <= 1024,
                  !userAgent.contains("\r"),
                  !userAgent.contains("\n"),
                  !userAgent.contains("\0") else { return nil }
            return userAgent
        }()

        appState.setBrowserSession(
            for: targetURL,
            rawCookies: sanitizedCookies,
            rawUserAgent: sanitizedUserAgent
        )

        if url.host == "fast-download" {
            let session = appState.consumeBrowserSession(for: rawVideoUrl)
            downloadManager.quickDownload(
                url: rawVideoUrl,
                rawCookies: session?.rawCookies,
                rawUserAgent: session?.rawUserAgent
            )
            appState.selectedNavItem = .downloading
            appState.showAddDownloadSheet = false
        } else {
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
