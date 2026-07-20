import SwiftUI

struct ContentView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    @State private var showPreferences = false
    @State private var showUpdateAlert = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    
    var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                NavigationSplitView {
                    SidebarView(showPreferences: $showPreferences)
                } detail: {
                    DetailView()
                }
            } else {
                NavigationView {
                    SidebarView(showPreferences: $showPreferences)
                    DetailView()
                }
            }
        }
        .onChange(of: appState.showAddDownloadSheet) { newValue in
            if newValue {
                AddDownloadWindowManager.shared.showAddDownloadWindow(downloadManager: downloadManager, appState: appState, languageService: languageService)
                appState.showAddDownloadSheet = false
            }
        }
        .sheet(isPresented: $showPreferences) {
            PreferencesView()
                .environmentObject(downloadManager)
                .environmentObject(languageService)
                .environmentObject(updateChecker)
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
        .onChange(of: showMenuBarIcon) { newValue in
            MenuBarManager.shared.setVisible(newValue)
        }
        .alert(languageService.s("update_available_title"), isPresented: $showUpdateAlert) {
            Button(languageService.s("update_now")) {
                showPreferences = true
            }
            Button(languageService.s("later"), role: .cancel) { }
        } message: {
            Text(String(format: languageService.s("update_available_message"), updateChecker.latestVersion ?? ""))
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @Binding var showPreferences: Bool
    
    var body: some View {
        List {
            Section {
                sidebarButton(item: .home)
            }
            
            Section(languageService.s("downloading")) {
                sidebarButton(item: .downloading, badgeCount: downloadManager.downloadingCount, badgeColor: .blue)
                sidebarButton(item: .queued, badgeCount: downloadManager.queuedCount, badgeColor: .orange)
            }
            
            Section(languageService.s("history")) {
                sidebarButton(item: .completed, badgeCount: downloadManager.completedCount, badgeColor: .green)
                sidebarButton(item: .failed, badgeCount: downloadManager.failedCount, badgeColor: .red)
            }
        }
        .listStyle(.sidebar)
        .veloxSidebarWidth()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                SpecialThanksView()
                
                SponsorView()
                
                Button {
                    showPreferences = true
                } label: {
                    HStack {
                        Image(systemName: "gear")
                        Text(languageService.s("settings"))
                        Spacer()
                        Text("⌘,")
                            .font(.caption2)
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
        }
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
        Button {
            appState.selectedNavItem = item
        } label: {
            HStack {
                Label(item.title(lang: languageService), systemImage: item.icon)
                Spacer()
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .foregroundColor(appState.selectedNavItem == item ? .accentColor : .primary)
        .listRowBackground(appState.selectedNavItem == item ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}

extension View {
    @ViewBuilder
    func veloxSidebarWidth() -> some View {
        if #available(macOS 13.0, *) {
            self.navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } else {
            self.frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    
    var body: some View {
        currentView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(appState.selectedNavItem)
    }
    
    @ViewBuilder
    private var currentView: some View {
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
}

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    
                    VStack(spacing: 40) {
                        // Logo & Title Section
                        VStack(spacing: 24) {
                            ZStack {
                                Circle()
                                    .fill(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 100, height: 100)
                                    .shadow(color: .purple.opacity(0.3), radius: 15)
                                
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 50, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            
                            VStack(spacing: 8) {
                                Text("VeloX Pro")
                                    .font(.system(size: 48, weight: .black))
                                
                                Text(LocalizedStringKey(languageService.s("url_placeholder")))
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }
                        
                        // Action Button
                        Button {
                            appState.showAddDownloadSheet = true
                        } label: {
                            Label(languageService.s("new_download"), systemImage: "plus.circle.fill")
                                .font(.headline)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut("n", modifiers: .command)
                        
                        // Stats Grid
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                            StatCard(title: languageService.s("stat_downloading"), count: downloadManager.downloadingCount, color: .blue) {
                                appState.selectedNavItem = .downloading
                            }
                            StatCard(title: languageService.s("stat_queued"), count: downloadManager.queuedCount, color: .orange) {
                                appState.selectedNavItem = .queued
                            }
                            StatCard(title: languageService.s("stat_completed"), count: downloadManager.completedCount, color: .green) {
                                appState.selectedNavItem = .completed
                            }
                            StatCard(title: languageService.s("stat_failed"), count: downloadManager.failedCount, color: .red) {
                                appState.selectedNavItem = .failed
                            }
                        }
                        .padding(.horizontal, 40)
                        .frame(maxWidth: 800)
                    }
                    .frame(maxWidth: 800)
                    
                    Spacer(minLength: 40)
                    
                    // Version info footer
                    if let version = downloadManager.ytdlpVersion {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10))
                            Text("yt-dlp \(version)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(.secondary.opacity(0.8))
                        .padding(.bottom, 20)
                    }
                }
                .frame(minWidth: geometry.size.width)
                .frame(minHeight: geometry.size.height)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .alert(languageService.s("whats_new_title"), isPresented: $downloadManager.showWhatsNew) {
            Button(languageService.s("star_github")) {
                if let url = URL(string: "https://github.com/marspater/jolly-hopper") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK") { }
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
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text("\(count)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                    .shadow(color: color.opacity(0.4), radius: isHovered ? 8 : 2)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 105)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(isHovered ? 0.6 : 0.25), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: color.opacity(isHovered ? 0.25 : 0.08), radius: isHovered ? 12 : 6, x: 0, y: isHovered ? 6 : 3)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovered)
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
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 14, weight: .semibold))
                Text(languageService.s("star_github"))
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color.yellow.opacity(0.2) : Color.yellow.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// Helper for blurred background
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct SpecialThanksView: View {
    @EnvironmentObject var languageService: LanguageService
    
    var body: some View {
        VStack(spacing: 2) {
            Text(languageService.s("special_thanks_sidebar"))
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 4) {
                Link("Iman Montajabi", destination: URL(string: "https://github.com/ImanMontajabi")!)
                Text("&")
                Link("Semmelstulle", destination: URL(string: "https://github.com/Semmelstulle")!)
            }
            .font(.system(size: 9, weight: .bold))
            
            Text(languageService.s("for_support"))
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 4)
    }
}
