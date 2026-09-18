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
    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op: Window configuration does not require dynamic view updates
    }
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
                .background(MainWindowConfigurator())
                .onAppear {
                    SiphonTheme.applyTheme(theme)
                }
                .onChange(of: theme) { _, newTheme in
                    SiphonTheme.applyTheme(newTheme)
                }
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
        .siphonAdaptiveRendering()
        .alert(languageService.s("update_available_title"), isPresented: $showUpdateAlert) {
            Button(languageService.s("update_now")) {
                PreferencesWindowManager.shared.showPreferencesWindow(
                    languageService: languageService,
                    updateChecker: updateChecker,
                    downloadManager: downloadManager,
                    initialTab: .about
                )
            }
            Button(languageService.s("later"), role: .cancel) { }
        } message: {
            Text(String(format: languageService.s("update_available_message"), updateChecker.latestVersion ?? ""))
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 580, idealHeight: 620)
    }
    
    @ViewBuilder
    private var mainLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .siphonWindowBackground()
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
                        downloadManager.clearCompletedDownloads()
                    } label: {
                        Label(languageService.s("clear_history"), systemImage: "trash")
                    }
                    .help(languageService.s("clear_history_help"))
                    .accessibilityLabel(languageService.s("clear_history"))
                } else if appState.selectedNavItem == .failed && !downloadManager.failedDownloads.isEmpty {
                    Button {
                        downloadManager.clearFailedDownloads()
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

struct SidebarView: View {
    @Environment(\.appearsActive) private var appearsActive
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    var body: some View {
        VStack(spacing: 0) {
            // Sidebar Header with Radiant Siphon Halo Logo
            sidebarHeader
                .opacity(appearsActive ? 1.0 : 0.62)
                .padding(.top, 28)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            List {
                sidebarButton(item: .home)
                
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
        }
        .siphonSidebarWidth()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: SiphonTheme.spacing10) {
                // Catchy Slogan
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play videos.")
                        .font(.geist(13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Your way.")
                        .font(.geist(13, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)

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
            .padding(.bottom, SiphonTheme.spacing10)
            .opacity(appearsActive ? 1.0 : 0.62)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            RadiantSiphonLogoView()

            VStack(alignment: .leading, spacing: 1) {
                Text("Siphon")
                    .font(.geist(15, weight: .bold))
                    .foregroundColor(.primary)
                Text(languageService.s("video_downloader"))
                    .font(.geist(11, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer()
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
        .buttonStyle(.bouncySubtle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .listRowBackground(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                .fill(isSelected ? SiphonTheme.accent.opacity(0.18) : Color.clear)
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
                DownloadListView(downloads: downloadManager.downloadingDownloads, emptyMessage: languageService.s("empty_downloading"), emptyIcon: "arrow.down.circle", showStop: true)
            case .queued:
                DownloadListView(downloads: downloadManager.queuedDownloads, emptyMessage: languageService.s("empty_queued"), emptyIcon: "clock", showStop: true)
            case .completed:
                DownloadListView(downloads: downloadManager.completedDownloads, emptyMessage: languageService.s("empty_completed"), emptyIcon: "checkmark.circle", showStop: false)
            case .failed:
                DownloadListView(downloads: downloadManager.failedDownloads, emptyMessage: languageService.s("empty_failed"), emptyIcon: "exclamationmark.triangle", showStop: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(SiphonAnimation.fluidSpring, value: appState.selectedNavItem)
    }
}

struct HomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    
    var body: some View {
        ScrollView {
            VStack(spacing: SiphonTheme.spacing20) {
                // Top Header: Ready to download + More videos. A calmer internet.
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(languageService.s("ready_to_download"))
                            .font(.geist(26, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Text(languageService.s("ready_to_download_subtitle"))
                            .font(.geist(13, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer(minLength: 20)
                    
                    VStack(alignment: .trailing, spacing: 5) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 28, height: 1.5)
                        
                        Text(languageService.s("more_videos_calmer_internet"))
                            .font(.geist(11, weight: .medium))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineSpacing(2)
                    }
                }
                .padding(.horizontal, SiphonTheme.spacing24)
                .padding(.top, SiphonTheme.spacing16)
                
                // Hero Drop URL Zone
                HeroDropURLView()
                    .padding(.horizontal, SiphonTheme.spacing24)
                
                // Status Bar with Liquid Water & Circular Progress Rings
                StatusBarView()
                    .padding(.horizontal, SiphonTheme.spacing24)
                
                // Recent Downloads Section
                recentDownloadsSection
                    .padding(.horizontal, SiphonTheme.spacing24)
                
                Spacer(minLength: SiphonTheme.spacing12)
                
                // Footer
                HStack {
                    if let version = downloadManager.ytdlpVersion {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10, weight: .medium))
                            Text("yt-dlp \(version)")
                                .font(.geistMono(11, weight: .medium))
                        }
                        .foregroundColor(.secondary.opacity(0.8))
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Text("Built for a more open internet.")
                            .font(.geist(11, weight: .regular))
                            .foregroundColor(.secondary.opacity(0.7))
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundColor(colorScheme == .light ? SiphonTheme.accent : Color.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, SiphonTheme.spacing24)
                .padding(.bottom, SiphonTheme.spacing12)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SiphonTheme.spacing12)
        }
        .background(
            GeometryReader { proxy in
                RadialGradient(
                    gradient: Gradient(colors: [
                        SiphonTheme.accent.opacity(0.12),
                        SiphonTheme.accent.opacity(0.03),
                        Color.clear
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.20),
                    startRadius: 20,
                    endRadius: max(proxy.size.width * 0.45, 380)
                )
                .allowsHitTesting(false)
            }
        )
    }
    
    // MARK: - Recent Downloads Section
    
    @ViewBuilder
    private var recentDownloadsSection: some View {
        VStack(spacing: SiphonTheme.spacing10) {
            HStack {
                Text(languageService.s("recent_downloads"))
                    .font(.geist(14, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button {
                    appState.selectedNavItem = downloadManager.mostRelevantNavigationItem
                } label: {
                    HStack(spacing: 4) {
                        Text(languageService.s("see_all"))
                            .font(.geist(12, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(languageService.s("see_all"))
            }
            
            if downloadManager.downloads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text(languageService.s("no_recent_downloads"))
                        .font(.geist(13, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                    Text(languageService.s("no_recent_downloads_sub"))
                        .font(.geist(11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(
                    SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
                )
                .overlay(
                    SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(downloadManager.downloads.prefix(3)) { download in
                        RecentDownloadRowView(download: download)
                    }
                }
            }
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService

    var body: some View {
        let downloadingProgress: Double = {
            let active = downloadManager.downloadingDownloads
            guard !active.isEmpty else { return 0.0 }
            let sum = active.reduce(0.0) { $0 + ($1.progress.isNaN ? 0.0 : max(0.0, min(1.0, $1.progress))) }
            return sum / Double(active.count)
        }()

        HStack(spacing: 0) {
            StatusSegmentButton(
                item: .downloading,
                title: languageService.s("stat_downloading"),
                count: downloadManager.downloadingCount,
                color: SiphonTheme.statusDownloading,
                ringProgress: downloadManager.downloadingCount > 0 ? max(0.08, downloadingProgress) : 0.0,
                isActive: downloadManager.downloadingCount > 0
            )

            Rectangle()
                .fill(SiphonTheme.separator)
                .frame(width: 1, height: 26)

            StatusSegmentButton(
                item: .queued,
                title: languageService.s("stat_queued"),
                count: downloadManager.queuedCount,
                color: SiphonTheme.statusQueued,
                ringProgress: downloadManager.queuedCount > 0 ? 0.5 : 0.0,
                isActive: downloadManager.queuedCount > 0
            )

            Rectangle()
                .fill(SiphonTheme.separator)
                .frame(width: 1, height: 26)

            StatusSegmentButton(
                item: .completed,
                title: languageService.s("stat_completed"),
                count: downloadManager.completedCount,
                color: SiphonTheme.statusCompleted,
                ringProgress: 1.0,
                isActive: downloadManager.completedCount > 0
            )

            Spacer(minLength: 0)

            Button {
                appState.selectedNavItem = downloadManager.mostRelevantNavigationItem
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .help(languageService.s("see_all"))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .siphonGlassSurface(cornerRadius: SiphonTheme.radiusStatusGroup)
    }
}

struct StatusSegmentButton: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    let item: NavigationItem
    let title: String
    let count: Int
    let color: Color
    let ringProgress: Double
    let isActive: Bool

    @State private var isHovered = false
    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared

    private var segmentSeed: Double {
        switch item {
        case .downloading:
            return 1.414
        case .queued:
            return 4.718
        case .completed:
            return 8.291
        default:
            return 0.0
        }
    }

    var body: some View {
        Button {
            appState.selectedNavItem = item
        } label: {
            ZStack {
                // Liquid water wave animation in accent color (ambient in background)
                LiquidWaterWaveView(color: color, isHovered: isHovered, isActive: isActive, seed: segmentSeed)
                    .opacity(isActive ? 0.70 : (isHovered ? 0.45 : 0.15))
                    .animation(SiphonAnimation.hoverSpring, value: isHovered)
                    .animation(SiphonAnimation.fluidSpring, value: isActive)
                    .zIndex(0)

                // Status text, count, and progress ring prominently in the front
                HStack(spacing: 8) {
                    // Circular Progress Ring
                    ZStack {
                        Circle()
                            .stroke(color.opacity(0.35), lineWidth: 2)
                            .frame(width: 16, height: 16)

                        Circle()
                            .trim(from: 0, to: CGFloat(ringProgress))
                            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 16, height: 16)

                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .opacity(isActive ? 1.0 : (isHovered ? 0.85 : 0.45))
                    }

                    Text("\(count)")
                        .font(.geistMono(13, weight: .bold))
                        .foregroundColor(count > 0 ? .primary : (isHovered ? .primary : .secondary))

                    Text(title)
                        .font(.geist(13, weight: .semibold))
                        .foregroundColor(count > 0 || isActive ? .primary : (isHovered ? .primary : .secondary))
                }
                .padding(.horizontal, 16)
                .zIndex(1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Button("\(title): \(count)") {
                appState.selectedNavItem = item
            }
            .accessibilityValue(isActive ? "Active" : "")
            .accessibilityHint("Show \(title.lowercased()) downloads")
        }
        .onHover { hovering in
            withAnimation(SiphonAnimation.hoverSpring) {
                isHovered = hovering
            }
        }
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
                SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl, isHovered: isHovered)
            )
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
            .overlay(
                SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusControl, isHovered: isHovered)
            )
        }
        .buttonStyle(.bouncy(scale: 0.97, hover: 1.015))
        .padding(.horizontal, SiphonTheme.spacing8)
        .help(languageService.s("star_github"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(languageService.s("star_github"))
        .onHover { hovering in
            withAnimation(SiphonAnimation.hoverSpring) {
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
                    Text(languageService.s("whats_new_badge"))
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

                Text(languageService.s("whats_new_title"))
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

            SiphonTheme.subtleDivider
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

            SiphonTheme.subtleDivider
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
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
                .ignoresSafeArea()
        )
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
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
                RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                    .fill(feature.iconColor.opacity(isHovered ? 0.18 : 0.12))
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
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
            withAnimation(SiphonAnimation.hoverSpring) {
                isHovered = hovering
            }
        }
    }
}
