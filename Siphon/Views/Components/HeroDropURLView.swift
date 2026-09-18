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

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities
    @FocusState private var isFieldFocused: Bool
    @State private var inputURL: String = ""
    @State private var isTargeted: Bool = false
    @State private var isPasting: Bool = false
    @State private var isExtracting: Bool = false
    @StateObject private var feedback = TransientFeedbackState()

    private var showsFieldFocus: Bool {
        isFieldFocused && appearsActive && !appState.showAddDownloadSheet
    }

    private var showBorders: Bool {
        renderingCapabilities.increaseContrast
    }

    init() {}

    var body: some View {
        ZStack {
            // 1. Adaptive hero surface
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusHero)

            // 2. Calm idle wash; drag targeting becomes deliberately brighter.
            RoundedRectangle(cornerRadius: SiphonTheme.radiusHero, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            SiphonTheme.accent.opacity(isTargeted ? 0.26 : 0.055),
                            SiphonTheme.accentSecondary.opacity(isTargeted ? 0.15 : 0.018),
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
                        SiphonTheme.accent.opacity(isTargeted ? 0.42 : 0.13),
                        SiphonTheme.accentSecondary.opacity(isTargeted ? 0.24 : 0.05),
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
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusHero, style: .continuous))

            // 4. The dashed accent outline is reserved for an actual drag target.
            if isTargeted {
                RoundedRectangle(cornerRadius: SiphonTheme.radiusHero, style: .continuous)
                    .strokeBorder(
                        SiphonTheme.accent,
                        style: StrokeStyle(
                            lineWidth: showBorders ? 2.2 : 2.0,
                            dash: [9, 6],
                            dashPhase: 1
                        )
                    )
                    .shadow(color: SiphonTheme.accent.opacity(0.34), radius: 10)
            } else {
                SiphonTheme.cardBorder(
                    cornerRadius: SiphonTheme.radiusHero,
                    accentColor: showsFieldFocus ? SiphonTheme.accent : nil
                )
            }

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
                            SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl)
                        )
                        .overlay(
                            SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusControl)
                        )
                    }
                    .buttonStyle(.bouncy(scale: 0.96, hover: 1.04))
                    .help(languageService.s("advanced_options"))
                    .accessibilityLabel(languageService.s("advanced_options"))
                }

                // Interactive URL Input Bar
                HStack(alignment: .center, spacing: SiphonTheme.spacing10) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(showsFieldFocus ? SiphonTheme.accent : .secondary)
                        .frame(width: 16, alignment: .center)

                    TextField(languageService.s("hero_enter_url"), text: $inputURL)
                        .textFieldStyle(.plain)
                        .font(.siphonStandard)
                        .focused($isFieldFocused)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .padding(.leading, SiphonTheme.spacing2)
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
                        .foregroundColor(isPasting ? SiphonTheme.statusForeground(for: .completed, colorScheme: colorScheme) : .primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusSmall))
                        .overlay(SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusSmall))
                    }
                    .buttonStyle(.bouncy(scale: 0.96, hover: 1.02))
                    .fixedSize(horizontal: true, vertical: false)
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
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isExtracting || inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.58 : 1.0)
                    .accessibilityLabel(languageService.s("download_btn"))
                }
                .padding(.horizontal, SiphonTheme.spacing12)
                .frame(minHeight: 44)
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
                            .foregroundColor(SiphonTheme.accentForeground(for: colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let current = feedback.current {
                        Image(systemName: current.icon ?? (current.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                            .font(.system(size: 11, weight: .semibold))
                        Text(current.message)
                            .font(.geist(11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(current.message)
                    } else {
                        Text(isTargeted ? languageService.s("drop_url_here") : languageService.s("or_paste_clipboard"))
                            .font(.geist(11, weight: .regular))
                            .foregroundColor(.secondary.opacity(0.70))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundColor(
                    feedback.current?.isSuccess == true
                        ? SiphonTheme.statusForeground(for: .completed, colorScheme: colorScheme)
                        : (feedback.current != nil
                            ? SiphonTheme.statusForeground(for: .failed, colorScheme: colorScheme)
                            : .secondary)
                )
                .frame(height: 16)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 168)
        .scaleEffect(isTargeted ? 1.012 : 1.0)
        .shadow(
            color: SiphonTheme.accent.opacity(isTargeted ? 0.24 : 0.04),
            radius: isTargeted ? 18 : 5,
            y: isTargeted ? 5 : 2
        )
        .animation(SiphonAnimation.bouncySpring, value: isTargeted)
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
