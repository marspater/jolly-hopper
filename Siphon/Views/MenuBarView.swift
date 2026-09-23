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
    @State private var isPasted: Bool = false

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
                }
                .buttonStyle(.plain)
                .help(languageService.s("clear"))
                .accessibilityLabel(languageService.s("clear"))
            }

            Button {
                if let clipboard = NSPasteboard.general.string(forType: .string) {
                    url = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                    isPasted = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        isPasted = false
                    }
                }
            } label: {
                Image(systemName: isPasted ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 12))
                    .foregroundColor(isPasted ? SiphonTheme.statusCompletedText : .secondary)
            }
            .buttonStyle(.plain)
            .help(languageService.s("paste_from_clipboard"))
            .accessibilityLabel(isPasted ? languageService.s("paste") : languageService.s("paste_from_clipboard"))
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
                        .fill(Color.primary.opacity(0.04))
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
            submitToManager(resolvedURL: "https://" + cleanURL)
        }
    }

    private func submitToManager(resolvedURL: String) {
        if selectedPreset.hasPrefix("custom_") {
            let idString = String(selectedPreset.dropFirst(7))
            if let preset = customPresets.first(where: { $0.id.uuidString == idString }) {
                downloadManager.addDownload(url: resolvedURL, options: DownloadOptions(
                    saveFolder: getSaveFolder(),
                    fileType: preset.fileType,
                    videoFormat: nil,
                    audioFormat: nil,
                    videoResolution: preset.videoResolution,
                    audioQuality: .best,
                    downloadSubtitles: preset.downloadSubtitles ?? false,
                    subtitleLanguages: [(preset.subtitleLanguage ?? "en").replacingOccurrences(of: "embed:", with: "")],
                    subtitleFormat: preset.subtitleFormat ?? .srt,
                    embedSubtitles: preset.downloadSubtitles ?? false,
                    downloadThumbnail: false,
                    embedThumbnail: true,
                    embedMetadata: true,
                    splitChapters: preset.splitChapters ?? false,
                    sponsorBlock: preset.sponsorBlock ?? false,
                    timeFrameStart: nil,
                    timeFrameEnd: nil,
                    customFilename: nil,
                    videoCodec: preset.videoCodec,
                    audioCodec: preset.audioCodec,
                    forceOverwrite: false
                ))
            }
        } else if let preset = DownloadPreset(rawValue: selectedPreset) {
            downloadManager.addDownload(url: resolvedURL, options: DownloadOptions(
                saveFolder: getSaveFolder(),
                fileType: preset.fileType,
                videoFormat: nil,
                audioFormat: nil,
                videoResolution: preset.videoResolution,
                audioQuality: .best,
                downloadSubtitles: false,
                subtitleLanguages: ["en"],
                subtitleFormat: .srt,
                embedSubtitles: false,
                downloadThumbnail: false,
                embedThumbnail: true,
                embedMetadata: true,
                splitChapters: false,
                sponsorBlock: UserDefaults.standard.bool(forKey: UserDefaultsKeys.sponsorBlock),
                timeFrameStart: nil,
                timeFrameEnd: nil,
                customFilename: nil,
                videoCodec: preset.videoCodec,
                audioCodec: preset.audioCodec,
                forceOverwrite: false
            ))
        }

        url = ""
        MenuBarManager.shared.closePopover()
    }

    private func getSaveFolder() -> URL {
        let defaultPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultSaveFolder) ?? ""
        return defaultPath.isEmpty ?
            (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")) :
            URL(fileURLWithPath: defaultPath)
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
