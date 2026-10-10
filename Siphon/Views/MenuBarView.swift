import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities

    private var showBorders: Bool {
        renderingCapabilities.increaseContrast
    }

    @FocusState private var isFieldFocused: Bool
    @State private var url: String = ""
    @State private var selectedType: String = "video"
    @State private var selectedPreset: String = "best_quality"
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    @AppStorage("customPresets") private var customPresetsData: Data = Data()
    
    @State private var customPresets: [CustomPreset] = []
    @StateObject private var pasteFeedback = TransientFeedbackState()

    var body: some View {
        VStack(spacing: SiphonTheme.spacing12) {
            // Hidden button for reliable Escape key handling across all macOS versions
            Button("") {
                MenuBarManager.shared.closePopover()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)

            // Primary Download Flow Card
            VStack(spacing: SiphonTheme.spacing10) {
                urlInput
                formatAndPresetRow
                downloadButton
            }
            .padding(SiphonTheme.spacing12)
            .background(
                SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
            )
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
            .overlay(
                SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
            )

            // Active Downloads Concise Rows
            if !downloadManager.downloadingDownloads.isEmpty {
                activeDownloadsSection
            }

            SiphonTheme.subtleDivider

            // Footer actions
            footer
        }
        .padding(SiphonTheme.spacing12)
        .frame(minWidth: 350, idealWidth: 370, maxWidth: 420)
        .siphonAdaptiveRendering()
        .siphonWindowBackground()
        .onAppear {
            customPresets = CustomPreset.loadAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFieldFocused = true
            }
        }
        .onChange(of: customPresetsData) { _, _ in
            customPresets = CustomPreset.loadAll()
        }
        .onChange(of: selectedType) { _, newValue in
            if newValue == "audio" {
                selectedPreset = "audio_only"
            } else {
                selectedPreset = "best_quality"
            }
        }
    }

    // MARK: - URL Input

    private var urlInput: some View {
        HStack(spacing: SiphonTheme.spacing8) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isFieldFocused && appearsActive ? SiphonTheme.accentText : .secondary)
                .accessibilityHidden(true)

            TextField(languageService.s("url_hint"), text: $url)
                .textFieldStyle(.plain)
                .font(.siphonSecondary)
                .focused($isFieldFocused)
                .accessibilityLabel(languageService.s("video_url"))
                .onSubmit {
                    initiateDownload()
                }

            if !url.isEmpty {
                Button {
                    url = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .help(languageService.s("clear"))
                .accessibilityLabel(languageService.s("clear"))
            }

            Button {
                if let clipboard = NSPasteboard.general.string(forType: .string) {
                    url = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                    pasteFeedback.show(languageService.s("paste"), isSuccess: true, duration: 1.2)
                }
            } label: {
                Image(systemName: pasteFeedback.isShowing ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 12))
                    .foregroundColor(pasteFeedback.isShowing ? SiphonTheme.statusCompletedText : .secondary)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help(languageService.s("paste_from_clipboard"))
            .accessibilityLabel(pasteFeedback.isShowing ? languageService.s("paste") : languageService.s("paste_from_clipboard"))
        }
        .padding(.horizontal, SiphonTheme.spacing10)
        .padding(.vertical, 7)
        .background(
            SiphonTheme.fieldBackground(cornerRadius: SiphonTheme.radiusControl, isFocused: isFieldFocused)
        )
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
        .overlay(
            SiphonTheme.fieldBorder(cornerRadius: SiphonTheme.radiusControl, isFocused: isFieldFocused)
        )
    }

    // MARK: - Format & Preset Unified Row

    private var formatAndPresetRow: some View {
        HStack(spacing: SiphonTheme.spacing8) {
            // Segmented format toggle (Video / Audio)
            SiphonSegmentedPicker(
                selection: $selectedType,
                options: [
                    ("video", languageService.s("video")),
                    ("audio", languageService.s("audio"))
                ],
                horizontalPadding: SiphonTheme.spacing10
            )

            Spacer()

            // Compact Preset Picker
            Picker("", selection: $selectedPreset) {
                Section(languageService.s("standard")) {
                    ForEach(DownloadPreset.allCases) { preset in
                        if (selectedType == "video" && preset != .audioOnly) || (selectedType == "audio" && preset == .audioOnly) {
                            Text(preset.title(lang: languageService)).tag(preset.rawValue)
                        }
                    }
                }

                let filtered = customPresets.filter { (selectedType == "video" && $0.fileType.isVideo) || (selectedType == "audio" && $0.fileType.isAudio) }
                if !filtered.isEmpty {
                    Section(languageService.s("custom")) {
                        ForEach(filtered) { preset in
                            Text(preset.name).tag("custom_" + preset.id.uuidString)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .tint(nil)
            .accessibilityLabel(languageService.s("menubar_preset"))
        }
    }

    // MARK: - Download Button

    private var downloadButton: some View {
        Button {
            initiateDownload()
        } label: {
            HStack(spacing: SiphonTheme.spacing6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(languageService.s("download_btn"))
                    .font(.siphonSecondarySemibold)
                Spacer()
                Text("⏎")
                    .font(.siphonMetadataMonoMedium)
                    .opacity(0.8)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.siphonPrimary)
        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(languageService.s("download_btn"))
    }

    // MARK: - Active Downloads Concise List

    private var activeDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(languageService.s("menubar_active_downloads"))
                    .font(.siphonMicroSemibold)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(downloadManager.downloadingDownloads.count)")
                    .font(.siphonMicroMonoSemibold)
                    .foregroundColor(SiphonTheme.statusDownloadingText)
            }
            .padding(.horizontal, 2)

            ForEach(downloadManager.downloadingDownloads.prefix(3)) { download in
                HStack(spacing: 7) {
                    SiphonSpinner(size: 9, color: SiphonTheme.statusDownloadingText, lineWidth: 1.6)

                    Text(download.displayTitle)
                        .font(.siphonMetadataMedium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Text(download.displayProgress)
                        .font(.siphonMicroMonoMedium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous)
                        .fill(Color.primary.opacity(SiphonTheme.Opacity.fillPill))
                )
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
            }
        }
    }

    // MARK: - Actions & Submission

    private func initiateDownload() {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }

        if case .valid(_, let resolved) = DownloadURLValidator.validate(cleanURL) {
            submitToManager(resolvedURL: resolved)
        } else if cleanURL.contains(".") && !cleanURL.contains(" ") {
            // If user typed without scheme, try prefixing https://
            let candidate = "https://" + cleanURL
            if case .valid(_, let resolved) = DownloadURLValidator.validate(candidate) {
                submitToManager(resolvedURL: resolved)
            }
        }
    }

    private func submitToManager(resolvedURL: String) {
        downloadManager.addDownload(
            url: resolvedURL,
            options: Self.downloadOptions(selectedPreset: selectedPreset, selectedType: selectedType, customPresets: customPresets)
        )
        url = ""
        MenuBarManager.shared.closePopover()
    }

    /// Starts from the same Preferences as the Add sheet and the Home drop target
    /// (save folder, embedding, fallback policy, default arguments), then applies
    /// the chosen preset's format choices on top.
    static func downloadOptions(
        selectedPreset: String,
        selectedType: String,
        customPresets: [CustomPreset],
        userDefaults: UserDefaults = .standard
    ) -> DownloadOptions {
        var options = DownloadOptions.defaultFromPreferences(userDefaults: userDefaults)
        // A deleted custom preset falls back to the standard preset instead of dropping the URL.
        if selectedPreset.hasPrefix("custom_"),
           let preset = customPresets.first(where: { $0.id.uuidString == String(selectedPreset.dropFirst(7)) }) {
            applyFormat(fileType: preset.fileType, resolution: preset.videoResolution, videoCodec: preset.videoCodec, audioCodec: preset.audioCodec, to: &options)
            // Same subtitle rule as the Add sheet: an "embed:" prefix embeds, otherwise a separate file.
            let rawLanguage = preset.subtitleLanguage ?? ""
            let language = rawLanguage.replacingOccurrences(of: "embed:", with: "")
            options.downloadSubtitles = preset.downloadSubtitles ?? false
            options.subtitleLanguages = [language.isEmpty ? "en" : language]
            options.subtitleFormat = preset.subtitleFormat ?? .srt
            options.embedSubtitles = options.downloadSubtitles && rawLanguage.hasPrefix("embed:")
            options.splitChapters = preset.splitChapters ?? false
            options.sponsorBlock = preset.sponsorBlock ?? false
        } else {
            let preset = DownloadPreset(rawValue: selectedPreset) ?? (selectedType == "audio" ? .audioOnly : .bestQuality)
            applyFormat(fileType: preset.fileType, resolution: preset.videoResolution, videoCodec: preset.videoCodec, audioCodec: preset.audioCodec, to: &options)
        }
        return options
    }

    private static func applyFormat(
        fileType: MediaFileType,
        resolution: VideoResolution,
        videoCodec: VideoCodec,
        audioCodec: AudioCodec,
        to options: inout DownloadOptions
    ) {
        options.fileType = fileType
        options.videoResolution = fileType.isVideo ? resolution : nil
        options.audioQuality = fileType.isAudio ? .best : nil
        options.videoCodec = videoCodec
        options.audioCodec = audioCodec
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: SiphonTheme.spacing8) {
            Button {
                MenuBarManager.shared.closePopover()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.className != "NSStatusBarWindow" }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    if let openURL = URL(string: "siphon://show") {
                        NSWorkspace.shared.open(openURL)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(languageService.s("show_main_window"))
                        .font(.siphonMetadataMedium)
                        .lineLimit(1)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundColor(.primary)
                .padding(.horizontal, SiphonTheme.spacing10)
                .frame(height: 28)
                .background(
                    SiphonTheme.pillBackground(isSelected: false)
                )
                .clipShape(Capsule())
                .overlay(
                    SiphonTheme.pillBorder(isSelected: false, showBorders: showBorders)
                )
            }
            .buttonStyle(.bouncy)
            .help(languageService.s("show_main_window"))
            .accessibilityLabel(languageService.s("show_main_window"))

            Spacer(minLength: 0)

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                        .accessibilityHidden(true)
                    Text(languageService.s("quit"))
                        .font(.siphonMetadataSemibold)
                        .lineLimit(1)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundColor(SiphonTheme.statusFailedText)
                .padding(.horizontal, SiphonTheme.spacing10)
                .frame(height: 28)
                .background(SiphonTheme.statusFailed.opacity(SiphonTheme.Opacity.tintBadge))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(SiphonTheme.statusFailed.opacity(SiphonTheme.Opacity.borderCallout), lineWidth: 1)
                )
            }
            .buttonStyle(.bouncy)
            .help(languageService.s("quit"))
            .accessibilityLabel(languageService.s("quit"))
        }
    }
}
