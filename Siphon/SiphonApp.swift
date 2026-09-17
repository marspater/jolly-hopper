import SwiftUI
import CryptoKit
@preconcurrency import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationService.shared
        NotificationService.shared.setup()
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
                .preferredColorScheme(theme == "light" ? .light : (theme == "dark" ? .dark : nil))
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
        
        guard url.host == "download" || url.host == "fast-download" else { return }
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems
        let videoUrl = queryItems?.first(where: { $0.name == "url" })?.value
        let rawCookies = url.host == "download" ? queryItems?.first(where: { $0.name == "cookies" })?.value : nil
        
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

        if url.host == "download" || url.host == "fast-download" {
            appState.urlToDownload = rawVideoUrl
            appState.rawCookiesToDownload = sanitizedCookies
            appState.showAddDownloadSheet = true
        }
        
        for window in NSApp.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
