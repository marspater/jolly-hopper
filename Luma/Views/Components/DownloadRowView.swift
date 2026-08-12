import SwiftUI

struct DownloadListView: View {
    let downloads: [Download]
    let emptyMessage: String
    let showStop: Bool
    
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    
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
                        } else {
                            Button {
                                downloadManager.clearDownloads(downloads)
                            } label: {
                                Label(languageService.s("clear"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(emptyMessage)
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DownloadRowView: View {
    @ObservedObject var download: Download
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    let showStop: Bool
    
    @State private var isHovering = false
    @State private var showLog = false
    @State private var isCopiedLog = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {

                thumbnailView
                

                VStack(alignment: .leading, spacing: 5) {
                    Text(download.title == "___FETCHING___" ? languageService.s("fetching") : download.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 8) {
                        statusBadge
                        
                        if let duration = download.duration {
                            Text(duration)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if download.status == .downloading {
                        Text(download.displayProgress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let error = download.errorMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if error.contains("Sign in to confirm you're not a bot") {
                                Button(languageService.s("fix_signin_error")) {
                                    PreferencesWindowManager.shared.showPreferencesWindow(
                                        languageService: languageService,
                                        updateChecker: UpdateChecker(),
                                        downloadManager: downloadManager
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
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
        .background(.ultraThinMaterial)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isHovering ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.02), radius: isHovering ? 8 : 4, y: 2)
        .scaleEffect(isHovering ? 1.006 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .sheet(isPresented: $showLog) {
            logSheet
        }
    }
    
    private var thumbnailView: some View {
        Group {
            if let url = download.thumbnailURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    thumbnailPlaceholder
                }
            } else {
                thumbnailPlaceholder
            }
        }
        .frame(width: 120, height: 68)
        .contentShape(Rectangle())
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var thumbnailPlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary.opacity(0.6))
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
                    .foregroundColor(.green)
                    .font(.caption2)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption2)
            case .stopped:
                Image(systemName: "stop.circle.fill")
                    .foregroundColor(.gray)
                    .font(.caption2)
            case .queued:
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
                    .font(.caption2)
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .foregroundColor(.yellow)
                    .font(.caption2)
            case .fileExists:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.caption2)
            }
            
            Text(download.status.title(lang: languageService))
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(badgeBackgroundColor)
        .foregroundColor(badgeForegroundColor)
        .clipShape(Capsule())
    }

    private var badgeBackgroundColor: Color {
        switch download.status {
        case .downloading, .fetching: return Color.blue.opacity(0.15)
        case .completed: return Color.green.opacity(0.15)
        case .failed: return Color.red.opacity(0.15)
        case .queued: return Color.orange.opacity(0.15)
        case .paused: return Color.yellow.opacity(0.15)
        default: return Color.gray.opacity(0.15)
        }
    }

    private var badgeForegroundColor: Color {
        switch download.status {
        case .downloading, .fetching: return .blue
        case .completed: return .green
        case .failed: return .red
        case .queued: return .orange
        case .paused: return .yellow
        default: return .secondary
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if download.status == .completed {
                Button {
                    if let path = download.filePath {
                        downloadManager.openFile(path)
                    }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .help(languageService.s("play"))
                .accessibilityLabel(languageService.s("play"))
                
                Button {
                    if let path = download.filePath {
                        downloadManager.showInFinder(path)
                    }
                } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(languageService.s("finder"))
                .accessibilityLabel(languageService.s("finder"))
                
                Button {
                    appState.urlToDownload = download.url
                    appState.showAddDownloadSheet = true
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(languageService.s("redownload"))
                .accessibilityLabel(languageService.s("redownload"))
            }
            
            if download.status == .failed || download.status == .stopped {
                Button {
                    downloadManager.retryDownload(download)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundColor(.orange)
                .help(languageService.s("retry"))
                .accessibilityLabel(languageService.s("retry"))
                
                Button {
                    appState.urlToDownload = download.url
                    appState.showAddDownloadSheet = true
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(languageService.s("redownload"))
                .accessibilityLabel(languageService.s("redownload"))
            }
            
            if download.status == .fileExists {
                Button {
                    downloadManager.resumeWithOverwrite(download)
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(.orange)
                .help(languageService.s("overwrite"))
                .accessibilityLabel(languageService.s("overwrite"))
                
                Button {
                    downloadManager.resumeWithNewName(download)
                } label: {
                    Image(systemName: "plus.square.on.square.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .help(languageService.s("download_new_name"))
                .accessibilityLabel(languageService.s("download_new_name"))
            }
            
            if showStop && (download.status == .downloading || download.status == .queued) {
                Button {
                    downloadManager.stopDownload(download)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .help(languageService.s("stop"))
                .accessibilityLabel(languageService.s("stop"))
            }
            
            Button {
                showLog = true
            } label: {
                Image(systemName: "doc.text")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(languageService.s("log"))
            .accessibilityLabel(languageService.s("log"))
            
            if download.status == .completed || download.status == .failed || download.status == .stopped {
                Button {
                    downloadManager.removeDownload(download)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary.opacity(0.7))
                .help(languageService.s("remove"))
                .accessibilityLabel(languageService.s("remove"))
            }
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
            .trim(from: 0, to: 0.7)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(isRotating))
            .onAppear {
                isRotating = 0
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
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
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(Color(.displayP3, red: 0.15, green: 0.55, blue: 1.0))
                    .frame(width: max(0, geometry.size.width * CGFloat(safeValue)))
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }
}
