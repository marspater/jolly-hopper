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
                .sheet(isPresented: $downloadManager.showWhatsNew) {
                    WhatsNewSheetView()
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
                if (appState.selectedNavItem == .downloading || appState.selectedNavItem == .queued || appState.selectedNavItem == .home) &&
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
            VStack(spacing: SiphonTheme.spacing8) {
                SponsorView()
                
                Button {
                    PreferencesWindowManager.shared.showPreferencesWindow(
                        languageService: languageService,
                        updateChecker: updateChecker,
                        downloadManager: downloadManager
                    )
                } label: {
                    HStack(spacing: SiphonTheme.spacing8) {
                        Image(systemName: "gear")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(languageService.s("settings"))
                            .font(.geist(13, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        Text("⌘,")
                            .font(.geistMono(10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, SiphonTheme.spacing12)
                    .padding(.vertical, SiphonTheme.spacing8)
                    .siphonInteractiveGlass(cornerRadius: SiphonTheme.radiusControl)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, SiphonTheme.spacing8)
            }
            .padding(.bottom, SiphonTheme.spacing8)
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
            HStack(spacing: SiphonTheme.spacing8) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundColor(isSelected ? SiphonTheme.accent : .secondary)
                Text(item.title(lang: languageService))
                    .font(.geist(13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
                Spacer()
                if badgeCount > 0 {
                    SiphonTagBadge(text: "\(badgeCount)", tintColor: badgeColor, isMonospaced: true)
                }
            }
            .padding(.horizontal, SiphonTheme.spacing8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bouncy(scale: 0.98, hover: 1.01))
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
            VStack(spacing: SiphonTheme.spacing32) {
                Spacer(minLength: SiphonTheme.spacing20)
                
                // Logo & Title Section
                VStack(spacing: SiphonTheme.spacing16) {
                    let reduceMotion = AdaptiveRenderingEnvironment.shared.capabilities.reduceMotion
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 92, height: 92)
                        .shadow(
                            color: SiphonTheme.accent.opacity(isLogoHovered ? 0.35 : 0.20),
                            radius: isLogoHovered ? 18 : 12,
                            x: 0,
                            y: isLogoHovered ? 8 : 4
                        )
                        .scaleEffect(reduceMotion ? 1.0 : (isLogoHovered ? 1.025 : 1.0))
                        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.65), value: isLogoHovered)
                        .onHover { hovering in
                            isLogoHovered = hovering
                        }
                    
                    VStack(spacing: SiphonTheme.spacing6) {
                        Text("Siphon")
                            .font(.geist(36, weight: .bold))
                        
                        Text(languageService.s("url_placeholder"))
                            .font(.geist(15))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, SiphonTheme.spacing24)
                    }
                }
                
                // Action Button
                Button {
                    appState.showAddDownloadSheet = true
                } label: {
                    HStack(spacing: SiphonTheme.spacing8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text(languageService.s("new_download"))
                            .font(.geist(14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, SiphonTheme.spacing24)
                    .padding(.vertical, SiphonTheme.spacing10)
                    .background(
                        SiphonTheme.primaryGradient
                    )
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(.bouncy(scale: 0.96, hover: 1.015))
                .keyboardShortcut("n", modifiers: .command)
                
                // Stats Grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SiphonTheme.spacing14), count: 4), spacing: SiphonTheme.spacing14) {
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
                .padding(.horizontal, SiphonTheme.spacing32)
                .frame(maxWidth: 820)
                
                Spacer(minLength: SiphonTheme.spacing20)
                
                // Version info footer
                if let version = downloadManager.ytdlpVersion {
                    HStack(spacing: SiphonTheme.spacing6) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10, weight: .medium))
                        Text("yt-dlp \(version)")
                            .font(.geistMono(11, weight: .medium))
                    }
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.bottom, SiphonTheme.spacing16)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 500)
            .padding(.vertical, SiphonTheme.spacing20)
        }
        .background(.ultraThinMaterial)
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
            VStack(spacing: SiphonTheme.spacing4) {
                Text("\(count)")
                    .font(.geist(26, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(color)
                Text(title)
                    .font(.geist(12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .padding(.vertical, SiphonTheme.spacing8)
            .padding(.horizontal, SiphonTheme.spacing6)
            .siphonInteractiveGlass(cornerRadius: SiphonTheme.radiusCard, tintColor: color)
        }
        .buttonStyle(.bouncy(scale: 0.97, hover: 1.015))
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
            HStack(spacing: SiphonTheme.spacing8) {
                Image(systemName: "star.fill")
                    .foregroundColor(SiphonTheme.statusQueued)
                    .font(.system(size: 11, weight: .semibold))
                Text(languageService.s("star_github"))
                    .font(.geist(12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, SiphonTheme.spacing12)
            .padding(.vertical, SiphonTheme.spacing8)
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
        .buttonStyle(.bouncy(scale: 0.97, hover: 1.015))
        .padding(.horizontal, SiphonTheme.spacing8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}

struct WhatsNewSheetView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header - Clean, non-redundant title and version pill
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("WHAT'S NEW")
                        .font(.geist(10, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(SiphonTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SiphonTheme.accent.opacity(0.12))
                        .clipShape(Capsule())

                    SiphonTagBadge(
                        text: "v\(downloadManager.appVersion)",
                        tintColor: SiphonTheme.accent,
                        isMonospaced: true
                    )
                }

                Text("What's New in Siphon")
                    .font(.geist(22, weight: .bold))
                    .foregroundColor(.primary)

                Text(languageService.s("whats_new_subtitle"))
                    .font(.geist(13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, SiphonTheme.spacing24)
            .padding(.horizontal, SiphonTheme.spacing24)
            .padding(.bottom, SiphonTheme.spacing16)

            Divider()
                .padding(.horizontal, SiphonTheme.spacing20)

            // Feature Showcase - Beautiful structured cards instead of raw unstyled markdown
            ScrollView(showsIndicators: true) {
                VStack(spacing: 10) {
                    ForEach(downloadManager.whatsNewFeatures) { feature in
                        FeatureCardRow(feature: feature)
                    }
                }
                .padding(.horizontal, SiphonTheme.spacing24)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 330)

            Divider()
                .padding(.horizontal, SiphonTheme.spacing20)

            // Footer Actions
            HStack(spacing: SiphonTheme.spacing12) {
                Button {
                    if let url = URL(string: "https://github.com/marspater/jolly-hopper/releases") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                        Text(languageService.s("view_on_github"))
                            .font(.geist(12, weight: .medium))
                    }
                }
                .buttonStyle(.siphonSecondary)
                .help("View release notes on GitHub")

                Spacer()

                Button {
                    downloadManager.showWhatsNew = false
                    dismiss()
                } label: {
                    Text(languageService.s("continue"))
                        .font(.geist(13, weight: .semibold))
                        .frame(minWidth: 100)
                }
                .buttonStyle(.siphonPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, SiphonTheme.spacing24)
            .padding(.vertical, SiphonTheme.spacing16)
        }
        .frame(width: 540, height: 520)
        .background(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusCard)
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        )
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusCard)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .ignoresSafeArea()
        )
    }
}

private struct FeatureCardRow: View {
    let feature: ReleaseFeature
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Category Icon Squircle
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(feature.iconColor.opacity(isHovered ? 0.18 : 0.12))
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(feature.iconColor.opacity(isHovered ? 0.35 : 0.20), lineWidth: 1)
                    )

                Image(systemName: feature.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(feature.iconColor)
            }

            // Title & Description
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.geist(13, weight: .semibold))
                    .foregroundColor(.primary)

                Text(feature.description)
                    .font(.geist(12))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                .fill(Color.primary.opacity(isHovered ? 0.055 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                .stroke(Color.primary.opacity(isHovered ? 0.10 : 0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}
