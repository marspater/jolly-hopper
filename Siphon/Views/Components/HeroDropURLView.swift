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
    @EnvironmentObject var updateChecker: UpdateChecker

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities
    @FocusState private var isFieldFocused: Bool
    @State private var inputURL: String = ""
    @State private var isTargeted: Bool = false
    @StateObject private var feedback = TransientFeedbackState()
    @StateObject private var pasteFeedback = TransientFeedbackState()

    private var showsFieldFocus: Bool {
        isFieldFocused && appearsActive && !appState.showAddDownloadSheet
    }

    private var showBorders: Bool {
        renderingCapabilities.increaseContrast
    }

    init() {
        // Intentionally empty initializer for SwiftUI View (swift:S1186)
    }

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
                    // Fits the 320 pt frame, so the glow fades out instead of
                    // being cut off at the frame's edges.
                    endRadius: 150
                )
                .frame(width: 320)
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
                        .accessibilityHidden(true)

                        Text(languageService.s("drop_url_here"))
                            .font(.siphonHeadline)
                            .foregroundColor(.primary)
                    }

                    Spacer()

                    // Compact Options Button
                    Button {
                        openOptions()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 12, weight: .semibold))
                                .accessibilityHidden(true)
                            Text(languageService.s("hero_options"))
                                .font(.siphonSecondaryMedium)
                        }
                    }
                    // Options, Paste and Download share one height, radius and type
                    // size; only Download, the primary action, is filled.
                    .buttonStyle(.siphonSecondary)
                    .help(languageService.s("hero_options_help"))
                    .accessibilityLabel(languageService.s("hero_options_help"))
                }

                // Interactive URL Input Bar
                HStack(alignment: .center, spacing: SiphonTheme.spacing10) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(showsFieldFocus ? SiphonTheme.accentText : .secondary)
                        .frame(width: 16, alignment: .center)
                        .accessibilityHidden(true)

                    TextField(languageService.s("url_hint"), text: $inputURL)
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
                        HStack(spacing: 5) {
                            Image(systemName: pasteFeedback.isShowing ? "checkmark" : "doc.on.clipboard")
                                .font(.system(size: 12, weight: .semibold))
                                .accessibilityHidden(true)
                            Text(languageService.s("paste"))
                                .font(.siphonSecondaryMedium)
                        }
                        .foregroundColor(pasteFeedback.isShowing ? SiphonTheme.statusForeground(for: .completed, colorScheme: colorScheme) : .primary)
                    }
                    .buttonStyle(.siphonSecondary)
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
                                .accessibilityHidden(true)
                            Text(languageService.s("download_btn"))
                                .font(.siphonSecondarySemibold)
                        }
                    }
                    .buttonStyle(.siphonPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    if let current = feedback.current {
                        Image(systemName: current.icon ?? (current.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(current.message)
                            .font(.siphonMetadataMedium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(current.message)
                    } else {
                        // The Paste button already offers the clipboard; teach the shortcut instead.
                        Text(isTargeted ? languageService.s("drop_url_here") : languageService.s("press_return_to_download"))
                            .font(.siphonMetadata)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundColor(feedbackForegroundColor)
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

    private var feedbackForegroundColor: Color {
        if feedback.current?.isSuccess == true {
            return SiphonTheme.statusForeground(for: .completed, colorScheme: colorScheme)
        } else if feedback.current != nil {
            return SiphonTheme.statusForeground(for: .failed, colorScheme: colorScheme)
        } else {
            return .secondary
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

    /// Links started here use the default download options, so Options opens
    /// the Settings tab that holds them.
    private func openOptions() {
        PreferencesWindowManager.shared.showPreferencesWindow(
            languageService: languageService,
            updateChecker: updateChecker,
            downloadManager: downloadManager,
            appState: appState,
            initialTab: .download
        )
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
                pasteFeedback.show(languageService.s("paste"), isSuccess: true, duration: 1.2)
                return
            }
        }

        feedback.show(languageService.s("hero_no_clipboard_url"), isSuccess: false, icon: "info.circle.fill")
    }

    /// The first type a drop is read as. File URLs also conform to `public.url`,
    /// so they are matched first; otherwise a dropped .txt list arrives as a
    /// `file://` link and is rejected as an invalid URL.
    static func dropType(of provider: NSItemProvider) -> UTType? {
        [UTType.fileURL, .url, .utf8PlainText].first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            let dropType = Self.dropType(of: provider)
            // 1. Handle file drops (.txt batch files)
            if dropType == .fileURL {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var fileURL: URL? = nil
                    if let url = item as? URL {
                        fileURL = url
                    } else if let data = item as? Data, let path = String(data: data, encoding: .utf8) {
                        fileURL = URL(string: path)
                    }

                    // Only .txt lists are read; any other file gets the same feedback as an empty list.
                    let urls: [String] = {
                        guard let fURL = fileURL, fURL.pathExtension.lowercased() == "txt",
                              let content = try? String(contentsOf: fURL, encoding: .utf8) else { return [] }
                        return DownloadURLValidator.extractURLs(from: content)
                    }()
                    Task { @MainActor in
                        if urls.isEmpty {
                            feedback.show(languageService.s("no_valid_urls"), isSuccess: false, icon: "exclamationmark.circle.fill")
                        } else {
                            startDownloads(urls: urls)
                            feedback.show(String(format: languageService.s("hero_started_downloads"), urls.count), isSuccess: true, icon: "checkmark.circle.fill")
                        }
                    }
                }
                return true
            }

            // 2. Handle direct URL drops
            if dropType == .url {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    let urlString: String? = {
                        if let url = item as? URL { return url.absoluteString }
                        if let data = item as? Data { return String(data: data, encoding: .utf8) }
                        if let str = item as? String { return str }
                        return nil
                    }()

                    if let raw = urlString {
                        Task { @MainActor in
                            if case .valid(_, let original) = DownloadURLValidator.validate(raw) {
                                inputURL = original
                                submitURL()
                            } else {
                                feedback.show(languageService.s("hero_invalid_url"), isSuccess: false, icon: "exclamationmark.circle.fill")
                            }
                        }
                    }
                }
                return true
            }

            // 3. Handle plain text drops
            if dropType == .utf8PlainText {
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
        let options = DownloadOptions.defaultFromPreferences()
        if urls.count == 1 {
            downloadManager.addDownload(url: urls[0], options: options)
        } else {
            downloadManager.addDownloads(urls: urls, options: options)
        }
    }
}
