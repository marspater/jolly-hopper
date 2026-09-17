//
//  HeroDropURLView.swift
//  Siphon
//

import SwiftUI
import UniformTypeIdentifiers

struct HeroDropURLView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService

    @State private var isTargeted: Bool = false
    @State private var isPasting: Bool = false
    @State private var statusFeedbackMessage: String? = nil
    @State private var statusFeedbackSuccess: Bool = true

    init() {}

    var body: some View {
        ZStack {
            // 1. Base Glass Material
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)

            // 2. Translucent accent wash with subtle depth
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            SiphonTheme.accent.opacity(isTargeted ? 0.22 : 0.08),
                            Color.cyan.opacity(isTargeted ? 0.12 : 0.03),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 3. Right-side refractive glass bubble / illumination (matching reference)
            HStack {
                Spacer()
                RadialGradient(
                    colors: [
                        SiphonTheme.accent.opacity(isTargeted ? 0.35 : 0.20),
                        Color.cyan.opacity(isTargeted ? 0.18 : 0.08),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 260
                )
                .frame(width: 320)
                .blur(radius: 20)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            // 4. Dashed Glass Border
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(
                        lineWidth: isTargeted ? 2.0 : 1.2,
                        dash: [8, 6]
                    )
                )
                .foregroundColor(
                    isTargeted
                        ? SiphonTheme.accent
                        : Color.white.opacity(0.18)
                )

            // 5. Central Interactive Area
            VStack(spacing: SiphonTheme.spacing14) {
                // Radiant + Button
                Button {
                    handlePasteAction()
                } label: {
                    ZStack {
                        Circle()
                            .fill(SiphonTheme.primaryGradient)
                            .frame(width: 54, height: 54)
                            .shadow(color: SiphonTheme.accent.opacity(0.45), radius: 12, y: 4)

                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.bouncy(scale: 0.94, hover: 1.05))
                .help(languageService.s("paste_or_add"))

                // Labels
                VStack(spacing: 4) {
                    Text(languageService.s("drop_url_here"))
                        .font(.geist(18, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(languageService.s("or_paste_clipboard"))
                        .font(.geist(13, weight: .regular))
                        .foregroundColor(.secondary)
                }

                // Paste from Clipboard Button Pill
                HStack(spacing: SiphonTheme.spacing12) {
                    Button {
                        handlePasteAction()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: isPasting ? "checkmark" : "doc.on.clipboard")
                                .font(.system(size: 12, weight: .semibold))
                            Text(languageService.s("paste_from_clipboard"))
                                .font(.geist(13, weight: .medium))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .background(
                                    RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                                .stroke(Color.white.opacity(0.20), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.bouncy(scale: 0.96, hover: 1.02))

                    // Advanced options button
                    Button {
                        appState.showAddDownloadSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(languageService.s("advanced_options"))
                }

                if let message = statusFeedbackMessage {
                    Text(message)
                        .font(.geist(11, weight: .medium))
                        .foregroundColor(statusFeedbackSuccess ? SiphonTheme.statusCompleted : SiphonTheme.statusFailed)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
        .onDrop(of: [UTType.url, UTType.utf8PlainText, UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Actions

    private func handlePasteAction() {
        if let clipboardString = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clipboardString.isEmpty {
            let lines = clipboardString.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let validURLs = lines.filter { line in
                line.hasPrefix("http://") || line.hasPrefix("https://")
            }

            if !validURLs.isEmpty {
                startDownloads(urls: validURLs)
                triggerFeedback(message: "Started \(validURLs.count) download\(validURLs.count > 1 ? "s" : "")", success: true)
                return
            }
        }

        // If no valid URL found on clipboard, open full add download window
        appState.showAddDownloadSheet = true
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // 1. Handle direct URL drops
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    let urlString: String? = {
                        if let url = item as? URL { return url.absoluteString }
                        if let data = item as? Data { return String(data: data, encoding: .utf8) }
                        if let str = item as? String { return str }
                        return nil
                    }()

                    if let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
                       raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                        Task { @MainActor in
                            startDownloads(urls: [raw])
                            triggerFeedback(message: "Started download", success: true)
                        }
                    }
                }
                return true
            }

            // 2. Handle file drops (.txt batch files)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var fileURL: URL? = nil
                    if let url = item as? URL {
                        fileURL = url
                    } else if let data = item as? Data, let path = String(data: data, encoding: .utf8) {
                        fileURL = URL(string: path)
                    }

                    if let fURL = fileURL, fURL.pathExtension.lowercased() == "txt" {
                        if let content = try? String(contentsOf: fURL, encoding: .utf8) {
                            let urls = content.components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
                            if !urls.isEmpty {
                                Task { @MainActor in
                                    startDownloads(urls: urls)
                                    triggerFeedback(message: "Queued \(urls.count) batch downloads", success: true)
                                }
                            }
                        }
                    }
                }
                return true
            }

            // 3. Handle plain text drops
            if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier, options: nil) { item, _ in
                    if let text = item as? String {
                        let lines = text.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
                        if !lines.isEmpty {
                            Task { @MainActor in
                                startDownloads(urls: lines)
                                triggerFeedback(message: "Started \(lines.count) download\(lines.count > 1 ? "s" : "")", success: true)
                            }
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func startDownloads(urls: [String]) {
        let options = DownloadOptions.default
        if urls.count == 1 {
            downloadManager.addDownload(url: urls[0], options: options)
        } else {
            downloadManager.addDownloads(urls: urls, options: options)
        }
    }

    private func triggerFeedback(message: String, success: Bool) {
        statusFeedbackMessage = message
        statusFeedbackSuccess = success
        isPasting = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                statusFeedbackMessage = nil
                isPasting = false
            }
        }
    }
}
