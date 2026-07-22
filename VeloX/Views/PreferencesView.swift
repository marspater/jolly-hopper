import SwiftUI
import AppKit

struct PreferencesView: View {
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    @AppStorage(UserDefaultsKeys.defaultSaveFolder) private var defaultSaveFolder: String = ""
    @AppStorage(UserDefaultsKeys.maxConcurrentDownloads) private var maxConcurrentDownloads: Int = 3
    @AppStorage(UserDefaultsKeys.embedThumbnail) private var embedThumbnail: Bool = true
    @AppStorage(UserDefaultsKeys.embedMetadata) private var embedMetadata: Bool = true
    @AppStorage(UserDefaultsKeys.defaultFileType) private var defaultFileType: String = "mp4"
    @AppStorage(UserDefaultsKeys.defaultVideoResolution) private var defaultVideoResolution: String = "r1080p"
    @AppStorage(UserDefaultsKeys.defaultVideoCodec) private var defaultVideoCodec: String = "h264"
    @AppStorage(UserDefaultsKeys.defaultAudioCodec) private var defaultAudioCodec: String = "aac"
    @AppStorage(UserDefaultsKeys.selectedPreset) private var selectedPreset: String = "max_compatibility"
    @AppStorage(UserDefaultsKeys.sponsorBlock) private var sponsorBlock: Bool = false
    @AppStorage(UserDefaultsKeys.browserForCookies) private var browserForCookies: String = "none"
    @AppStorage(UserDefaultsKeys.defaultAdditionalArguments) private var defaultAdditionalArguments: String = ""
    @AppStorage(UserDefaultsKeys.showNotifications) private var showNotifications: Bool = true
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon: Bool = true
    @AppStorage(UserDefaultsKeys.startInBackground) private var startInBackground: Bool = false
    
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var selectedReleaseId: Int? = nil
    @State private var showLanguageChangeAlert = false
    @State private var previousLanguage: Language? = nil
    @State private var installedBrowsers: [SupportedBrowser] = []
    @StateObject private var logger = LoggerService.shared
    @State private var showDebugLogsSheet = false
    @State private var customPresets: [CustomPreset] = []
    @State private var showCreatePresetSheet = false
    @State private var newPresetName = ""
    @AppStorage(UserDefaultsKeys.selectedCustomPresetId) private var selectedCustomPresetIdString: String = ""
    
    // Preset form state
    @State private var presetFileType: MediaFileType = .mp4
    @State private var presetVideoResolution: VideoResolution = .r1080p
    @State private var presetVideoCodec: VideoCodec = .h264
    @State private var presetAudioCodec: AudioCodec = .aac
    @State private var presetEmbedSubtitles: Bool = false
    @State private var presetSubtitleLang: String = ""
    @State private var presetSubtitleFormat: SubtitleFormat = .srt
    @State private var presetSponsorBlock: Bool = false

    @State private var presetSplitChapters: Bool = false
    @State private var presetAdditionalArguments: String = ""
    @State private var editingPreset: CustomPreset? = nil
    
    private var presetFilteredResolutions: [VideoResolution] {
        if presetVideoCodec == .h264 {
            return VideoResolution.allCases.filter { res in
                res != .best && res != .r2160p && res != .r1440p
            }
        }
        return VideoResolution.allCases
    }
    
    enum PreferenceTab: Int, Hashable {
        case general, download, advanced, about
    }

    @State private var selectedTab: PreferenceTab

    init(initialTab: PreferenceTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tag(PreferenceTab.general)
                .tabItem {
                    Label(languageService.s("general"), systemImage: "gear")
                }
            
            downloadTab
                .tag(PreferenceTab.download)
                .tabItem {
                    Label(languageService.s("download"), systemImage: "arrow.down.circle")
                }
            
            advancedTab
                .tag(PreferenceTab.advanced)
                .tabItem {
                    Label(languageService.s("advanced"), systemImage: "wrench.and.screwdriver")
                }
            
            aboutTab
                .tag(PreferenceTab.about)
                .tabItem {
                    Label(languageService.s("about"), systemImage: "info.circle")
                }
        }
        .padding(12)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 500, idealHeight: 580)
        .background(.ultraThinMaterial)
        .onChange(of: theme) { newValue in
            applyTheme(newValue)
        }
        .onChange(of: languageService.selectedLanguage) { newValue in
            if previousLanguage != nil && previousLanguage != newValue {
                showLanguageChangeAlert = true
            }
            previousLanguage = newValue
        }
        .onAppear {
            applyTheme(theme)
            previousLanguage = languageService.selectedLanguage
            installedBrowsers = BrowserUtils.shared.getInstalledBrowsers()
            customPresets = CustomPreset.loadAll()
        }
        .sheet(isPresented: $showCreatePresetSheet) {
            createPresetSheet
        }
        .alert(languageService.s("update_ready_title"), isPresented: $updateChecker.needsRestart) {
            Button(languageService.s("ok")) {
                updateChecker.needsRestart = false
            }
        } message: {
            Text(languageService.s("update_ready_message"))
        }
        .alert(languageService.s("language_changed_title"), isPresented: $showLanguageChangeAlert) {
            Button(languageService.s("ok")) {
                showLanguageChangeAlert = false
            }
        } message: {
            Text(languageService.s("language_changed_message"))
        }
    }
    

    struct CloseButton: View {
        @State private var isHovering = false
        
        var body: some View {
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.black.opacity(0.5))
                        .opacity(isHovering ? 1 : 0)
                )
                .onHover { hovering in
                    isHovering = hovering
                }
        }
    }
    

    
    static func applyTheme(_ theme: String) {
        guard let app = NSApp else { return }
        switch theme {
        case "light":
            app.appearance = NSAppearance(named: .aqua)
        case "dark":
            app.appearance = NSAppearance(named: .darkAqua)
        default:
            app.appearance = nil
        }
    }

    static func applyStoredTheme() {
        let theme = UserDefaults.standard.string(forKey: UserDefaultsKeys.theme) ?? "system"
        applyTheme(theme)
    }

    private func applyTheme(_ theme: String) {
        Self.applyTheme(theme)
    }
    

    
    private var generalTab: some View {
        Form {
            themeSection
            saveFolderSection
            launchAtLoginSection
            appUpdatesSection
        }
        .veloxFormStyle()
        .padding()
    }

    private var launchAtLoginSection: some View {
        Section(languageService.s("other")) {
            Toggle(languageService.s("launch_at_login"), isOn: Binding(
                get: { LoginItemHelper.shared.isEnabled },
                set: { LoginItemHelper.shared.setEnabled($0) }
            ))
            
            if LoginItemHelper.shared.isEnabled {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(languageService.s("start_in_background"), isOn: $startInBackground)
                    Text(languageService.s("start_in_background_desc"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 20)
            }
            
            Toggle(languageService.s("notifications"), isOn: $showNotifications)
            if showNotifications {
                Button(languageService.s("test_notification")) {
                    NotificationService.shared.sendDownloadCompleted(filename: "VeloX Test", languageService: languageService)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            
            Toggle(languageService.s("show_menubar_icon"), isOn: $showMenuBarIcon)
        }
    }

    private var themeSection: some View {
        Section(languageService.s("theme")) {
            Picker(languageService.s("theme"), selection: $theme) {
                Text(languageService.s("system")).tag("system")
                Text(languageService.s("light")).tag("light")
                Text(languageService.s("dark")).tag("dark")
            }
            .pickerStyle(.segmented)
        }
    }

    private var saveFolderSection: some View {
        Section(languageService.s("save_folder")) {
            HStack {
                TextField(languageService.s("save_folder"), text: .constant(defaultSaveFolder.isEmpty ? "Downloads" : defaultSaveFolder))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                
                Button(languageService.s("select")) {
                    selectFolder()
                }
                
                if !defaultSaveFolder.isEmpty {
                    Button {
                        defaultSaveFolder = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var appUpdatesSection: some View {
        Section(languageService.s("updates")) {
            HStack {
                VStack(alignment: .leading) {
                    Text(languageService.s("app_updates"))
                    if let latestVersion = updateChecker.latestVersion {
                        Text("\(languageService.s("latest")): \(latestVersion)")
                            .font(.caption)
                            .foregroundColor(updateChecker.hasUpdate ? .orange : .green)
                    }
                }
                Spacer()
                if updateChecker.isChecking {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if updateChecker.hasUpdate {
                    updateAvailableView
                } else if updateChecker.showUpToDateMessage {
                    Text(languageService.s("app_up_to_date"))
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Button(languageService.s("check_updates")) {
                        Task {
                            await updateChecker.checkForUpdates()
                        }
                    }
                }
            }
        }
    }

    private var updateAvailableView: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if updateChecker.isDownloading {
                HStack {
                    ProgressView(value: max(0, min(1, updateChecker.updateProgress)))
                        .controlSize(.small)
                    Text(languageService.s("downloading_update"))
                        .font(.caption)
                }
                .frame(width: 200)
            } else if updateChecker.isInstalling {
                Text(languageService.s("installing_update"))
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if updateChecker.needsRestart {
                Text("✅ \(languageService.s("update_ready_title"))")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Button(languageService.s("update_now")) {
                    Task {
                        await updateChecker.downloadAndInstallUpdate()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    

    
    private var downloadTab: some View {
        Form {
            downloadPresetsSection
            customPresetsSection
            formatSettingsSection
            codecSettingsSection
            embedOptionsSection
            concurrentDownloadsSection
        }
        .veloxFormStyle()
        .padding()
    }

    private var downloadPresetsSection: some View {
        Section(languageService.s("download_presets")) {
            Picker("", selection: $selectedPreset) {
                ForEach(DownloadPreset.allCases) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title(lang: languageService))
                                .fontWeight(.medium)
                            Text(preset.description(lang: languageService))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .tag(preset.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: selectedPreset) { newValue in
                if let preset = DownloadPreset(rawValue: newValue) {
                    selectedCustomPresetIdString = ""
                    applyPreset(preset)
                }
            }
        }
    }

    private var customPresetsSection: some View {
        Section(languageService.s("custom_presets")) {
            if customPresets.isEmpty {
                Text(languageService.s("no_custom_presets"))
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(customPresets) { preset in
                    customPresetRow(preset)
                }
            }
            
            Button {
                showCreatePresetSheet = true
            } label: {
                Label(languageService.s("create_preset"), systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func customPresetRow(_ preset: CustomPreset) -> some View {
        HStack {
            Button {
                selectedPreset = ""
                selectedCustomPresetIdString = preset.id.uuidString
                applyCustomPreset(preset)
            } label: {
                HStack {
                    Image(systemName: selectedCustomPresetIdString == preset.id.uuidString ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(selectedCustomPresetIdString == preset.id.uuidString ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text("\(preset.videoCodec.title(lang: languageService)) + \(preset.audioCodec.title(lang: languageService)) • \(preset.videoResolution.title(lang: languageService))\(preset.downloadSubtitles == true ? " • CC: \(preset.subtitleLanguage ?? "")" : "")\(preset.splitChapters == true ? " • 📑" : "")\(preset.sponsorBlock == true ? " • 🚫" : "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            HStack(spacing: 12) {
                Button {
                    startEditingPreset(preset)
                } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
                
                Button {
                    deleteCustomPreset(preset)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var formatSettingsSection: some View {
        Section {
            Picker(languageService.s("file_type"), selection: $defaultFileType) {
                ForEach(MediaFileType.allCases) { type in
                    Text(type.rawValue).tag(type.rawValue.lowercased())
                }
            }
            
            Picker(languageService.s("video_quality"), selection: $defaultVideoResolution) {
                ForEach(VideoResolution.allCases) { res in
                    Text(res.title(lang: languageService)).tag(res.rawValue)
                }
            }
            
            HStack {
                Spacer()
                Button {
                    resetFormatToDefaults()
                } label: {
                    Label(languageService.s("reset_to_defaults"), systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .controlSize(.small)
            }
        } header: {
            Text(languageService.s("format_settings"))
        }
    }

    private var codecSettingsSection: some View {
        Section(languageService.s("codec_settings")) {
            Picker(languageService.s("preferred_video_codec"), selection: $defaultVideoCodec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.title(lang: languageService)).tag(codec.rawValue)
                }
            }
            
            Picker(languageService.s("preferred_audio_codec"), selection: $defaultAudioCodec) {
                ForEach(AudioCodec.allCases) { codec in
                    Text(codec.title(lang: languageService)).tag(codec.rawValue)
                }
            }
            
            Text(languageService.s("codec_fallback_note"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var embedOptionsSection: some View {
        Section(languageService.s("embed_options")) {
            Toggle(languageService.s("embed_thumbnail"), isOn: $embedThumbnail)
            Toggle(languageService.s("embed_metadata"), isOn: $embedMetadata)
        }
    }

    private var concurrentDownloadsSection: some View {
        Section(languageService.s("concurrent_downloads")) {
            Stepper("\(languageService.s("max")): \(maxConcurrentDownloads)", value: $maxConcurrentDownloads, in: 1...10)
        }
    }
    
    private var createPresetSheet: some View {
        VStack(spacing: 16) {
            Text(editingPreset == nil ? languageService.s("create_preset") : languageService.s("edit_preset"))
                .font(.headline)
            
            TextField(languageService.s("preset_name"), text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 350)
            
            Divider()
            
            Form {
                presetFormatSection
                presetCodecSection
                presetSubtitleSection
                presetAdvancedSection
                
                Section(languageService.s("additional_arguments")) {
                    TextField(languageService.s("additional_arguments_hint"), text: $presetAdditionalArguments)
                        .textFieldStyle(.roundedBorder)
                    
                    Text(.init(languageService.s("additional_arguments_help")))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .veloxFormStyle()
            
            HStack(spacing: 16) {
                Button(languageService.s("cancel")) {
                    showCreatePresetSheet = false
                    resetPresetForm()
                }
                .buttonStyle(.plain)
                
                Button(languageService.s("save")) {
                    createCustomPreset()
                    showCreatePresetSheet = false
                    resetPresetForm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPresetName.isEmpty)
            }
        }
        .padding()
        .frame(width: 450, height: 500)
    }

    private var presetFormatSection: some View {
        Section(languageService.s("format_settings")) {
            Picker(languageService.s("file_type"), selection: $presetFileType) {
                ForEach(MediaFileType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            
            Picker(languageService.s("video_quality"), selection: $presetVideoResolution) {
                ForEach(presetFilteredResolutions) { res in
                    Text(res.title(lang: languageService)).tag(res)
                }
            }
        }
    }

    private var presetCodecSection: some View {
        Section(languageService.s("codec_settings")) {
            Picker(languageService.s("video_codec"), selection: $presetVideoCodec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.title(lang: languageService)).tag(codec)
                }
            }
            
            Picker(languageService.s("audio_codec"), selection: $presetAudioCodec) {
                ForEach(AudioCodec.allCases) { codec in
                    Text(codec.title(lang: languageService)).tag(codec)
                }
            }
            
            if presetVideoCodec == .h264 {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text(languageService.s("h264_preset_info"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var presetSubtitleSection: some View {
        Section(languageService.s("subtitles")) {
            Toggle(languageService.s("download_subtitles"), isOn: $presetEmbedSubtitles)
            
            if presetEmbedSubtitles {
                Picker(languageService.s("subtitle_output"), selection: Binding(
                    get: { presetSubtitleLang.hasPrefix("embed:") },
                    set: { isEmbed in
                        let lang = presetSubtitleLang.replacingOccurrences(of: "embed:", with: "")
                        presetSubtitleLang = isEmbed ? "embed:\(lang)" : lang
                    }
                )) {
                    Text(languageService.s("subtitle_external")).tag(false)
                    Text(languageService.s("subtitle_embedded")).tag(true)
                }
                .pickerStyle(.segmented)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(languageService.s("languages"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextField(languageService.s("subtitle_lang_hint"), text: Binding(
                        get: { presetSubtitleLang.replacingOccurrences(of: "embed:", with: "") },
                        set: { newLang in
                            let isEmbed = presetSubtitleLang.hasPrefix("embed:")
                            presetSubtitleLang = isEmbed ? "embed:\(newLang)" : newLang
                        }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Picker(languageService.s("subtitle_format"), selection: $presetSubtitleFormat) {
                        ForEach(SubtitleFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }
    
    private var presetAdvancedSection: some View {
        Section(languageService.s("extra_settings")) {
            Toggle(languageService.s("split_chapters"), isOn: $presetSplitChapters)
            Toggle(languageService.s("sponsorblock"), isOn: $presetSponsorBlock)
        }
    }
    
    private func resetPresetForm() {
        newPresetName = ""
        presetFileType = .mp4
        presetVideoResolution = .r1080p
        presetVideoCodec = .h264
        presetAudioCodec = .aac
        presetSubtitleLang = ""
        presetSubtitleFormat = .srt
        presetSponsorBlock = false
        presetSplitChapters = false
        presetAdditionalArguments = ""
    }
    
    private func startEditingPreset(_ preset: CustomPreset) {
        editingPreset = preset
        newPresetName = preset.name
        presetFileType = preset.fileType
        presetVideoResolution = preset.videoResolution
        presetVideoCodec = preset.videoCodec
        presetAudioCodec = preset.audioCodec
        presetSubtitleLang = preset.subtitleLanguage ?? ""
        presetSubtitleFormat = preset.subtitleFormat ?? .srt
        presetSponsorBlock = preset.sponsorBlock ?? false
        presetSplitChapters = preset.splitChapters ?? false
        presetAdditionalArguments = preset.additionalArguments ?? ""
        showCreatePresetSheet = true
    }
    
    private func applyPreset(_ preset: DownloadPreset) {
        defaultVideoCodec = preset.videoCodec.rawValue
        defaultAudioCodec = preset.audioCodec.rawValue
        defaultVideoResolution = preset.videoResolution.rawValue
        defaultFileType = preset.fileType.rawValue.lowercased()
        defaultAdditionalArguments = ""
    }
    
    private func applyCustomPreset(_ preset: CustomPreset) {
        defaultVideoCodec = preset.videoCodec.rawValue
        defaultAudioCodec = preset.audioCodec.rawValue
        defaultVideoResolution = preset.videoResolution.rawValue
        defaultFileType = preset.fileType.rawValue.lowercased()
        // Do not overwrite global defaultAdditionalArguments with preset-specific ones
    }
    
    private func createCustomPreset() {
        if let editing = editingPreset {
            if let index = customPresets.firstIndex(where: { $0.id == editing.id }) {
                customPresets[index].name = newPresetName
                customPresets[index].fileType = presetFileType
                customPresets[index].videoResolution = presetVideoResolution
                customPresets[index].videoCodec = presetVideoCodec
                customPresets[index].audioCodec = presetAudioCodec
                customPresets[index].downloadSubtitles = presetEmbedSubtitles
                customPresets[index].subtitleLanguage = presetSubtitleLang
                customPresets[index].subtitleFormat = presetSubtitleFormat
                customPresets[index].sponsorBlock = presetSponsorBlock
                customPresets[index].splitChapters = presetSplitChapters
                customPresets[index].additionalArguments = presetAdditionalArguments
            }
            editingPreset = nil
        } else {
            let preset = CustomPreset(
                name: newPresetName,
                videoCodec: presetVideoCodec,
                audioCodec: presetAudioCodec,
                videoResolution: presetVideoResolution,
                fileType: presetFileType,
                downloadSubtitles: presetEmbedSubtitles,
                subtitleLanguage: presetSubtitleLang,
                subtitleFormat: presetSubtitleFormat,
                sponsorBlock: presetSponsorBlock,
                splitChapters: presetSplitChapters,
                additionalArguments: presetAdditionalArguments
            )
            customPresets.append(preset)
        }
        
        CustomPreset.saveAll(customPresets)
        resetPresetForm()
        showCreatePresetSheet = false
    }
    
    private func deleteCustomPreset(_ preset: CustomPreset) {
        customPresets.removeAll { $0.id == preset.id }
        CustomPreset.saveAll(customPresets)
    }
    
    private func resetFormatToDefaults() {
        defaultFileType = "mp4"
        defaultVideoResolution = "r1080p"
        defaultVideoCodec = "h264"
        defaultAudioCodec = "aac"
        defaultAdditionalArguments = ""
    }
    

    
    private var advancedTab: some View {
        Form {
            Section("SponsorBlock") {
                Toggle(languageService.s("sponsorblock_desc"), isOn: $sponsorBlock)
            }
            
            ytdlpUpdateSection
            browserCookiesSection
            debugLogsSection
        }
        .veloxFormStyle()
        .padding()
        .sheet(isPresented: $showDebugLogsSheet) {
            debugLogsSheet
        }
    }

    private var debugLogsSection: some View {
        Section("Debugging & Logs") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Application & Download Logs")
                        .fontWeight(.medium)
                    Text("View or export debug logs to report issues.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("View Debug Logs") {
                    showDebugLogsSheet = true
                }
            }
        }
    }
    
    private var debugLogsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Debug Logs")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    showDebugLogsSheet = false
                }
                .keyboardShortcut(.cancelAction)
            }
            
            ScrollView {
                Text(logger.logs.joined(separator: "\n").isEmpty ? "No logs available." : logger.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            
            HStack {
                Button("Copy All") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(logger.logs.joined(separator: "\n"), forType: .string)
                }
                
                Button("Clear Logs") {
                    logger.clearLogs()
                }
                
                Spacer()
                
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([logger.exportLogs()])
                }
            }
        }
        .padding()
        .frame(width: 650, height: 450)
    }

    private var ytdlpUpdateSection: some View {
        Section(languageService.s("ytdlp_update")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("yt-dlp")
                        .fontWeight(.medium)
                    if let version = downloadManager.ytdlpVersion {
                        Text("\(languageService.s("version")): \(version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if downloadManager.isUpdatingYtdlp {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: max(0, min(1, downloadManager.ytdlpUpdateProgress)))
                            .frame(width: 120)
                        Text("\(Int(downloadManager.ytdlpUpdateProgress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if let message = downloadManager.ytdlpUpdateMessage?.message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    Button(languageService.s("update_now")) {
                        updateYtdlp()
                    }
                }
            }
        }
    }

    private var browserCookiesSection: some View {
        Section(languageService.s("browser_cookies")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $browserForCookies) {
                    Text(languageService.s("none")).tag("none")
                    ForEach(installedBrowsers) { browser in
                        Text(browser.displayName).tag(browser.id)
                    }
                }
                .labelsHidden()
                
                Text(languageService.s("browser_hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if browserForCookies == "safari" {
                    safariWarningView
                }
            }
        }
    }

    private var safariWarningView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(languageService.s("safari_warning"))
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(languageService.s("open_system_settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 4)
    }
    

    
    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header section with glowing icon
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 72, height: 72)
                            .shadow(color: .purple.opacity(0.3), radius: 10)
                        
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    
                    VStack(spacing: 4) {
                        Text("VeloX Pro")
                            .font(.system(size: 24, weight: .bold))
                        
                        Text(languageService.s("version") + " \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.0.0")")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    
                    Text(languageService.s("app_desc"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 8)

                // Legal Disclaimer Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(.orange)
                        Text(languageService.s("legal_disclaimer_title"))
                            .font(.system(size: 13, weight: .bold))
                    }
                    
                    Text(languageService.s("legal_disclaimer_message"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )

                // Credits & Details Card
                VStack(alignment: .leading, spacing: 10) {
                    Text(languageService.s("credits"))
                        .font(.system(size: 13, weight: .bold))
                    
                    HStack {
                        Text("Maintainer")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("marspater")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .font(.caption)
                    
                    Divider()
                    
                    HStack {
                        Text(languageService.s("video_downloading"))
                            .foregroundColor(.secondary)
                        Spacer()
                        Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .font(.caption)
                }
                .padding(14)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                // License Card
                VStack(alignment: .leading, spacing: 6) {
                    Text(languageService.s("license"))
                        .font(.system(size: 13, weight: .bold))
                    Text("GNU General Public License v3.0")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(languageService.s("license_desc"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Link(languageService.s("view_license"), destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                        .font(.caption)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                // Quick links
                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://github.com/marspater/jolly-hopper")!) {
                        Label("GitHub", systemImage: "link")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }
                    Link(destination: URL(string: "https://github.com/marspater/jolly-hopper/blob/main/SUPPORTED_SITES.md")!) {
                        Label(languageService.s("supported_sites"), systemImage: "globe")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.purple.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
                .font(.caption)
                .padding(.top, 4)

                Text("© 2026 marspater • All rights reserved")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 16)
        }
    }
    

    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = languageService.s("save")
        
        if panel.runModal() == .OK, let url = panel.url {
            defaultSaveFolder = url.path
        }
    }
    
    private func updateYtdlp() {
        Task {
            await downloadManager.updateYtdlp()
        }
    }
}



#Preview {
    PreferencesView()
}

enum SupportedBrowser: String, CaseIterable, Identifiable {
    case chrome = "chrome"
    case firefox = "firefox"
    case opera = "opera"
    case edge = "edge"
    case brave = "brave"
    case vivaldi = "vivaldi"
    case safari = "safari"
    case chromium = "chromium"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .firefox: return "Mozilla Firefox"
        case .opera: return "Opera"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .vivaldi: return "Vivaldi"
        case .safari: return "Safari"
        case .chromium: return "Chromium"
        }
    }
    
    var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .opera: return "com.operasoftware.Opera"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .safari: return "com.apple.Safari"
        case .chromium: return "org.chromium.Chromium"
        }
    }
}

class BrowserUtils {
    static let shared = BrowserUtils()
    
    func getInstalledBrowsers() -> [SupportedBrowser] {
        let workspace = NSWorkspace.shared
        var installed: [SupportedBrowser] = []
        
        for browser in SupportedBrowser.allCases {
            if let _ = workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
                installed.append(browser)
            }
        }
        
        return installed
    }
}
