//
//  RecentDownloadRowView.swift
//  Siphon
//

import SwiftUI

struct RecentDownloadRowView: View {
    @ObservedObject var download: Download
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @State private var isHovered: Bool = false

    init(download: Download) {
        self.download = download
    }

    var body: some View {
        HStack(spacing: SiphonTheme.spacing12) {
            thumbnailView
            metadataView
            Spacer()
            formatPillsView
            statusActionView
        }
        .padding(.horizontal, SiphonTheme.spacing14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02))
                .background(
                    RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.15 : 0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(SiphonAnimation.hoverSpring) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 54, height: 36)

            if let thumb = download.thumbnailURL {
                AsyncImage(url: thumb) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 54, height: 36)
                        .clipped()
                } placeholder: {
                    Image(systemName: "film")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "film")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var metadataView: some View {
        VStack(alignment: .leading, spacing: 3) {
            let displayTitle = download.title.isEmpty || download.title == "___FETCHING___" ? download.url : download.title
            Text(displayTitle)
                .font(.geist(12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            HStack(spacing: 6) {
                if download.sourceDomain == "YouTube" {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                }
                Text(download.sourceDomain)
                    .font(.geist(11, weight: .regular))
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 160, alignment: .leading)
    }

    @ViewBuilder
    private var formatPillsView: some View {
        HStack(spacing: 4) {
            Text(download.options.fileType.rawValue)
                .font(.geistMono(10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))

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
                Text(resText)
                    .font(.geistMono(10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
    }

    @ViewBuilder
    private var statusActionView: some View {
        HStack(spacing: SiphonTheme.spacing8) {
            switch download.status {
            case .downloading:
                let rawProgress = download.progress
                let safeProgress = rawProgress.isNaN ? 0.0 : max(0.0, min(1.0, rawProgress))
                let percentText = "\(Int(safeProgress * 100))%"

                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(languageService.s("downloading"))
                            .font(.geist(11, weight: .medium))
                            .foregroundColor(SiphonTheme.statusDownloading)
                        Text(percentText)
                            .font(.geistMono(11, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    ProgressView(value: safeProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                        .tint(SiphonTheme.statusDownloading)
                }

                Button {
                    downloadManager.stopDownload(download)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(SiphonTheme.statusDownloading)
                }
                .buttonStyle(.plain)
                .help(languageService.s("stop_download"))

            case .queued:
                Text(languageService.s("queued"))
                    .font(.geist(11, weight: .medium))
                    .foregroundColor(SiphonTheme.statusQueued)
                Image(systemName: "clock.fill")
                    .font(.system(size: 13))
                    .foregroundColor(SiphonTheme.statusQueued)

            case .completed:
                HStack(spacing: 6) {
                    Text(languageService.s("completed"))
                        .font(.geist(11, weight: .medium))
                        .foregroundColor(SiphonTheme.statusCompleted)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(SiphonTheme.statusCompleted)
                }

                if let fileURL = download.primaryFilePath, FileManager.default.fileExists(atPath: fileURL.path) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(languageService.s("reveal_in_finder"))
                }

            case .failed:
                Text(languageService.s("failed"))
                    .font(.geist(11, weight: .medium))
                    .foregroundColor(SiphonTheme.statusFailed)
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(SiphonTheme.statusFailed)

            default:
                Text(download.status.rawValue.capitalized)
                    .font(.geist(11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 160, alignment: .trailing)
    }
}
