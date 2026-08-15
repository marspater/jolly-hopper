import SwiftUI

struct AddDownloadView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageService: LanguageService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedPreset") private var selectedPreset: String = "best_quality"
    @AppStorage("selectedCustomPresetId") private var selectedCustomPresetIdString: String = ""
    @AppStorage("defaultAdditionalArguments") private var defaultAdditionalArguments: String = ""

    @State private var urlInput: String = ""
    @State private var isLoading: Bool = false
    @State private var mediaInfo: MediaInfo?
    @State private var errorMessage: String?


    @State private var saveFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
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
    @State private var selectedSubtitleLangs: Set<String> = []
    @State private var availableSubtitles: [SubtitleOption] = []
    @State private var embedSubtitles: Bool = true
    @State private var subtitleFormat: SubtitleFormat = .srt
    @State private var embedThumbnail: Bool = true
    @State private var embedMetadata: Bool = true
    @State private var splitChapters: Bool = false
    @State private var sponsorBlock: Bool = false
    @State private var additionalArguments: String = ""

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
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 1000, minHeight: 560, idealHeight: 700, maxHeight: 1000)
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
                selectedAudioCodec = customPreset.audioCodec.rawValue
                isVideoTab = customPreset.fileType.isVideo
                selectedPresetName = customPreset.name
                downloadSubtitles = customPreset.downloadSubtitles ?? false
                additionalArguments = customPreset.additionalArguments ?? ""

                let rawLang = customPreset.subtitleLanguage ?? ""
                if rawLang.hasPrefix("embed:") {
                    embedSubtitles = true
                    presetSubtitleLanguage = rawLang.replacingOccurrences(of: "embed:", with: "")
                } else {
                    embedSubtitles = false
                    presetSubtitleLanguage = rawLang
                }

                sponsorBlock = customPreset.sponsorBlock ?? false
                splitChapters = customPreset.splitChapters ?? false

            }
            // 2. Fallback to Standard Preset
            else if let preset = DownloadPreset(rawValue: selectedPreset) {
                fileType = preset.fileType
                videoResolution = preset.videoResolution
                selectedCodec = preset.videoCodec.rawValue
                selectedConversionCodec = "none"
                selectedAudioCodec = preset.audioCodec.rawValue
                isVideoTab = preset.fileType.isVideo
                selectedPresetName = preset.title(lang: languageService)

                downloadSubtitles = false
                embedSubtitles = false
                presetSubtitleLanguage = ""
                additionalArguments = defaultAdditionalArguments
            }
            // 3. Last fallback (should not happen normally)
            else {
                additionalArguments = defaultAdditionalArguments
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
    }

    private var header: some View {
        HStack {
            Text(languageService.s("new_download"))
                .font(.geist(18, weight: .bold))

            Spacer()

            Picker("", selection: $inputMode) {
                Text(languageService.s("single_mode")).tag(InputMode.single)
                Text(languageService.s("batch_import")).tag(InputMode.batch)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .padding()
    }

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(languageService.s("paste_multiple_urls"))
                    .font(.geist(14, weight: .semibold))
                Spacer()
                let count = extractBatchUrls(from: batchUrlsText).count
                if count > 0 {
                    Text("\(count) URLs")
                        .font(.geistMono(11, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                }
            }

            TextEditor(text: $batchUrlsText)
                .font(.geistMono(12))
                .frame(minHeight: 130, maxHeight: 180)
                .padding(6)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Button {
                    importBatchFromFile()
                } label: {
                    Label(languageService.s("import_file"), systemImage: "doc.text")
                }
                .buttonStyle(.bordered)

                Button(languageService.s("clear")) {
                    batchUrlsText = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(batchUrlsText.isEmpty)

                Spacer()
            }

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
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.accentColor)
                            Text(languageService.s("stream_inspector"))
                                .font(.geist(13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            if let selected = selectedFormatId {
                                Text("\(languageService.s("custom_stream")): \(selected)")
                                    .font(.geistMono(11, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
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
                                            .font(.system(size: 12, weight: .semibold))
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
                                    ForEach(formats) { fmt in
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
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundColor(.primary)

                                                Text(fmt.displaySummary)
                                                    .font(.system(size: 11))
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
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                    }
                }
            }
        }
    }

    private var extraOptionsToggleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvancedOptions.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: showAdvancedOptions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                    Text(languageService.s("extra_settings"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if showAdvancedOptions {
                extraOptionsSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(languageService.s("video_url"))
                .font(.geist(14, weight: .semibold))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField(languageService.s("url_hint"), text: $urlInput)
                    .font(.geist(13))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        fetchInfo()
                    }

                Button {
                    if let clipboardString = NSPasteboard.general.string(forType: .string) {
                        urlInput = clipboardString
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .help(languageService.s("paste_from_clipboard"))
                .accessibilityLabel(languageService.s("paste_from_clipboard"))

                Button {
                    fetchInfo()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                }
                .disabled(urlInput.isEmpty || isLoading)
                .help(languageService.s("fetch_info"))
                .accessibilityLabel(languageService.s("fetch_info"))
            }
        }
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
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    private var playlistDetectedBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(languageService.s("playlist_detected")).font(.headline)
                Text(languageService.s("entire_playlist")).font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            if isLoadingPlaylist {
                ProgressView().controlSize(.small)
            } else {
                Button(languageService.s("load_playlist")) { loadPlaylist() }.buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    private var playlistSelectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(languageService.s("entire_playlist")).font(.headline)
                Spacer()
                Button(languageService.s("single_video")) {
                    showPlaylistSelector = false
                    downloadMode = .single
                }
                .buttonStyle(.link)
            }

            HStack(spacing: 12) {
                Button(languageService.s("select_all")) { selectedPlaylistIds = Set(playlistItems.map { $0.id }) }
                    .buttonStyle(.plain).foregroundColor(.blue)
                Button(languageService.s("deselect_all")) { selectedPlaylistIds.removeAll() }
                    .buttonStyle(.plain).foregroundColor(.blue)
                Spacer()
                Text("\(selectedPlaylistIds.count) / \(playlistItems.count)").font(.caption).foregroundColor(.secondary)
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
                                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if let duration = item.durationString {
                                    Text(duration).font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(8).background(Color.gray.opacity(0.05)).cornerRadius(8)
                    }
                }
            }
            .frame(height: 250)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(languageService.s("format")).font(.geist(14, weight: .semibold))
                Spacer()

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
                                            .font(.caption)
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
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                        if let presetName = selectedPresetName {
                            Text("\(languageService.s("quick_presets")) (\(presetName))")
                        } else {
                            Text(languageService.s("quick_presets"))
                        }
                    }
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)
            }

            Picker("", selection: $isVideoTab) {
                Text(languageService.s("video")).tag(true)
                Text(languageService.s("audio")).tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: isVideoTab) { _, isVideo in
                if isVideo { fileType = .mp4 } else { fileType = .mp3 }
            }

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Picker(languageService.s("file_type"), selection: $fileType) {
                    if isVideoTab { ForEach(MediaFileType.videoTypes) { type in Text(type.rawValue).tag(type) } }
                    else { ForEach(MediaFileType.audioTypes) { type in Text(type.rawValue).tag(type) } }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 200, alignment: .leading)

                if isVideoTab {
                    Picker(languageService.s("quality"), selection: $videoResolution) {
                        ForEach(filteredResolutions) { res in Text(res.title(lang: languageService)).tag(res) }
                    }
                    .pickerStyle(.menu).frame(minWidth: 220, alignment: .leading)
                    .onChange(of: selectedCodec) { _, newCodec in
                        if newCodec == "h264" && (videoResolution == .r1440p || videoResolution == .r2160p || videoResolution == .best) {
                            videoResolution = .r1080p
                        }
                    }
                } else {
                    Picker(languageService.s("audio_quality"), selection: $audioQuality) {
                        ForEach(AudioQuality.allCases) { quality in Text(quality.title(lang: languageService)).tag(quality) }
                    }
                    .pickerStyle(.menu).frame(minWidth: 220, alignment: .leading)
                }
            }

            if isVideoTab {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Picker(languageService.s("video_codec"), selection: $selectedCodec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(videoCodecLabel(for: codec)).tag(codec.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 220, alignment: .leading)

                    Picker(languageService.s("audio_codec"), selection: $selectedAudioCodec) {
                        ForEach(AudioCodec.allCases) { codec in
                            Text(codec.title(lang: languageService)).tag(codec.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 220, alignment: .leading)
                }

                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Picker("Post-Processing", selection: $selectedConversionCodec) {
                        ForEach(ConversionCodec.allCases) { codec in
                            Text(codec.title(lang: languageService)).tag(codec.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 220, alignment: .leading)
                }
            }

            if isVideoTab && selectedCodec == "h264" {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text(languageService.s("h264_preset_info"))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            }

            if isVideoTab && selectedCodec != "auto" {
                HStack {
                    Image(systemName: "info.circle")
                    Text(languageService.s("codec_fallback_note"))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            }

            if isVideoTab && selectedCodec != "h264" && (videoResolution == .r1440p || videoResolution == .r2160p || videoResolution == .best) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(languageService.s("codec_warning"))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            }
        }
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
        additionalArguments = defaultAdditionalArguments
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
        additionalArguments = preset.additionalArguments ?? ""

        if !presetSubtitleLanguage.isEmpty && !availableSubtitles.isEmpty {
            if availableSubtitles.contains(where: { $0.id == presetSubtitleLanguage }) {
                selectedSubtitleLangs = [presetSubtitleLanguage]
            }
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(languageService.s("save_folder")).font(.geist(14, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField(languageService.s("save_folder"), text: .constant(saveFolder.path)).font(.geist(12)).textFieldStyle(.roundedBorder).disabled(true)
                Button(languageService.s("select")) { selectFolder() }
            }
            TextField(languageService.s("custom_filename_hint"), text: $customFilename).font(.geist(13)).textFieldStyle(.roundedBorder)
        }
    }

    private var extraOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isVideoTab {
                GroupBox(languageService.s("subtitles")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(languageService.s("download_subtitles"), isOn: $downloadSubtitles)
                            .disabled(availableSubtitles.isEmpty)

                        if availableSubtitles.isEmpty && mediaInfo != nil {
                            Text(languageService.s("no_subtitles"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if downloadSubtitles {
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
                                }
 label: {
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

                            Toggle(languageService.s("embed_video"), isOn: $embedSubtitles)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            GroupBox(languageService.s("embedded_data")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(languageService.s("embed_thumbnail"), isOn: $embedThumbnail)
                    Toggle(languageService.s("metadata_desc"), isOn: $embedMetadata)
                }
                .padding(.vertical, 4)
            }
            GroupBox(languageService.s("advanced")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(languageService.s("split_chapters"), isOn: $splitChapters)
                    Toggle(languageService.s("sponsorblock_hint"), isOn: $sponsorBlock)
                }
                .padding(.vertical, 4)
            }
            GroupBox(languageService.s("additional_arguments")) {
                TextField(languageService.s("additional_arguments_hint"), text: $additionalArguments)
                    .textFieldStyle(.roundedBorder)

                Text(.init(languageService.s("additional_arguments_help")))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 8)
    }

    private func errorSection(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(error)
                .foregroundColor(.red)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(languageService.s("cancel")) {
                AddDownloadWindowManager.shared.closeWindow()
                dismiss()
            }.keyboardShortcut(.escape)

            if inputMode == .batch {
                let count = extractBatchUrls(from: batchUrlsText).count
                Button(String(format: languageService.s("queue_batch"), count)) {
                    startDownload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
                .keyboardShortcut(.return)
            } else {
                let downloadTitle = downloadMode == .playlist ?
                    String(format: languageService.s("download_selected"), selectedPlaylistIds.count) :
                    languageService.s("download_btn")

                Button(downloadTitle) { startDownload() }
                .buttonStyle(.borderedProminent)
                .disabled(mediaInfo == nil || (downloadMode == .playlist && selectedPlaylistIds.isEmpty))
                .keyboardShortcut(.return)
            }
        }
        .padding()
    }

    private func fetchInfo() {
        guard !urlInput.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        mediaInfo = nil
        Task {
            do {
                let info = try await downloadManager.ytdlpService.fetchInfo(url: urlInput)
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

            } catch { errorMessage = error.localizedDescription }
            isLoading = false
        }
    }

    private func loadPlaylist() {
        isLoadingPlaylist = true
        errorMessage = nil
        Task {
            do {
                let items = try await downloadManager.ytdlpService.fetchPlaylistInfo(url: urlInput)
                playlistItems = items
                selectedPlaylistIds = Set(items.map { $0.id })
                showPlaylistSelector = true
                downloadMode = .playlist
            } catch { errorMessage = error.localizedDescription }
            isLoadingPlaylist = false
        }
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
            additionalArguments: additionalArguments.isEmpty ? nil : additionalArguments,
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
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) && !valid.contains(trimmed) {
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
            for item in selectedItems {
                let videoUrl = item.resolvedURL
                var itemOptions = finalOptions
                itemOptions.customFilename = nil
                downloadManager.addDownload(url: videoUrl, options: itemOptions)
            }
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
