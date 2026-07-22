import SwiftUI

@main
struct VeloXApp: App {
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var appState = AppState()
    @StateObject private var languageService = LanguageService()
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("startInBackground") private var startInBackground: Bool = false
    @State private var hasAppliedBackgroundMode = false
    
    init() {
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloadManager)
                .environmentObject(appState)
                .environmentObject(languageService)
                .environmentObject(updateChecker)
                .onAppear {
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
            CommandGroup(replacing: .newItem) {
                Button(languageService.s("new_download") + "...") {
                    AddDownloadWindowManager.shared.showAddDownloadWindow(downloadManager: downloadManager, appState: appState, languageService: languageService)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
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
        guard url.scheme == "velox" else { return }
        
        // Restore dock icon when opening from URL scheme (browser extension, etc.)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems
        let videoUrl = queryItems?.first(where: { $0.name == "url" })?.value
        
        guard let videoUrl = videoUrl, !videoUrl.isEmpty else { return }
        
        if url.host == "download" {
            appState.urlToDownload = videoUrl
            appState.showAddDownloadSheet = true
        } else if url.host == "fast-download" {
            downloadManager.quickDownload(url: videoUrl)
            appState.selectedNavItem = .downloading
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
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.0.0"
    }
    private let repoOwner = "marspater"
    private let repoName = "jolly-hopper"
    private var downloadURL: URL?
    
    func checkForUpdates() async {
        isChecking = true
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String,
               let assets = json["assets"] as? [[String: Any]] {
                
                latestVersion = tagName.replacingOccurrences(of: "v", with: "")
                if let latest = latestVersion {
                    hasUpdate = latest.compare(currentVersion, options: .numeric) == .orderedDescending
                } else {
                    hasUpdate = false
                }
                
                if let dlpAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                   let downloadUrlStr = dlpAsset["browser_download_url"] as? String {
                    downloadURL = URL(string: downloadUrlStr)
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
        guard let url = downloadURL else { return }
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
        let tempDmg = FileManager.default.temporaryDirectory.appendingPathComponent("VeloX_Update.dmg")
        try? FileManager.default.removeItem(at: tempDmg)
        try? FileManager.default.moveItem(at: location, to: tempDmg)
        
        Task { @MainActor in
            isDownloading = false
            isInstalling = true
            installUpdate(dmgPath: tempDmg.path)
        }
    }
    
    private func installUpdate(dmgPath: String) {
        let appPath = Bundle.main.bundlePath
        let script = """
        (
            exec > /tmp/velox_update.log 2>&1
            echo "Starting update..."
            sleep 3
            MOUNT_POINT="/tmp/VeloXUpdate_$(date +%s)"
            mkdir -p "$MOUNT_POINT"
            hdiutil mount "\(dmgPath)" -mountpoint "$MOUNT_POINT" -quiet
            
            if [ -d "$MOUNT_POINT/VeloX Pro.app" ]; then
                echo "Found new app, replacing..."
                rm -rf "\(appPath)"
                ditto "$MOUNT_POINT/VeloX Pro.app" "\(appPath)"
                hdiutil unmount "$MOUNT_POINT" -quiet
                rm -rf "$MOUNT_POINT"
                echo "Update files replaced. Waiting for app to restart."
            else
                echo "New app not found in DMG!"
                hdiutil unmount "$MOUNT_POINT" -quiet
                rm -rf "$MOUNT_POINT"
            fi
        ) & disown
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        
        do {
            try process.run()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self.isInstalling = false
                self.needsRestart = true
            }
        } catch {
            print("Update error: \(error)")
            isInstalling = false
        }
    }
    
    func restartApp() {
        let script = "pkill 'VeloX Pro'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        
        do {
            try process.run()
        } catch {
            NSApp.terminate(nil)
        }
    }
}


@MainActor
class AppState: ObservableObject {
    @Published var showAddDownloadSheet = false
    @Published var selectedNavItem: NavigationItem = .home
    @Published var urlToDownload: String = ""
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
                
                Text("Welcome to VeloX Pro")
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
