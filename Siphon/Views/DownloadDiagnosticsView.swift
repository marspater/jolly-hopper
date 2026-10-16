import SwiftUI
import AppKit

struct DownloadDiagnosticsView: View {
    @ObservedObject var download: Download
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var languageService: LanguageService

    @State private var selectedTab = 0
    @StateObject private var copyFeedback = TransientFeedbackState()
    @State private var logSearchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerView

            SiphonTheme.subtleDivider

            SiphonSegmentedPicker(
                selection: $selectedTab,
                options: [
                    (0, languageService.s("runtime_and_process")),
                    (1, languageService.s("media_and_color")),
                    (2, languageService.s("command_and_logs"))
                ]
            )
            .accessibilityElement(children: .contain)
            .padding(.horizontal, SiphonTheme.spacing20)
            .padding(.vertical, SiphonTheme.spacing12)
            .accessibilityLabel(languageService.s("view_diagnostics"))

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
                ThumbnailImage(url: thumb) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 54, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.primary.opacity(SiphonTheme.Opacity.fillPlaceholder))
                            .frame(width: 54, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
                    }
                }
            } else {
                Image(systemName: "cpu")
                    .font(.system(size: 24))
                    .foregroundColor(SiphonTheme.accentText)
                    .frame(width: 54, height: 36)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(download.displayTitle)
                        .font(.siphonPrimarySemibold)
                        .lineLimit(1)

                    if let hdr = download.diagnostics.hdrSummary ?? download.mediaInfo?.formats?.first(where: { $0.isHDR })?.hdrSummary {
                        SiphonTagBadge(text: hdr, isHdr: true)
                    }
                }

                HStack(spacing: SiphonTheme.spacing6) {
                    Text(download.status.title(lang: languageService))
                        .font(.siphonMetadataMedium)
                        .foregroundColor(SiphonTheme.statusForeground(for: download.status, colorScheme: colorScheme))

                    Text("•")
                        .foregroundColor(.secondary)
                        .font(.siphonMetadata)

                    Text(download.sourceDomain)
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)

                    if let pid = download.diagnostics.pid, pid > 0 {
                        Text("•")
                            .foregroundColor(.secondary)
                            .font(.siphonMetadata)
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
                    .accessibilityHidden(true)
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
            return languageService.s("diag_exit_completed")
        case .failed:
            return languageService.s("diag_exit_failed")
        default:
            return languageService.s("diag_exit_running")
        }
    }

    private var runtimeTab: some View {
        VStack(spacing: 12) {
            diagnosticSection(title: languageService.s("diag_process_execution")) {
                diagnosticRow(label: languageService.s("diag_process_id"), value: download.diagnostics.pid.map { "\($0)" } ?? (download.status == .downloading || download.status == .fetching || download.status == .processing ? languageService.s("diag_active_subprocess") : languageService.s("diag_terminated")))
                diagnosticRow(label: languageService.s("diag_exit_status"), value: diagnosticExitStatus)
                diagnosticRow(label: languageService.s("diag_ytdlp_engine"), value: download.diagnostics.ytdlpVersion ?? languageService.s("diag_ytdlp_fallback"))
                diagnosticRow(label: languageService.s("diag_ffmpeg_pipeline"), value: download.diagnostics.ffmpegVersion ?? languageService.s("diag_ffmpeg_fallback"))
            }

            diagnosticSection(title: languageService.s("diag_network_timing")) {
                diagnosticRow(label: languageService.s("diag_source_url"), value: download.url, isMonospace: true)
                diagnosticRow(label: languageService.s("diag_resolved_domain"), value: download.sourceDomain)
                diagnosticRow(label: languageService.s("diag_peak_speed"), value: download.diagnostics.peakSpeed ?? download.speed ?? languageService.s("diag_not_available"))
                diagnosticRow(label: languageService.s("diag_duration"), value: download.duration ?? languageService.s("diag_not_available"))
                diagnosticRow(label: languageService.s("diag_http_retries"), value: "\(download.diagnostics.httpRetries)")
            }
        }
    }

    // MARK: - Tab 2: Media & Color (HDR)

    private var mediaAndColorTab: some View {
        VStack(spacing: 12) {
            diagnosticSection(title: languageService.s("diag_stream_formats")) {
                diagnosticRow(label: languageService.s("diag_format_id"), value: download.diagnostics.formatId ?? download.options.selectedFormatId ?? languageService.s("not_detected"))
                diagnosticRow(label: languageService.s("diag_video_codec"), value: download.diagnostics.videoCodec ?? download.options.videoCodec?.title(lang: languageService) ?? languageService.s("diag_auto"))
                diagnosticRow(label: languageService.s("diag_audio_codec"), value: download.diagnostics.audioCodec ?? download.options.audioCodec?.title(lang: languageService) ?? languageService.s("diag_auto"))
                diagnosticRow(label: languageService.s("diag_container"), value: (download.diagnostics.container ?? download.options.fileType.rawValue).uppercased())
                diagnosticRow(label: languageService.s("diag_resolution_fps"), value: download.diagnostics.resolution ?? download.options.videoResolution?.title(lang: languageService) ?? languageService.s("diag_best"))
            }

            diagnosticSection(title: languageService.s("diag_color_section")) {
                diagnosticRow(label: languageService.s("diag_dynamic_range"), value: download.diagnostics.dynamicRange ?? (download.mediaInfo?.formats?.first(where: { $0.isHDR }) != nil ? languageService.s("diag_hdr") : languageService.s("not_detected")))
                diagnosticRow(label: languageService.s("diag_color_space"), value: download.diagnostics.colorSpace ?? languageService.s("not_detected"))
                diagnosticRow(label: languageService.s("diag_bit_depth"), value: download.diagnostics.bitDepth.map { String(format: languageService.s("diag_bit_depth_value"), $0) } ?? languageService.s("not_detected"))
                diagnosticRow(label: languageService.s("diag_hdr_policy"), value: download.options.hdrAction?.title(lang: languageService) ?? languageService.s("diag_preserve_hdr"))
            }

            if !download.filePaths.isEmpty {
                diagnosticSection(title: download.filePaths.count > 1 ? String(format: languageService.s("diag_file_targets"), download.filePaths.count) : languageService.s("diag_file_target")) {
                    ForEach(Array(download.filePaths.enumerated()), id: \.element) { idx, file in
                        diagnosticRow(label: download.filePaths.count > 1 ? String(format: languageService.s("diag_file_n"), idx + 1) : languageService.s("diag_destination_path"), value: file.path, isMonospace: true)
                        diagnosticRow(label: download.filePaths.count > 1 ? String(format: languageService.s("diag_status_n"), idx + 1) : languageService.s("diag_file_exists"), value: FileManager.default.fileExists(atPath: file.path) ? languageService.s("diag_file_present") : languageService.s("diag_file_missing"))
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
                            .font(.siphonSecondarySemibold)
                            .foregroundColor(.primary)

                        Spacer()

                        Button {
                            copyToClipboard(cmd, label: languageService.s("copied"))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text(languageService.s("copy_command"))
                            }
                            .font(.siphonMetadata)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(SiphonTheme.accentText)
                    }

                    Text(LoggerService.sanitizedDiagnosticExport(cmd))
                        .font(.siphonMetadataMono)
                        .foregroundColor(.primary.opacity(0.85))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(SiphonTheme.Opacity.fillPill))
                        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous)
                                .stroke(Color.primary.opacity(SiphonTheme.Opacity.borderHairline), lineWidth: 1)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(languageService.s("execution_log_output"))
                        .font(.siphonSecondarySemibold)
                        .foregroundColor(.primary)

                    Spacer()

                    Button {
                        copyToClipboard(download.log, label: languageService.s("copied"))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text(languageService.s("copy_log"))
                        }
                        .font(.siphonMetadata)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(SiphonTheme.accentText)
                }

                HStack(spacing: SiphonTheme.spacing6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)

                    TextField(languageService.s("search_logs"), text: $logSearchText)
                        .textFieldStyle(.plain)
                        .font(.siphonMetadata)
                        .accessibilityLabel(languageService.s("search_logs"))

                    if !logSearchText.isEmpty {
                        Button {
                            logSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .help(languageService.s("clear"))
                        .accessibilityLabel(languageService.s("clear"))
                    }
                }
                .padding(.horizontal, SiphonTheme.spacing8)
                .padding(.vertical, 6)
                .background(SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl))
                .overlay(SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl))

                ScrollView {
                    Text(filteredLogs)
                        .font(.siphonMicroMono)
                        .foregroundColor(.primary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 180, maxHeight: 240)
                .background(Color.primary.opacity(SiphonTheme.Opacity.fillCard))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous)
                        .stroke(Color.primary.opacity(SiphonTheme.Opacity.borderHairline), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if let notice = copyFeedback.current?.message {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(SiphonTheme.statusCompletedText)
                    Text(notice)
                        .font(.siphonMetadata)
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
                        .font(.siphonSecondaryMedium)
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
                            .font(.siphonSecondaryMedium)
                    }
                }
                .buttonStyle(.siphonSecondary)
            }

            Button {
                dismiss()
            } label: {
                Text(languageService.s("done"))
                    .font(.siphonSecondarySemibold)
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
                .font(.siphonSecondarySemibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                content()
            }
            .background(SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard))
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
            .overlay(SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard))
        }
    }

    @ViewBuilder
    private func diagnosticRow(label: String, value: String, isMonospace: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.siphonSecondary)
                .foregroundColor(.secondary)
                .frame(minWidth: 150, idealWidth: 170, maxWidth: 220, alignment: .leading)

            Spacer()

            Text(LoggerService.sanitizedDiagnosticExport(value))
                .font(isMonospace ? .siphonMetadataMono : .siphonSecondaryMedium)
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
        let logs = LoggerService.sanitizedDiagnosticExport(download.log)
        if logSearchText.isEmpty {
            return logs.isEmpty ? languageService.s("no_log_output") : logs
        }
        let matches = logs.split(whereSeparator: \.isNewline)
            .filter { $0.localizedCaseInsensitiveContains(logSearchText) }
        return matches.isEmpty ? String(format: languageService.s("diag_no_matches"), logSearchText) : matches.joined(separator: "\n")
    }

    private func copyToClipboard(_ text: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(LoggerService.sanitizedDiagnosticExport(text), forType: .string)
        copyFeedback.show(label, isSuccess: true, duration: 2.0, animation: .default)
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
        copyToClipboard(report, label: languageService.s("diag_report_copied"))
    }
}
