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
        YtdlpService.purgeOrphanedTempCookieFiles()
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
                    setupMenuBarIfNeeded()
                    applyBackgroundModeIfNeeded()
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
        
        guard let rawVideoUrl = videoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVideoUrl.isEmpty,
              !rawVideoUrl.contains("\r") && !rawVideoUrl.contains("\n") && !rawVideoUrl.contains("\0"),
              let targetURL = URL(string: rawVideoUrl),
              let host = targetURL.host, !host.isEmpty,
              targetURL.scheme == "http" || targetURL.scheme == "https" else { return }
        
        // Sanitize incoming cookies: cap payload size to 64KB and filter out illegal control chars
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
    private var downloadAssetName: String?
    private var expectedChecksum: String?
    private var checksumURL: URL?
    private var currentDownloadTask: URLSessionDownloadTask?
    private var activeSession: URLSession?
    
    @Published var releasePageURL: URL? = URL(string: "https://github.com/marspater/jolly-hopper/releases/latest")
    
    func cancelUpdate() {
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
        isDownloading = false
        isInstalling = false
        updateProgress = 0
    }
    
    func checkForUpdates(manual: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            isChecking = false
            return
        }
        
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Siphon-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                throw NSError(domain: "UpdateChecker", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(httpResponse.statusCode)"])
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                
                let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
                latestVersion = cleanTag
                hasUpdate = cleanTag.compare(currentVersion, options: .numeric) == .orderedDescending
                
                if let htmlUrlStr = json["html_url"] as? String, let htmlUrl = URL(string: htmlUrlStr) {
                    releasePageURL = htmlUrl
                }
                
                downloadURL = nil
                downloadAssetName = nil
                expectedChecksum = nil
                checksumURL = nil
                
                if let assets = json["assets"] as? [[String: Any]] {
                    #if arch(arm64)
                    let targetArch = "arm64"
                    let altArch = "aarch64"
                    let nonTargetArch = "x86_64"
                    #else
                    let targetArch = "x86_64"
                    let altArch = "intel"
                    let nonTargetArch = "arm64"
                    #endif

                    // Prefer packages matching current architecture, then universal, and prefer .dmg over .zip
                    let sortedAssets = assets.sorted { a, b in
                        let nameA = (a["name"] as? String)?.lowercased() ?? ""
                        let nameB = (b["name"] as? String)?.lowercased() ?? ""

                        let aMatchesTarget = nameA.contains(targetArch) || nameA.contains(altArch) || nameA.contains("universal")
                        let bMatchesTarget = nameB.contains(targetArch) || nameB.contains(altArch) || nameB.contains("universal")
                        let aMatchesNonTarget = nameA.contains(nonTargetArch)
                        let bMatchesNonTarget = nameB.contains(nonTargetArch)

                        if aMatchesTarget && !bMatchesTarget { return true }
                        if !aMatchesTarget && bMatchesTarget { return false }
                        if !aMatchesNonTarget && bMatchesNonTarget { return true }
                        if aMatchesNonTarget && !bMatchesNonTarget { return false }

                        if nameA.hasSuffix(".dmg") && !nameB.hasSuffix(".dmg") { return true }
                        return false
                    }

                    if let dlpAsset = sortedAssets.first(where: {
                        let name = ($0["name"] as? String)?.lowercased() ?? ""
                        return name.hasSuffix(".dmg") || name.hasSuffix(".zip") || name.hasSuffix(".app.zip")
                    }), let downloadUrlStr = dlpAsset["browser_download_url"] as? String {
                        downloadURL = URL(string: downloadUrlStr)
                        let assetName = (dlpAsset["name"] as? String) ?? ""
                        downloadAssetName = assetName
                        
                        // Check if an exact corresponding sha256 checksum asset or central manifest exists
                        let lowerAssetName = assetName.lowercased()
                        if let sumAsset = assets.first(where: {
                            let name = ($0["name"] as? String)?.lowercased() ?? ""
                            return name == "\(lowerAssetName).sha256" ||
                                   name == "\(lowerAssetName).sha256.txt" ||
                                   name == "\(lowerAssetName).sha256sum" ||
                                   name == "sha256sums.txt" ||
                                   name == "checksums.txt" ||
                                   name == "sha256sum.txt" ||
                                   name == "checksums.sha256"
                        }), let sumUrlStr = sumAsset["browser_download_url"] as? String {
                            checksumURL = URL(string: sumUrlStr)
                        }
                    }
                }
                
                if !hasUpdate {
                    showUpToDateMessage = true
                    if manual {
                        NotificationService.shared.sendAppUpdateNotification(
                            title: "Siphon is Up to Date",
                            body: "Version \(currentVersion) is the latest version available."
                        )
                    }
                    try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                    showUpToDateMessage = false
                } else if manual {
                    NotificationService.shared.sendAppUpdateNotification(
                        title: "Update Available",
                        body: "Siphon v\(cleanTag) is now available."
                    )
                }
            }
        } catch {
            LoggerService.shared.log("Failed to check for app updates: \(error.localizedDescription)", level: .warning)
            if latestVersion == nil {
                latestVersion = currentVersion
            }
            hasUpdate = false
            if manual {
                NotificationService.shared.sendAppUpdateNotification(
                    title: "Update Check Failed",
                    body: error.localizedDescription
                )
            }
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
        
        // Fetch checksum in background if available
        if let cURL = checksumURL {
            if let (cData, _) = try? await URLSession.shared.data(from: cURL),
               let text = String(data: cData, encoding: .utf8) {
                // Parse sha256 hex string (64 hex characters) specifically matching downloaded asset
                let lines = text.components(separatedBy: .newlines)
                let targetAssetName = downloadAssetName?.lowercased() ?? ""
                let cURLName = cURL.lastPathComponent.lowercased()
                let isAssetSpecificChecksumFile = !targetAssetName.isEmpty && cURLName.hasPrefix(targetAssetName)
                
                for line in lines {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard let first = parts.first, first.count == 64 else { continue }
                    let hash = String(first).lowercased()
                    
                    // Single-hash file specifically named for this asset (e.g. Siphon-arm64.dmg.sha256)
                    if isAssetSpecificChecksumFile && parts.count <= 2 {
                        expectedChecksum = hash
                        break
                    }

                    // Multi-entry manifest (e.g. SHA256SUMS.txt): must strictly match targeted asset name
                    if parts.count >= 2 {
                        let manifestFilename = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^\\*", with: "", options: .regularExpression).lowercased()
                        if manifestFilename == targetAssetName || URL(fileURLWithPath: manifestFilename).lastPathComponent.lowercased() == targetAssetName {
                            expectedChecksum = hash
                            break
                        }
                    }
                }
            }
        }
        
        isDownloading = true
        updateProgress = 0
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.activeSession = session
        let downloadTask = session.downloadTask(with: url)
        self.currentDownloadTask = downloadTask
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

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        Task { @MainActor in
            self.currentDownloadTask = nil
            self.activeSession = nil
            if let error = error {
                LoggerService.shared.log("Update package download failed: \(error.localizedDescription)", level: .error)
                self.isDownloading = false
                self.isInstalling = false
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        session.finishTasksAndInvalidate()
        let tempUpdate = FileManager.default.temporaryDirectory.appendingPathComponent("Siphon_Update_Package_\(UUID().uuidString)")
        do {
            if FileManager.default.fileExists(atPath: tempUpdate.path) {
                try FileManager.default.removeItem(at: tempUpdate)
            }
            try FileManager.default.moveItem(at: location, to: tempUpdate)
            
            Task { @MainActor in
                self.currentDownloadTask = nil
                self.activeSession = nil
                isDownloading = false
                
                // Cryptographic checksum verification if expected checksum was retrieved
                if let expected = expectedChecksum {
                    let computed = computeSHA256(for: tempUpdate)
                    if computed == nil || computed?.lowercased() != expected.lowercased() {
                        LoggerService.shared.log("Update checksum verification failed: expected \(expected), got \(computed ?? "nil")", level: .error)
                        try? FileManager.default.removeItem(at: tempUpdate)
                        isInstalling = false
                        return
                    }
                    LoggerService.shared.log("Cryptographic SHA256 checksum verified successfully", level: .info)
                }
                
                isInstalling = true
                installUpdate(packagePath: tempUpdate.path)
            }
        } catch {
            Task { @MainActor in
                LoggerService.shared.log("Failed to stage downloaded update package: \(error.localizedDescription)", level: .error)
                isDownloading = false
                isInstalling = false
            }
        }
    }
    
    nonisolated static func computeSHA256(for fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 64 * 1024)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
    
    private func computeSHA256(for fileURL: URL) -> String? {
        return Self.computeSHA256(for: fileURL)
    }
    
    static func updateInstallerScript() -> String {
        return """
        (
            set -e
            sleep 2
            
            # Step 1: Unpack into staging directory
            if file "$PKG_PATH" | grep -q "Zip archive"; then
                /usr/bin/unzip -q "$PKG_PATH" -d "$WORK_DIR"
            else
                hdiutil mount "$PKG_PATH" -mountpoint "$WORK_DIR" -quiet || exit 1
            fi
            
            NEW_APP="$(find "$WORK_DIR" -maxdepth 2 -name "*.app" | head -n 1)"
            
            if [ -z "$NEW_APP" ] || [ ! -d "$NEW_APP" ]; then
                echo "No application bundle found in update payload"
                hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                rm -rf "$WORK_DIR" "$PKG_PATH"
                exit 1
            fi
            
            # Step 2: Verify Code Signature Integrity
            if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$NEW_APP" 2>/dev/null; then
                echo "Code signature verification failed on new app payload"
                hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                rm -rf "$WORK_DIR" "$PKG_PATH"
                exit 1
            fi
            
            # Step 3: Verify Bundle Identifier matches
            NEW_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$NEW_APP/Contents/Info.plist" 2>/dev/null || true)"
            if [ -n "$EXPECTED_BUNDLE_ID" ] && [ "$NEW_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
                echo "Bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID, got $NEW_BUNDLE_ID"
                hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                rm -rf "$WORK_DIR" "$PKG_PATH"
                exit 1
            fi
            
            # Step 4: Atomic Swap with Backup and Rollback
            BACKUP_PATH="${APP_PATH}.backup.$$"
            
            # Move existing app to backup
            if ! mv "$APP_PATH" "$BACKUP_PATH"; then
                echo "Failed to create atomic backup of existing app bundle"
                hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                rm -rf "$WORK_DIR" "$PKG_PATH"
                exit 1
            fi
            
            # Copy new app to target location
            if ditto "$NEW_APP" "$APP_PATH"; then
                # Verify that installed app is present and intact
                if [ -d "$APP_PATH" ] && /usr/bin/codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
                    # Success: remove backup and clean up staging
                    rm -rf "$BACKUP_PATH"
                    hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                    rm -rf "$WORK_DIR" "$PKG_PATH"
                    open "$APP_PATH"
                    exit 0
                else
                    # Verification of installed target failed -> rollback
                    rm -rf "$APP_PATH"
                    mv "$BACKUP_PATH" "$APP_PATH"
                    hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                    rm -rf "$WORK_DIR" "$PKG_PATH"
                    exit 1
                fi
            else
                # Copy failed -> rollback
                mv "$BACKUP_PATH" "$APP_PATH"
                hdiutil unmount "$WORK_DIR" -quiet 2>/dev/null || true
                rm -rf "$WORK_DIR" "$PKG_PATH"
                exit 1
            fi
        ) & disown
        """
    }

    private func installUpdate(packagePath: String) {
        let appPath = Bundle.main.bundlePath
        let bundleId = Bundle.main.bundleIdentifier ?? "com.siphon.Siphon"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Siphon_Staging_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            LoggerService.shared.log("Failed to create temporary directory for update installation: \(error.localizedDescription)", level: .error)
            isInstalling = false
            return
        }

        let script = Self.updateInstallerScript()
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["PKG_PATH"] = packagePath
        env["APP_PATH"] = appPath
        env["WORK_DIR"] = tempDir.path
        env["EXPECTED_BUNDLE_ID"] = bundleId
        process.environment = env
        
        do {
            try process.run()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.isInstalling = false
                self.needsRestart = true
            }
        } catch {
            LoggerService.shared.log("Update process run error: \(error)", level: .error)
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
        case .home: return "house.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .queued: return "clock.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "hand.wave.fill")
                    .font(.geist(48, weight: .bold))
                    .foregroundColor(SiphonTheme.accent)
                
                Text(languageService.s("welcome_to_siphon"))
                    .font(.geist(26, weight: .bold))
            }
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(SiphonTheme.statusQueued)
                    Text(languageService.s("legal_disclaimer"))
                        .font(.geist(14, weight: .bold))
                }
                
                ScrollView {
                    Text(languageService.s("legal_disclaimer_message"))
                        .font(.geist(12))
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxHeight: 180)
                .padding(12)
                .background(
                    SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl)
                )
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                .overlay(
                    SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl)
                )
            }
            .padding(.horizontal, 36)
            
            Button {
                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.disclaimerAcknowledged)
                languageService.isFirstLaunch = false
                dismiss()
            } label: {
                Text(languageService.s("start_using"))
                    .font(.geist(14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(SiphonTheme.primaryGradient)
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 6, y: 2)
            .padding(.horizontal, 36)
        }
        .padding(.vertical, 32)
        .frame(width: 480)
    }
}
