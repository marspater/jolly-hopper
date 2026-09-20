import SwiftUI
import QuickLookUI

final class QuickLookPreviewHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    static let shared = QuickLookPreviewHelper()
    private var currentURL: URL?
    private let lock = NSLock()

    @MainActor
    func preview(url: URL) {
        lock.lock()
        currentURL = url
        lock.unlock()

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    nonisolated func numberOfPreviewItems(in _: QLPreviewPanel?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return currentURL != nil ? 1 : 0
    }

    nonisolated func previewPanel(_ _: QLPreviewPanel?, previewItemAt _: Int) -> QLPreviewItem? {
        lock.lock()
        defer { lock.unlock() }
        return (currentURL as NSURL?)
    }
}

struct DownloadListView: View {
    let downloads: [Download]
    let emptyMessage: String
    let emptyDetail: String
    var emptyIcon: String = "tray.fill"
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
        .siphonWindowBackground()
    }
    
    private var emptyState: some View {
        SiphonEmptyStateView(
            icon: emptyIcon,
            title: emptyMessage,
            message: emptyDetail,
            actionTitle: languageService.s("new_download")
        ) {
            appState.showAddDownloadSheet = true
        }
    }
}

struct DownloadRowView: View {
    @ObservedObject var download: Download
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    @Environment(\.colorScheme) private var colorScheme
    let showStop: Bool
    
    @State private var isHovering = false
    @State private var showLog = false
    @State private var showDiagnostics = false
    @State private var isCopiedLog = false
    @State private var isCopiedError = false
    @State private var showRawError = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                thumbnailView
                
                VStack(alignment: .leading, spacing: 4) {
                    // Line 1: Title
                    Text(download.status == .fetching ? languageService.s("fetching") : download.displayTitle)
                        .font(.geist(14, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .help(download.displayTitle)
                    
                    // Line 2: Subtitle (Domain • Quality • Format • Duration)
                    Text(download.formatSubtitle(lang: languageService))
                        .font(.geist(12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(download.formatSubtitle(lang: languageService))
                    
                    // Line 3: Status / Progress / Metrics
                    if download.status == .downloading || download.status == .processing || download.status == .fetching {
                        HStack(spacing: 8) {
                            statusBadge
                            
                            if download.status == .downloading {
                                HStack(spacing: 8) {
                                    let safePercent: Int = {
                                        if download.progress.isNaN { return 0 }
                                        if download.progress.isInfinite { return download.progress > 0 ? 100 : 0 }
                                        return Int(max(0.0, min(1.0, download.progress)) * 100)
                                    }()
                                    Text("\(safePercent)%")
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
                                            .foregroundColor(.secondary)
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
                                    .foregroundColor(SiphonTheme.statusForeground(for: .paused, colorScheme: colorScheme))
                            }
                        }
                    }
                }
                .frame(minHeight: 68, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                
                Spacer(minLength: SiphonTheme.spacing8)
                
                actionButtons
                    .frame(minWidth: download.status == .fileExists ? 0 : 62, alignment: .trailing)
                    .padding(.top, 1)
                    .animation(SiphonAnimation.snappySpring, value: download.status)
            }
        }
        .padding(SiphonTheme.spacing14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard, isHovered: isHovering)
        )
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard))
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard, isHovered: isHovering)
        )
        .overlay(alignment: .bottom) {
            if download.status == .downloading || download.status == .processing {
                LinearProgressBar(value: max(0, min(1, download.progress)))
                    .padding(.horizontal, SiphonTheme.spacing14)
                    .padding(.bottom, SiphonTheme.spacing6)
                    .transition(.opacity)
            }
        }
        .siphonCardHover(isHovered: isHovering, tint: statusTint)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            rowContextMenu
        }
        .sheet(isPresented: $showLog) {
            logSheet
        }
        .sheet(isPresented: $showDiagnostics) {
            DownloadDiagnosticsView(download: download)
                .environmentObject(languageService)
        }
    }
    
    private var errorSection: some View {
        Group {
            if let info = download.errorUXInfo(lang: languageService) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.geist(12))
                            .foregroundColor(SiphonTheme.statusForeground(for: .failed, colorScheme: colorScheme))
                        Text(info.headline)
                            .font(.geist(13, weight: .bold))
                            .foregroundColor(SiphonTheme.statusForeground(for: .failed, colorScheme: colorScheme))
                            .lineLimit(1)
                        
                        Text("—")
                            .foregroundColor(SiphonTheme.statusForeground(for: .failed, colorScheme: colorScheme).opacity(0.55))
                        
                        Text(info.description)
                            .font(.geist(12))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    
                    HStack(spacing: 8) {
                        switch info.actionType {
                        case .fixInSettings:
                            Button {
                                PreferencesWindowManager.shared.showPreferencesWindow(
                                    languageService: languageService,
                                    updateChecker: updateChecker,
                                    downloadManager: downloadManager,
                                    appState: appState,
                                    initialTab: .advanced
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
                                    downloadManager: downloadManager,
                                    appState: appState
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
                            withAnimation(SiphonAnimation.snappySpring) {
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
                                .background(
                                    SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusSmall)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall))
                                .overlay(
                                    SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusSmall)
                                )
                            
                            HStack {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(info.rawError, forType: .string)
                                    isCopiedError = true
                                    Task {
                                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                                        isCopiedError = false
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: isCopiedError ? "checkmark" : "doc.on.doc")
                                            .font(.geist(9))
                                        Text(isCopiedError ? languageService.s("copied") : languageService.s("copy_error"))
                                            .font(.geist(10, weight: .medium))
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(isCopiedError ? SiphonTheme.statusCompleted : SiphonTheme.accent)
                                .help(languageService.s("copy_error"))
                                .accessibilityLabel(isCopiedError ? languageService.s("copied") : languageService.s("copy_error"))
                                
                                Spacer()
                                
                                Button {
                                    showLog = true
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "doc.text")
                                            .font(.geist(9))
                                        Text(languageService.s("download_log"))
                                            .font(.geist(10, weight: .medium))
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                .help(languageService.s("download_log"))
                                .accessibilityLabel(languageService.s("download_log"))
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
            if canPreviewMedia {
                Button(action: previewMedia) {
                    thumbnailContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(thumbnailAccessibilityLabel)
                .accessibilityHint("Press Space to preview media")
            } else {
                thumbnailContent
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(thumbnailAccessibilityLabel)
            }
        }
        .frame(width: 120, height: 68)
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .help(canPreviewMedia ? languageService.s("click_to_quick_look") : "")
    }

    private var canPreviewMedia: Bool {
        guard download.status == .completed, let path = download.primaryFilePath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    private var thumbnailAccessibilityLabel: String {
        download.displayTitle.isEmpty ? "Media preview" : "\(download.displayTitle) thumbnail"
    }

    private var isHDRMedia: Bool {
        download.diagnostics.hdrSummary != nil || download.mediaInfo?.firstHDRSummary != nil
    }

    private func previewMedia() {
        guard canPreviewMedia, let path = download.primaryFilePath else { return }
        QuickLookPreviewHelper.shared.preview(url: path)
    }

    private var thumbnailContent: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = download.thumbnailURL, let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure, .empty:
                            if let filePath = download.primaryFilePath {
                                FileThumbnailView(fileURL: filePath, isHDR: isHDRMedia)
                            } else {
                                thumbnailPlaceholder
                            }
                        @unknown default:
                            thumbnailPlaceholder
                        }
                    }
                } else if let filePath = download.primaryFilePath {
                    FileThumbnailView(fileURL: filePath, isHDR: isHDRMedia)
                } else {
                    thumbnailPlaceholder
                }
            }
            .frame(width: 120, height: 68)
            .contentShape(Rectangle())
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))

            // Hover play/quicklook overlay for completed files
            if canPreviewMedia, isHovering {
                ZStack {
                    Color.black.opacity(0.35)
                    Image(systemName: "eye.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                }
                .transition(.opacity)
            }

            // HDR Badge tag on thumbnail if HDR detected
            if let hdr = download.diagnostics.hdrSummary ?? download.mediaInfo?.firstHDRSummary {
                VStack {
                    HStack {
                        SiphonTagBadge(text: hdr.components(separatedBy: " • ").first ?? "HDR", isHdr: true)
                            .padding(SiphonTheme.spacing4)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
    }
    
    private var thumbnailPlaceholder: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary.opacity(0.6))
            }
    }

struct FileThumbnailView: View {
    let fileURL: URL
    let isHDR: Bool
    @State private var thumbnailImage: NSImage? = nil

    var body: some View {
        Group {
            if let image = thumbnailImage {
                thumbnail(image)
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
            }
        }
        .task {
            await generateThumbnail()
        }
    }

    @ViewBuilder
    private func thumbnail(_ image: NSImage) -> some View {
        if isHDR {
            Image(nsImage: image)
                .resizable()
                .allowedDynamicRange(.constrainedHigh)
                .aspectRatio(contentMode: .fill)
        } else {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }

    private func generateThumbnail() async {
        if let image = await ImageUtilities.generateThumbnail(for: fileURL) {
            await MainActor.run {
                self.thumbnailImage = image
            }
        }
    }
}
    
    private var statusBadge: some View {
        SiphonStatusBadge(
            status: download.status,
            title: download.status.title(lang: languageService),
            foregroundColor: badgeForegroundColor
        )
    }

    private var statusTint: Color {
        switch download.status {
        case .downloading, .fetching, .processing: return SiphonTheme.statusDownloading
        case .completed: return SiphonTheme.statusCompleted
        case .failed, .stopped: return SiphonTheme.statusFailed
        case .queued, .paused, .fileExists: return SiphonTheme.statusQueued
        }
    }

    private var badgeForegroundColor: Color {
        SiphonTheme.statusForeground(for: download.status, colorScheme: colorScheme)
    }
    
    private var actionButtons: some View {
        HStack(spacing: SiphonTheme.spacing6) {
            // Completed state: one visible contextual action + exhaustive More menu
            if download.status == .completed {
                if let path = download.primaryFilePath, FileManager.default.fileExists(atPath: path.path) {
                    Button {
                        downloadManager.openFile(path)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.siphonIcon(size: 28))
                    .foregroundColor(SiphonTheme.accent)
                    .help(languageService.s("play"))
                    .accessibilityLabel(languageService.s("play"))
                }
                
                Menu {
                    if download.filePaths.count > 1 {
                        Menu {
                            ForEach(download.filePaths, id: \.self) { chapter in
                                Button(chapter.lastPathComponent) {
                                    QuickLookPreviewHelper.shared.preview(url: chapter)
                                }
                            }
                        } label: {
                            Label(languageService.s("quick_look_chapters"), systemImage: "eye")
                        }

                        Menu {
                            ForEach(download.filePaths, id: \.self) { chapter in
                                Button(chapter.lastPathComponent) {
                                    downloadManager.openFile(chapter)
                                }
                            }
                        } label: {
                            Label(languageService.s("play_chapters"), systemImage: "play.fill")
                        }
                    } else if let path = download.primaryFilePath, FileManager.default.fileExists(atPath: path.path) {
                        Button {
                            QuickLookPreviewHelper.shared.preview(url: path)
                        } label: {
                            Label(languageService.s("quick_look"), systemImage: "eye")
                        }

                        Button {
                            downloadManager.openFile(path)
                        } label: {
                            Label(languageService.s("play"), systemImage: "play.fill")
                        }
                    }
                    
                    if !download.filePaths.isEmpty {
                        Button {
                            downloadManager.showInFinder(download.filePaths)
                        } label: {
                            Label(languageService.s("show_in_finder"), systemImage: "folder")
                        }
                        
                        Button {
                            NSPasteboard.general.clearContents()
                            let pathsString = download.filePathStrings.joined(separator: "\n")
                            NSPasteboard.general.setString(pathsString, forType: .string)
                        } label: {
                            Label(download.filePaths.count > 1 ? languageService.s("copy_all_paths") : languageService.s("copy_file_path"), systemImage: "doc.on.doc")
                        }
                    }
                    
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label(languageService.s("view_diagnostics"), systemImage: "cpu")
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
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help(languageService.s("more_actions"))
                .accessibilityLabel(languageService.s("more_actions"))
            }
            
            // Downloading / Fetching / Processing: one visible Pause action + More menu
            if download.status == .downloading || download.status == .fetching || download.status == .processing {
                Button {
                    downloadManager.pauseDownload(download)
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.siphonIcon(size: 28))
                .foregroundColor(SiphonTheme.statusForeground(for: .queued, colorScheme: colorScheme))
                .help(languageService.s("pause"))
                .accessibilityLabel(languageService.s("pause"))
                
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
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help(languageService.s("more_actions"))
                .accessibilityLabel(languageService.s("more_actions"))
            }
            
            // Queued state: Pause + Reorder + More Menu
            if download.status == .queued {
                Button {
                    downloadManager.pauseDownload(download)
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.siphonIcon(size: 28))
                .foregroundColor(SiphonTheme.statusForeground(for: .queued, colorScheme: colorScheme))
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
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help(languageService.s("more_actions"))
                .accessibilityLabel(languageService.s("more_actions"))
            }
            
            // Paused state: Resume + More Menu
            if download.status == .paused {
                Button {
                    downloadManager.resumeDownload(download)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.siphonIcon(size: 28))
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
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help(languageService.s("more_actions"))
                .accessibilityLabel(languageService.s("more_actions"))
            }
            
            // Failed / Stopped state: Retry + More Menu
            if download.status == .failed || download.status == .stopped {
                Button {
                    downloadManager.retryDownload(download)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.siphonIcon(size: 28))
                .foregroundColor(SiphonTheme.statusForeground(for: .queued, colorScheme: colorScheme))
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
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help(languageService.s("more_actions"))
                .accessibilityLabel(languageService.s("more_actions"))
            }
            
            // FileExists state
            if download.status == .fileExists {
                Button {
                    downloadManager.resumeWithOverwrite(download)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down.on.square.fill")
                            .font(.system(size: 13))
                        Text(languageService.s("overwrite"))
                            .font(.geist(11, weight: .medium))
                    }
                    .foregroundColor(SiphonTheme.statusForeground(for: .queued, colorScheme: colorScheme))
                }
                .buttonStyle(.siphonGhost)
                .help(languageService.s("overwrite"))
                .accessibilityLabel(languageService.s("overwrite"))
                
                Button {
                    downloadManager.resumeWithNewName(download)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.square.on.square.fill")
                            .font(.system(size: 13))
                        Text(languageService.s("download_new_name"))
                            .font(.geist(11, weight: .medium))
                    }
                    .foregroundColor(SiphonTheme.accent)
                }
                .buttonStyle(.siphonGhost)
                .help(languageService.s("download_new_name"))
                .accessibilityLabel(languageService.s("download_new_name"))
            }
        }
    }
    
    @ViewBuilder
    private var rowContextMenu: some View {
        if download.status == .completed {
            if download.filePaths.count > 1 {
                Menu {
                    ForEach(download.filePaths, id: \.self) { chapter in
                        Button(chapter.lastPathComponent) {
                            QuickLookPreviewHelper.shared.preview(url: chapter)
                        }
                    }
                } label: {
                    Label(languageService.s("quick_look_chapters"), systemImage: "eye")
                }
                
                Menu {
                    ForEach(download.filePaths, id: \.self) { chapter in
                        Button(chapter.lastPathComponent) {
                            downloadManager.openFile(chapter)
                        }
                    }
                } label: {
                    Label(languageService.s("play_chapters"), systemImage: "play.fill")
                }
            } else if let path = download.primaryFilePath, FileManager.default.fileExists(atPath: path.path) {
                Button {
                    QuickLookPreviewHelper.shared.preview(url: path)
                } label: {
                    Label(languageService.s("quick_look"), systemImage: "eye")
                }
                
                Button {
                    downloadManager.openFile(path)
                } label: {
                    Label(languageService.s("play"), systemImage: "play.fill")
                }
            }

            if !download.filePaths.isEmpty {
                Button {
                    downloadManager.showInFinder(download.filePaths)
                } label: {
                    Label(languageService.s("show_in_finder"), systemImage: "folder")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    let pathsJoined = download.filePathStrings.joined(separator: "\n")
                    NSPasteboard.general.setString(pathsJoined, forType: .string)
                } label: {
                    Label(download.filePaths.count > 1 ? languageService.s("copy_all_paths") : languageService.s("copy_file_path"), systemImage: "doc.on.doc")
                }
            }
            
            Divider()
        }
        
        Button {
            showDiagnostics = true
        } label: {
            Label(languageService.s("view_diagnostics"), systemImage: "cpu")
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
        } else if download.status == .fileExists {
            Button {
                downloadManager.resumeWithOverwrite(download)
            } label: {
                Label(languageService.s("overwrite"), systemImage: "square.and.arrow.down.on.square.fill")
            }
            
            Button {
                downloadManager.resumeWithNewName(download)
            } label: {
                Label(languageService.s("download_new_name"), systemImage: "plus.square.on.square.fill")
            }
            
            Button {
                downloadManager.stopDownload(download)
            } label: {
                Label(languageService.s("stop"), systemImage: "stop.fill")
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
            // Header
            HStack(spacing: SiphonTheme.spacing12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SiphonTheme.accent)

                Text(languageService.s("download_log"))
                    .font(.geist(15, weight: .bold))

                if !download.log.isEmpty {
                    SiphonTagBadge(
                        text: "\(download.log.split(whereSeparator: \.isNewline).count) \(languageService.s("entries"))",
                        tintColor: .secondary,
                        isMonospaced: true
                    )
                }

                Spacer()

                Button {
                    showLog = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.siphonIcon(size: 24))
                .help(languageService.s("close"))
                .accessibilityLabel(languageService.s("close"))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.top, SiphonTheme.spacing16)
            .padding(.bottom, SiphonTheme.spacing12)

            // Log Console Container
            ZStack {
                SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl)
                    .overlay(SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl))

                ReadOnlyLogView(
                    text: download.log.isEmpty ? languageService.s("no_log") : download.log,
                    fontSize: 11
                )
                .padding(SiphonTheme.spacing8)
            }
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.bottom, SiphonTheme.spacing14)

            // Bottom Action Bar
            HStack(spacing: SiphonTheme.spacing10) {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(download.log, forType: .string)
                    withAnimation(SiphonAnimation.snappySpring) {
                        isCopiedLog = true
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(SiphonAnimation.snappySpring) {
                            isCopiedLog = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCopiedLog ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isCopiedLog ? languageService.s("copied") : languageService.s("copy_log"))
                            .font(.geist(12, weight: .medium))
                    }
                    .foregroundColor(isCopiedLog ? SiphonTheme.statusCompleted : .primary)
                    .opacity(download.log.isEmpty ? 0.5 : 1.0)
                }
                .buttonStyle(.siphonSecondary)
                .disabled(download.log.isEmpty)
                .help(languageService.s("copy_log"))
                .accessibilityLabel(languageService.s("copy_log"))

                Spacer()

                Button(languageService.s("done")) {
                    showLog = false
                }
                .buttonStyle(.siphonPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.bottom, SiphonTheme.spacing16)
        }
        .frame(width: 640, height: 440)
        .siphonWindowBackground()
    }
}

struct LinearProgressBar: View {
    let value: Double
    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared

    // Bug #3 fix: Guard against NaN to prevent SwiftUI layout crash
    var safeValue: Double {
        value.isNaN ? 0 : max(0, min(1, value))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Liquid glass track
                SiphonTheme.tintedPillBackground(
                    tint: .primary,
                    opacity: 0.08
                )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.14), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                
                // Glowing progress fill
                Capsule()
                    .fill(SiphonTheme.primaryGradient)
                    .frame(width: max(0, geometry.size.width * CGFloat(safeValue)))
                    .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 3, y: 1)
                    .animation(SiphonAnimation.snappySpring, value: safeValue)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }
}
