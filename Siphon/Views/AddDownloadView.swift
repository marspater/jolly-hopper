import SwiftUI

struct AddDownloadView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedPreset") private var selectedPreset: String = "best_quality"
    @AppStorage("selectedCustomPresetId") private var selectedCustomPresetIdString: String = ""
    @AppStorage("defaultAdditionalArguments") private var defaultAdditionalArguments: String = ""
    @AppStorage(UserDefaultsKeys.theme) private var selectedTheme: String = "system"

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
    @State private var customPresets: [CustomPreset] = []
    @State private var selectedPresetName: String? = nil
    @State private var presetSubtitleLanguage: String = ""


    @State private var downloadSubtitles: Bool = false
    @State private var isPasted: Bool = false
    @State private var selectedSubtitleLangs: Set<String> = []
    @State private var availableSubtitles: [SubtitleOption] = []
    @State private var embedSubtitles: Bool = true
    @State private var subtitleFormat: SubtitleFormat = .srt
    @State private var embedThumbnail: Bool = true
    @State private var embedMetadata: Bool = true
    @State private var splitChapters: Bool = false
    @State private var sponsorBlock: Bool = false

    @State private var showFileExistsAlert: Bool = false
    @State private var pendingDownloadOptions: DownloadOptions? = nil
    @State private var existingFilePath: String = ""

    @State private var showAdvancedOptions: Bool = false

    @State private var playlistItems: [MediaInfo] = []
    @State private var selectedPlaylistIds: Set<String> = []
    @State private var isLoadingPlaylist: Bool = false
    @State private var showPlaylistSelector: Bool = false
    @State private var downloadMode: DownloadMode = .single
    @State private var inputMode: InputMode = .single
    @State private var batchUrlsText: String = ""
    @State private var selectedFormatId: String? = nil
    @State private var showStreamInspector: Bool = false
    @State private var fetchTask: Task<Void, Never>? = nil
    @State private var playlistTask: Task<Void, Never>? = nil

    enum InputMode: String, CaseIterable, Identifiable {
        case single = "single"
        case batch = "batch"
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
        Set(availableCodecs.map(\.id))
    }

    private var filteredResolutions: [VideoResolution] {
        if selectedCodec == "h264" {
            return VideoResolution.allCases.filter { res in
                res != .best && res != .r2160p && res != .r1440p
            }
        }
        return VideoResolution.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if inputMode == .single {
                        urlSection

                        if let info = mediaInfo {
                            if !showPlaylistSelector {
                                mediaInfoSection(info)

                                if info.playlist != nil {
                                    playlistDetectedBanner
                                }

                                streamInspectorSection(info)
                            } else {
                                playlistSelectorSection
                            }

                            formatSection
                            saveSection
                            extraOptionsToggleSection
                        }

                        if let error = errorMessage {
                            errorSection(error)
                        }
                    } else {
                        batchSection
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 620, minHeight: 560, idealHeight: 700, maxHeight: .infinity)
        .preferredColorScheme(selectedTheme == "light" ? .light : (selectedTheme == "dark" ? .dark : nil))
        .background(.ultraThinMaterial)
        .onAppear {
            let loadedPresets = CustomPreset.loadAll()
            self.customPresets = loadedPresets

            // 1. Try to load from Custom Preset first
            if !selectedCustomPresetIdString.isEmpty,
               let customPresetId = UUID(uuidString: selectedCustomPresetIdString),
               let customPreset = loadedPresets.first(where: { $0.id == customPresetId }) {

                fileType = customPreset.fileType
                videoResolution = customPreset.videoResolution
                selectedCodec = customPreset.videoCodec.rawValue
                selectedConversionCodec = "none"
                downloadSubtitles = false
                embedSubtitles = false
                presetSubtitleLanguage = ""
            }

            // Handle Clipboard and External URLs
            if let clipboardString = NSPasteboard.general.string(forType: .string),
               clipboardString.hasPrefix("http") {
                urlInput = clipboardString
            }

            if !appState.urlToDownload.isEmpty {
                urlInput = appState.urlToDownload
                appState.urlToDownload = ""
            }
        }
        .onChange(of: urlInput) { _, newValue in
            if newValue.hasPrefix("http") && mediaInfo == nil && !isLoading {
                fetchInfo()
            }
        }
        .onChange(of: appState.urlToDownload) { _, newUrl in
            if !newUrl.isEmpty {
                urlInput = newUrl
                appState.urlToDownload = ""
                inputMode = .single
                fetchInfo()
            }
        }
        .alert(languageService.s("file_exists_title"), isPresented: $showFileExistsAlert) {
            Button(languageService.s("overwrite"), role: .destructive) {
                if let options = pendingDownloadOptions {
                    proceedWithDownload(options: options, forceOverwrite: true)
                }
            }
            Button(languageService.s("add_number")) {
                downloadWithUniqueFilename()
            }
            Button(languageService.s("cancel"), role: .cancel) {
                pendingDownloadOptions = nil
            }
        } message: {
            Text(languageService.s("file_exists_message"))
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let newPresets = CustomPreset.loadAll()
            if newPresets != self.customPresets {
                self.customPresets = newPresets

                // If the currently selected custom preset was updated, re-apply its values
                if let customPresetId = UUID(uuidString: selectedCustomPresetIdString),
                   let customPreset = newPresets.first(where: { $0.id == customPresetId }) {
                    applyCustomPreset(customPreset)
                    selectedPresetName = customPreset.name
                }
            }
        }
        .onDisappear {
            fetchTask?.cancel()
            fetchTask = nil
            playlistTask?.cancel()
            playlistTask = nil
        }
    }

    private var header: some View {
        HStack {
            Text(languageService.s("new_download"))
                .font(.geist(18, weight: .bold))

            Spacer()

            HStack(spacing: 2) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        inputMode = .single
                    }
                } label: {
                    Text(languageService.s("single_mode"))
                        .font(.geist(11, weight: .semibold))
                        .foregroundColor(inputMode == .single ? .white : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background {
                            if inputMode == .single {
                                Capsule()
                                    .fill(SiphonTheme.primaryGradient)
                                    .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 4, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        inputMode = .batch
                    }
                } label: {
                    Text(languageService.s("batch_import"))
                        .font(.geist(11, weight: .semibold))
                        .foregroundColor(inputMode == .batch ? .white : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background {
                            if inputMode == .batch {
                                Capsule()
                                    .fill(SiphonTheme.primaryGradient)
                                    .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 4, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(2)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.04))
                    .background(Capsule().fill(.ultraThinMaterial))
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
                            .font(.geist(13, weight: .semibold))
                            .foregroundColor(SiphonTheme.accent)
                        Text(languageService.s("paste_multiple_urls"))
                            .font(.geist(14, weight: .bold))
                    }
                    Spacer()
                    let count = extractBatchUrls(from: batchUrlsText).count
                    if count > 0 {
                        Text("\(count) URLs")
                            .font(.geistMono(11, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SiphonTheme.accent.opacity(0.15))
                            .foregroundColor(SiphonTheme.accent)
                            .clipShape(Capsule())
                    }
                }

                ZStack(alignment: .topLeading) {
                    if batchUrlsText.isEmpty {
                        Text("https://example.com/video1\nhttps://example.com/video2\n...")
                            .font(.geistMono(12))
                            .foregroundColor(.secondary.opacity(0.4))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $batchUrlsText)
                        .font(.geistMono(12))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120, idealHeight: 150, maxHeight: 220)
                        .padding(6)
                }
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                .overlay(
                    RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                HStack(spacing: 10) {
                    Button {
                        importBatchFromFile()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.badge.plus")
                                .font(.geist(12))
                            Text(languageService.s("import_file"))
                                .font(.geist(12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl))
                        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                        .overlay(
                            SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusControl)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        batchUrlsText = ""
                    } label: {
                        Text(languageService.s("clear"))
                            .font(.geist(12, weight: .medium))
                            .foregroundColor(batchUrlsText.isEmpty ? .secondary.opacity(0.5) : SiphonTheme.statusFailed)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(batchUrlsText.isEmpty ? Color.clear : SiphonTheme.statusFailed.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                    }
                    .buttonStyle(.plain)
                    .disabled(batchUrlsText.isEmpty)

                    Spacer()
                }
            }
            .padding(14)
            .background(
                SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
            )
            .cornerRadius(SiphonTheme.radiusCard)
            .overlay(
                SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
            )

            formatSection
            saveSection
            extraOptionsToggleSection
        }
    }

    private func streamInspectorSection(_ info: MediaInfo) -> some View {
        Group {
            if let formats = info.formats, !formats.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showStreamInspector.toggle()
                        }
                    } label: {
                        HStack {
                            Image(systemName: showStreamInspector ? "chevron.down" : "chevron.right")
                                .font(.geist(11, weight: .bold))
                                .foregroundColor(SiphonTheme.accent)
                            Text(languageService.s("stream_inspector"))
                                .font(.geist(13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            if let selected = selectedFormatId {
                                Text("\(languageService.s("custom_stream")): \(selected)")
                                    .font(.geistMono(11, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(SiphonTheme.accent.opacity(0.15))
                                    .foregroundColor(SiphonTheme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl)
                        )
                        .cornerRadius(SiphonTheme.radiusControl)
                        .overlay(
                            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl)
                        )
                    }
                    .buttonStyle(.plain)

                    if showStreamInspector {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button {
                                    selectedFormatId = nil
                                } label: {
                                    HStack {
                                        Image(systemName: selectedFormatId == nil ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selectedFormatId == nil ? .accentColor : .secondary)
                                        Text(languageService.s("auto_recommended"))
                                            .font(.geist(12, weight: .semibold))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(selectedFormatId == nil ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)

                                Spacer()
                            }

                            ScrollView {
                                VStack(spacing: 4) {
                                    let displayFormats = formats.filter { $0.needsTesting != true }.isEmpty ? formats : formats.filter { $0.needsTesting != true }
                                    ForEach(displayFormats) { fmt in
                                        Button {
                                            selectedFormatId = fmt.formatId
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: selectedFormatId == fmt.formatId ? "checkmark.circle.fill" : "circle")
                                                    .foregroundColor(selectedFormatId == fmt.formatId ? .accentColor : .secondary)

                                                Text(fmt.formatId)
                                                    .font(.geistMono(11, weight: .bold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.primary.opacity(0.08))
                                                    .cornerRadius(4)

                                                Text(fmt.ext.uppercased())
                                                    .font(.geist(11, weight: .bold))
                                                    .foregroundColor(.primary)

                                                Text(fmt.displaySummary)
                                                    .font(.geist(11))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)

                                                Spacer()
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(selectedFormatId == fmt.formatId ? Color.accentColor.opacity(0.12) : Color.clear)
                                            .cornerRadius(6)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 180)
                        }
                        .padding(12)
                        .background(
                            SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl)
                        )
                        .cornerRadius(SiphonTheme.radiusControl)
                        .overlay(
                            SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusControl)
                        )
                    }
                }
            }
        }
    }


    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.geist(13, weight: .semibold))
                    .foregroundColor(SiphonTheme.accent)
                Text(languageService.s("video_url"))
                    .font(.geist(14, weight: .bold))
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField(languageService.s("url_hint"), text: $urlInput)
                        .font(.geistMono(12, relativeTo: .body))
                        .textFieldStyle(.plain)
                        .onSubmit {
                            fetchInfo()
                        }
                    
                    if !urlInput.isEmpty {
                        Button {
                            urlInput = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.geist(12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(languageService.s("clear"))
                        .accessibilityLabel(languageService.s("clear"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                .overlay(
                    RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                Button {
                    if let clipboardString = NSPasteboard.general.string(forType: .string) {
                        urlInput = clipboardString
                        isPasted = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            isPasted = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isPasted ? "checkmark" : "doc.on.clipboard")
                            .font(.geist(12, weight: .medium))
                        Text(languageService.s("paste"))
                            .font(.geist(12, weight: .medium))
                    }
                    .foregroundColor(isPasted ? SiphonTheme.statusCompleted : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl))
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                    .overlay(
                        SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusControl)
                    )
                }
                .buttonStyle(.plain)
                .help(languageService.s("paste_from_clipboard"))
                .accessibilityLabel(languageService.s("paste_from_clipboard"))

                Button {
                    fetchInfo()
                } label: {
                    HStack(spacing: 6) {
                        if isLoading {
                            SiphonSpinner(size: 12, color: .white, lineWidth: 2)
                            Text(languageService.s("fetching"))
                                .font(.geist(12, weight: .semibold))
                        } else {
                            Text(languageService.s("fetch"))
                                .font(.geist(12, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.geist(11, weight: .bold))
                        }
                    }
                    .foregroundColor(urlInput.isEmpty ? .secondary.opacity(0.5) : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        urlInput.isEmpty ?
                        LinearGradient(colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom) :
                        SiphonTheme.primaryGradient
                    )
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                            .stroke(Color.white.opacity(urlInput.isEmpty ? 0.05 : 0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(urlInput.isEmpty || isLoading)
                .shadow(color: urlInput.isEmpty ? .clear : SiphonTheme.accent.opacity(0.35), radius: 4, y: 1)
                .help(languageService.s("fetch_info"))
                .accessibilityLabel(languageService.s("fetch_info"))
            }
        }
        .padding(14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .cornerRadius(SiphonTheme.radiusCard)
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private func mediaInfoSection(_ info: MediaInfo) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: info.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.2))
                    .overlay { Image(systemName: "photo").font(.largeTitle).foregroundColor(.gray) }
            }
            .frame(width: 180, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.geist(15, weight: .semibold)).lineLimit(2)
                if let uploader = info.uploader {
                    Text(uploader).font(.geist(12)).foregroundColor(.secondary)
                }
                HStack(spacing: 12) {
                    if let duration = info.durationString {
                        Label(duration, systemImage: "clock").font(.geistMono(11)).foregroundColor(.secondary)
                    }
                    if let views = info.viewCount {
                        Label(formatNumber(views), systemImage: "eye").font(.geistMono(11)).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding()
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .cornerRadius(SiphonTheme.radiusCard)
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private var playlistDetectedBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(languageService.s("playlist_detected")).font(.geist(14, weight: .bold))
                Text(languageService.s("entire_playlist")).font(.geist(12)).foregroundColor(.secondary)
            }
            Spacer()
            if isLoadingPlaylist {
                ProgressView().controlSize(.small)
            } else {
                Button(languageService.s("load_playlist")) { loadPlaylist() }.buttonStyle(.bordered)
            }
        }
        .padding()
        .background(SiphonTheme.accent.opacity(0.12))
        .cornerRadius(SiphonTheme.radiusCard)
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusCard)
                .stroke(SiphonTheme.accent.opacity(0.25), lineWidth: 1)
        )
    }

    private var playlistSelectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(languageService.s("entire_playlist")).font(.geist(14, weight: .bold))
                Spacer()
                Button(languageService.s("single_video")) {
                    showPlaylistSelector = false
                    downloadMode = .single
                }
                .buttonStyle(.link)
            }

            HStack(spacing: 12) {
                Button(languageService.s("select_all")) { selectedPlaylistIds = Set(playlistItems.map { $0.id }) }
                    .buttonStyle(.plain).foregroundColor(SiphonTheme.accent)
                Button(languageService.s("deselect_all")) { selectedPlaylistIds.removeAll() }
                    .buttonStyle(.plain).foregroundColor(SiphonTheme.accent)
                Spacer()
                Text("\(selectedPlaylistIds.count) / \(playlistItems.count)").font(.geistMono(11, weight: .semibold)).foregroundColor(.secondary)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(playlistItems, id: \.id) { item in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { selectedPlaylistIds.contains(item.id) },
                                set: { isSelected in
                                    if isSelected { selectedPlaylistIds.insert(item.id) }
                                    else { selectedPlaylistIds.remove(item.id) }
                                }
                            )).toggleStyle(.checkbox)

                            AsyncImage(url: item.thumbnailURL) { image in image.resizable().aspectRatio(contentMode: .fill) }
                            placeholder: { Rectangle().fill(Color.gray.opacity(0.2)) }
                            .frame(width: 50, height: 30).cornerRadius(4)

                            VStack(alignment: .leading) {
                                Text(item.title).font(.geist(13, weight: .medium)).lineLimit(1)
                                if let duration = item.durationString {
                                    Text(duration).font(.geist(11)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl)
                        )
                        .cornerRadius(SiphonTheme.radiusControl)
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
        .cornerRadius(SiphonTheme.radiusCard)
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
                        .font(.geist(13, weight: .semibold))
                        .foregroundColor(SiphonTheme.accent)
                    Text(languageService.s("format_and_quality"))
                        .font(.geist(14, weight: .bold))
                }

                Spacer()

                // Quick Presets dropdown menu button
                Menu {
                    Section(languageService.s("download_presets")) {
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
                                            .font(.geist(11))
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
                        Section(languageService.s("custom_presets")) {
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
                            .font(.geist(11))
                            .foregroundColor(SiphonTheme.statusQueued)
                        if let presetName = selectedPresetName {
                            Text("\(languageService.s("quick_presets")): \(presetName)")
                        } else {
                            Text(languageService.s("quick_presets"))
                        }
                        Image(systemName: "chevron.down")
                            .font(.geist(9, weight: .semibold))
                    }
                    .font(.geist(11, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(SiphonTheme.pillBackground(isSelected: false))
                    .clipShape(Capsule())
                    .overlay(SiphonTheme.pillBorder(isSelected: false))
                }
                .menuStyle(.borderlessButton)
                
                // Video / Audio Capsule Switcher
                HStack(spacing: 2) {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isVideoTab = true
                            fileType = .mp4
                        }
                    } label: {
                        Text(languageService.s("video"))
                            .font(.geist(11, weight: .semibold))
                            .foregroundColor(isVideoTab ? .white : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background {
                                if isVideoTab {
                                    Capsule()
                                        .fill(SiphonTheme.primaryGradient)
                                        .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 4, y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isVideoTab = false
                            fileType = .mp3
                        }
                    } label: {
                        Text(languageService.s("audio"))
                            .font(.geist(11, weight: .semibold))
                            .foregroundColor(!isVideoTab ? .white : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background {
                                if !isVideoTab {
                                    Capsule()
                                        .fill(SiphonTheme.primaryGradient)
                                        .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 4, y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                .padding(2)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.04))
                        .background(Capsule().fill(.ultraThinMaterial))
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            // Grid Form inside Card
            VStack(spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(languageService.s("file_type"))
                                .font(.geist(11, weight: .medium))
                                .foregroundColor(.secondary)
                            Picker("", selection: $fileType) {
                                if isVideoTab { ForEach(MediaFileType.videoTypes) { type in Text(type.rawValue).tag(type) } }
                                else { ForEach(MediaFileType.audioTypes) { type in Text(type.rawValue).tag(type) } }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text(isVideoTab ? languageService.s("quality") : languageService.s("audio_quality"))
                                .font(.geist(11, weight: .medium))
                                .foregroundColor(.secondary)
                            if isVideoTab {
                                Picker("", selection: $videoResolution) {
                                    ForEach(filteredResolutions) { res in Text(res.title(lang: languageService)).tag(res) }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onChange(of: selectedCodec) { _, newCodec in
                                    if newCodec == "h264" && (videoResolution == .r1440p || videoResolution == .r2160p || videoResolution == .best) {
                                        videoResolution = .r1080p
                                    }
                                }
                            } else {
                                Picker("", selection: $audioQuality) {
                                    ForEach(AudioQuality.allCases) { quality in Text(quality.title(lang: languageService)).tag(quality) }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    if isVideoTab {
                        GridRow {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(languageService.s("video_codec"))
                                    .font(.geist(11, weight: .medium))
                                    .foregroundColor(.secondary)
                                Picker("", selection: $selectedCodec) {
                                    ForEach(VideoCodec.allCases) { codec in
                                        Text(videoCodecLabel(for: codec)).tag(codec.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            
                            VStack(alignment: .leading, spacing: 5) {
                                Text(languageService.s("audio_codec"))
                                    .font(.geist(11, weight: .medium))
                                    .foregroundColor(.secondary)
                                Picker("", selection: $selectedAudioCodec) {
                                    ForEach(AudioCodec.allCases) { codec in
                                        Text(codec.title(lang: languageService)).tag(codec.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        GridRow {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Post-Processing")
                                    .font(.geist(11, weight: .medium))
                                    .foregroundColor(.secondary)
                                Picker("", selection: $selectedConversionCodec) {
                                    ForEach(ConversionCodec.allCases) { codec in
                                        Text(codec.title(lang: languageService)).tag(codec.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            
                            Color.clear
                                .gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }

            // Info notices
            if isVideoTab && selectedCodec == "h264" {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(SiphonTheme.accent)
                        .font(.geist(11))
                    Text(languageService.s("h264_preset_info"))
                        .font(.geist(11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(SiphonTheme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
            }
        }
        .padding(14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .cornerRadius(SiphonTheme.radiusCard)
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private func videoCodecLabel(for codec: VideoCodec) -> String {
        let title = codec.title(lang: languageService)
        guard codec != .auto, !availableCodecs.isEmpty else { return title }
        return availableCodecIDs.contains(codec.rawValue) ? "\(title) • Detected" : "\(title) • Fallback if unavailable"
    }

    private func applyPreset(_ preset: DownloadPreset, preserveSelectedCodec: Bool = true) {
        let currentCodec = selectedCodec
        let currentConversion = selectedConversionCodec
        selectedCodec = preserveSelectedCodec ? currentCodec : preset.videoCodec.rawValue
        selectedConversionCodec = preserveSelectedCodec ? currentConversion : "none"
        selectedAudioCodec = preset.audioCodec.rawValue
        videoResolution = preset.videoResolution
        fileType = preset.fileType
        isVideoTab = preset.fileType.isVideo

        downloadSubtitles = false
        embedSubtitles = false
        selectedSubtitleLangs.removeAll()
        presetSubtitleLanguage = ""
    }

    private func applyCustomPreset(_ preset: CustomPreset, preserveSelectedCodec: Bool = true) {
        let currentCodec = selectedCodec
        let currentConversion = selectedConversionCodec
        selectedCodec = preserveSelectedCodec ? currentCodec : preset.videoCodec.rawValue
        selectedConversionCodec = preserveSelectedCodec ? currentConversion : "none"
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

        if !presetSubtitleLanguage.isEmpty && !availableSubtitles.isEmpty {
            if availableSubtitles.contains(where: { $0.id == presetSubtitleLanguage }) {
                selectedSubtitleLangs = [presetSubtitleLanguage]
            }
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.geist(13, weight: .semibold))
                    .foregroundColor(SiphonTheme.accent)
                Text(languageService.s("save_folder"))
                    .font(.geist(14, weight: .bold))
            }

            VStack(alignment: .leading, spacing: 10) {
                // Save Folder Row
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.geist(12))
                            .foregroundColor(.secondary)
                        Text(saveFolder.path)
                            .font(.geistMono(11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    Button {
                        selectFolder()
                    } label: {
                        Text(languageService.s("select"))
                            .font(.geist(12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl))
                            .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                            .overlay(
                                SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusControl)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Custom Filename Row
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.geist(12))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    TextField(languageService.s("custom_filename_hint"), text: $customFilename)
                        .font(.geist(12))
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                .overlay(
                    RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .cornerRadius(SiphonTheme.radiusCard)
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private var extraOptionsToggleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    showAdvancedOptions.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showAdvancedOptions ? "chevron.down" : "chevron.right")
                        .font(.geist(11, weight: .bold))
                        .foregroundColor(SiphonTheme.accent)
                        .frame(width: 12)
                    Text(languageService.s("extra_settings"))
                        .font(.geist(13, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl)
                )
                .cornerRadius(SiphonTheme.radiusControl)
                .overlay(
                    SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl)
                )
            }
            .buttonStyle(.plain)

            if showAdvancedOptions {
                extraOptionsSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var extraOptionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isVideoTab {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(languageService.s("subtitles"))
                            .font(.geist(12, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    Toggle(languageService.s("download_subtitles"), isOn: $downloadSubtitles)
                        .disabled(availableSubtitles.isEmpty)
                        .tint(SiphonTheme.accent)

                    if availableSubtitles.isEmpty && mediaInfo != nil {
                        Text(languageService.s("no_subtitles"))
                            .font(.geist(11))
                            .foregroundColor(.secondary)
                    } else if downloadSubtitles {
                        HStack(spacing: 12) {
                            Menu {
                                let manualSubs = availableSubtitles.filter { !$0.isAuto }.sorted(by: { $0.name < $1.name })
                                let autoSubs = availableSubtitles.filter { $0.isAuto }.sorted(by: { $0.name < $1.name })

                                if !manualSubs.isEmpty {
                                    Section(header: Text(languageService.s("internal"))) {
                                        ForEach(manualSubs) { sub in
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

                                if !autoSubs.isEmpty {
                                    Section(header: Text(languageService.s("auto_subs"))) {
                                        ForEach(autoSubs) { sub in
                                            Button {
                                                toggleSubtitle(sub.id)
                                            } label: {
                                                HStack {
                                                    if selectedSubtitleLangs.contains(sub.id) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                    Text("\(sub.name) [Auto]")
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(languageService.s("languages"))
                                    Spacer()
                                    if selectedSubtitleLangs.isEmpty {
                                        Text(languageService.s("select"))
                                    } else {
                                        Text(String(format: languageService.s("subtitles_selected"), selectedSubtitleLangs.count))
                                    }
                                }
                            }
                            .menuStyle(.borderedButton)

                            Picker(languageService.s("subtitle_format"), selection: $subtitleFormat) {
                                ForEach(SubtitleFormat.allCases) { format in
                                    Text(format.displayName).tag(format)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Toggle(languageService.s("embed_video"), isOn: $embedSubtitles)
                            .tint(SiphonTheme.accent)
                    }
                }
                
                Divider()
                    .opacity(0.5)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(languageService.s("embedded_data"))
                    .font(.geist(12, weight: .semibold))
                    .foregroundColor(.secondary)
                Toggle(languageService.s("embed_thumbnail"), isOn: $embedThumbnail)
                    .tint(SiphonTheme.accent)
                Toggle(languageService.s("metadata_desc"), isOn: $embedMetadata)
                    .tint(SiphonTheme.accent)
            }

            Divider()
                .opacity(0.5)

            VStack(alignment: .leading, spacing: 8) {
                Text(languageService.s("advanced"))
                    .font(.geist(12, weight: .semibold))
                    .foregroundColor(.secondary)
                Toggle(languageService.s("split_chapters"), isOn: $splitChapters)
                    .tint(SiphonTheme.accent)
                Toggle(languageService.s("sponsorblock_hint"), isOn: $sponsorBlock)
                    .tint(SiphonTheme.accent)
            }
        }
        .padding(14)
        .background(
            SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
        )
        .cornerRadius(SiphonTheme.radiusCard)
        .overlay(
            SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
        )
    }

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(SiphonTheme.statusFailed)
                    .font(.geist(13))
                Text(error)
                    .font(.geist(12, weight: .medium))
                    .foregroundColor(SiphonTheme.statusFailed)
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
                                .font(.geist(11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SiphonTheme.accent)
                        .controlSize(.small)
                    }

                    if isFDAError {
                        Button {
                            PreferencesWindowManager.shared.showPreferencesWindow(
                                languageService: languageService,
                                updateChecker: UpdateChecker(),
                                downloadManager: downloadManager,
                                initialTab: .advanced
                            )
                        } label: {
                            Text(languageService.s("settings"))
                                .font(.geist(11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button {
                            PreferencesWindowManager.shared.showPreferencesWindow(
                                languageService: languageService,
                                updateChecker: UpdateChecker(),
                                downloadManager: downloadManager,
                                initialTab: .advanced
                            )
                        } label: {
                            Text(languageService.s("settings"))
                                .font(.geist(11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SiphonTheme.accent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SiphonTheme.statusFailed.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                .stroke(SiphonTheme.statusFailed.opacity(0.25), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                AddDownloadWindowManager.shared.closeWindow()
                dismiss()
            } label: {
                Text(languageService.s("cancel"))
                    .font(.geist(13, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(SiphonTheme.controlBackground(cornerRadius: SiphonTheme.radiusControl))
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                    .overlay(
                        SiphonTheme.controlBorder(cornerRadius: SiphonTheme.radiusControl)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape)

            if inputMode == .batch {
                let count = extractBatchUrls(from: batchUrlsText).count
                let isDisabled = count == 0
                Button {
                    startDownload()
                } label: {
                    Text(String(format: languageService.s("queue_batch"), count))
                        .font(.geist(13, weight: .bold))
                        .foregroundColor(isDisabled ? .secondary.opacity(0.6) : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .background(
                            isDisabled ?
                            LinearGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom) :
                            SiphonTheme.primaryGradient
                        )
                        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                        .overlay(
                            RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                                .stroke(Color.white.opacity(isDisabled ? 0.05 : 0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .shadow(color: isDisabled ? .clear : SiphonTheme.accent.opacity(0.35), radius: 6, y: 2)
                .keyboardShortcut(.return)
            } else {
                let downloadTitle = downloadMode == .playlist ?
                    String(format: languageService.s("download_selected"), selectedPlaylistIds.count) :
                    languageService.s("download_btn")
                let isDisabled = mediaInfo == nil || (downloadMode == .playlist && selectedPlaylistIds.isEmpty)

                Button {
                    startDownload()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.geist(13, weight: .semibold))
                        Text(downloadTitle)
                            .font(.geist(13, weight: .bold))
                    }
                    .foregroundColor(isDisabled ? .secondary.opacity(0.6) : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(
                        isDisabled ?
                        LinearGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom) :
                        SiphonTheme.primaryGradient
                    )
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                            .stroke(Color.white.opacity(isDisabled ? 0.05 : 0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .shadow(color: isDisabled ? .clear : SiphonTheme.accent.opacity(0.35), radius: 6, y: 2)
                .keyboardShortcut(.return)
            }
        }
        .padding()
    }

    private func fetchInfo() {
        guard !urlInput.isEmpty else { return }
        fetchTask?.cancel()
        isLoading = true
        errorMessage = nil
        mediaInfo = nil
        selectedFormatId = nil
        fetchTask = Task {
            do {
                let info = try await downloadManager.ytdlpService.fetchInfo(url: urlInput, rawCookies: appState.rawCookiesToDownload)
                guard !Task.isCancelled else { return }
                mediaInfo = info
                customFilename = info.title

                var subs: [SubtitleOption] = []
                var foundLangs: Set<String> = []

                if let manual = info.subtitles {
                    for key in manual.keys {
                        if !foundLangs.contains(key) {
                            let name = manual[key]?.first?.name ?? key
                            subs.append(SubtitleOption(id: key, name: name, isAuto: false))
                            foundLangs.insert(key)
                        }
                    }
                }

                if let auto = info.automaticCaptions {
                    for key in auto.keys {
                        if !foundLangs.contains(key) {
                            let name = auto[key]?.first?.name ?? key
                            subs.append(SubtitleOption(id: key, name: name, isAuto: true))
                            foundLangs.insert(key)
                        }
                    }
                }

                availableSubtitles = subs
                selectedSubtitleLangs.removeAll()

                // Extract Codecs
                var codecs: Set<String> = []
                var codecOptions: [CodecOption] = []

                if let formats = info.formats {
                    for format in formats {
                        if let vcodec = format.vcodec, vcodec != "none" {
                            if vcodec.hasPrefix("avc1") {
                                if !codecs.contains("h264") {
                                    codecs.insert("h264")
                                    codecOptions.append(CodecOption(id: "h264", name: "H.264"))
                                }
                            } else if vcodec.hasPrefix("vp9") {
                                if !codecs.contains("vp9") {
                                    codecs.insert("vp9")
                                    codecOptions.append(CodecOption(id: "vp9", name: "VP9"))
                                }
                            } else if vcodec.hasPrefix("av01") {
                                if !codecs.contains("av1") {
                                    codecs.insert("av1")
                                    codecOptions.append(CodecOption(id: "av1", name: "AV1"))
                                }
                            } else if vcodec.hasPrefix("hev1") || vcodec.hasPrefix("hvc1") {
                                if !codecs.contains("h265") {
                                    codecs.insert("h265")
                                    codecOptions.append(CodecOption(id: "h265", name: "H.265 (HEVC)"))
                                }
                            }
                        }
                    }
                }
                availableCodecs = codecOptions.sorted(by: { $0.name < $1.name })
                // Don't reset selectedCodec here - preserve preset selection
                availableSubtitles = subs

                if !presetSubtitleLanguage.isEmpty {
                    if foundLangs.contains(presetSubtitleLanguage) {
                        selectedSubtitleLangs = [presetSubtitleLanguage]
                    } else {
                        selectedSubtitleLangs.removeAll()
                    }
                } else {
                    selectedSubtitleLangs.removeAll()
                }

            } catch {
                if !Task.isCancelled {
                    errorMessage = formatErrorMessage(error)
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    private func loadPlaylist() {
        playlistTask?.cancel()
        isLoadingPlaylist = true
        errorMessage = nil
        playlistTask = Task {
            do {
                let items = try await downloadManager.ytdlpService.fetchPlaylistInfo(url: urlInput)
                guard !Task.isCancelled else { return }
                playlistItems = items
                selectedPlaylistIds = Set(items.map { $0.id })
                showPlaylistSelector = true
                downloadMode = .playlist
            } catch {
                if !Task.isCancelled {
                    errorMessage = formatErrorMessage(error)
                }
            }
            if !Task.isCancelled {
                isLoadingPlaylist = false
            }
        }
    }

    private func formatErrorMessage(_ error: Error) -> String {
        if let ytdlpError = error as? YtdlpError {
            switch ytdlpError {
            case .safariCookiesFullDiskAccessRequired:
                return languageService.s("safari_fda_required")
            case .tooManyRequests:
                return languageService.s("too_many_requests")
            case .cloudflareBlocked:
                return languageService.s("cloudflare_blocked")
            case .notFound:
                return languageService.s("ytdlp_not_found")
            case .parseError:
                return languageService.s("parse_error")
            case .boyfriendTVNeedsBrowserCookies:
                return "This site requires signed-in browser cookies. Open Settings > Advanced > Browser Cookies, choose your browser, then try again."
            case .boyfriendTVLoginRequired:
                return languageService.s("login_required")
            case .subtitleError(let details):
                return String(format: languageService.s("subtitle_download_failed"), details)
            case .ffmpegInstallationFailed:
                return languageService.s("ffmpeg_error")
            case .securityViolation(let message):
                return "Security violation: \(message)"
            case .downloadFailed(let reason), .commandFailed(let reason):
                let lower = reason.lowercased()
                if lower.contains("safari") && (lower.contains("full disk access") || lower.contains("operation not permitted") || lower.contains("cookies.binarycookies")) {
                    return languageService.s("safari_fda_required")
                } else if lower.contains("cloudflare") || lower.contains("403") || lower.contains("anti-bot") || lower.contains("captcha") {
                    return languageService.s("cloudflare_blocked")
                } else if lower.contains("sign in") || lower.contains("private video") || lower.contains("login") {
                    return languageService.s("login_required")
                } else if lower.contains("drm") || lower.contains("encrypted") {
                    return languageService.s("drm_protected")
                } else if lower.contains("unavailable") || lower.contains("removed") || lower.contains("404") {
                    return languageService.s("video_unavailable")
                } else if lower.contains("unsupported url") {
                    return languageService.s("unsupported_url")
                } else if lower.contains("timed out") || lower.contains("timeout") {
                    return languageService.s("network_timeout")
                } else {
                    return reason.isEmpty ? languageService.s("parse_error") : reason
                }
            }
        }
        return error.localizedDescription
    }

    private func startDownload() {
        let videoCodecEnum = isVideoTab ? VideoCodec(rawValue: selectedCodec) : nil
        let conversionCodecEnum = isVideoTab ? ConversionCodec(rawValue: selectedConversionCodec) : nil
        let audioCodecEnum: AudioCodec? = {
            if !isVideoTab || selectedAudioCodec == "auto" {
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
            subtitleLanguages: Array(selectedSubtitleLangs),
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
            selectedFormatId: inputMode == .single ? selectedFormatId : nil
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
                let potentialPath = saveFolder.appendingPathComponent("\(filename).\(fileType.fileExtension)")
                let pathString = potentialPath.path

                Task {
                    let fileExists = await Task.detached {
                        FileManager.default.fileExists(atPath: pathString)
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

    private func extractBatchUrls(from text: String) -> [String] {
        let lines = text.components(separatedBy: CharacterSet.newlines.union(CharacterSet.whitespaces))
        var valid: [String] = []
        var seen = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) && !seen.contains(trimmed) {
                seen.insert(trimmed)
                valid.append(trimmed)
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
            if let content = try? String(contentsOf: selectedURL, encoding: .utf8) {
                let existing = batchUrlsText.isEmpty ? "" : batchUrlsText + "\n"
                batchUrlsText = existing + content
            }
        }
    }

    private func proceedWithBatchDownload(urls: [String], options: DownloadOptions) {
        var finalOptions = options
        if let rawCookies = appState.rawCookiesToDownload, !rawCookies.isEmpty {
            finalOptions.rawCookies = rawCookies
            appState.rawCookiesToDownload = nil
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
        if let rawCookies = appState.rawCookiesToDownload, !rawCookies.isEmpty {
            finalOptions.rawCookies = rawCookies
            appState.rawCookiesToDownload = nil
        }

        if downloadMode == .single {
            downloadManager.addDownload(url: urlInput, options: finalOptions)
        } else {
            let selectedItems = playlistItems.filter { selectedPlaylistIds.contains($0.id) }
            let urls = selectedItems.map { $0.resolvedURL }
            var itemOptions = finalOptions
            itemOptions.customFilename = nil
            downloadManager.addDownloads(urls: urls, options: itemOptions)
        }
        appState.selectedNavItem = .downloading
        AddDownloadWindowManager.shared.closeWindow()
        dismiss()
    }

    private func downloadWithUniqueFilename() {
        guard let options = pendingDownloadOptions else { return }

        let originalFilename = customFilename.isEmpty ? (mediaInfo?.title ?? "video") : customFilename
        let currentFolder = saveFolder
        let extensionString = fileType.fileExtension

        Task {
            let uniqueFilename = await Task.detached {
                var counter = 1
                var newFilename = "\(originalFilename) (\(counter))"
                var potentialPath = currentFolder.appendingPathComponent("\(newFilename).\(extensionString)")

                while FileManager.default.fileExists(atPath: potentialPath.path) {
                    counter += 1
                    newFilename = "\(originalFilename) (\(counter))"
                    potentialPath = currentFolder.appendingPathComponent("\(newFilename).\(extensionString)")
                }

                return newFilename
            }.value

            var finalOptions = options
            finalOptions.customFilename = uniqueFilename
            proceedWithDownload(options: finalOptions, forceOverwrite: false)
        }
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

    private func toggleSubtitle(_ id: String) {
        if selectedSubtitleLangs.contains(id) {
            selectedSubtitleLangs.remove(id)
        } else {
            selectedSubtitleLangs.insert(id)
        }
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        if number >= 1_000_000_000 { return "\(formatter.string(from: NSNumber(value: Double(number) / 1_000_000_000)) ?? "")B" }
        else if number >= 1_000_000 { return "\(formatter.string(from: NSNumber(value: Double(number) / 1_000_000)) ?? "")M" }
        else if number >= 1_000 { return "\(formatter.string(from: NSNumber(value: Double(number) / 1_000)) ?? "")K" }
        return "\(number)"
    }
}

#Preview {
    AddDownloadView()
        .environmentObject(DownloadManager())
        .environmentObject(AppState())
        .environmentObject(LanguageService())
}
