import SwiftUI

@main
struct SiphonApp: App {
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var appState = AppState()
    @StateObject private var languageService = LanguageService()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("startInBackground") private var startInBackground: Bool = false
    @State private var hasAppliedBackgroundMode = false
    
    init() {
        GeistFontRegistrar.registerFonts()
        NotificationService.shared.setup()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloadManager)
                .environmentObject(appState)
                .environmentObject(languageService)
                .environmentObject(updateChecker)
                .onAppear {
                    PreferencesView.applyStoredTheme()
                    setupMenuBarIfNeeded()
                    applyBackgroundModeIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    downloadManager.stopAllDownloads()
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
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
        
        #if os(macOS)
        Settings {
            PreferencesView()
                .environmentObject(downloadManager)
                .environmentObject(languageService)
                .environmentObject(updateChecker)
        }
        #endif
    }
    
    private func setupMenuBarIfNeeded() {
        // MenuBarManager.setup() has its own idempotency guard (if statusItem != nil { return })
        MenuBarManager.shared.setup(languageService: languageService, downloadManager: downloadManager)
    }
    
    private func applyBackgroundModeIfNeeded() {
        guard !hasAppliedBackgroundMode else { return }
        DispatchQueue.main.async {
            hasAppliedBackgroundMode = true
            if startInBackground {
                // Hide dock icon — app runs as menu bar only
                NSApp.setActivationPolicy(.accessory)
                // Close any auto-opened windows
                for window in NSApp.windows {
                    if window.canBecomeMain {
                        window.close()
                    }
                }
            } else {
                // Ensure Dock icon is visible
                NSApp.setActivationPolicy(.regular)
            }
        }
    }
    
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "siphon" || url.scheme == "luma" else { return }
        
        // Restore dock icon when opening from URL scheme (browser extension, etc.)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems
        let videoUrl = queryItems?.first(where: { $0.name == "url" })?.value
        let rawCookies = queryItems?.first(where: { $0.name == "cookies" })?.value
        
        guard let rawVideoUrl = videoUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !rawVideoUrl.isEmpty,
              let targetURL = URL(string: rawVideoUrl), targetURL.scheme == "http" || targetURL.scheme == "https" else { return }
        
        if url.host == "download" {
            appState.urlToDownload = rawVideoUrl
            appState.rawCookiesToDownload = rawCookies
            appState.showAddDownloadSheet = true
        } else if url.host == "fast-download" {
            downloadManager.quickDownload(url: rawVideoUrl, rawCookies: rawCookies)
            appState.selectedNavItem = .downloading
        }
        
        for window in NSApp.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}


@MainActor
class UpdateChecker: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var isChecking = false
    @Published var hasUpdate = false
    @Published var latestVersion: String?
    @Published var showUpToDateMessage = false
    @Published var isDownloading = false
    @Published var updateProgress: Double = 0
    @Published var isInstalling = false
    @Published var needsRestart = false
    
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.0.0"
    }
    private let repoOwner = "marspater"
    private let repoName = "jolly-hopper"
    private var downloadURL: URL?
    
    @Published var releasePageURL: URL? = URL(string: "https://github.com/marspater/jolly-hopper/releases/latest")
    
    func checkForUpdates() async {
        isChecking = true
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                
                latestVersion = tagName.replacingOccurrences(of: "v", with: "")
                if let latest = latestVersion {
                    hasUpdate = latest.compare(currentVersion, options: .numeric) == .orderedDescending
                } else {
                    hasUpdate = false
                }
                
                if let htmlUrlStr = json["html_url"] as? String, let htmlUrl = URL(string: htmlUrlStr) {
                    releasePageURL = htmlUrl
                }
                
                if let assets = json["assets"] as? [[String: Any]] {
                    if let dlpAsset = assets.first(where: {
                        let name = ($0["name"] as? String)?.lowercased() ?? ""
                        return name.hasSuffix(".dmg") || name.hasSuffix(".zip") || name.hasSuffix(".app.zip") || name.hasSuffix(".tar.gz")
                    }), let downloadUrlStr = dlpAsset["browser_download_url"] as? String {
                        downloadURL = URL(string: downloadUrlStr)
                    }
                }
                
                if !hasUpdate {
                    showUpToDateMessage = true
                    try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                    showUpToDateMessage = false
                }
            }
        } catch {
            latestVersion = currentVersion
            hasUpdate = false
        }
        isChecking = false
    }
    
    func downloadAndInstallUpdate() async {
        guard let url = downloadURL else {
            if let pageURL = releasePageURL {
                NSWorkspace.shared.open(pageURL)
            }
            return
        }
        isDownloading = true
        updateProgress = 0
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let downloadTask = session.downloadTask(with: url)
        downloadTask.resume()
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            if totalBytesExpectedToWrite > 0 {
                updateProgress = max(0, min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            } else {
                updateProgress = 0
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempUpdate = FileManager.default.temporaryDirectory.appendingPathComponent("Siphon_Update_Package")
        try? FileManager.default.removeItem(at: tempUpdate)
        try? FileManager.default.moveItem(at: location, to: tempUpdate)
        
        Task { @MainActor in
            isDownloading = false
            isInstalling = true
            installUpdate(packagePath: tempUpdate.path)
        }
    }
    
    private func installUpdate(packagePath: String) {
        let appPath = Bundle.main.bundlePath
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let script = """
        (
            PKG_PATH="$1"
            APP_PATH="$2"
            WORK_DIR="$3"
            
            sleep 2
            
            if file "$PKG_PATH" | grep -q "Zip archive"; then
                /usr/bin/unzip -q "$PKG_PATH" -d "$WORK_DIR"
            else
                hdiutil mount "$PKG_PATH" -mountpoint "$WORK_DIR" -quiet
            fi
            
            NEW_APP="$(find "$WORK_DIR" -maxdepth 2 -name "*.app" | head -n 1)"
            
            if [ -n "$NEW_APP" ] && [ -d "$NEW_APP" ]; then
                rm -rf "$APP_PATH"
                ditto "$NEW_APP" "$APP_PATH"
                hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                rm -rf "$WORK_DIR"
                open "$APP_PATH"
            else
                hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                rm -rf "$WORK_DIR"
            fi
        ) & disown
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "bash", packagePath, appPath, tempDir.path]
        
        do {
            try process.run()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.isInstalling = false
                self.needsRestart = true
            }
        } catch {
            print("Update error: \(error)")
            isInstalling = false
        }
    }
    
    func restartApp() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}


@MainActor
class AppState: ObservableObject {
    @Published var showAddDownloadSheet = false
    @Published var selectedNavItem: NavigationItem = .home
    @Published var urlToDownload: String = ""
    @Published var rawCookiesToDownload: String? = nil
}

enum NavigationItem: String, CaseIterable, Identifiable {
    case home
    case downloading
    case queued
    case completed
    case failed
    
    var id: String { rawValue }
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .home: return lang.s("home")
        case .downloading: return lang.s("downloading")
        case .queued: return lang.s("queued")
        case .completed: return lang.s("completed")
        case .failed: return lang.s("failed")
        }
    }
    
    var icon: String {
        switch self {
        case .home: return "house"
        case .downloading: return "arrow.down.circle"
        case .queued: return "clock"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 15) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                
                Text("Welcome to Siphon")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Legal Disclaimer")
                    .font(.headline)
                
                ScrollView {
                    Text(languageService.s("legal_disclaimer_message"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxHeight: 200)
                .padding(10)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(.horizontal, 40)
            
            Button {
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.disclaimerAcknowledged)
                languageService.isFirstLaunch = false
                dismiss()
            } label: {
                Text("Start Using")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 40)
        .frame(width: 500)
    }
}
