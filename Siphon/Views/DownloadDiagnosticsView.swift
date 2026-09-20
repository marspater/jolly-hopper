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
            
            SiphonTheme.subtleDivider
            
            Picker("", selection: $selectedTab) {
                Text(languageService.s("runtime_and_process")).tag(0)
                Text(languageService.s("media_and_color")).tag(1)
                Text(languageService.s("command_and_logs")).tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, SiphonTheme.spacing20)
            .padding(.vertical, SiphonTheme.spacing12)
            
            ScrollView {
                VStack(spacing: SiphonTheme.spacing16) {
                    if selectedTab == 0 {
                        runtimeTab
                    } else if selectedTab == 1 {
                        mediaAndColorTab
                    } else {
                        commandAndLogsTab
                    }
                }
                .padding(.horizontal, SiphonTheme.spacing20)
                .padding(.bottom, SiphonTheme.spacing20)
            }
            
            SiphonTheme.subtleDivider
            
            footerView
        }
        .frame(minWidth: 580, idealWidth: 640, maxWidth: 760, minHeight: 480, idealHeight: 540)
        .siphonAdaptiveRendering()
        .siphonWindowBackground()
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
                            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall))
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 54, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall))
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
                    Text(download.displayTitle)
                        .font(.geist(14, weight: .bold))
                        .lineLimit(1)
                    
                    if let hdr = download.diagnostics.hdrSummary ?? download.mediaInfo?.formats?.first(where: { $0.isHDR })?.hdrSummary {
                        SiphonTagBadge(text: hdr, isHdr: true)
                    }
                }
                
                HStack(spacing: SiphonTheme.spacing6) {
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
                        SiphonTagBadge(text: "PID: \(pid)", tintColor: .secondary, isMonospaced: true)
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
            .buttonStyle(.siphonIcon(size: 24))
            .help(languageService.s("close"))
            .accessibilityLabel(languageService.s("close"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    // MARK: - Tab 1: Runtime & Process

    private var diagnosticExitStatus: String {
        if let status = download.diagnostics.exitStatus {
            return status
        }
        switch download.status {
        case .completed:
            return "Completed (0)"
        case .failed:
            return "Failed"
        default:
            return "Running"
        }
    }
    
    private var runtimeTab: some View {
        VStack(spacing: 12) {
            diagnosticSection(title: "Process Execution") {
                diagnosticRow(label: "Process ID (PID)", value: download.diagnostics.pid.map { "\($0)" } ?? (download.status == .downloading || download.status == .processing ? "Active Subprocess" : "Terminated"))
                diagnosticRow(label: "Exit Status", value: diagnosticExitStatus)
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
                diagnosticRow(label: "Selected Format ID", value: download.diagnostics.formatId ?? download.options.selectedFormatId ?? languageService.s("not_detected"))
                diagnosticRow(label: "Video Codec", value: download.diagnostics.videoCodec ?? download.options.videoCodec?.title(lang: languageService) ?? "Auto")
                diagnosticRow(label: "Audio Codec", value: download.diagnostics.audioCodec ?? download.options.audioCodec?.title(lang: languageService) ?? "Auto")
                diagnosticRow(label: "Container", value: (download.diagnostics.container ?? download.options.fileType.rawValue).uppercased())
                diagnosticRow(label: "Resolution & FPS", value: download.diagnostics.resolution ?? download.options.videoResolution?.title(lang: languageService) ?? "Best")
            }
            
            diagnosticSection(title: "Color Space & Dynamic Range (EDR)") {
                diagnosticRow(label: "Dynamic Range", value: download.diagnostics.dynamicRange ?? (download.mediaInfo?.formats?.first(where: { $0.isHDR }) != nil ? "HDR" : languageService.s("not_detected")))
                diagnosticRow(label: "Color Primaries / Space", value: download.diagnostics.colorSpace ?? languageService.s("not_detected"))
                diagnosticRow(label: "Bit Depth", value: download.diagnostics.bitDepth.map { "\($0)-bit per channel" } ?? languageService.s("not_detected"))
                diagnosticRow(label: "HDR Action Policy", value: download.options.hdrAction?.title(lang: languageService) ?? "Preserve HDR")
            }
            
            if !download.filePaths.isEmpty {
                diagnosticSection(title: download.filePaths.count > 1 ? "Local File Targets (\(download.filePaths.count) files)" : "Local File Target") {
                    ForEach(Array(download.filePaths.enumerated()), id: \.element) { idx, file in
                        diagnosticRow(label: download.filePaths.count > 1 ? "File \(idx + 1)" : "Destination Path", value: file.path, isMonospace: true)
                        diagnosticRow(label: download.filePaths.count > 1 ? "Status \(idx + 1)" : "File Exists", value: FileManager.default.fileExists(atPath: file.path) ? "Yes (Valid)" : "No (Temporary/Moved)")
                    }
                }
            }
        }
    }
    
    // MARK: - Tab 3: Command & Logs
    
    private var commandAndLogsTab: some View {
        VStack(spacing: 14) {
            if let cmd = download.diagnostics.commandLine ?? (download.log.split(whereSeparator: \.isNewline).first(where: { $0.contains("yt-dlp") }).map(String.init)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(languageService.s("executed_command"))
                            .font(.geist(12, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Button {
                            copyToClipboard(cmd, label: languageService.s("copied"))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text(languageService.s("copy_command"))
                            }
                            .font(.geist(11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(SiphonTheme.accent)
                    }
                    
                    Text(cmd)
                        .font(.geistMono(11))
                        .foregroundColor(.primary.opacity(0.85))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(languageService.s("execution_log_output"))
                        .font(.geist(12, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button {
                        copyToClipboard(download.log, label: languageService.s("copied"))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text(languageService.s("copy_log"))
                        }
                        .font(.geist(11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(SiphonTheme.accent)
                }
                
                TextField(languageService.s("search_logs"), text: $logSearchText)
                    .textFieldStyle(.plain)
                    .font(.geist(11))
                    .padding(.horizontal, SiphonTheme.spacing8)
                    .padding(.vertical, 6)
                    .background(SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl))
                    .overlay(SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl))
                
                ScrollView {
                    Text(filteredLogs)
                        .font(.geistMono(10))
                        .foregroundColor(.primary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 180, maxHeight: 240)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall)
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
                        .font(.system(size: 12))
                    Text(languageService.s("copy_report"))
                        .font(.geist(12, weight: .medium))
                }
            }
            .buttonStyle(.siphonSecondary)
            
            let validFiles = download.filePaths.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !validFiles.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(validFiles)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                        Text(languageService.s("show_in_finder"))
                            .font(.geist(12, weight: .medium))
                    }
                }
                .buttonStyle(.siphonSecondary)
            }
            
            Button {
                dismiss()
            } label: {
                Text(languageService.s("done"))
                    .font(.geist(12, weight: .semibold))
            }
            .buttonStyle(.siphonPrimary)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, SiphonTheme.spacing20)
        .padding(.vertical, SiphonTheme.spacing12)
    }
    
    // MARK: - Helpers & Components
    
    @ViewBuilder
    private func diagnosticSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SiphonTheme.spacing8) {
            Text(title)
                .font(.geist(12, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            
            VStack(spacing: 0) {
                content()
            }
            .background(SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard))
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard))
            .overlay(SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard))
        }
    }
    
    @ViewBuilder
    private func diagnosticRow(label: String, value: String, isMonospace: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.geist(12))
                .foregroundColor(.secondary)
                .frame(minWidth: 150, idealWidth: 170, maxWidth: 220, alignment: .leading)
            
            Spacer()
            
            Text(value)
                .font(isMonospace ? .geistMono(11) : .geist(12, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(
            SiphonTheme.subtleDivider,
            alignment: .bottom
        )
    }
    
    private var filteredLogs: String {
        if logSearchText.isEmpty {
            return download.log.isEmpty ? languageService.s("no_log_output") : download.log
        }
        let matches = download.log.split(whereSeparator: \.isNewline)
            .filter { $0.localizedCaseInsensitiveContains(logSearchText) }
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
        - **Title**: \(download.displayTitle)
        - **URL**: \(download.url)
        - **Status**: \(download.status.rawValue)
        - **PID**: \(download.diagnostics.pid.map(String.init) ?? "N/A")
        - **Format**: \(download.diagnostics.formatId ?? "auto")
        - **Codecs**: \(download.diagnostics.videoCodec ?? "N/A") / \(download.diagnostics.audioCodec ?? "N/A")
        - **HDR / Color**: \(download.diagnostics.hdrSummary ?? "SDR (BT.709)")
        - **yt-dlp**: \(download.diagnostics.ytdlpVersion ?? "N/A")
        - **FFmpeg**: \(download.diagnostics.ffmpegVersion ?? "N/A")
        - **Exit Status**: \(download.diagnostics.exitStatus ?? "N/A")
        - **Path(s)**: \(download.filePathStrings.isEmpty ? "N/A" : download.filePathStrings.joined(separator: ", "))
        """
        copyToClipboard(report, label: "Markdown report copied!")
    }
}
