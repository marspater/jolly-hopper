import SwiftUI
import QuickLookThumbnailing
import AVFoundation

struct DownloadListView: View {
    let downloads: [Download]
    let emptyMessage: String
    let showStop: Bool
    
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if downloads.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(downloads) { download in
                            DownloadRowView(download: download, showStop: showStop)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(.ultraThinMaterial)
        .toolbar {
            ToolbarItem {
                Group {
                    if !downloads.isEmpty {
                        if showStop {
                            Button {
                                downloadManager.stopAllDownloads()
                            } label: {
                                Label(languageService.s("stop_all"), systemImage: "stop.circle")
                            }
                            .help(languageService.s("stop_all"))
                            .accessibilityLabel(languageService.s("stop_all"))
                        } else {
                            Button {
                                downloadManager.clearDownloads(downloads)
                            } label: {
                                Label(languageService.s("clear_history"), systemImage: "trash")
                            }
                            .help(languageService.s("clear_history_help"))
                            .accessibilityLabel(languageService.s("clear_history_help"))
                        }
                    }
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 80, height: 80)
                Image(systemName: "tray.fill")
                    .font(.geist(36))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            
            VStack(spacing: 6) {
                Text(emptyMessage)
                    .font(.geist(16, weight: .semibold))
                    .foregroundColor(.primary)
                Text(languageService.s("url_placeholder"))
                    .font(.geist(13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            
            Button {
                appState.showAddDownloadSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.geist(13, weight: .semibold))
                    Text(languageService.s("new_download"))
                        .font(.geist(13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    SiphonTheme.primaryGradient
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 8, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct DownloadRowView: View {
    @ObservedObject var download: Download
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    let showStop: Bool
    
    @State private var isHovering = false
    @State private var showLog = false
    @State private var isCopiedLog = false
    @State private var showRawError = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                thumbnailView
                
                VStack(alignment: .leading, spacing: 4) {
                    // Line 1: Title
                    Text(download.status == .fetching ? languageService.s("fetching") : download.title)
                        .font(.geist(14, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    // Line 2: Subtitle (Domain • Quality • Format • Duration)
                    Text(download.formatSubtitle(lang: languageService))
                        .font(.geist(12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    // Line 3: Status / Progress / Metrics
                    if download.status == .downloading || download.status == .processing || download.status == .fetching {
                        HStack(spacing: 8) {
                            statusBadge
                            
                            if download.status == .downloading {
                                HStack(spacing: 8) {
                                    Text("\(Int(download.progress * 100))%")
                                        .font(.geistMono(12, weight: .bold))
                                        .foregroundColor(SiphonTheme.accent)
                                    
                                    if let speed = download.speed, !speed.isEmpty {
                                        Text("•")
                                            .foregroundColor(.secondary.opacity(0.4))
                                        Text(speed)
                                            .font(.geistMono(11, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    if let eta = download.eta, !eta.isEmpty {
                                        Text("•")
                                            .foregroundColor(.secondary.opacity(0.4))
                                        Text("~\(eta)")
                                            .font(.geistMono(11, weight: .medium))
                                            .foregroundColor(.secondary.opacity(0.8))
                                    }
                                }
                            }
                        }
                    } else if download.status == .failed || download.status == .stopped || download.errorMessage != nil {
                        errorSection
                    } else {
                        HStack(spacing: 8) {
                            statusBadge
                            
                            if download.status == .paused && download.progress > 0 {
                                Text("\(Int(download.progress * 100))%")
                                    .font(.geistMono(11, weight: .semibold))
                                    .foregroundColor(SiphonTheme.statusQueued)
                            }
                        }
                    }
                }
                
                Spacer(minLength: 8)
                
                actionButtons
            }
            
            if download.status == .downloading || download.status == .processing {
                LinearProgressBar(value: max(0, min(1, download.progress)))
            }
        }
        .padding(14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard, isHovered: isHovering)
        )
        .cornerRadius(SiphonTheme.radiusCard)
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard, isHovered: isHovering)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.02), radius: isHovering ? 8 : 4, y: 2)
        .scaleEffect(isHovering ? 1.004 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            rowContextMenu
        }
        .sheet(isPresented: $showLog) {
            logSheet
        }
    }
    
    private var errorSection: some View {
        Group {
            if let info = download.errorUXInfo(lang: languageService) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.geist(12))
                            .foregroundColor(SiphonTheme.statusFailed)
                        Text(info.headline)
                            .font(.geist(13, weight: .bold))
                            .foregroundColor(SiphonTheme.statusFailed)
                        
                        Text("—")
                            .foregroundColor(SiphonTheme.statusFailed.opacity(0.5))
                        
                        Text(info.description)
                            .font(.geist(12))
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 8) {
                        switch info.actionType {
                        case .fixInSettings:
                            Button {
                                PreferencesWindowManager.shared.showPreferencesWindow(
                                    languageService: languageService,
                                    updateChecker: updateChecker,
                                    downloadManager: downloadManager
                                )
                            } label: {
                                Text(languageService.s("fix_signin_error"))
                                    .font(.geist(11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SiphonTheme.accent)
                            .controlSize(.small)
                            
                        case .retry:
                            Button {
                                downloadManager.retryDownload(download)
                            } label: {
                                Text(languageService.s("retry"))
                                    .font(.geist(11, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                        case .changeFolder:
                            Button {
                                PreferencesWindowManager.shared.showPreferencesWindow(
                                    languageService: languageService,
                                    updateChecker: updateChecker,
                                    downloadManager: downloadManager
                                )
                            } label: {
                                Text(languageService.s("change_folder"))
                                    .font(.geist(11, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                        case .noAction:
                            EmptyView()
                        }
                        
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showRawError.toggle()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(showRawError ? languageService.s("hide_details") : languageService.s("details"))
                                    .font(.geist(11, weight: .medium))
                                Image(systemName: showRawError ? "chevron.up" : "chevron.down")
                                    .font(.geist(9))
                            }
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if showRawError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.rawError)
                                .font(.geistMono(10))
                                .foregroundColor(.secondary)
                                .lineLimit(6)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.15))
                                .cornerRadius(6)
                            
                            HStack {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(info.rawError, forType: .string)
                                } label: {
                                    Text(languageService.s("copy_error"))
                                        .font(.geist(10, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(SiphonTheme.accent)
                                
                                Spacer()
                                
                                Button {
                                    showLog = true
                                } label: {
                                    Text(languageService.s("download_log"))
                                        .font(.geist(10, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 2)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, 2)
            }
        }
    }
    
    private var thumbnailView: some View {
        Group {
            if let url = download.thumbnailURL, let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        if let filePath = download.filePath, FileManager.default.fileExists(atPath: filePath.path) {
                            FileThumbnailView(fileURL: filePath)
                        } else {
                            thumbnailPlaceholder
                        }
                    @unknown default:
                        thumbnailPlaceholder
                    }
                }
            } else if let filePath = download.filePath, FileManager.default.fileExists(atPath: filePath.path) {
                FileThumbnailView(fileURL: filePath)
            } else {
                thumbnailPlaceholder
            }
        }
        .frame(width: 120, height: 68)
        .contentShape(Rectangle())
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
    
    private var thumbnailPlaceholder: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .font(.geist(24))
                    .foregroundColor(.secondary.opacity(0.6))
            }
    }

struct FileThumbnailView: View {
    let fileURL: URL
    @State private var thumbnailImage: NSImage? = nil

    var body: some View {
        Group {
            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        Image(systemName: "play.rectangle.fill")
                            .font(.geist(24))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
            }
        }
        .task {
            await generateThumbnail()
        }
    }

    private func generateThumbnail() async {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let request = QLThumbnailGenerator.Request(fileAt: fileURL, size: CGSize(width: 240, height: 136), scale: 2.0, representationTypes: .thumbnail)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            await MainActor.run {
                self.thumbnailImage = representation.nsImage
            }
            return
        }

        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 1, preferredTimescale: 60)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run {
                self.thumbnailImage = nsImage
            }
        }
    }
}
    
    private var statusBadge: some View {
        HStack(spacing: 5) {
            switch download.status {
            case .downloading:
                StatusSpinnerView()
            case .fetching:
                StatusSpinnerView()
            case .processing:
                StatusSpinnerView()
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(SiphonTheme.statusCompleted)
                    .font(.caption2)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(SiphonTheme.statusFailed)
                    .font(.caption2)
            case .stopped:
                Image(systemName: "stop.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.caption2)
            case .queued:
                Image(systemName: "clock.fill")
                    .foregroundColor(SiphonTheme.statusQueued)
                    .font(.caption2)
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .foregroundColor(SiphonTheme.statusQueued)
                    .font(.caption2)
            case .fileExists:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(SiphonTheme.statusQueued)
                    .font(.caption2)
            }
            
            Text(download.status.title(lang: languageService))
                .font(.geist(11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(badgeBackgroundColor)
        .foregroundColor(badgeForegroundColor)
        .clipShape(Capsule())
    }

    private var badgeBackgroundColor: Color {
        switch download.status {
        case .downloading, .fetching, .processing: return SiphonTheme.statusDownloading.opacity(0.15)
        case .completed: return SiphonTheme.statusCompleted.opacity(0.15)
        case .failed: return SiphonTheme.statusFailed.opacity(0.15)
        case .queued, .paused, .fileExists: return SiphonTheme.statusQueued.opacity(0.15)
        default: return Color.primary.opacity(0.06)
        }
    }

    private var badgeForegroundColor: Color {
        switch download.status {
        case .downloading, .fetching, .processing: return SiphonTheme.statusDownloading
        case .completed: return SiphonTheme.statusCompleted
        case .failed: return SiphonTheme.statusFailed
        case .queued, .paused, .fileExists: return SiphonTheme.statusQueued
        default: return .secondary
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Completed state: Primary Play button + Single More Menu
            if download.status == .completed {
                Button {
                    if let path = download.filePath {
                        downloadManager.openFile(path)
                    }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.geist(20))
                }
                .buttonStyle(.plain)
                .foregroundColor(SiphonTheme.accent)
                .help(languageService.s("play"))
                .accessibilityLabel(languageService.s("play"))
                
                Menu {
                    Button {
                        if let path = download.filePath {
                            downloadManager.openFile(path)
                        }
                    } label: {
                        Label(languageService.s("play"), systemImage: "play.fill")
                    }
                    
                    if let path = download.filePath {
                        Button {
                            downloadManager.showInFinder(path)
                        } label: {
                            Label(languageService.s("show_in_finder"), systemImage: "folder")
                        }
                    }
                    
                    Button {
                        appState.urlToDownload = download.url
                        appState.showAddDownloadSheet = true
                    } label: {
                        Label(languageService.s("redownload"), systemImage: "arrow.down.circle")
                    }
                    
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(download.url, forType: .string)
                    } label: {
                        Label(languageService.s("copy_url"), systemImage: "link")
                    }
                    
                    Button {
                        showLog = true
                    } label: {
                        Label(languageService.s("log"), systemImage: "doc.text")
                    }
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        downloadManager.removeDownload(download)
                    } label: {
                        Label(languageService.s("remove"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.geist(18))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .help(languageService.s("more_actions"))
                .accessibilityLabel(languageService.s("more_actions"))
            }
            
            // Downloading / Fetching / Processing state: Pause + Stop (revealed on hover) + More Menu
            if download.status == .downloading || download.status == .fetching || download.status == .processing {
                Button {
                    downloadManager.pauseDownload(download)
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.geist(18))
                }
                .buttonStyle(.plain)
                .foregroundColor(SiphonTheme.statusQueued)
                .help(languageService.s("pause"))
                .accessibilityLabel(languageService.s("pause"))
                
                if isHovering {
                    Button {
                        downloadManager.stopDownload(download)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.geist(18))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(SiphonTheme.statusFailed)
                    .help(languageService.s("stop"))
                    .accessibilityLabel(languageService.s("stop"))
                    .transition(.opacity)
                }
                
                Menu {
                    Button {
                        downloadManager.pauseDownload(download)
                    } label: {
                        Label(languageService.s("pause"), systemImage: "pause.fill")
                    }
                    
                    Button {
                        downloadManager.stopDownload(download)
                    } label: {
                        Label(languageService.s("stop"), systemImage: "stop.fill")
                    }
                    
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(download.url, forType: .string)
                    } label: {
                        Label(languageService.s("copy_url"), systemImage: "link")
                    }
                    
                    Button {
                        showLog = true
                    } label: {
                        Label(languageService.s("log"), systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.geist(18))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            
            // Queued state: Pause + Reorder + More Menu
            if download.status == .queued {
                Button {
                    downloadManager.pauseDownload(download)
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.geist(18))
                }
                .buttonStyle(.plain)
                .foregroundColor(SiphonTheme.statusQueued)
                .help(languageService.s("pause"))
                .accessibilityLabel(languageService.s("pause"))
                
                Menu {
                    Button {
                        downloadManager.moveDownloadToTop(download)
                    } label: {
                        Label(languageService.s("move_to_top"), systemImage: "arrow.up.to.line")
                    }
                    
                    Button {
                        downloadManager.moveDownloadUp(download)
                    } label: {
                        Label(languageService.s("move_up"), systemImage: "arrow.up")
                    }
                    
                    Button {
                        downloadManager.moveDownloadDown(download)
                    } label: {
                        Label(languageService.s("move_down"), systemImage: "arrow.down")
                    }
                    
                    Button {
                        downloadManager.moveDownloadToBottom(download)
                    } label: {
                        Label(languageService.s("move_to_bottom"), systemImage: "arrow.down.to.line")
                    }
                    
                    Divider()
                    
                    Button {
                        downloadManager.stopDownload(download)
                    } label: {
                        Label(languageService.s("stop"), systemImage: "stop.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.geist(18))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            
            // Paused state: Resume + More Menu
            if download.status == .paused {
                Button {
                    downloadManager.resumeDownload(download)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.geist(18))
                }
                .buttonStyle(.plain)
                .foregroundColor(SiphonTheme.accent)
                .help(languageService.s("resume"))
                .accessibilityLabel(languageService.s("resume"))
                
                Menu {
                    Button {
                        downloadManager.resumeDownload(download)
                    } label: {
                        Label(languageService.s("resume"), systemImage: "play.fill")
                    }
                    
                    Button {
                        downloadManager.stopDownload(download)
                    } label: {
                        Label(languageService.s("stop"), systemImage: "stop.fill")
                    }
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        downloadManager.removeDownload(download)
                    } label: {
                        Label(languageService.s("remove"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.geist(18))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            
            // Failed / Stopped state: Retry + More Menu
            if download.status == .failed || download.status == .stopped {
                Button {
                    downloadManager.retryDownload(download)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.geist(18))
                }
                .buttonStyle(.plain)
                .foregroundColor(SiphonTheme.statusQueued)
                .help(languageService.s("retry"))
                .accessibilityLabel(languageService.s("retry"))
                
                Menu {
                    Button {
                        downloadManager.retryDownload(download)
                    } label: {
                        Label(languageService.s("retry"), systemImage: "arrow.clockwise")
                    }
                    
                    Button {
                        appState.urlToDownload = download.url
                        appState.showAddDownloadSheet = true
                    } label: {
                        Label(languageService.s("redownload"), systemImage: "arrow.down.circle")
                    }
                    
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(download.url, forType: .string)
                    } label: {
                        Label(languageService.s("copy_url"), systemImage: "link")
                    }
                    
                    Button {
                        showLog = true
                    } label: {
                        Label(languageService.s("log"), systemImage: "doc.text")
                    }
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        downloadManager.removeDownload(download)
                    } label: {
                        Label(languageService.s("remove"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.geist(18))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
            
            // FileExists state
            if download.status == .fileExists {
                Button {
                    downloadManager.resumeWithOverwrite(download)
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.geist(16))
                }
                .buttonStyle(.plain)
                .foregroundColor(SiphonTheme.statusQueued)
                .help(languageService.s("overwrite"))
                .accessibilityLabel(languageService.s("overwrite"))
                
                Button {
                    downloadManager.resumeWithNewName(download)
                } label: {
                    Image(systemName: "plus.square.on.square.fill")
                        .font(.geist(16))
                }
                .buttonStyle(.plain)
                .foregroundColor(SiphonTheme.accent)
                .help(languageService.s("download_new_name"))
                .accessibilityLabel(languageService.s("download_new_name"))
            }
        }
    }
    
    @ViewBuilder
    private var rowContextMenu: some View {
        if let path = download.filePath {
            Button {
                downloadManager.showInFinder(path)
            } label: {
                Label(languageService.s("show_in_finder"), systemImage: "folder")
            }
            
            Button {
                downloadManager.openFile(path)
            } label: {
                Label(languageService.s("play"), systemImage: "play.fill")
            }
            
            Divider()
        }
        
        if download.status == .downloading || download.status == .fetching || download.status == .processing {
            Button {
                downloadManager.pauseDownload(download)
            } label: {
                Label(languageService.s("pause"), systemImage: "pause.fill")
            }
            
            Button {
                downloadManager.stopDownload(download)
            } label: {
                Label(languageService.s("stop"), systemImage: "stop.fill")
            }
            
            Divider()
        } else if download.status == .paused {
            Button {
                downloadManager.resumeDownload(download)
            } label: {
                Label(languageService.s("resume"), systemImage: "play.fill")
            }
            
            Button {
                downloadManager.stopDownload(download)
            } label: {
                Label(languageService.s("stop"), systemImage: "stop.fill")
            }
            
            Divider()
        } else if download.status == .queued {
            Button {
                downloadManager.pauseDownload(download)
            } label: {
                Label(languageService.s("pause"), systemImage: "pause.fill")
            }
            
            Button {
                downloadManager.moveDownloadToTop(download)
            } label: {
                Label(languageService.s("move_to_top"), systemImage: "arrow.up.to.line")
            }
            
            Button {
                downloadManager.moveDownloadUp(download)
            } label: {
                Label(languageService.s("move_up"), systemImage: "arrow.up")
            }
            
            Button {
                downloadManager.moveDownloadDown(download)
            } label: {
                Label(languageService.s("move_down"), systemImage: "arrow.down")
            }
            
            Button {
                downloadManager.moveDownloadToBottom(download)
            } label: {
                Label(languageService.s("move_to_bottom"), systemImage: "arrow.down.to.line")
            }
            
            Divider()
        } else if download.status == .failed || download.status == .stopped {
            Button {
                downloadManager.retryDownload(download)
            } label: {
                Label(languageService.s("retry"), systemImage: "arrow.clockwise")
            }
            
            Divider()
        }
        
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(download.url, forType: .string)
        } label: {
            Label(languageService.s("copy_url"), systemImage: "link")
        }
        
        Button {
            showLog = true
        } label: {
            Label(languageService.s("log"), systemImage: "doc.text")
        }
        
        Divider()
        
        Button(role: .destructive) {
            downloadManager.removeDownload(download)
        } label: {
            Label(languageService.s("remove"), systemImage: "trash")
        }
    }
    
    private var logSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(languageService.s("download_log"))
                    .font(.headline)
                Spacer()
                
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(download.log, forType: .string)
                    isCopiedLog = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                        isCopiedLog = false
                    }
                } label: {
                    Label(isCopiedLog ? "Copied!" : "Copy Log", systemImage: isCopiedLog ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                
                Button(languageService.s("close")) {
                    showLog = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(.ultraThinMaterial)
            
            Divider()
            
            ReadOnlyLogView(text: download.log.isEmpty ? languageService.s("no_log") : download.log)
                .padding(8)
                .background(Color.black.opacity(0.2))
        }
        .frame(width: 620, height: 420)
    }
}

struct StatusSpinnerView: View {
    @State private var isRotating = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                style: StrokeStyle(lineWidth: 1.9, lineCap: .round)
            )
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(isRotating))
            .onAppear {
                isRotating = 0
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    isRotating = 360
                }
            }
    }
}

struct LinearProgressBar: View {
    let value: Double

    // Bug #3 fix: Guard against NaN to prevent SwiftUI layout crash
    private var safeValue: Double {
        value.isNaN ? 0 : max(0, min(1, value))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(SiphonTheme.primaryGradient)
                    .frame(width: max(0, geometry.size.width * CGFloat(safeValue)))
                    .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 3, y: 1)
                    .animation(.linear(duration: 0.2), value: safeValue)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }
}
