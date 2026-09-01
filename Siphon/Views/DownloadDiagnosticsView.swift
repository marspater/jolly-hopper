import SwiftUI
import AppKit

struct DownloadDiagnosticsView: View {
    @ObservedObject var download: Download
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var languageService: LanguageService
    
    @State private var selectedTab = 0
    @State private var copiedNotice: String? = nil
    @State private var logSearchText: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            Picker("", selection: $selectedTab) {
                Text("Runtime & Process").tag(0)
                Text("Media & Color (HDR)").tag(1)
                Text("Command & Logs").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            ScrollView {
                VStack(spacing: 16) {
                    if selectedTab == 0 {
                        runtimeTab
                    } else if selectedTab == 1 {
                        mediaAndColorTab
                    } else {
                        commandAndLogsTab
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            
            Divider()
            
            footerView
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 480, idealHeight: 540)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 14) {
            if let thumb = download.thumbnailURL {
                AsyncImage(url: thumb) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 54, height: 36)
                            .cornerRadius(6)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 54, height: 36)
                            .cornerRadius(6)
                    }
                }
            } else {
                Image(systemName: "cpu")
                    .font(.system(size: 24))
                    .foregroundColor(SiphonTheme.accent)
                    .frame(width: 54, height: 36)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(download.title.isEmpty ? download.url : download.title)
                        .font(.geist(14, weight: .bold))
                        .lineLimit(1)
                    
                    if let hdr = download.diagnostics.hdrSummary ?? download.mediaInfo?.formats?.first(where: { $0.isHDR })?.hdrSummary {
                        Text(hdr)
                            .font(.geist(10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                LinearGradient(
                                    colors: [SiphonTheme.statusHdr, Color.orange],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .allowedDynamicRange(AdaptiveRenderingEnvironment.shared.capabilities.supportsEDR ? .high : .standard)
                            )
                            .clipShape(Capsule())
                    }
                }
                
                HStack(spacing: 6) {
                    Text(download.status.title(lang: languageService))
                        .font(.geist(11, weight: .medium))
                        .foregroundColor(statusColor(for: download.status))
                    
                    Text("•")
                        .foregroundColor(.secondary)
                        .font(.geist(11))
                    
                    Text(download.sourceDomain)
                        .font(.geist(11))
                        .foregroundColor(.secondary)
                    
                    if let pid = download.diagnostics.pid, pid > 0 {
                        Text("•")
                            .foregroundColor(.secondary)
                            .font(.geist(11))
                        Text("PID: \(pid)")
                            .font(.geist(11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.bouncy(scale: 0.90, hover: 1.10))
            .help(languageService.s("close"))
            .accessibilityLabel(languageService.s("close"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    // MARK: - Tab 1: Runtime & Process
    
    private var runtimeTab: some View {
        VStack(spacing: 12) {
            diagnosticSection(title: "Process Execution") {
                diagnosticRow(label: "Process ID (PID)", value: download.diagnostics.pid.map { "\($0)" } ?? (download.status == .downloading || download.status == .processing ? "Active Subprocess" : "Terminated"))
                diagnosticRow(label: "Exit Status", value: download.diagnostics.exitStatus ?? (download.status == .completed ? "Completed (0)" : download.status == .failed ? "Failed" : "Running"))
                diagnosticRow(label: "yt-dlp Engine", value: download.diagnostics.ytdlpVersion ?? "yt-dlp (System/AppSupport)")
                diagnosticRow(label: "FFmpeg Pipeline", value: download.diagnostics.ffmpegVersion ?? "FFmpeg (Static build)")
            }
            
            diagnosticSection(title: "Network & Timing") {
                diagnosticRow(label: "Source URL", value: download.url, isMonospace: true)
                diagnosticRow(label: "Resolved Domain", value: download.sourceDomain)
                diagnosticRow(label: "Peak Download Speed", value: download.diagnostics.peakSpeed ?? download.speed ?? "N/A")
                diagnosticRow(label: "Duration", value: download.duration ?? "N/A")
                diagnosticRow(label: "HTTP Retry Count", value: "\(download.diagnostics.httpRetries)")
            }
        }
    }
    
    // MARK: - Tab 2: Media & Color (HDR)
    
    private var mediaAndColorTab: some View {
        VStack(spacing: 12) {
            diagnosticSection(title: "Stream & Formats") {
                diagnosticRow(label: "Selected Format ID", value: download.diagnostics.formatId ?? download.options.selectedFormatId ?? "auto/best")
                diagnosticRow(label: "Video Codec", value: download.diagnostics.videoCodec ?? download.options.videoCodec?.title(lang: languageService) ?? "Auto")
                diagnosticRow(label: "Audio Codec", value: download.diagnostics.audioCodec ?? download.options.audioCodec?.title(lang: languageService) ?? "Auto")
                diagnosticRow(label: "Container", value: (download.diagnostics.container ?? download.options.fileType.rawValue).uppercased())
                diagnosticRow(label: "Resolution & FPS", value: download.diagnostics.resolution ?? download.options.videoResolution?.title(lang: languageService) ?? "Best")
            }
            
            diagnosticSection(title: "Color Space & Dynamic Range (EDR)") {
                diagnosticRow(label: "Dynamic Range", value: download.diagnostics.dynamicRange ?? (download.mediaInfo?.formats?.first(where: { $0.isHDR }) != nil ? "HDR" : "SDR"))
                diagnosticRow(label: "Color Primaries / Space", value: download.diagnostics.colorSpace ?? "BT.709 (Rec. 709 Standard Gamut)")
                diagnosticRow(label: "Bit Depth", value: download.diagnostics.bitDepth.map { "\($0)-bit per channel" } ?? "8-bit (Standard)")
                diagnosticRow(label: "HDR Action Policy", value: download.options.hdrAction?.title(lang: languageService) ?? "Preserve HDR")
            }
            
            if let file = download.filePath {
                diagnosticSection(title: "Local File Target") {
                    diagnosticRow(label: "Destination Path", value: file.path, isMonospace: true)
                    diagnosticRow(label: "File Exists", value: FileManager.default.fileExists(atPath: file.path) ? "Yes (Valid)" : "No (Temporary/Moved)")
                }
            }
        }
    }
    
    // MARK: - Tab 3: Command & Logs
    
    private var commandAndLogsTab: some View {
        VStack(spacing: 14) {
            if let cmd = download.diagnostics.commandLine ?? (download.log.components(separatedBy: "\n").first(where: { $0.contains("yt-dlp") })) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Executed Command")
                            .font(.geist(12, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Button {
                            copyToClipboard(cmd, label: "Command copied")
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy Command")
                            }
                            .font(.geist(11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(SiphonTheme.accent)
                    }
                    
                    Text(cmd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Execution Log Output")
                        .font(.geist(12, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button {
                        copyToClipboard(download.log, label: "Log copied")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Full Log")
                        }
                        .font(.geist(11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(SiphonTheme.accent)
                }
                
                TextField("Search logs...", text: $logSearchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.geist(11))
                
                ScrollView {
                    Text(filteredLogs)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 180, maxHeight: 240)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack {
            if let notice = copiedNotice {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(SiphonTheme.statusCompleted)
                    Text(notice)
                        .font(.geist(11))
                        .foregroundColor(.secondary)
                }
                .transition(.opacity)
            }
            
            Spacer()
            
            Button {
                exportDiagnosticsMarkdown()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Copy Markdown Report")
                }
                .font(.geist(12, weight: .medium))
            }
            .buttonStyle(.bordered)
            
            if let file = download.filePath, FileManager.default.fileExists(atPath: file.path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("Show in Finder")
                    }
                    .font(.geist(12, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
            
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.geist(12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(SiphonTheme.accent)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    // MARK: - Helpers & Components
    
    @ViewBuilder
    private func diagnosticSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.geist(12, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            
            VStack(spacing: 0) {
                content()
            }
            .background(SiphonTheme.cardBackground(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(SiphonTheme.cardBorder(cornerRadius: 8))
        }
    }
    
    @ViewBuilder
    private func diagnosticRow(label: String, value: String, isMonospace: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.geist(12))
                .foregroundColor(.secondary)
                .frame(width: 170, alignment: .leading)
            
            Spacer()
            
            Text(value)
                .font(isMonospace ? .system(size: 11, design: .monospaced) : .geist(12, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(
            Divider().opacity(0.18),
            alignment: .bottom
        )
    }
    
    private var filteredLogs: String {
        let lines = download.log.components(separatedBy: "\n")
        if logSearchText.isEmpty {
            return download.log.isEmpty ? "No log output recorded." : download.log
        }
        let matches = lines.filter { $0.localizedCaseInsensitiveContains(logSearchText) }
        return matches.isEmpty ? "No matches for '\(logSearchText)'" : matches.joined(separator: "\n")
    }
    
    private func statusColor(for status: DownloadStatus) -> Color {
        switch status {
        case .downloading, .fetching: return SiphonTheme.statusDownloading
        case .queued: return SiphonTheme.statusQueued
        case .completed: return SiphonTheme.statusCompleted
        case .failed: return SiphonTheme.statusFailed
        case .stopped, .paused: return .secondary
        case .processing: return .purple
        case .fileExists: return .orange
        }
    }
    
    private func copyToClipboard(_ text: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        withAnimation {
            copiedNotice = label
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                copiedNotice = nil
            }
        }
    }
    
    private func exportDiagnosticsMarkdown() {
        let report = """
        # Siphon Download Diagnostics Report
        - **Title**: \(download.title)
        - **URL**: \(download.url)
        - **Status**: \(download.status.rawValue)
        - **PID**: \(download.diagnostics.pid.map(String.init) ?? "N/A")
        - **Format**: \(download.diagnostics.formatId ?? "auto")
        - **Codecs**: \(download.diagnostics.videoCodec ?? "N/A") / \(download.diagnostics.audioCodec ?? "N/A")
        - **HDR / Color**: \(download.diagnostics.hdrSummary ?? "SDR (BT.709)")
        - **yt-dlp**: \(download.diagnostics.ytdlpVersion ?? "N/A")
        - **FFmpeg**: \(download.diagnostics.ffmpegVersion ?? "N/A")
        - **Exit Status**: \(download.diagnostics.exitStatus ?? "N/A")
        - **Path**: \(download.filePath?.path ?? "N/A")
        """
        copyToClipboard(report, label: "Markdown report copied!")
    }
}
