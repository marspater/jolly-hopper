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
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
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
                .sheet(isPresented: $languageService.isFirstLaunch) {
                    WelcomeView()
                        .environmentObject(languageService)
                        .interactiveDismissDisabled()
                }
                .task {
                    await MainActor.run {
                        NotificationService.shared.requestPermission()
                    }
                    
                    await downloadManager.initialize(languageService: languageService)
                    await updateChecker.checkForUpdates()
                    if updateChecker.hasUpdate {
                        showUpdateAlert = true
                    }
                }
                .onChange(of: languageService.selectedLanguage) { _ in
                    MenuBarManager.shared.updateMenu()
                }
                .onChange(of: theme) { _ in
                    MenuBarManager.shared.updateMenu()
                }
                .onChange(of: showMenuBarIcon) { newValue in
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
        .alert(isPresented: $showUpdateAlert) {
            Alert(
                title: Text(languageService.s("update_available_title")),
                message: Text(String(format: languageService.s("update_available_message"), updateChecker.latestVersion ?? "")),
                primaryButton: .default(Text(languageService.s("update_now"))) {
                    showNativeSettingsWindow()
                },
                secondaryButton: .cancel(Text(languageService.s("later")))
            )
        }
        .frame(minWidth: 900, minHeight: 600)
    }
    
    @ViewBuilder
    private var mainLayout: some View {
        if #available(macOS 13.0, *) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
            } detail: {
                DetailView()
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationView {
                SidebarView()
                DetailView()
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
            
            Section(header: Text(languageService.s("downloading"))) {
                sidebarButton(item: .downloading, badgeCount: downloadManager.downloadingCount, badgeColor: Color(.displayP3, red: 0.15, green: 0.55, blue: 1.0))
                sidebarButton(item: .queued, badgeCount: downloadManager.queuedCount, badgeColor: Color(.displayP3, red: 0.95, green: 0.55, blue: 0.15))
            }
            
            Section(header: Text(languageService.s("history"))) {
                sidebarButton(item: .completed, badgeCount: downloadManager.completedCount, badgeColor: Color(.displayP3, red: 0.20, green: 0.65, blue: 0.35))
                sidebarButton(item: .failed, badgeCount: downloadManager.failedCount, badgeColor: Color(.displayP3, red: 0.90, green: 0.25, blue: 0.35))
            }
        }
        .listStyle(.sidebar)
        .siphonSidebarWidth()
        .overlay(
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
                            .font(.geist(10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            .padding(.bottom, 8)
            .padding(.top, 8)
            .background(Color(NSColor.windowBackgroundColor))
            , alignment: .bottom
        )
        .toolbar {
            ToolbarItem {
                Button {
                    appState.showAddDownloadSheet = true
                } label: {
                    Label(languageService.s("new_download"), systemImage: "plus")
                }
            }
        }
    }
    
    @ViewBuilder
    private func sidebarButton(item: NavigationItem, badgeCount: Int = 0, badgeColor: Color = .blue) -> some View {
        let isSelected = appState.selectedNavItem == item
        Button {
            withAnimation(.smooth(duration: 0.22)) {
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
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.18))
                        .foregroundColor(badgeColor)
                        .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? SiphonTheme.accent.opacity(0.12) : Color.clear)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        )
    }
}

extension View {
    @ViewBuilder
    func siphonSidebarWidth() -> some View {
        self.frame(minWidth: 200, idealWidth: 220, maxWidth: .infinity)
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
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.99)),
                        removal: .opacity
                    ))
            case .downloading:
                DownloadListView(downloads: downloadManager.downloadingDownloads, emptyMessage: languageService.s("empty_downloading"), showStop: true)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.99)),
                        removal: .opacity
                    ))
            case .queued:
                DownloadListView(downloads: downloadManager.queuedDownloads, emptyMessage: languageService.s("empty_queued"), showStop: true)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.99)),
                        removal: .opacity
                    ))
            case .completed:
                DownloadListView(downloads: downloadManager.completedDownloads, emptyMessage: languageService.s("empty_completed"), showStop: false)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.99)),
                        removal: .opacity
                    ))
            case .failed:
                DownloadListView(downloads: downloadManager.failedDownloads, emptyMessage: languageService.s("empty_failed"), showStop: false)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.99)),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.22), value: appState.selectedNavItem)
    }
}

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @State private var isLogoHovered = false
    @State private var isButtonHovered = false
    
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
                        .scaleEffect(isLogoHovered ? 1.05 : 1.0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isLogoHovered)
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
                            .font(.system(size: 16, weight: .semibold))
                        Text(languageService.s("new_download"))
                            .font(.geist(15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.20, green: 0.50, blue: 1.0),
                                Color(red: 0.12, green: 0.40, blue: 0.95)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .scaleEffect(isButtonHovered ? 1.03 : 1.0)
                .shadow(color: Color.blue.opacity(isButtonHovered ? 0.5 : 0.3), radius: isButtonHovered ? 14 : 10, y: isButtonHovered ? 6 : 4)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isButtonHovered)
                .onHover { hovering in
                    isButtonHovered = hovering
                }
                
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
                            .font(.system(size: 10))
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
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
        .alert(isPresented: $downloadManager.showWhatsNew) {
            Alert(
                title: Text(languageService.s("whats_new_title")),
                message: Text(languageService.s("whats_new_message")),
                primaryButton: .default(Text(languageService.s("star_github"))) {
                    if let url = URL(string: "https://github.com/marspater/jolly-hopper") {
                        NSWorkspace.shared.open(url)
                    }
                },
                secondaryButton: .default(Text(languageService.s("ok")))
            )
        }
    }
}

struct StatCard: View {
    @EnvironmentObject var languageService: LanguageService
    let title: String
    let count: Int
    let color: Color
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("\(count)")
                    .font(.geist(30, weight: .bold))
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                Text(title)
                    .font(.geist(12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                SiphonTheme.cardBackground(cornerRadius: 14, isHovered: isHovered)
            )
            .cornerRadius(14)
            .overlay(
                SiphonTheme.cardBorder(cornerRadius: 14, isHovered: isHovered)
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 8 : 3, x: 0, y: 2)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct SponsorView: View {
    @EnvironmentObject var languageService: LanguageService
    @State private var isHovered = false
    
    var body: some View {
        Button {
            if let url = URL(string: "https://github.com/marspater/jolly-hopper") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12, weight: .semibold))
                Text(languageService.s("star_github"))
                    .font(.geist(12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    #if os(macOS)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    #endif
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03))
                }
            )
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? Color.primary.opacity(0.18) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}
