import SwiftUI
#if os(macOS)
import AppKit
#endif

// Makes the main window transparent so .ultraThinMaterial shows desktop blur
struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = ""
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var showUpdateAlert = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    
    var body: some View {
        ZStack {
            mainLayout
                .preferredColorScheme(theme == "light" ? .light : (theme == "dark" ? .dark : nil))
                .background(MainWindowConfigurator())
                .onChange(of: appState.showAddDownloadSheet) { _, newValue in
                    if newValue {
                        AddDownloadWindowManager.shared.showAddDownloadWindow(downloadManager: downloadManager, appState: appState, languageService: languageService)
                        appState.showAddDownloadSheet = false
                    }
                }
                .task {
                    await downloadManager.initialize(languageService: languageService)
                    await updateChecker.checkForUpdates()
                    if updateChecker.hasUpdate {
                        showUpdateAlert = true
                    }
                }
                .onChange(of: languageService.selectedLanguage) { _, _ in
                    MenuBarManager.shared.updateMenu()
                }
                .onChange(of: theme) { _, _ in
                    MenuBarManager.shared.updateMenu()
                }
                .onChange(of: showMenuBarIcon) { _, newValue in
                    MenuBarManager.shared.setVisible(newValue)
                }
                .alert(item: $downloadManager.ytdlpUpdateMessage) { status in
                    Alert(
                        title: Text(status.title),
                        message: Text(status.message),
                        dismissButton: .default(Text(languageService.s("ok")))
                    )
                }
        }
        .alert(languageService.s("update_available_title"), isPresented: $showUpdateAlert) {
            Button(languageService.s("update_now")) {
                showNativeSettingsWindow()
            }
            Button(languageService.s("later"), role: .cancel) { }
        } message: {
            Text(String(format: languageService.s("update_available_message"), updateChecker.latestVersion ?? ""))
        }
        .frame(minWidth: 900, minHeight: 600)
    }
    
    @ViewBuilder
    private var mainLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .background(.ultraThinMaterial)
        .siphonEnvironmentalBackdrop()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if (appState.selectedNavItem == .downloading || appState.selectedNavItem == .queued) &&
                    (downloadManager.downloadingCount > 0 || downloadManager.queuedCount > 0) {
                    Button {
                        downloadManager.stopAllDownloads()
                    } label: {
                        Label(languageService.s("stop_all"), systemImage: "stop.circle")
                    }
                    .help(languageService.s("stop_all"))
                    .accessibilityLabel(languageService.s("stop_all"))
                } else if appState.selectedNavItem == .completed && !downloadManager.completedDownloads.isEmpty {
                    Button {
                        downloadManager.clearDownloads(downloadManager.completedDownloads)
                    } label: {
                        Label(languageService.s("clear_history"), systemImage: "trash")
                    }
                    .help(languageService.s("clear_history_help"))
                    .accessibilityLabel(languageService.s("clear_history"))
                } else if appState.selectedNavItem == .failed && !downloadManager.failedDownloads.isEmpty {
                    Button {
                        downloadManager.clearDownloads(downloadManager.failedDownloads)
                    } label: {
                        Label(languageService.s("clear_history"), systemImage: "trash")
                    }
                    .help(languageService.s("clear_history_help"))
                    .accessibilityLabel(languageService.s("clear_history"))
                }
                
                Button {
                    appState.showAddDownloadSheet = true
                } label: {
                    Label(languageService.s("new_download"), systemImage: "plus")
                        .help(languageService.s("new_download"))
                        .accessibilityLabel(languageService.s("new_download"))
                }
            }
        }
    }
}

#if os(macOS)
@MainActor
private func showNativeSettingsWindow() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}
#endif

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    
    var body: some View {
        List {
            Section {
                sidebarButton(item: .home)
            }
            
            Section(languageService.s("downloading")) {
                sidebarButton(item: .downloading, badgeCount: downloadManager.downloadingCount, badgeColor: SiphonTheme.statusDownloading)
                sidebarButton(item: .queued, badgeCount: downloadManager.queuedCount, badgeColor: SiphonTheme.statusQueued)
            }
            
            Section(languageService.s("history")) {
                sidebarButton(item: .completed, badgeCount: downloadManager.completedCount, badgeColor: SiphonTheme.statusCompleted)
                sidebarButton(item: .failed, badgeCount: downloadManager.failedCount, badgeColor: SiphonTheme.statusFailed)
            }
        }
        .listStyle(.sidebar)
        .siphonSidebarWidth()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                SponsorView()
                
                Button {
                    PreferencesWindowManager.shared.showPreferencesWindow(
                        languageService: languageService,
                        updateChecker: updateChecker,
                        downloadManager: downloadManager
                    )
                } label: {
                    HStack {
                        Image(systemName: "gear")
                        Text(languageService.s("settings"))
                            .font(.geist(13, weight: .medium))
                        Spacer()
                        Text("⌘,")
                            .font(.geistMono(10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .siphonInteractiveGlass(cornerRadius: SiphonTheme.radiusControl)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            .padding(.bottom, 8)
        }
    }
    
    @ViewBuilder
    private func sidebarButton(item: NavigationItem, badgeCount: Int = 0, badgeColor: Color = .blue) -> some View {
        let isSelected = appState.selectedNavItem == item
        Button {
            if appState.selectedNavItem != item {
                appState.selectedNavItem = item
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundColor(isSelected ? SiphonTheme.accent : .secondary)
                Text(item.title(lang: languageService))
                    .font(.geist(13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
                Spacer()
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.geist(10, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.18))
                        .foregroundColor(badgeColor)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bouncy(scale: 0.97, hover: 1.01))
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .listRowBackground(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                .fill(isSelected ? SiphonTheme.accent.opacity(0.12) : Color.clear)
                .padding(.horizontal, 2)
        )
    }
}

extension View {
    @ViewBuilder
    func siphonSidebarWidth() -> some View {
        self.navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }
}

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    
    var body: some View {
        ZStack {
            switch appState.selectedNavItem {
            case .home:
                HomeView()
            case .downloading:
                DownloadListView(downloads: downloadManager.downloadingDownloads, emptyMessage: languageService.s("empty_downloading"), showStop: true)
            case .queued:
                DownloadListView(downloads: downloadManager.queuedDownloads, emptyMessage: languageService.s("empty_queued"), showStop: true)
            case .completed:
                DownloadListView(downloads: downloadManager.completedDownloads, emptyMessage: languageService.s("empty_completed"), showStop: false)
            case .failed:
                DownloadListView(downloads: downloadManager.failedDownloads, emptyMessage: languageService.s("empty_failed"), showStop: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.30, dampingFraction: 0.72), value: appState.selectedNavItem)
    }
}

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @State private var isLogoHovered = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                Spacer(minLength: 20)
                
                // Logo & Title Section
                VStack(spacing: 20) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .purple.opacity(isLogoHovered ? 0.6 : 0.4), radius: isLogoHovered ? 32 : 24, x: 0, y: isLogoHovered ? 12 : 8)
                        .shadow(color: .blue.opacity(isLogoHovered ? 0.35 : 0.2), radius: isLogoHovered ? 48 : 40, x: 0, y: 12)
                        .scaleEffect(isLogoHovered ? 1.06 : 1.0)
                        .animation(.spring(response: 0.32, dampingFraction: 0.65), value: isLogoHovered)
                        .onHover { hovering in
                            isLogoHovered = hovering
                        }
                    
                    VStack(spacing: 8) {
                        Text("Siphon")
                            .font(.geist(42, weight: .black))
                        
                        Text(languageService.s("url_placeholder"))
                            .font(.geist(17))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                
                // Action Button
                Button {
                    appState.showAddDownloadSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.geist(16, weight: .semibold))
                        Text(languageService.s("new_download"))
                            .font(.geist(15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(
                        SiphonTheme.primaryGradient
                    )
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 12, y: 4)
                }
                .buttonStyle(.bouncy(scale: 0.94, hover: 1.03))
                .keyboardShortcut("n", modifiers: .command)
                
                // Stats Grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                    StatCard(title: languageService.s("stat_downloading"), count: downloadManager.downloadingCount, color: SiphonTheme.downloading) {
                        appState.selectedNavItem = .downloading
                    }
                    StatCard(title: languageService.s("stat_queued"), count: downloadManager.queuedCount, color: SiphonTheme.queued) {
                        appState.selectedNavItem = .queued
                    }
                    StatCard(title: languageService.s("stat_completed"), count: downloadManager.completedCount, color: SiphonTheme.completed) {
                        appState.selectedNavItem = .completed
                    }
                    StatCard(title: languageService.s("stat_failed"), count: downloadManager.failedCount, color: SiphonTheme.failed) {
                        appState.selectedNavItem = .failed
                    }
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 850)
                
                Spacer(minLength: 20)
                
                // Version info footer
                if let version = downloadManager.ytdlpVersion {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.geist(10))
                        Text("yt-dlp \(version)")
                            .font(.geistMono(11, weight: .medium))
                    }
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 520)
            .padding(.vertical, 20)
        }
        .background(.ultraThinMaterial)
        .alert(languageService.s("whats_new_title"), isPresented: $downloadManager.showWhatsNew) {
            Button(languageService.s("star_github")) {
                if let url = URL(string: "https://github.com/marspater/jolly-hopper") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(languageService.s("ok")) { }
        } message: {
            Text(languageService.s("whats_new_message"))
        }
    }
}

struct StatCard: View {
    @EnvironmentObject var languageService: LanguageService
    let title: String
    let count: Int
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("\(count)")
                    .font(.geist(28, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(color)
                Text(title)
                    .font(.geist(13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.80))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .siphonInteractiveGlass(cornerRadius: SiphonTheme.radiusCard, tintColor: color)
        }
        .buttonStyle(.bouncy(scale: 0.95, hover: 1.025))
    }
}

struct SponsorView: View {
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovered = false
    
    var body: some View {
        Button {
            if let url = URL(string: "https://github.com/marspater/jolly-hopper") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundColor(SiphonTheme.statusQueued)
                    .font(.geist(12, weight: .semibold))
                Text(languageService.s("star_github"))
                    .font(.geist(12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.geist(10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                    .fill(
                        colorScheme == .light
                            ? (isHovered ? Color(white: 0.91) : Color(white: 0.96))
                            : (isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                    .strokeBorder(
                        colorScheme == .light
                            ? Color.black.opacity(isHovered ? 0.14 : 0.08)
                            : Color.white.opacity(isHovered ? 0.20 : 0.10),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.bouncy(scale: 0.96, hover: 1.02))
        .padding(.horizontal, 8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}
