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

    @Environment(\.controlActiveState) private var controlActiveState
    @FocusState private var isFieldFocused: Bool
    @State private var inputURL: String = ""
    @State private var isTargeted: Bool = false
    @State private var isPasting: Bool = false
    @State private var isExtracting: Bool = false
    @StateObject private var feedback = TransientFeedbackState()

    private var showsFieldFocus: Bool {
        isFieldFocused && controlActiveState == .key && !appState.showAddDownloadSheet
    }

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

            // 3. Right-side refractive glass bubble / illumination
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

            // 4. Dashed Glass Border (Adaptive Semantic Stroke)
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
                        : Color.primary.opacity(0.14)
                )

            // 5. Main Card Content
            VStack(spacing: SiphonTheme.spacing14) {
                // Top Brand & Actions Header
                HStack(alignment: .center) {
                    HStack(spacing: 9) {
                        ZStack {
                            Circle()
                                .fill(SiphonTheme.primaryGradient)
                                .frame(width: 28, height: 28)
                                .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 6, y: 2)

                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(languageService.s("drop_url_here"))
                                .font(.geist(15, weight: .semibold))
                                .foregroundColor(.primary)

                            Text(languageService.s("ready_to_download_subtitle"))
                                .font(.geist(11, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Compact Options Button
                    Button {
                        openOptions()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11, weight: .medium))
                            Text(languageService.s("hero_options"))
                                .font(.geist(11, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                                .background(
                                    RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.bouncy(scale: 0.96, hover: 1.04))
                    .help(languageService.s("advanced_options"))
                    .accessibilityLabel(languageService.s("advanced_options"))
                }

                // Interactive URL Input Bar
                HStack(spacing: SiphonTheme.spacing8) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(showsFieldFocus ? SiphonTheme.accent : .secondary)

                    TextField(languageService.s("hero_enter_url"), text: $inputURL)
                        .textFieldStyle(.plain)
                        .font(.geist(13))
                        .focused($isFieldFocused)
                        .onSubmit {
                            submitURL()
                        }

                    if !inputURL.isEmpty {
                        Button {
                            inputURL = ""
                            feedback.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(languageService.s("clear"))
                        .accessibilityLabel(languageService.s("clear"))
                    }

                    // Paste from clipboard button
                    Button {
                        handlePasteAction()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isPasting ? "checkmark" : "doc.on.clipboard")
                                .font(.system(size: 11, weight: .semibold))
                            Text(languageService.s("paste"))
                                .font(.geist(11, weight: .medium))
                        }
                        .foregroundColor(isPasting ? SiphonTheme.statusCompleted : .primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.bouncy(scale: 0.96, hover: 1.02))
                    .help(languageService.s("paste_from_clipboard"))
                    .accessibilityLabel(languageService.s("paste_from_clipboard"))

                    // Download / Return Button
                    Button {
                        submitURL()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(languageService.s("download_btn"))
                                .font(.geist(12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(SiphonTheme.primaryGradient)
                        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
                        .shadow(color: SiphonTheme.accent.opacity(0.30), radius: 4, y: 1)
                    }
                    .buttonStyle(.bouncy(scale: 0.96, hover: 1.02))
                    .disabled(isExtracting)
                    .accessibilityLabel(languageService.s("download_btn"))
                }
                .padding(.horizontal, SiphonTheme.spacing12)
                .padding(.vertical, 8)
                .background(
                    SiphonTheme.fieldBackground(cornerRadius: SiphonTheme.radiusCard, isFocused: showsFieldFocus)
                )
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
                .overlay(
                    SiphonTheme.fieldBorder(cornerRadius: SiphonTheme.radiusCard, isFocused: showsFieldFocus)
                )

                // Inline Real-Time Status & Validation Feedback
                HStack(spacing: 6) {
                    if isExtracting {
                        SiphonSpinner(size: 11, color: SiphonTheme.accent, lineWidth: 1.8)
                        Text(languageService.s("hero_extracting_metadata"))
                            .font(.geist(11, weight: .medium))
                            .foregroundColor(SiphonTheme.accent)
                    } else if let current = feedback.current {
                        Image(systemName: current.icon ?? (current.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                            .font(.system(size: 11, weight: .semibold))
                        Text(current.message)
                            .font(.geist(11, weight: .medium))
                            .lineLimit(1)
                    } else {
                        Text(isTargeted ? languageService.s("drop_url_here") : languageService.s("or_paste_clipboard"))
                            .font(.geist(11, weight: .regular))
                            .foregroundColor(.secondary.opacity(0.70))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundColor(feedback.current?.isSuccess == true ? SiphonTheme.statusCompleted : (feedback.current != nil ? SiphonTheme.statusFailed : .secondary))
                .frame(height: 16)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 168)
        .onDrop(of: [UTType.url, UTType.utf8PlainText, UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onAppear {
            autoFocusIfNeeded()
        }
        .onChange(of: appState.showAddDownloadSheet) { _, showing in
            isFieldFocused = !showing
        }
    }

    // MARK: - Actions

    private func autoFocusIfNeeded() {
        isFieldFocused = !appState.showAddDownloadSheet
    }

    private func submitURL() {
        switch DownloadURLValidator.validate(inputURL) {
        case .empty:
            feedback.show(languageService.s("hero_invalid_url"), isSuccess: false, icon: "exclamationmark.circle.fill")
        case .invalidScheme, .malformed:
            feedback.show(languageService.s("hero_invalid_url"), isSuccess: false, icon: "exclamationmark.circle.fill")
        case .valid(_, let original):
            startDownloads(urls: [original])
            inputURL = ""
            feedback.show(languageService.s("hero_started_download"), isSuccess: true, icon: "checkmark.circle.fill")
        }
    }

    private func openOptions() {
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appState.urlToDownload = trimmed
        }
        appState.showAddDownloadSheet = true
    }

    private func handlePasteAction() {
        if let clipboardString = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clipboardString.isEmpty {
            let extracted = DownloadURLValidator.extractURLs(from: clipboardString)

            if extracted.count > 1 {
                startDownloads(urls: extracted)
                inputURL = ""
                feedback.show(String(format: languageService.s("hero_started_downloads"), extracted.count), isSuccess: true, icon: "checkmark.circle.fill")
                return
            } else if let single = extracted.first {
                inputURL = single
                isPasting = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    isPasting = false
                }
                return
            }
        }

        feedback.show(languageService.s("hero_no_clipboard_url"), isSuccess: false, icon: "info.circle.fill")
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

                    if let raw = urlString {
                        Task { @MainActor in
                            switch DownloadURLValidator.validate(raw) {
                            case .valid(_, let original):
                                inputURL = original
                                submitURL()
                            default:
                                feedback.show(languageService.s("hero_invalid_url"), isSuccess: false, icon: "exclamationmark.circle.fill")
                            }
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
                            let urls = DownloadURLValidator.extractURLs(from: content)
                            if !urls.isEmpty {
                                Task { @MainActor in
                                    startDownloads(urls: urls)
                                    feedback.show(String(format: languageService.s("hero_started_downloads"), urls.count), isSuccess: true, icon: "checkmark.circle.fill")
                                }
                            } else {
                                Task { @MainActor in
                                    feedback.show(languageService.s("no_valid_urls"), isSuccess: false, icon: "exclamationmark.circle.fill")
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
                        let urls = DownloadURLValidator.extractURLs(from: text)
                        if urls.count > 1 {
                            Task { @MainActor in
                                startDownloads(urls: urls)
                                feedback.show(String(format: languageService.s("hero_started_downloads"), urls.count), isSuccess: true, icon: "checkmark.circle.fill")
                            }
                        } else if let single = urls.first {
                            Task { @MainActor in
                                inputURL = single
                                submitURL()
                            }
                        } else {
                            Task { @MainActor in
                                feedback.show(languageService.s("hero_invalid_url"), isSuccess: false, icon: "exclamationmark.circle.fill")
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
}
