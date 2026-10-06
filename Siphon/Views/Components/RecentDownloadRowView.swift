//
//  RecentDownloadRowView.swift
//  Siphon
//

import SwiftUI

struct RecentDownloadRowView: View {
    @ObservedObject var download: Download
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered: Bool = false
    @State private var primaryFileIsPresent: Bool?

    init(download: Download) {
        self.download = download
    }

    var body: some View {
        HStack(alignment: .center, spacing: SiphonTheme.spacing12) {
            thumbnailView
            metadataView
            formatPillsView
                .fixedSize(horizontal: true, vertical: false)
            statusLabelView
                .frame(width: 136, alignment: .trailing)

            // Fixed 24 pt slots keep every row's icons on the same columns,
            // whether or not a row has a primary action.
            HStack(spacing: SiphonTheme.spacing8) {
                primaryActionView
                    .frame(width: 24, height: 24)
                removeActionView
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, SiphonTheme.spacing14)
        .padding(.vertical, 8)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl, isHovered: isHovered)
        )
        .overlay(
            SiphonTheme.borderSubtle(
                cornerRadius: SiphonTheme.radiusControl,
                isHovered: isHovered,
                accentColor: activeTint
            )
        )
        .siphonCardHover(isHovered: isHovered, tint: activeTint ?? .clear)
        .task(id: download.primaryFilePath) {
            primaryFileIsPresent.refreshPresence(of: download)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            primaryFileIsPresent.refreshPresence(of: download)
        }
        .onHover { hovering in
            withAnimation(SiphonAnimation.hoverSpring) {
                isHovered = hovering
            }
        }
        .onTapGesture(count: 2) {
            // Double-clicking a finished row plays it, like Play on its card.
            if download.status == .completed, let path = download.primaryFilePath, primaryFileIsPresent != false {
                downloadManager.openFile(path)
            }
        }
    }

    /// Only in-flight rows are tinted. Finished rows stay neutral (no colored
    /// border, no glow); the status label already says how they ended.
    private var activeTint: Color? {
        switch download.status {
        case .downloading, .fetching, .processing: return SiphonTheme.statusDownloading
        case .queued, .paused, .fileExists: return SiphonTheme.statusQueued
        case .completed, .failed, .stopped: return nil
        }
    }

    private var canRemoveFromHistory: Bool {
        switch download.status {
        case .completed, .failed, .stopped, .fileExists: return true
        default: return false
        }
    }

    // MARK: - Subviews

    /// Signed poster links (Recu's) expire, so a finished download falls back to its file.
    @ViewBuilder
    private var fileThumbnail: some View {
        if let filePath = download.primaryFilePath, primaryFileIsPresent != false {
            DownloadRowView.FileThumbnailView(fileURL: filePath, isHDR: false)
                .frame(width: 54, height: 36)
        } else {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 16))
                .foregroundColor(.secondary.opacity(0.6))
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous)
                .fill(Color.primary.opacity(SiphonTheme.Opacity.fillPlaceholder))
                .frame(width: 54, height: 36)

            if let thumb = download.thumbnailURL {
                ThumbnailImage(url: thumb) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 54, height: 36)
                        .clipped()
                } placeholder: {
                    fileThumbnail
                }
            } else {
                fileThumbnail
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous)
                .stroke(Color.primary.opacity(SiphonTheme.Opacity.borderRest), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var metadataView: some View {
        VStack(alignment: .leading, spacing: 3) {
            let displayTitle = download.displayTitle
            Text(displayTitle)
                .font(.siphonSecondaryMedium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(displayTitle)

            HStack(spacing: 6) {
                if download.sourceDomain == "YouTube" {
                    Circle()
                        .fill(SiphonTheme.sourceYouTube)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(download.sourceDomain)
                    .font(.siphonMetadata)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(download.sourceDomain)
            }
        }
        .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var formatPillsView: some View {
        HStack(spacing: 4) {
            SiphonTagBadge(text: download.options.fileType.rawValue, isMonospaced: true)

            if let res = download.options.videoResolution {
                let resText: String = {
                    switch res {
                    case .r2160p: return "4K"
                    case .r1440p: return "1440p"
                    case .r1080p: return "1080p"
                    case .r720p: return "720p"
                    case .r480p: return "480p"
                    case .r360p: return "360p"
                    case .r240p: return "240p"
                    case .best: return "Best"
                    case .worst: return "Worst"
                    }
                }()
                SiphonTagBadge(text: resText, isMonospaced: true)
            }
        }
    }

    @ViewBuilder
    private var statusLabelView: some View {
        switch download.status {
        case .downloading:
            let rawProgress = download.progress
            let safeProgress = rawProgress.isNaN ? 0.0 : max(0.0, min(1.0, rawProgress))
            let percentText = "\(Int(safeProgress * 100))%"

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Text(languageService.s("downloading"))
                        .font(.siphonMetadataMedium)
                        .foregroundColor(SiphonTheme.statusForeground(for: .downloading, colorScheme: colorScheme))
                    Text(percentText)
                        .font(.siphonMetadataMonoSemibold)
                        .foregroundColor(.primary)
                }

                ProgressView(value: safeProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .tint(SiphonTheme.statusDownloading)
                    .animation(SiphonAnimation.snappySpring, value: safeProgress)
            }
        case .fetching, .processing:
            HStack(spacing: 6) {
                Text(download.status.title(lang: languageService))
                    .font(.siphonMetadataMedium)
                    .foregroundColor(SiphonTheme.statusForeground(for: download.status, colorScheme: colorScheme))
                    .lineLimit(1)
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            }
        case .queued:
            statusLabel(languageService.s("queued"), icon: "clock.fill", status: .queued)
        case .paused:
            statusLabel(download.status.title(lang: languageService), icon: "pause.circle.fill", status: .paused)
        case .completed:
            statusLabel(languageService.s("completed"), icon: "checkmark.circle.fill", status: .completed)
        case .failed:
            statusLabel(languageService.s("failed"), icon: "exclamationmark.circle.fill", status: .failed)
        case .stopped:
            statusLabel(download.status.title(lang: languageService), icon: "stop.circle.fill", status: .stopped)
        case .fileExists:
            statusLabel(download.status.title(lang: languageService), icon: "doc.on.doc.fill", status: .fileExists)
        }
    }

    private func statusLabel(_ text: String, icon: String, status: DownloadStatus) -> some View {
        let color = SiphonTheme.statusForeground(for: status, colorScheme: colorScheme)
        return HStack(spacing: 6) {
            Text(text)
                .font(.siphonMetadataMedium)
                .foregroundColor(color)
                .lineLimit(1)
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var primaryActionView: some View {
        switch download.status {
        case .downloading, .fetching, .processing:
            Button {
                downloadManager.stopDownload(download)
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(SiphonTheme.statusDownloadingText)
            }
            .buttonStyle(.siphonIcon(size: 24))
            .help(languageService.s("stop_download"))
            .accessibilityLabel(languageService.s("stop_download"))
        case .completed where download.primaryFilePath != nil && primaryFileIsPresent != false:
            revealButton { downloadManager.showInFinder(download.filePaths) }
        case .fileExists:
            revealButton { downloadManager.revealExistingFile(for: download) }
        default:
            Color.clear.accessibilityHidden(true)
        }
    }

    private func revealButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.siphonIcon(size: 24))
        .help(languageService.s("reveal_in_finder"))
        .accessibilityLabel(languageService.s("reveal_in_finder"))
    }

    @ViewBuilder
    private var removeActionView: some View {
        if canRemoveFromHistory {
            Button {
                downloadManager.removeDownload(download)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.siphonIcon(size: 24))
            .help(languageService.s("remove_from_history"))
            .accessibilityLabel(languageService.s("remove_from_history"))
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }
}
