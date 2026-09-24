import SwiftUI
#if os(macOS)
import AppKit
#endif

// Makes the main window transparent so .ultraThinMaterial shows desktop blur
struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
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
    func updateNSView(_ _: NSView, context _: Context) {
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
                    // When Siphon only hosts the unit tests, do not load or persist
                    // the user's history, install binaries, or query GitHub.
                    guard !NotificationService.isRunningTests else { return }
                    downloadManager.initialize(languageService: languageService)
                    await appState.initializeApplicationServices(
                        ytdlpService: downloadManager.ytdlpService,
                        languageService: languageService
                    )
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
                .sheet(isPresented: $appState.showWhatsNew) {
                    WhatsNewSheetView()
                }
                .alert(item: $appState.ytdlpUpdateMessage) { status in
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
                    appState: appState,
                    initialTab: .about
                )
            }
            Button(languageService.s("later"), role: .cancel) {
                // User chose to dismiss update alert (swift:S1186)
            }
        } message: {
            Text(String(format: languageService.s("update_available_message"), updateChecker.latestVersion ?? ""))
        }
        .alert(languageService.s("queue_recovery_title"), isPresented: $downloadManager.showQueueRecoveryAlert) {
            Button(languageService.s("queue_recovery_restore")) {
                downloadManager.recoverInterruptedJobs()
            }
            Button(languageService.s("queue_recovery_discard"), role: .cancel) {
                downloadManager.discardInterruptedJobs()
            }
        } message: {
            Text(String(format: languageService.s("queue_recovery_message"), downloadManager.recoverableJobsCount))
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
                    sidebarButton(item: .downloading, badgeCount: downloadManager.downloadingCount, badgeColor: SiphonTheme.statusDownloadingText)
                    sidebarButton(item: .queued, badgeCount: downloadManager.queuedCount, badgeColor: SiphonTheme.statusQueuedText)
                }
                
                Section(languageService.s("history")) {
                    sidebarButton(item: .completed, badgeCount: downloadManager.completedCount, badgeColor: SiphonTheme.statusCompletedText)
                    sidebarButton(item: .failed, badgeCount: downloadManager.failedCount, badgeColor: SiphonTheme.statusFailedText)
                }
            }
            .listStyle(.sidebar)
        }
        .siphonSidebarWidth()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: SiphonTheme.spacing10) {
                // Catchy Slogan
                Text(languageService.s("play_videos_your_way"))
                    .font(.siphonStandardMedium)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)

                SponsorView()
                
                Button {
                    PreferencesWindowManager.shared.showPreferencesWindow(
                        languageService: languageService,
                        updateChecker: updateChecker,
                        downloadManager: downloadManager,
                        appState: appState
                    )
                } label: {
                    HStack(spacing: SiphonTheme.spacing8) {
                        Image(systemName: "gear")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(languageService.s("settings"))
                            .font(.siphonStandardMedium)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("⌘,")
                            .font(.siphonMicroMonoMedium)
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
                    .font(.siphonHeadline)
                    .foregroundColor(.primary)
                Text(languageService.s("video_downloader"))
                    .font(.siphonMetadata)
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
                    .foregroundColor(isSelected ? SiphonTheme.accentText : .secondary)
                Text(item.title(lang: languageService))
                    .font((isSelected ? .siphonStandardSemibold : .siphonStandardMedium))
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
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                .fill(isSelected ? SiphonTheme.accent.opacity(SiphonTheme.Opacity.tintSidebarSelected) : Color.clear)
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
                DownloadListView(downloads: downloadManager.downloadingDownloads, emptyMessage: languageService.s("empty_downloading"), emptyDetail: languageService.s("empty_downloading_detail"), emptyIcon: "arrow.down.circle", showStop: true)
            case .queued:
                DownloadListView(downloads: downloadManager.queuedDownloads, emptyMessage: languageService.s("empty_queued"), emptyDetail: languageService.s("empty_queued_detail"), emptyIcon: "clock", showStop: true)
            case .completed:
                DownloadListView(downloads: downloadManager.completedDownloads, emptyMessage: languageService.s("empty_completed"), emptyDetail: languageService.s("empty_completed_detail"), emptyIcon: "checkmark.circle", showStop: false)
            case .failed:
                DownloadListView(downloads: downloadManager.failedDownloads, emptyMessage: languageService.s("empty_failed"), emptyDetail: languageService.s("empty_failed_detail"), emptyIcon: "exclamationmark.triangle", showStop: false)
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
                            .font(.siphonHomeTitle)
                            .foregroundColor(.primary)
                        
                        Text(languageService.s("ready_to_download_subtitle"))
                            .font(.siphonStandard)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer(minLength: 20)
                    
                    VStack(alignment: .trailing, spacing: 5) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 28, height: 1.5)
                        
                        Text(languageService.s("more_videos_calmer_internet"))
                            .font(.siphonMetadataMedium)
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
                    if let version = appState.ytdlpVersion {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10, weight: .medium))
                            Text("yt-dlp \(version)")
                                .font(.siphonMetadataMonoMedium)
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Text(languageService.s("built_for_open_internet"))
                            .font(.siphonMetadata)
                            .foregroundColor(.secondary)
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundColor(SiphonTheme.accentText)
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
                    .font(.siphonPrimarySemibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button {
                    appState.selectedNavItem = downloadManager.mostRelevantNavigationItem
                } label: {
                    HStack(spacing: 4) {
                        Text(languageService.s("see_all"))
                            .font(.siphonSecondaryMedium)
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
                        .font(.siphonStandardMedium)
                        .foregroundColor(.primary)
                    Text(languageService.s("no_recent_downloads_sub"))
                        .font(.siphonMetadata)
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
                item: .completed,
                title: languageService.s("stat_completed"),
                count: downloadManager.completedCount,
                color: SiphonTheme.statusCompleted,
                ringProgress: 0.0,
                isActive: downloadManager.completedCount > 0
            )

            Rectangle()
                .fill(SiphonTheme.separator)
                .frame(width: 1, height: 26)

            StatusSegmentButton(
                item: .failed,
                title: languageService.s("stat_failed"),
                count: downloadManager.failedCount,
                color: SiphonTheme.statusFailed,
                ringProgress: 0.0,
                isActive: downloadManager.failedCount > 0
            )

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
            .accessibilityLabel(languageService.s("see_all"))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        // Glass on macOS 26 does not clip; keep segment fills inside the corners.
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusStatusGroup, style: .continuous))
        .siphonGlassSurface(cornerRadius: SiphonTheme.radiusStatusGroup)
    }
}

struct StatusSegmentButton: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.colorScheme) var colorScheme
    let item: NavigationItem
    let title: String
    let count: Int
    let color: Color
    let ringProgress: Double
    let isActive: Bool

    @State private var isHovered = false
    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared

    @ViewBuilder
    private var statusIndicator: some View {
        switch item {
        case .downloading:
            ZStack {
                Circle()
                    .stroke(readableColor.opacity(0.34), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(ringProgress))
                    .stroke(readableColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(readableColor)
                    .frame(width: 4.5, height: 4.5)
            }
            .frame(width: 16, height: 16)

        case .queued:
            Image(systemName: "clock.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(readableColor)
                .frame(width: 16, height: 16)

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(readableColor)
                .frame(width: 16, height: 16)

        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(readableColor)
                .frame(width: 16, height: 16)

        default:
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .frame(width: 16, height: 16)
        }
    }

    private var readableColor: Color {
        // An empty segment stays neutral: a red icon beside "0 Failed" reads as an error.
        guard isActive else { return .secondary }
        switch item {
        case .downloading:
            return SiphonTheme.statusForeground(for: .downloading, colorScheme: colorScheme)
        case .queued:
            return SiphonTheme.statusForeground(for: .queued, colorScheme: colorScheme)
        case .completed:
            return SiphonTheme.statusForeground(for: .completed, colorScheme: colorScheme)
        case .failed:
            return SiphonTheme.statusForeground(for: .failed, colorScheme: colorScheme)
        default:
            return color
        }
    }

    var body: some View {
        Button {
            appState.selectedNavItem = item
        } label: {
            ZStack {
                StatusSegmentFill(
                    color: color,
                    progress: item == .downloading ? ringProgress : nil,
                    isHovered: isHovered,
                    isActive: isActive
                )
                .zIndex(0)

                HStack(spacing: SiphonTheme.spacing8) {
                    statusIndicator

                    Text("\(count)")
                        .font(.siphonStandardSemibold)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                        .animation(SiphonAnimation.fluidSpring, value: count)
                        .foregroundColor((count > 0 || isHovered) ? .primary : .secondary)
                        .frame(minWidth: 20, alignment: .trailing)

                    Text(title)
                        .font(.siphonStandardSemibold)
                        .foregroundColor((count > 0 || isActive || isHovered) ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 16)
                .animation(SiphonAnimation.fluidSpring, value: isActive)
                .zIndex(1)
            }
            // Equal widths in every state, so the strip never reflows when a count changes.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Button("\(title): \(count)") {
                appState.selectedNavItem = item
            }
            .accessibilityValue(isActive ? languageService.s("status_active") : "")
            .accessibilityHint(String(format: languageService.s("show_downloads_hint"), title.lowercased()))
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
                    .foregroundColor(SiphonTheme.statusQueuedText)
                    .font(.system(size: 11, weight: .semibold))
                Text(languageService.s("star_github"))
                    .font(.siphonSecondaryMedium)
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
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
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
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header - Clean, non-redundant title and version pill
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(languageService.s("whats_new_badge"))
                        .font(.siphonMicroSemibold)
                        .tracking(1.2)
                        .foregroundColor(SiphonTheme.accentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SiphonTheme.accent.opacity(SiphonTheme.Opacity.tintBadge))
                        .clipShape(Capsule())

                    SiphonTagBadge(
                        text: "v\(appState.appVersion)",
                        tintColor: SiphonTheme.accent,
                        isMonospaced: true
                    )
                }

                Text(languageService.s("whats_new_title"))
                    .font(.siphonSheetTitle)
                    .foregroundColor(.primary)

                Text(languageService.s("whats_new_subtitle"))
                    .font(.siphonStandard)
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
                    ForEach(appState.whatsNewFeatures) { feature in
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
                            .font(.siphonSecondaryMedium)
                    }
                }
                .buttonStyle(.siphonSecondary)
                .help("View release notes on GitHub")

                Spacer()

                Button {
                    appState.showWhatsNew = false
                    dismiss()
                } label: {
                    Text(languageService.s("continue"))
                        .font(.siphonStandardSemibold)
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
                RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                    .fill(feature.iconColor.opacity(isHovered ? 0.18 : 0.12))
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                            .stroke(feature.iconColor.opacity(isHovered ? 0.35 : 0.20), lineWidth: 1)
                    )

                Image(systemName: feature.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(feature.iconColor)
            }

            // Title & Description
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.siphonStandardSemibold)
                    .foregroundColor(.primary)

                Text(feature.description)
                    .font(.siphonSecondary)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.055 : 0.035))
        )
        .overlay(
            SiphonTheme.cardBorder(
                cornerRadius: SiphonTheme.radiusControl,
                isHovered: isHovered,
                accentColor: feature.iconColor
            )
        )
        .siphonCardHover(isHovered: isHovered, tint: feature.iconColor)
        .onHover { hovering in
            withAnimation(SiphonAnimation.hoverSpring) {
                isHovered = hovering
            }
        }
    }
}
