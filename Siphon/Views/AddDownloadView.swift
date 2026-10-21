import SwiftUI

struct AddDownloadView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var advancedPanePresented = false
    @State private var advancedPaneOpacity = 0.0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @FocusState private var focusedField: InputField?

    private enum InputField: Hashable {
        case url, batch, filename, arguments, subtitleLanguages
    }

    private func showsFocus(_ field: InputField) -> Bool {
        focusedField == field && appearsActive
    }
    @AppStorage("selectedPreset") private var selectedPreset: String = "best_quality"
    @AppStorage("selectedCustomPresetId") private var selectedCustomPresetIdString: String = ""
    @AppStorage("defaultAdditionalArguments") private var defaultAdditionalArguments: String = ""

    @State private var urlInput: String = ""
    @State private var isLoading: Bool = false
    @State private var mediaInfo: MediaInfo?
    @State private var errorMessage: String?

    @State private var saveFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    @State private var fileType: MediaFileType = .mp4
    @State private var videoResolution: VideoResolution = .best
    @State private var audioQuality: AudioQuality = .best
    @State private var customFilename: String = ""
    @State private var isVideoTab: Bool = true
    @State private var availableCodecs: [CodecOption] = []
    @State private var selectedCodec: String = "auto"
    @State private var selectedConversionCodec: String = "none"
    @State private var selectedAudioCodec: String = "auto"
    @State private var selectedHDRAction: String = HDRAction.preserveHDR.rawValue
    @State private var customPresets: [CustomPreset] = []
    @State private var selectedPresetName: String?
    @State private var presetSubtitleLanguage: String = ""
    @AppStorage(UserDefaultsKeys.resolutionFallbackPolicy) private var resolutionFallbackPolicyRaw: String = ResolutionFallbackPolicy.strictCeiling.rawValue

    @State private var downloadSubtitles: Bool = false
    @StateObject private var pasteFeedback = TransientFeedbackState()
    @State private var selectedSubtitleLangs: Set<String> = []
    @State private var availableSubtitles: [SubtitleOption] = []
    @State private var batchSubtitleLanguages = "en"
    @State private var embedSubtitles: Bool = true
    @State private var subtitleFormat: SubtitleFormat = .srt
    @State private var embedThumbnail: Bool = true
    @State private var embedMetadata: Bool = true
    @State private var splitChapters: Bool = false
    @State private var sponsorBlock: Bool = false

    @State private var showFileExistsAlert: Bool = false
    @State private var isCheckingExistingFile: Bool = false
    @State private var pendingDownloadOptions: DownloadOptions?
    @State private var existingFilePath: String = ""

    @State private var showOptionalSettings: Bool = false
    @State private var additionalArguments: String = ""

    @State private var playlistItems: [MediaInfo] = []
    @State private var selectedPlaylistIds: Set<String> = []
    @State private var isLoadingPlaylist: Bool = false
    @State private var showPlaylistSelector: Bool = false
    @State private var downloadMode: DownloadMode = .single
    @State private var inputMode: InputMode = .single
    @State private var batchUrlsText: String = ""
    @State private var selectedFormatId: String?
    @State private var showStreamInspector: Bool = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var playlistTask: Task<Void, Never>?

    enum InputMode: String, CaseIterable, Identifiable {
        case single
        case batch
        var id: String { rawValue }
    }

    enum DownloadMode {
        case single, playlist
    }

    struct SubtitleOption: Identifiable, Hashable {
        let id: String
        let name: String
        let isAuto: Bool
    }

    struct CodecOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private var availableCodecIDs: Set<String> {
        Set(availableCodecs.lazy.map(\.id))
    }

    private var filteredResolutions: [VideoResolution] {
        if selectedCodec == "h264" {
            return VideoResolution.allCases.filter { res in
                res != .best && res != .r2160p && res != .r1440p
            }
        }
        return VideoResolution.allCases
    }

    /// Fetched cards drop 8 pt into place. `.move(edge: .top)` would slide them
    /// their full height, across the URL card. Reduce Motion keeps only the fade.
    private var revealTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private var showsAdvancedOptions: Bool {
        showOptionalSettings && (inputMode == .batch || mediaInfo != nil)
    }

    private var windowLayout: AddDownloadWindowManager.Layout {
        AddDownloadWindowManager.Layout(
            contentHeight: scrollContentHeight,
            chromeHeight: headerHeight > 0 && footerHeight > 0 ? headerHeight + footerHeight : 0,
            advancedVisible: showsAdvancedOptions,
            allowsShrink: inputMode == .single && mediaInfo == nil
        )
    }

    var body: some View {
        windowContent
            .frame(minWidth: 500, idealWidth: 540,
                   minHeight: AddDownloadWindowManager.compactHeight, maxHeight: .infinity)
            .siphonAdaptiveRendering()
            .siphonWindowBackground()
            .onAppear(perform: initializeForm)
            .onChange(of: downloadSubtitles) { _, enabled in
                if enabled { selectDefaultSubtitleLanguages() }
            }
            .onChange(of: inputMode) { _, _ in
                if downloadSubtitles { selectDefaultSubtitleLanguages() }
            }
            .onChange(of: urlInput) { _, newValue in resetForURL(newValue) }
            .onChange(of: appState.urlToDownload) { _, newURL in acceptExternalURL(newURL) }
            .alert(languageService.s("file_exists_title"), isPresented: $showFileExistsAlert) {
                Button(languageService.s("overwrite"), role: .destructive) {
                    if let options = pendingDownloadOptions {
                        proceedWithDownload(options: options, forceOverwrite: true)
                    }
                }
                Button(languageService.s("add_number"), action: downloadWithUniqueFilename)
                Button(languageService.s("cancel"), role: .cancel) { pendingDownloadOptions = nil }
            } message: {
                Text(languageService.s("file_exists_message"))
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                refreshCustomPresets()
            }
            .onDisappear(perform: tearDownForm)
    }

    private var windowContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                SiphonTheme.subtleDivider
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            formColumns
                // Resize after layout; a geometry callback would reenter NSHostingView.
                .task(id: windowLayout) { updateWindowLayout() }
            VStack(spacing: 0) {
                SiphonTheme.subtleDivider
                footer
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
    }

    private var formColumns: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SiphonTheme.spacing20) {
                    if inputMode == .single {
                        singleInputContent
                    } else {
                        batchSection
                    }
                }
                .padding(SiphonTheme.spacing20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollContentHeight = $0 }
            }
            .frame(minWidth: 500, maxWidth: .infinity)
            if advancedPanePresented {
                Divider()
                advancedPane
            }
        }
    }

    private var singleInputContent: some View {
        Group {
            urlSection
            if let info = mediaInfo {
                VStack(alignment: .leading, spacing: SiphonTheme.spacing20) {
                    if !showPlaylistSelector {
                        mediaInfoSection(info)
                        if info.playlist != nil { playlistDetectedBanner }
                    } else {
                        playlistSelectorSection
                    }
                    formatSection
                    saveSection
                    optionalSettingsSection
                }
                .transition(revealTransition)
            }
            if let error = errorMessage {
                errorSection(error)
                    .transition(revealTransition)
            }
        }
    }

    private var advancedPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiphonTheme.spacing14) {
                Text(languageService.s("advanced_options"))
                    .font(.siphonPrimarySemibold)
                    .accessibilityAddTraits(.isHeader)
                optionalSettingsContent
            }
            .padding(SiphonTheme.spacing16)
            .opacity(advancedPaneOpacity)
            .offset(x: reduceMotion ? 0 : (1 - advancedPaneOpacity) * SiphonTheme.spacing16)
            .onAppear {
                withAnimation(reduceMotion ? nil : SiphonAnimation.panelReveal) {
                    advancedPaneOpacity = 1
                }
            }
        }
        .frame(width: AddDownloadWindowManager.advancedPaneWidth)
    }

    private func updateWindowLayout() {
        if showsAdvancedOptions {
            if advancedPanePresented {
                withAnimation(reduceMotion ? nil : SiphonAnimation.panelReveal) {
                    advancedPaneOpacity = 1
                }
            } else {
                advancedPanePresented = true
            }
        } else {
            withAnimation(reduceMotion ? nil : SiphonAnimation.panelReveal) {
                advancedPaneOpacity = 0
            }
        }
        AddDownloadWindowManager.shared.updateLayout(windowLayout)
        guard !Task.isCancelled else { return }
        if !showsAdvancedOptions { advancedPanePresented = false }
    }

    private func initializeForm() {
        focusedField = .url
        loadPreferencesDefaults()
        batchSubtitleLanguages = presetSubtitleLanguage.isEmpty ? "en" : presetSubtitleLanguage
        let loadedPresets = CustomPreset.loadAll()
        customPresets = loadedPresets
        if !selectedCustomPresetIdString.isEmpty,
           let customPresetID = UUID(uuidString: selectedCustomPresetIdString),
           let customPreset = loadedPresets.first(where: { $0.id == customPresetID }) {
            applyCustomPreset(customPreset)
            selectedPresetName = customPreset.name
        } else {
            selectedPresetName = DownloadPreset(rawValue: selectedPreset)?.title(lang: languageService)
        }
        if !appState.urlToDownload.isEmpty {
            urlInput = appState.urlToDownload
            appState.urlToDownload = ""
        }
        if additionalArguments.isEmpty && !defaultAdditionalArguments.isEmpty {
            additionalArguments = defaultAdditionalArguments
        }
    }

    private func resetForURL(_ newValue: String) {
        fetchTask?.cancel()
        // A playlist load for the previous URL must not land on the new one.
        playlistTask?.cancel()
        isLoadingPlaylist = false
        showPlaylistSelector = false
        downloadMode = .single
        mediaInfo = nil
        customFilename = ""
        selectedFormatId = nil
        availableSubtitles = []
        selectedSubtitleLangs.removeAll()
        availableCodecs = []
        errorMessage = nil
        playlistItems = []
        selectedPlaylistIds.removeAll()
        isLoading = false
        let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.clearBrowserSessionIfOriginChanged(to: clean)
        guard let normalized = DownloadURLValidator.normalizedWebURL(clean) else { return }
        // Every later step reads urlInput; the change handler runs again with the fixed value.
        if normalized != clean {
            urlInput = normalized
            return
        }
        fetchInfo(debounce: true)
    }

    private func acceptExternalURL(_ newURL: String) {
        guard !newURL.isEmpty else { return }
        appState.urlToDownload = ""
        inputMode = .single
        // A changed URL fetches through onChange(of: urlInput); fetching here too
        // would start a request that the reset immediately cancels.
        if urlInput == newURL {
            fetchInfo(debounce: false)
        } else {
            urlInput = newURL
        }
    }

    private func refreshCustomPresets() {
        let newPresets = CustomPreset.loadAll()
        guard newPresets != customPresets else { return }
        customPresets = newPresets
        if let customPresetID = UUID(uuidString: selectedCustomPresetIdString),
           let customPreset = newPresets.first(where: { $0.id == customPresetID }) {
            applyCustomPreset(customPreset)
            selectedPresetName = customPreset.name
        }
    }

    private func tearDownForm() {
        fetchTask?.cancel()
        fetchTask = nil
        playlistTask?.cancel()
        playlistTask = nil
        appState.clearBrowserSession()
        appState.clearExternalTarget()
    }

    private var header: some View {
        HStack {
            Text(languageService.s("new_download"))
                .font(.siphonWindowTitle)

            Spacer()

            SiphonSegmentedPicker(
                selection: $inputMode,
                options: [
                    (.single, languageService.s("single_mode")),
                    (.batch, languageService.s("batch_import"))
                ]
            )
        }
        .padding()
    }

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle.portrait.fill")
                            .font(.siphonStandardSemibold)
                            .foregroundColor(SiphonTheme.accentText)
                            .accessibilityHidden(true)
                        Text(languageService.s("paste_multiple_urls"))
                            .font(.siphonPrimarySemibold)
                    }
                    Spacer()
                    let count = extractBatchUrls(from: batchUrlsText).count
                    if count > 0 {
                        Text(String(format: languageService.s("batch_url_count"), count))
                            .font(.siphonMetadataMonoSemibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SiphonTheme.accent.opacity(SiphonTheme.Opacity.tintBadge))
                            .foregroundColor(SiphonTheme.accentText)
                            .clipShape(Capsule())
                    }
                }

                ZStack(alignment: .topLeading) {
                    if batchUrlsText.isEmpty {
                        Text("https://example.com/video1\nhttps://example.com/video2\n...")
                            .font(.siphonSecondaryMono)
                            .foregroundColor(Color(nsColor: .placeholderTextColor))
                            .padding(.horizontal, SiphonTheme.spacing10)
                            .padding(.vertical, SiphonTheme.spacing10)
                            .allowsHitTesting(false)
                    }
                    BatchURLTextEditor(text: $batchUrlsText, label: languageService.s("paste_multiple_urls")) { focused in
                        focusedField = focused ? .batch : nil
                    }
                        .frame(minHeight: 120, idealHeight: 150, maxHeight: 220)
                        .padding(6)
                }
                .background(SiphonTheme.fieldBackground(cornerRadius: SiphonTheme.radiusControl, isFocused: showsFocus(.batch)))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
                .overlay(
                    SiphonTheme.fieldBorder(cornerRadius: SiphonTheme.radiusControl, isFocused: showsFocus(.batch))
                )

                HStack(spacing: 10) {
                    Button {
                        importBatchFromFile()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.badge.plus")
                                .font(.siphonSecondary)
                                .accessibilityHidden(true)
                            Text(languageService.s("import_file"))
                                .font(.siphonSecondaryMedium)
                        }
                    }
                    .buttonStyle(.siphonSecondary)

                    Button {
                        batchUrlsText = ""
                    } label: {
                        Text(languageService.s("clear"))
                            .font(.siphonSecondaryMedium)
                            .foregroundColor(batchUrlsText.isEmpty ? .secondary : SiphonTheme.statusFailedText)
                    }
                    .buttonStyle(.siphonSecondary)
                    .disabled(batchUrlsText.isEmpty)

                    Spacer()
                }
            }
            .padding(SiphonTheme.spacing14)
            .background(
                SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
            )
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
            .overlay(
                SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
            )

            formatSection
            saveSection
            optionalSettingsSection
        }
    }

    private func streamInspectorSection(_ info: MediaInfo) -> some View {
        Group {
            let formats = info.downloadableFormats
            if !formats.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(SiphonAnimation.snappySpring) {
                            showStreamInspector.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showStreamInspector ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 12)
                                .accessibilityHidden(true)

                            Text(languageService.s("stream_inspector"))
                                .font(.siphonSecondaryMedium)
                                .foregroundColor(.secondary)

                            SiphonTagBadge(text: languageService.s("advanced_badge"), isMonospaced: true)

                            Spacer()

                            if let selected = selectedFormatId {
                                SiphonTagBadge(
                                    text: "\(languageService.s("custom_stream")): \(selected)",
                                    tintColor: SiphonTheme.accentText,
                                    isMonospaced: true
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SiphonTheme.fieldBackground())
                        .overlay(SiphonTheme.fieldBorder())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(languageService.s(showStreamInspector ? "a11y_expanded" : "a11y_collapsed"))

                    if showStreamInspector {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button {
                                    selectedFormatId = nil
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: selectedFormatId == nil ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selectedFormatId == nil ? SiphonTheme.accentText : .secondary)
                                            .accessibilityHidden(true)
                                        Text(languageService.s("auto_recommended"))
                                            .font(.siphonSecondaryMedium)
                                    }
                                    .padding(.horizontal, SiphonTheme.spacing10)
                                    .padding(.vertical, 5)
                                    .background(selectedFormatId == nil ? SiphonTheme.accent.opacity(SiphonTheme.Opacity.tintBadge) : Color.primary.opacity(SiphonTheme.Opacity.fillGhostHover))
                                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(selectedFormatId == nil ? [.isButton, .isSelected] : [.isButton])

                                Spacer()
                            }

                            ScrollView {
                                VStack(spacing: 4) {
                                    let testedFormats = formats.filter { $0.needsTesting != true }
                                    let displayFormats = testedFormats.isEmpty ? formats : testedFormats
                                    ForEach(displayFormats) { fmt in
                                        Button {
                                            selectedFormatId = fmt.formatId
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: selectedFormatId == fmt.formatId ? "checkmark.circle.fill" : "circle")
                                                    .foregroundColor(selectedFormatId == fmt.formatId ? SiphonTheme.accentText : .secondary)
                                                    .accessibilityHidden(true)

                                                SiphonTagBadge(text: fmt.formatId, tintColor: .primary, isMonospaced: true)

                                                Text(fmt.ext.uppercased())
                                                    .font(.siphonMetadataSemibold)
                                                    .foregroundColor(.primary)

                                                Text(fmt.displaySummary)
                                                    .font(.siphonMetadata)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)

                                                Spacer()
                                            }
                                            .padding(.horizontal, SiphonTheme.spacing10)
                                            .padding(.vertical, 6)
                                            .background(selectedFormatId == fmt.formatId ? SiphonTheme.accent.opacity(SiphonTheme.Opacity.tintBadge) : Color.clear)
                                            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityAddTraits(selectedFormatId == fmt.formatId ? [.isButton, .isSelected] : [.isButton])
                                    }
                                }
                            }
                            .frame(maxHeight: 180)
                        }
                        .padding(10)
                        .background(SiphonTheme.fieldBackground())
                        .overlay(SiphonTheme.fieldBorder())
                    }
                }
            }
        }
    }

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.siphonStandardSemibold)
                    .foregroundColor(SiphonTheme.accentText)
                    .accessibilityHidden(true)
                Text(languageService.s("video_url"))
                    .font(.siphonPrimarySemibold)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField(languageService.s("url_hint"), text: $urlInput)
                        .focused($focusedField, equals: .url)
                        .font(.siphonSecondaryMono)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .accessibilityLabel(languageService.s("video_url"))
                        .onSubmit {
                            fetchInfo()
                        }

                    if !urlInput.isEmpty {
                        Button {
                            urlInput = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .help(languageService.s("clear"))
                        .accessibilityLabel(languageService.s("clear"))
                        .transition(.opacity)
                    }
                }
                .animation(SiphonAnimation.snappySpring, value: urlInput.isEmpty)
                .padding(.horizontal, SiphonTheme.spacing10)
                .padding(.vertical, 7)
                .background(SiphonTheme.fieldBackground(cornerRadius: SiphonTheme.radiusControl, isFocused: showsFocus(.url)))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
                .overlay(
                    SiphonTheme.fieldBorder(cornerRadius: SiphonTheme.radiusControl, isFocused: showsFocus(.url))
                )

                Button {
                    if let clipboardString = NSPasteboard.general.string(forType: .string) {
                        urlInput = clipboardString
                        pasteFeedback.show(languageService.s("paste"), isSuccess: true, duration: 1.5)
                    }
                } label: {
                    HStack(spacing: SiphonTheme.spacing4) {
                        Image(systemName: pasteFeedback.isShowing ? "checkmark" : "doc.on.clipboard")
                            .font(.system(size: 12, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                            .accessibilityHidden(true)
                        Text(languageService.s("paste"))
                            .font(.siphonSecondaryMedium)
                    }
                    .foregroundColor(pasteFeedback.isShowing ? SiphonTheme.statusForeground(for: .completed, colorScheme: colorScheme) : .primary)
                }
                .buttonStyle(.siphonSecondary)
                .help(languageService.s("paste_from_clipboard"))

                Button {
                    fetchInfo()
                } label: {
                    // The spinner takes the arrow's slot, so the button keeps
                    // Paste's height and its own width while fetching.
                    HStack(spacing: SiphonTheme.spacing6) {
                        Text(languageService.s("fetch"))
                            .font(.siphonSecondarySemibold)
                        ZStack {
                            if isLoading {
                                SiphonSpinner(size: 11, color: .secondary, lineWidth: 2)
                            } else {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11, weight: .bold))
                            }
                        }
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    }
                    .frame(minWidth: 74, alignment: .center)
                    .fixedSize()
                }
                .buttonStyle(.siphonPrimary)
                .disabled(urlInput.isEmpty || isLoading)
                .help(languageService.s(isLoading ? "fetching" : "fetch_info"))
                .accessibilityValue(isLoading ? languageService.s("fetching") : "")
            }
        }
        .padding(SiphonTheme.spacing14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private func mediaInfoSection(_ info: MediaInfo) -> some View {
        HStack(spacing: 16) {
            ThumbnailImage(url: info.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.primary.opacity(SiphonTheme.Opacity.fillPlaceholder))
                    .overlay { Image(systemName: "photo").font(.largeTitle).foregroundColor(.secondary) }
            }
            .frame(width: 180, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.siphonHeadline)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(info.title)

                if let uploader = info.uploader {
                    Text(uploader)
                        .font(.siphonSecondary)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(uploader)
                }

                HStack(spacing: 12) {
                    if let duration = info.durationString {
                        Label(duration, systemImage: "clock").font(.siphonMetadataMono).foregroundColor(.secondary)
                    }
                    if let views = info.viewCount {
                        Label(formatNumber(views), systemImage: "eye").font(.siphonMetadataMono).foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: SiphonTheme.spacing8)
        }
        .padding()
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private var playlistDetectedBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(languageService.s("playlist_detected")).font(.siphonPrimarySemibold)
                Text(languageService.s("entire_playlist")).font(.siphonSecondary).foregroundColor(.secondary)
            }
            Spacer()
            if isLoadingPlaylist {
                ProgressView().controlSize(.small)
            } else {
                Button(languageService.s("load_playlist")) { loadPlaylist() }.buttonStyle(.siphonSecondary).tint(nil)
            }
        }
        .padding()
        .siphonCallout(tint: SiphonTheme.accent, cornerRadius: SiphonTheme.radiusCard)
    }

    private var playlistSelectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(languageService.s("entire_playlist")).font(.siphonPrimarySemibold)
                Spacer()
                Button(languageService.s("single_video")) {
                    withAnimation(SiphonAnimation.fluidSpring) {
                        showPlaylistSelector = false
                        downloadMode = .single
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(SiphonTheme.accentText)
            }

            HStack(spacing: 12) {
                Button(languageService.s("select_all")) { selectedPlaylistIds = Set(playlistItems.lazy.map(\.id)) }
                    .buttonStyle(.plain).foregroundColor(SiphonTheme.accentForeground(for: colorScheme))
                Button(languageService.s("deselect_all")) { selectedPlaylistIds.removeAll() }
                    .buttonStyle(.plain).foregroundColor(SiphonTheme.accentForeground(for: colorScheme))
                Spacer()
                Text("\(selectedPlaylistIds.count) / \(playlistItems.count)").font(.siphonMetadataMonoSemibold).foregroundColor(.secondary)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(playlistItems, id: \.id) { item in
                        Toggle(isOn: Binding(
                            get: { selectedPlaylistIds.contains(item.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedPlaylistIds.insert(item.id)
                                } else {
                                    selectedPlaylistIds.remove(item.id)
                                }
                            }
                        )) {
                            HStack(spacing: 12) {
                                ThumbnailImage(url: item.thumbnailURL) { image in image.resizable().aspectRatio(contentMode: .fill) }
                                placeholder: { Rectangle().fill(Color.primary.opacity(SiphonTheme.Opacity.fillPlaceholder)) }
                                .frame(width: 50, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
                                .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: SiphonTheme.spacing2) {
                                    Text(item.title)
                                        .font(.siphonStandardMedium)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(item.title)
                                    if let duration = item.durationString {
                                        Text(duration)
                                            .font(.siphonMetadata)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(8)
                        .background(
                            SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
                        .overlay(
                            SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusControl)
                        )
                    }
                }
            }
            .frame(height: 250)
        }
        .padding()
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.siphonStandardSemibold)
                        .foregroundColor(SiphonTheme.accentText)
                        .accessibilityHidden(true)
                    Text(languageService.s("format_and_quality"))
                        .font(.siphonPrimarySemibold)
                }

                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))],
                      alignment: .leading, spacing: SiphonTheme.spacing12) {
                // Quick Presets dropdown menu button
                Menu {
                    Section(siphonHeader: languageService.s("download_presets")) {
                        ForEach(DownloadPreset.allCases) { preset in
                            Button {
                                selectedPreset = preset.rawValue
                                selectedCustomPresetIdString = ""
                                applyPreset(preset)
                                selectedPresetName = preset.title(lang: languageService)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(preset.title(lang: languageService))
                                        Text(preset.description(lang: languageService))
                                            .font(.siphonMetadata)
                                            .foregroundColor(.secondary)
                                    }
                                    if selectedPreset == preset.rawValue {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    if !customPresets.isEmpty {
                        Divider()
                        Section(siphonHeader: languageService.s("custom_presets")) {
                            ForEach(customPresets) { preset in
                                Button {
                                    selectedPreset = ""
                                    selectedCustomPresetIdString = preset.id.uuidString
                                    applyCustomPreset(preset)
                                    selectedPresetName = preset.name
                                } label: {
                                    HStack {
                                        Text(preset.name)
                                        if selectedCustomPresetIdString == preset.id.uuidString {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.siphonMetadata)
                            .foregroundColor(SiphonTheme.statusForeground(for: .queued, colorScheme: colorScheme))
                            .accessibilityHidden(true)
                        if let presetName = selectedPresetName {
                            Text("\(languageService.s("quick_presets")): \(presetName)")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text(languageService.s("quick_presets"))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.siphonMicroSemibold)
                            .accessibilityHidden(true)
                    }
                    .font(.siphonMetadataSemibold)
                    .foregroundColor(.primary)
                    .padding(.horizontal, SiphonTheme.spacing10)
                    .padding(.vertical, 4)
                    .background(SiphonTheme.pillBackground(isSelected: false))
                    .clipShape(Capsule())
                    .overlay(SiphonTheme.pillBorder(isSelected: false))
                }
                .siphonMenuStyle()
                .frame(maxWidth: .infinity, alignment: .leading)

                // Video / Audio Capsule Switcher
                SiphonSegmentedPicker(
                    selection: Binding(
                        get: { isVideoTab },
                        set: { isVideo in
                            isVideoTab = isVideo
                            fileType = isVideo ? .mp4 : .mp3
                        }
                    ),
                    options: [
                        (true, languageService.s("video")),
                        (false, languageService.s("audio"))
                    ],
                    fillsWidth: true
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(languageService.s("file_type"))
                        .font(.siphonMetadataMedium)
                        .foregroundColor(.secondary)
                    SiphonMenuPicker(
                        selection: $fileType,
                        fillsWidth: true,
                        options: (isVideoTab ? MediaFileType.videoTypes : MediaFileType.audioTypes)
                            .map { type in (value: type, title: type.rawValue) }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(languageService.s("file_type"))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(isVideoTab ? languageService.s("quality") : languageService.s("audio_quality"))
                        .font(.siphonMetadataMedium)
                        .foregroundColor(.secondary)
                    if isVideoTab {
                        SiphonMenuPicker(
                            selection: $videoResolution,
                            fillsWidth: true,
                            options: filteredResolutions.map { res in (value: res, title: res.title(lang: languageService)) }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(languageService.s("quality"))
                        .onChange(of: selectedCodec) { _, newCodec in
                            if newCodec == "h264" && (videoResolution == .r1440p || videoResolution == .r2160p || videoResolution == .best) {
                                videoResolution = .r1080p
                            }
                        }
                    } else {
                        SiphonMenuPicker(
                            selection: $audioQuality,
                            fillsWidth: true,
                            options: AudioQuality.allCases.map { quality in (value: quality, title: quality.title(lang: languageService)) }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(languageService.s("audio_quality"))
                    }
                }
            }

            // Info notices
            if isVideoTab && selectedCodec == "h264" {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(SiphonTheme.accentText)
                        .font(.siphonMetadata)
                    Text(languageService.s("h264_preset_info"))
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, SiphonTheme.spacing10)
                .padding(.vertical, 6)
                .siphonCallout(tint: SiphonTheme.accent)
            }
        }
        .padding(SiphonTheme.spacing14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private func videoCodecLabel(for codec: VideoCodec) -> String {
        let title = codec.title(lang: languageService)
        guard codec != .auto, !availableCodecs.isEmpty else { return title }
        return availableCodecIDs.contains(codec.rawValue) ? "\(title) • Detected" : "\(title) • Fallback if unavailable"
    }

    private func applyPreset(_ preset: DownloadPreset) {
        selectedCodec = preset.videoCodec.rawValue
        selectedAudioCodec = preset.audioCodec.rawValue
        videoResolution = preset.videoResolution
        fileType = preset.fileType
        isVideoTab = preset.fileType.isVideo

        downloadSubtitles = false
        embedSubtitles = false
        selectedSubtitleLangs.removeAll()
        presetSubtitleLanguage = ""
        // A custom preset applied earlier may have changed these.
        splitChapters = false
        sponsorBlock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.sponsorBlock)
    }

    private func applyCustomPreset(_ preset: CustomPreset) {
        selectedCodec = preset.videoCodec.rawValue
        selectedAudioCodec = preset.audioCodec.rawValue
        videoResolution = preset.videoResolution
        fileType = preset.fileType
        isVideoTab = preset.fileType.isVideo
        downloadSubtitles = preset.downloadSubtitles ?? false

        let rawLang = preset.subtitleLanguage ?? ""
        if rawLang.hasPrefix("embed:") {
            embedSubtitles = true
            presetSubtitleLanguage = rawLang.replacingOccurrences(of: "embed:", with: "")
        } else {
            embedSubtitles = false
            presetSubtitleLanguage = rawLang
        }

        subtitleFormat = preset.subtitleFormat ?? .srt
        sponsorBlock = preset.sponsorBlock ?? false
        splitChapters = preset.splitChapters ?? false

        selectedSubtitleLangs.removeAll()
        batchSubtitleLanguages = presetSubtitleLanguage.isEmpty ? "en" : presetSubtitleLanguage
        if downloadSubtitles { selectDefaultSubtitleLanguages() }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.siphonStandardSemibold)
                    .foregroundColor(SiphonTheme.accentText)
                    .accessibilityHidden(true)
                Text(languageService.s("save_folder"))
                    .font(.siphonPrimarySemibold)
            }

            // Save Folder Row
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.siphonSecondary)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text(saveFolder.path)
                        .font(.siphonMetadataMonoMedium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(saveFolder.path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .padding(.horizontal, SiphonTheme.spacing10)
                .padding(.vertical, 6)
                // As tall as the Choose Folder button beside it.
                .frame(maxHeight: .infinity)
                .background(SiphonTheme.fieldBackground(cornerRadius: SiphonTheme.radiusControl))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
                .overlay(
                    SiphonTheme.fieldBorder(cornerRadius: SiphonTheme.radiusControl)
                )

                Button {
                    selectFolder()
                } label: {
                    Text(languageService.s("choose_folder"))
                        .font(.siphonSecondaryMedium)
                }
                .buttonStyle(.siphonSecondary)
                .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SiphonTheme.spacing14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private var optionalSettingsSection: some View {
        Button {
            showOptionalSettings.toggle()
        } label: {
            HStack(spacing: SiphonTheme.spacing8) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(showOptionalSettings ? 180 : 0))
                    .animation(SiphonAnimation.snappySpring, value: showOptionalSettings)
                    .font(.siphonMetadataSemibold)
                    .foregroundColor(SiphonTheme.accentText)
                    .frame(width: 12)
                    .accessibilityHidden(true)

                Text(languageService.s("advanced_options"))
                    .font(.siphonStandardSemibold)
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.horizontal, SiphonTheme.spacing14)
            .padding(.vertical, SiphonTheme.spacing10)
            .background(
                SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl)
            )
            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
            .overlay(
                SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(languageService.s(showOptionalSettings ? "a11y_expanded" : "a11y_collapsed"))
    }

    private var optionalSettingsContent: some View {
        VStack(alignment: .leading, spacing: SiphonTheme.spacing14) {
            // Custom filename
            VStack(alignment: .leading, spacing: SiphonTheme.spacing6) {
                Text(languageService.s("custom_filename"))
                    .font(.siphonSecondarySemibold)
                    .foregroundColor(.secondary)

                HStack(spacing: SiphonTheme.spacing8) {
                    Image(systemName: "pencil")
                        .font(.siphonSecondary)
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)

                    TextField(languageService.s("custom_filename_hint"), text: $customFilename)
                        .focused($focusedField, equals: .filename)
                        .font(.siphonSecondary)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                }
                .padding(.horizontal, SiphonTheme.spacing10)
                .padding(.vertical, SiphonTheme.spacing6)
                .background(
                    SiphonTheme.fieldBackground(
                        cornerRadius: SiphonTheme.radiusControl,
                        isFocused: showsFocus(.filename)
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
                .overlay(
                    SiphonTheme.fieldBorder(
                        cornerRadius: SiphonTheme.radiusControl,
                        isFocused: showsFocus(.filename)
                    )
                )
            }

            if isVideoTab {
                SiphonTheme.subtleDivider

                VStack(alignment: .leading, spacing: SiphonTheme.spacing8) {
                    Toggle(languageService.s("download_subtitles"), isOn: $downloadSubtitles.animation(SiphonAnimation.fluidSpring))
                        .disabled(inputMode == .single && availableSubtitles.isEmpty)

                    if inputMode == .batch && downloadSubtitles {
                        TextField(languageService.s("subtitle_language_codes"), text: $batchSubtitleLanguages)
                            .focused($focusedField, equals: .subtitleLanguages)
                            .siphonField(isFocused: focusedField == .subtitleLanguages)
                            .accessibilityLabel(languageService.s("subtitle_language_codes"))
                        SiphonMenuPicker(
                            languageService.s("subtitle_format"), selection: $subtitleFormat,
                            options: SubtitleFormat.allCases.map { format in (value: format, title: format.displayName) }
                        )
                        Toggle(languageService.s("embed_video"), isOn: $embedSubtitles)
                    } else if inputMode == .single && availableSubtitles.isEmpty && mediaInfo != nil {
                        Text(languageService.s("no_subtitles"))
                            .font(.siphonMetadata)
                            .foregroundColor(.secondary)
                    } else if inputMode == .single && downloadSubtitles {
                        HStack(spacing: SiphonTheme.spacing12) {
                            Menu {
                                let (manualSubs, autoSubs): ([SubtitleOption], [SubtitleOption]) = availableSubtitles.reduce(into: ([], [])) { result, sub in
                                    if sub.isAuto {
                                        result.1.append(sub)
                                    } else {
                                        result.0.append(sub)
                                    }
                                }
                                let sortedManualSubs = manualSubs.sorted(by: { $0.name < $1.name })
                                let sortedAutoSubs = autoSubs.sorted(by: { $0.name < $1.name })

                                if !sortedManualSubs.isEmpty {
                                    Section(siphonHeader: languageService.s("internal")) {
                                        ForEach(sortedManualSubs) { sub in
                                            Button {
                                                toggleSubtitle(sub.id)
                                            } label: {
                                                HStack {
                                                    if selectedSubtitleLangs.contains(sub.id) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                    Text(sub.name)
                                                }
                                            }
                                        }
                                    }
                                }

                                if !sortedAutoSubs.isEmpty {
                                    Section(siphonHeader: languageService.s("auto_subs")) {
                                        ForEach(sortedAutoSubs) { sub in
                                            Button {
                                                toggleSubtitle(sub.id)
                                            } label: {
                                                HStack {
                                                    if selectedSubtitleLangs.contains(sub.id) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                    Text(String(format: languageService.s("subtitle_auto_format"), sub.name))
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                SiphonMenuLabel {
                                    Text(languageService.s("languages"))
                                    Spacer()
                                    if selectedSubtitleLangs.isEmpty {
                                        Text(languageService.s("select"))
                                    } else {
                                        Text(String(
                                            format: languageService.s("subtitles_selected"),
                                            selectedSubtitleLangs.count
                                        ))
                                    }
                                }
                            }
                            .siphonMenuStyle()

                            SiphonMenuPicker(
                                languageService.s("subtitle_format"), selection: $subtitleFormat,
                                options: SubtitleFormat.allCases.map { format in (value: format, title: format.displayName) }
                            )
                        }

                        Toggle(languageService.s("embed_video"), isOn: $embedSubtitles)
                    }
                }
            }

            SiphonTheme.subtleDivider

            LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))],
                      alignment: .leading, spacing: SiphonTheme.spacing12) {
                Toggle(languageService.s("embed_thumbnail"), isOn: $embedThumbnail)
                Toggle(languageService.s("embed_metadata_short"), isOn: $embedMetadata)
                    .help(languageService.s("metadata_desc"))
                Toggle(languageService.s("split_chapters"), isOn: $splitChapters)
                Toggle(languageService.s("sponsorblock"), isOn: $sponsorBlock)
                    .help(languageService.s("sponsorblock_hint"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SiphonTheme.subtleDivider

            advancedOptionsContent(inputMode == .single ? mediaInfo : nil)
        }
        .padding(SiphonTheme.spacing16)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusCard, style: .continuous))
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    @ViewBuilder
    private func advancedOptionsContent(_ info: MediaInfo?) -> some View {
        VStack(alignment: .leading, spacing: SiphonTheme.spacing14) {
            if let info = info {
                streamInspectorSection(info)
                SiphonTheme.subtleDivider
            }

            if isVideoTab {
                VStack(alignment: .leading, spacing: SiphonTheme.spacing10) {
                    Text(languageService.s("codec_settings"))
                        .font(.siphonSecondarySemibold)
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))],
                              alignment: .leading, spacing: SiphonTheme.spacing14) {
                        advancedPicker(
                            title: languageService.s("video_codec"),
                            selection: $selectedCodec,
                            options: VideoCodec.allCases.map { codec in (value: codec.rawValue, title: videoCodecLabel(for: codec)) }
                        )

                        advancedPicker(
                            title: languageService.s("audio_codec"),
                            selection: $selectedAudioCodec,
                            options: AudioCodec.allCases.map { codec in (value: codec.rawValue, title: codec.title(lang: languageService)) }
                        )
                    }

                    advancedPicker(
                        title: languageService.s("post_processing"),
                        selection: $selectedConversionCodec,
                        options: ConversionCodec.allCases.map { codec in (value: codec.rawValue, title: codec.title(lang: languageService)) },
                        horizontal: true
                    )

                    advancedPicker(
                        title: languageService.s("hdr_dynamic_range"),
                        selection: $selectedHDRAction,
                        options: HDRAction.allCases.map { action in (value: action.rawValue, title: action.title(lang: languageService)) },
                        horizontal: true
                    )
                }

                SiphonTheme.subtleDivider
            }

            VStack(alignment: .leading, spacing: SiphonTheme.spacing6) {
                Text(languageService.s("additional_arguments"))
                    .font(.siphonSecondarySemibold)
                    .foregroundColor(.secondary)

                HStack(spacing: SiphonTheme.spacing8) {
                    Image(systemName: "terminal")
                        .font(.siphonSecondary)
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)

                    TextField(languageService.s("additional_arguments_hint"), text: $additionalArguments)
                        .focused($focusedField, equals: .arguments)
                        .font(.siphonMetadataMono)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                }
                .padding(.horizontal, SiphonTheme.spacing10)
                .padding(.vertical, SiphonTheme.spacing6)
                .background(
                    SiphonTheme.fieldBackground(
                        cornerRadius: SiphonTheme.radiusControl,
                        isFocused: showsFocus(.arguments)
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
                .overlay(
                    SiphonTheme.fieldBorder(
                        cornerRadius: SiphonTheme.radiusControl,
                        isFocused: showsFocus(.arguments)
                    )
                )
            }

        }
    }

    @ViewBuilder
    private func advancedPicker<Selection: Hashable>(
        title: String,
        selection: Binding<Selection>,
        options: [(value: Selection, title: String)],
        horizontal: Bool = false
    ) -> some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: SiphonTheme.spacing12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: SiphonTheme.spacing6))
        layout {
            Text(title)
                .font(.siphonMetadataMedium)
                .foregroundColor(.secondary)
                .frame(width: horizontal ? 120 : nil, alignment: .leading)

            SiphonMenuPicker(selection: selection, fillsWidth: true, options: options)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(title)
        }
    }

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(SiphonTheme.statusForeground(for: .failed, colorScheme: colorScheme))
                    .font(.siphonStandard)
                Text(error)
                    .font(.siphonSecondaryMedium)
                    .foregroundColor(SiphonTheme.statusForeground(for: .failed, colorScheme: colorScheme))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let isFDAError = error.contains("Full Disk Access") || error.contains("Privacy & Security")
            let isAuthOrCookieError = error.contains("Settings") || error.contains("Browser Cookies") || error.contains("cookies") || error.contains("sign in") || error.contains("login")
            if isFDAError || isAuthOrCookieError {
                HStack(spacing: 8) {
                    Spacer()
                    if isFDAError {
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text(languageService.s("open_system_settings"))
                                .font(.siphonMetadataSemibold)
                        }
                        .buttonStyle(.siphonPrimary)
                        .controlSize(.small)

                        Button {
                            PreferencesWindowManager.shared.showPreferencesWindow(
                                languageService: languageService,
                                updateChecker: updateChecker,
                                downloadManager: downloadManager,
                                appState: appState,
                                initialTab: .advanced
                            )
                        } label: {
                            Text(languageService.s("settings"))
                                .font(.siphonMetadataSemibold)
                        }
                        .buttonStyle(.siphonSecondary)
                        .controlSize(.small)
                        .tint(nil)
                    } else {
                        Button {
                            PreferencesWindowManager.shared.showPreferencesWindow(
                                languageService: languageService,
                                updateChecker: updateChecker,
                                downloadManager: downloadManager,
                                appState: appState,
                                initialTab: .advanced
                            )
                        } label: {
                            Text(languageService.s("settings"))
                                .font(.siphonMetadataSemibold)
                        }
                        .buttonStyle(.siphonPrimary)
                        .controlSize(.small)
                    }
                }

                if isFDAError {
                    Text(languageService.s("safari_fda_restart_hint"))
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .siphonCallout(tint: SiphonTheme.statusFailed)
    }

    private var footer: some View {
        HStack(spacing: SiphonTheme.spacing12) {
            Spacer()

            Button {
                AddDownloadWindowManager.shared.closeWindow()
                dismiss()
            } label: {
                Text(languageService.s("cancel"))
            }
            .buttonStyle(.siphonSecondary)
            .keyboardShortcut(.escape)

            if inputMode == .batch {
                let count = extractBatchUrls(from: batchUrlsText).count

                Button {
                    startDownload()
                } label: {
                    Text(String(format: languageService.s("queue_batch"), count))
                }
                .buttonStyle(.siphonPrimary)
                .disabled(count == 0)
                .keyboardShortcut(.return)
            } else {
                let downloadTitle = downloadMode == .playlist
                    ? String(format: languageService.s("download_selected"), selectedPlaylistIds.count)
                    : languageService.s("download_btn")
                let isDisabled = mediaInfo == nil || (downloadMode == .playlist && selectedPlaylistIds.isEmpty)

                Button {
                    startDownload()
                } label: {
                    HStack(spacing: SiphonTheme.spacing6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(downloadTitle)
                    }
                }
                .buttonStyle(.siphonPrimary)
                .disabled(isDisabled)
                .keyboardShortcut(.return)
            }
        }
        .padding()
    }

    private func fetchInfo(debounce: Bool = false) {
        let cleanURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        fetchTask?.cancel()
        isLoading = true
        errorMessage = nil
        mediaInfo = nil
        selectedFormatId = nil
        fetchTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            do {
                let session = appState.browserSession(for: cleanURL)
                let info = try await downloadManager.ytdlpService.fetchInfo(
                    url: cleanURL,
                    rawCookies: session?.rawCookies,
                    rawUserAgent: session?.rawUserAgent,
                    browserCookieSource: session?.browserCookieSource,
                    proxy: try await previewProxy()
                )
                guard !Task.isCancelled else { return }
                withAnimation(SiphonAnimation.fluidSpring) {
                    mediaInfo = info
                }
                customFilename = info.title

                var subs: [SubtitleOption] = []
                var foundLangs: Set<String> = []

                if let manual = info.subtitles {
                    for key in manual.keys where !foundLangs.contains(key) {
                        let name = manual[key]?.first?.name ?? key
                        subs.append(SubtitleOption(id: key, name: name, isAuto: false))
                        foundLangs.insert(key)
                    }
                }

                if let auto = info.automaticCaptions {
                    for key in auto.keys where !foundLangs.contains(key) {
                        let name = auto[key]?.first?.name ?? key
                        subs.append(SubtitleOption(id: key, name: name, isAuto: true))
                        foundLangs.insert(key)
                    }
                }

                availableSubtitles = subs
                selectedSubtitleLangs.removeAll()

                // Extract Codecs
                var codecs: Set<String> = []
                var codecOptions: [CodecOption] = []

                if let formats = info.formats {
                    for format in formats where format.isDownloadable {
                        if let vcodec = format.vcodec, vcodec != "none" {
                            if vcodec.hasPrefix("avc1"), !codecs.contains("h264") {
                                codecs.insert("h264")
                                codecOptions.append(CodecOption(id: "h264", name: "H.264"))
                            } else if vcodec.hasPrefix("vp9"), !codecs.contains("vp9") {
                                codecs.insert("vp9")
                                codecOptions.append(CodecOption(id: "vp9", name: "VP9"))
                            } else if vcodec.hasPrefix("av01"), !codecs.contains("av1") {
                                codecs.insert("av1")
                                codecOptions.append(CodecOption(id: "av1", name: "AV1"))
                            } else if vcodec.hasPrefix("hev1") || vcodec.hasPrefix("hvc1"), !codecs.contains("h265") {
                                codecs.insert("h265")
                                codecOptions.append(CodecOption(id: "h265", name: "H.265 (HEVC)"))
                            }
                        }
                    }
                }
                availableCodecs = codecOptions.sorted(by: { $0.name < $1.name })
                // Don't reset selectedCodec here - preserve preset selection
                availableSubtitles = subs

                if downloadSubtitles { selectDefaultSubtitleLanguages() }

            } catch {
                if !Task.isCancelled {
                    withAnimation(SiphonAnimation.fluidSpring) {
                        errorMessage = formatErrorMessage(error)
                    }
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    /// Deep-link targets are probed through the egress proxy too: the preview
    /// runs before the user confirms, and its info JSON is reused for the download.
    private func previewProxy() async throws -> String? {
        guard appState.hasExternalTarget else { return nil }
        return try await downloadManager.ytdlpService.egressProxyURL()
    }

    private func loadPlaylist() {
        playlistTask?.cancel()
        isLoadingPlaylist = true
        errorMessage = nil
        playlistTask = Task {
            do {
                let session = appState.browserSession(for: urlInput)
                let items = try await downloadManager.ytdlpService.fetchPlaylistInfo(
                    url: urlInput,
                    rawCookies: session?.rawCookies,
                    rawUserAgent: session?.rawUserAgent,
                    browserCookieSource: session?.browserCookieSource,
                    proxy: try await previewProxy()
                )
                guard !Task.isCancelled else { return }
                playlistItems = items
                selectedPlaylistIds = Set(items.lazy.map(\.id))
                withAnimation(SiphonAnimation.fluidSpring) {
                    showPlaylistSelector = true
                    downloadMode = .playlist
                }
            } catch {
                if !Task.isCancelled {
                    withAnimation(SiphonAnimation.fluidSpring) {
                        errorMessage = formatErrorMessage(error)
                    }
                }
            }
            if !Task.isCancelled {
                isLoadingPlaylist = false
            }
        }
    }

    /// Same wording as the download row, so one failure reads the same in both places.
    private func formatErrorMessage(_ error: Error) -> String {
        DownloadExecutor.errorMessage(for: error, languageService: languageService)
    }

    private func startDownload() {
        let videoCodecEnum = isVideoTab ? VideoCodec(rawValue: selectedCodec) : nil
        let conversionCodecEnum = isVideoTab ? ConversionCodec(rawValue: selectedConversionCodec) : nil
        let audioCodecEnum: AudioCodec? = {
            if selectedAudioCodec == "auto" {
                return nil
            }
            return AudioCodec(rawValue: selectedAudioCodec)
        }()

        let options = DownloadOptions(
            saveFolder: saveFolder,
            fileType: fileType,
            videoResolution: isVideoTab ? videoResolution : nil,
            audioQuality: isVideoTab ? nil : audioQuality,
            downloadSubtitles: isVideoTab ? downloadSubtitles : false,
            subtitleLanguages: inputMode == .batch
                ? Self.batchSubtitleCodes(batchSubtitleLanguages)
                : Self.resolvedSubtitleLanguages(selected: selectedSubtitleLangs, preferred: presetSubtitleLanguage, available: availableSubtitles),
            subtitleFormat: subtitleFormat,
            embedSubtitles: isVideoTab ? embedSubtitles : false,
            downloadThumbnail: false,
            embedThumbnail: embedThumbnail,
            embedMetadata: embedMetadata,
            splitChapters: splitChapters,
            sponsorBlock: sponsorBlock,
            customFilename: customFilename.isEmpty ? nil : customFilename,
            videoCodec: videoCodecEnum,
            audioCodec: audioCodecEnum,
            conversionCodec: conversionCodecEnum,
            forceOverwrite: false,
            rawCookies: nil,
            rawUserAgent: nil,
            browserCookieSource: nil,
            selectedFormatId: (inputMode == .single && downloadMode == .single) ? selectedFormatId : nil,
            hdrAction: isVideoTab ? (HDRAction(rawValue: selectedHDRAction) ?? .preserveHDR) : nil,
            resolutionFallbackPolicy: isVideoTab ? (ResolutionFallbackPolicy(rawValue: resolutionFallbackPolicyRaw) ?? .strictCeiling) : nil,
            additionalArguments: additionalArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : additionalArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if inputMode == .batch {
            let urls = extractBatchUrls(from: batchUrlsText)
            guard !urls.isEmpty else { return }
            proceedWithBatchDownload(urls: urls, options: options)
            return
        }

        if downloadMode == .single {
            let filename = customFilename.isEmpty ? (mediaInfo?.title ?? "") : customFilename
            if !filename.isEmpty {
                let safeName = YtdlpService.sanitizeFilename(filename)
                let potentialPath = saveFolder.appendingPathComponent("\(safeName).\(YtdlpService.resolvedOutputFileExtension(for: options))")
                let pathString = potentialPath.path

                let folder = saveFolder
                // The check is async; a second click meanwhile would queue the job twice.
                guard !isCheckingExistingFile else { return }
                isCheckingExistingFile = true
                Task {
                    defer { isCheckingExistingFile = false }
                    let fileExists = await Task.detached { [folder, options] in
                        DownloadQueue.mediaFileCollides(
                            baseName: safeName,
                            options: options,
                            existingMediaFileKeys: DownloadQueue.existingMediaFileKeys(in: folder)
                        )
                    }.value

                    if fileExists {
                        existingFilePath = pathString
                        pendingDownloadOptions = options
                        showFileExistsAlert = true
                    } else {
                        proceedWithDownload(options: options, forceOverwrite: false)
                    }
                }
                return
            }
        }

        proceedWithDownload(options: options, forceOverwrite: false)
    }

    // Bolt Performance Optimization: Pre-allocated CharacterSet to prevent allocation overhead during keystrokes
    private static let batchUrlStripSet = CharacterSet(charactersIn: "\"',;:()[]{}<>").union(.whitespacesAndNewlines)

    private func extractBatchUrls(from text: String) -> [String] {
        // Bolt Performance Optimization: Use split(whereSeparator:) with Substring to eliminate intermediate String array allocations
        let tokens = text.split(whereSeparator: \.isWhitespace)
        var valid: [String] = []
        var seen = Set<String>()
        for token in tokens {
            let line = String(token)
            let trimmed = line.trimmingCharacters(in: Self.batchUrlStripSet)
            if let url = DownloadURLValidator.normalizedWebURL(trimmed), seen.insert(url).inserted {
                valid.append(url)
            }
        }
        return valid
    }

    private func importBatchFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, .text, .item]

        if panel.runModal() == .OK, let selectedURL = panel.url {
            Task {
                if let content = await Task.detached(priority: .userInitiated, operation: {
                    try? String(contentsOf: selectedURL, encoding: .utf8)
                }).value {
                    let existing = batchUrlsText.isEmpty ? "" : batchUrlsText + "\n"
                    batchUrlsText = existing + content
                }
            }
        }
    }

    private func proceedWithBatchDownload(urls: [String], options: DownloadOptions) {
        var finalOptions = options
        if appState.hasExternalTarget {
            finalOptions.enforcePublicNetworkBoundary = true
        }
        if let session = appState.consumeBrowserSession(for: urls) {
            finalOptions.rawCookies = session.rawCookies
            finalOptions.rawUserAgent = session.rawUserAgent
            finalOptions.browserCookieSource = session.browserCookieSource
        }
        finalOptions.customFilename = nil
        downloadManager.addDownloads(urls: urls, options: finalOptions)
        appState.selectedNavItem = .downloading
        AddDownloadWindowManager.shared.closeWindow()
        dismiss()
    }

    private func proceedWithDownload(options: DownloadOptions, forceOverwrite: Bool) {
        var finalOptions = options
        finalOptions.forceOverwrite = forceOverwrite

        let cleanURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExternal = appState.hasExternalTarget
        if isExternal {
            finalOptions.enforcePublicNetworkBoundary = true
        }
        if downloadMode == .single {
            if let session = appState.consumeBrowserSession(for: cleanURL) {
                finalOptions.rawCookies = session.rawCookies
                finalOptions.rawUserAgent = session.rawUserAgent
                finalOptions.browserCookieSource = session.browserCookieSource
            }
            downloadManager.addDownload(url: cleanURL, options: finalOptions, mediaInfo: mediaInfo)
        } else {
            let selectedItems = playlistItems.filter { selectedPlaylistIds.contains($0.id) }
            let urls = selectedItems.map { $0.resolvedURL }
            if let session = appState.consumeBrowserSession(forPlaylistURL: cleanURL, itemURLs: urls) {
                finalOptions.rawCookies = session.rawCookies
                finalOptions.rawUserAgent = session.rawUserAgent
                finalOptions.browserCookieSource = session.browserCookieSource
            }
            var itemOptions = finalOptions
            itemOptions.customFilename = nil
            itemOptions.selectedFormatId = nil
            downloadManager.addDownloads(urls: urls, options: itemOptions)
        }
        appState.selectedNavItem = .downloading
        AddDownloadWindowManager.shared.closeWindow()
        dismiss()
    }

    private func downloadWithUniqueFilename() {
        guard let options = pendingDownloadOptions else { return }

        let originalFilename = customFilename.isEmpty ? (mediaInfo?.title ?? "video") : customFilename
        var tempOptions = options
        tempOptions.customFilename = originalFilename
        let cleanURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let dummyDl = Download(
            url: cleanURL,
            options: tempOptions,
            title: originalFilename
        )
        let (uniqueFilename, _) = downloadManager.planUniqueOutputPath(for: dummyDl)

        var finalOptions = options
        finalOptions.customFilename = uniqueFilename
        proceedWithDownload(options: finalOptions, forceOverwrite: false)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = languageService.s("save")
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }

    static func resolvedSubtitleLanguages(selected: Set<String>, preferred: String, available: [SubtitleOption]) -> [String] {
        let validSelection = available.isEmpty ? selected : selected.intersection(available.map(\.id))
        if !validSelection.isEmpty { return validSelection.sorted() }
        if !preferred.isEmpty, available.isEmpty || available.contains(where: { $0.id == preferred }) { return [preferred] }
        if available.contains(where: { $0.id == "en" }) { return ["en"] }
        return [available.map(\.id).sorted().first ?? "en"]
    }

    static func batchSubtitleCodes(_ text: String) -> [String] {
        let codes = text.split { $0 == "," || $0.isWhitespace }.map(String.init).filter(YtdlpService.isSafeSubtitleLanguage)
        return codes.isEmpty ? ["en"] : Array(Set(codes)).sorted()
    }

    private func selectDefaultSubtitleLanguages() {
        selectedSubtitleLangs = Set(Self.resolvedSubtitleLanguages(selected: selectedSubtitleLangs,
            preferred: presetSubtitleLanguage, available: availableSubtitles))
    }

    private func toggleSubtitle(_ id: String) {
        if selectedSubtitleLangs.contains(id) {
            selectedSubtitleLangs.remove(id)
        } else {
            selectedSubtitleLangs.insert(id)
        }
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private func formatNumber(_ number: Int) -> String {
        let formatter = Self.countFormatter
        if number >= 1_000_000_000 {
            return "\(formatter.string(from: NSNumber(value: Double(number) / 1_000_000_000)) ?? "")B"
        } else if number >= 1_000_000 {
            return "\(formatter.string(from: NSNumber(value: Double(number) / 1_000_000)) ?? "")M"
        } else if number >= 1_000 {
            return "\(formatter.string(from: NSNumber(value: Double(number) / 1_000)) ?? "")K"
        }
        return "\(number)"
    }

    private func loadPreferencesDefaults() {
        let defaults = UserDefaults.standard
        let defaultPath = defaults.string(forKey: UserDefaultsKeys.defaultSaveFolder) ?? ""
        if !defaultPath.isEmpty && FileManager.default.fileExists(atPath: defaultPath) {
            saveFolder = URL(fileURLWithPath: defaultPath)
        }

        // Custom presets do not define these; the preset (applied later) may override sponsorBlock.
        if defaults.object(forKey: UserDefaultsKeys.embedThumbnail) != nil {
            embedThumbnail = defaults.bool(forKey: UserDefaultsKeys.embedThumbnail)
        }
        if defaults.object(forKey: UserDefaultsKeys.embedMetadata) != nil {
            embedMetadata = defaults.bool(forKey: UserDefaultsKeys.embedMetadata)
        }
        if defaults.object(forKey: UserDefaultsKeys.sponsorBlock) != nil {
            sponsorBlock = defaults.bool(forKey: UserDefaultsKeys.sponsorBlock)
        }

        if selectedCustomPresetIdString.isEmpty {
            let fileTypeStr = defaults.string(forKey: UserDefaultsKeys.defaultFileType) ?? "mp4"
            if let matched = MediaFileType.allCases.first(where: { $0.rawValue.lowercased() == fileTypeStr.lowercased() }) {
                fileType = matched
                isVideoTab = matched.isVideo
            }

            let resStr = defaults.string(forKey: UserDefaultsKeys.defaultVideoResolution) ?? "r1080p"
            if let res = VideoResolution(rawValue: resStr) {
                videoResolution = res
            }

            if let vcodec = defaults.string(forKey: UserDefaultsKeys.defaultVideoCodec) {
                selectedCodec = vcodec
            }

            if let acodec = defaults.string(forKey: UserDefaultsKeys.defaultAudioCodec) {
                selectedAudioCodec = acodec
            }

            if let fallback = defaults.string(forKey: UserDefaultsKeys.resolutionFallbackPolicy) {
                resolutionFallbackPolicyRaw = fallback
            }
        }
    }
}

/// A plain native URL editor with an autohiding overlay scroller. SwiftUI's
/// TextEditor leaves a disabled, full-height scroller after window resizing.
struct BatchURLTextEditor: NSViewRepresentable {
    @Binding var text: String
    var label: String
    var onFocusChange: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme

    final class TextView: NSTextView {
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocusChange?(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { onFocusChange?(false) }
            return accepted
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BatchURLTextEditor
        init(_ parent: BatchURLTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let editor = TextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.drawsBackground = false
        editor.font = NSFont(name: "GeistMono-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.scrollerKnobStyle = colorScheme == .dark ? .light : .dark
        guard let editor = scroll.documentView as? TextView else { return }
        editor.onFocusChange = onFocusChange
        editor.setAccessibilityLabel(label)
        if editor.string != text { editor.string = text }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator _: Coordinator) {
        (scroll.documentView as? TextView)?.onFocusChange = nil
        (scroll.documentView as? NSTextView)?.delegate = nil
    }
}

#Preview {
    AddDownloadView()
        .environmentObject(DownloadManager())
        .environmentObject(AppState())
        .environmentObject(LanguageService())
        .environmentObject(UpdateChecker())
}
