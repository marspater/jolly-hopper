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
                        } else {
                            Button {
                                downloadManager.clearDownloads(downloads)
                            } label: {
                                Label(languageService.s("clear_history"), systemImage: "trash")
                            }
                            .help(languageService.s("clear_history_help"))
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
                    .font(.system(size: 36))
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
                        .font(.system(size: 13, weight: .semibold))
                    Text(languageService.s("new_download"))
                        .font(.geist(13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
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
            .shadow(color: Color.blue.opacity(0.35), radius: 8, y: 3)
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {

                thumbnailView
                

                VStack(alignment: .leading, spacing: 5) {
                    Text(download.status == .fetching ? languageService.s("fetching") : download.title)
                        .font(.geist(14, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 8) {
                        statusBadge
                        
                        if let duration = download.duration {
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                    .font(.system(size: 9))
                                Text(duration)
                                    .font(.geistMono(11, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(Capsule())
                        }
                    }
                    
                    if download.status == .downloading {
                        HStack(spacing: 10) {
                            Text("\(Int(download.progress * 100))%")
                                .font(.geistMono(12, weight: .bold))
                                .foregroundColor(.accentColor)
                            
                            if let speed = download.speed, !speed.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(speed)
                                        .font(.geistMono(11, weight: .medium))
                                }
                                .foregroundColor(.secondary)
                            }
                            
                            if let eta = download.eta, !eta.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 9, weight: .regular))
                                    Text(eta)
                                        .font(.geistMono(11, weight: .medium))
                                }
                                .foregroundColor(.secondary.opacity(0.8))
                            }
                        }
                    }
                    
                    if let error = download.errorMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error)
                                .font(.geist(11))
                                .foregroundColor(.red)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if error.contains("Sign in to confirm you're not a bot") {
                                Button(languageService.s("fix_signin_error")) {
                                    PreferencesWindowManager.shared.showPreferencesWindow(
                                        languageService: languageService,
                                        updateChecker: updateChecker,
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
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
                    .fill(Color.gray.opacity(0.15))
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
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(.displayP3, red: 0.12, green: 0.52, blue: 0.98),
                                Color(.displayP3, red: 0.18, green: 0.72, blue: 0.98)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geometry.size.width * CGFloat(safeValue)))
                    .shadow(color: Color.blue.opacity(0.3), radius: 3, y: 1)
                    .animation(.linear(duration: 0.2), value: safeValue)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }
}
