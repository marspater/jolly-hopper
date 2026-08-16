import SwiftUI
import AppKit

struct PreferencesWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = ""
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

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
    @AppStorage(UserDefaultsKeys.browserForCookies) private var browserForCookies: String = "safari"
    @AppStorage(UserDefaultsKeys.defaultAdditionalArguments) private var defaultAdditionalArguments: String = ""
    @AppStorage(UserDefaultsKeys.showNotifications) private var showNotifications: Bool = true
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon: Bool = true
    @AppStorage(UserDefaultsKeys.startInBackground) private var startInBackground: Bool = false
    @AppStorage(UserDefaultsKeys.downloadSpeedLimit) private var downloadSpeedLimit: Int = 0
    
    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var selectedReleaseId: Int? = nil
    @State private var showLanguageChangeAlert = false
    @State private var previousLanguage: Language? = nil
    @State private var installedBrowsers: [SupportedBrowser] = []
    @ObservedObject private var logger = LoggerService.shared
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
    
    @Namespace private var tabNamespace

    var body: some View {
        VStack(spacing: 0) {
            // Fluid Glass Segmented Tab Bar
            HStack(spacing: 4) {
                tabSegment(.general, title: languageService.s("general"), icon: "gearshape.fill")
                tabSegment(.download, title: languageService.s("download"), icon: "arrow.down.circle.fill")
                tabSegment(.advanced, title: languageService.s("advanced"), icon: "wrench.and.screwdriver.fill")
                tabSegment(.about, title: languageService.s("about"), icon: "info.circle.fill")
            }
            .padding(4)
            .background(
                ZStack {
                    #if os(macOS)
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
                    #endif
                    Capsule()
                        .fill(Color.primary.opacity(0.04))
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            // Active Tab Content View
            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .download:
                    downloadTab
                case .advanced:
                    advancedTab
                case .about:
                    aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(minWidth: 520, idealWidth: 680, maxWidth: .infinity, minHeight: 420, idealHeight: 580, maxHeight: .infinity)
        .preferredColorScheme(theme == "light" ? .light : (theme == "dark" ? .dark : nil))
        .background(PreferencesWindowConfigurator())
        .background(.ultraThinMaterial)
        .onChange(of: languageService.selectedLanguage) { _, newValue in
            if previousLanguage != nil && previousLanguage != newValue {
                showLanguageChangeAlert = true
            }
            previousLanguage = newValue
        }
        .onAppear {
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
    @ViewBuilder
    private func tabSegment(_ tab: PreferenceTab, title: String, icon: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.geist(12, weight: .semibold))
            }
            .foregroundColor(selectedTab == tab ? .white : .secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background {
                if selectedTab == tab {
                    Capsule()
                        .fill(SiphonTheme.primaryGradient)
                        .matchedGeometryEffect(id: "activeTabBubble", in: tabNamespace)
                        .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 8, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var generalTab: some View {
        Form {
            themeSection
            saveFolderSection
            launchAtLoginSection
            appUpdatesSection
        }
        .siphonFormStyle()
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
                    NotificationService.shared.sendDownloadCompleted(filename: "Siphon Test", languageService: languageService)
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
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(SiphonTheme.accent)
                        .font(.system(size: 14))

                    Text(defaultSaveFolder.isEmpty ? "~/Downloads" : defaultSaveFolder)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer(minLength: 4)

                    if !defaultSaveFolder.isEmpty {
                        Button {
                            defaultSaveFolder = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(languageService.s("reset_save_folder"))
                        .accessibilityLabel(languageService.s("reset_save_folder"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    SiphonTheme.cardBackground(cornerRadius: 10)
                )
                .cornerRadius(10)
                .overlay(
                    SiphonTheme.cardBorder(cornerRadius: 10)
                )

                Button {
                    selectFolder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text(languageService.s("select"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        SiphonTheme.primaryGradient
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .shadow(color: SiphonTheme.accent.opacity(0.25), radius: 6, y: 2)
            }
            .padding(.vertical, 2)
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
            speedLimiterSection
        }
        .siphonFormStyle()
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
            .onChange(of: selectedPreset) { _, newValue in
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
                .help(languageService.s("edit_preset"))
                .accessibilityLabel(languageService.s("edit_preset"))
                
                Button {
                    deleteCustomPreset(preset)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help(languageService.s("delete_preset"))
                .accessibilityLabel(languageService.s("delete_preset"))
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

    private var speedLimiterSection: some View {
        Section(languageService.s("speed_limiter")) {
            Picker(languageService.s("max_download_speed"), selection: $downloadSpeedLimit) {
                Text(languageService.s("unlimited")).tag(0)
                Text("1 MB/s (1024 KB/s)").tag(1024)
                Text("5 MB/s (5120 KB/s)").tag(5120)
                Text("10 MB/s (10240 KB/s)").tag(10240)
                Text("25 MB/s (25600 KB/s)").tag(25600)
                Text("50 MB/s (51200 KB/s)").tag(51200)
            }
            Text(languageService.s("speed_limiter_desc"))
                .font(.caption)
                .foregroundColor(.secondary)
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
            }
            .siphonFormStyle()
            
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
    }
    
    private func startEditingPreset(_ preset: CustomPreset) {
        editingPreset = preset
        newPresetName = preset.name
        presetFileType = preset.fileType
        presetVideoResolution = preset.videoResolution
        presetVideoCodec = preset.videoCodec
        presetAudioCodec = preset.audioCodec
        presetEmbedSubtitles = preset.downloadSubtitles ?? false
        presetSubtitleLang = preset.subtitleLanguage ?? ""
        presetSubtitleFormat = preset.subtitleFormat ?? .srt
        presetSponsorBlock = preset.sponsorBlock ?? false
        presetSplitChapters = preset.splitChapters ?? false
        showCreatePresetSheet = true
    }
    
    private func applyPreset(_ preset: DownloadPreset) {
        defaultVideoCodec = preset.videoCodec.rawValue
        defaultAudioCodec = preset.audioCodec.rawValue
        defaultVideoResolution = preset.videoResolution.rawValue
        defaultFileType = preset.fileType.rawValue.lowercased()
    }
    
    private func applyCustomPreset(_ preset: CustomPreset) {
        defaultVideoCodec = preset.videoCodec.rawValue
        defaultAudioCodec = preset.audioCodec.rawValue
        defaultVideoResolution = preset.videoResolution.rawValue
        defaultFileType = preset.fileType.rawValue.lowercased()
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
                splitChapters: presetSplitChapters
            )
            customPresets.append(preset)
        }
        
        CustomPreset.saveAll(customPresets)
        resetPresetForm()
        showCreatePresetSheet = false
    }
    
    private func deleteCustomPreset(_ preset: CustomPreset) {
        if selectedCustomPresetIdString == preset.id.uuidString {
            selectedCustomPresetIdString = ""
        }
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
        .siphonFormStyle()
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
            
            ReadOnlyLogView(text: logger.logs.joined(separator: "\n").isEmpty ? "No logs available." : logger.logs.joined(separator: "\n"))
                .padding(4)
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

    private var hasFullDiskAccess: Bool {
        let cookiesPath = NSHomeDirectory() + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
        let bookmarksPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        return FileManager.default.isReadableFile(atPath: cookiesPath) || FileManager.default.isReadableFile(atPath: bookmarksPath)
    }

    private var safariWarningView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasFullDiskAccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("Full Disk Access: Granted")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
            } else {
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
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }
    

    
    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header section with glowing icon
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .shadow(color: .purple.opacity(0.4), radius: 20, x: 0, y: 6)
                        .shadow(color: .blue.opacity(0.2), radius: 30, x: 0, y: 8)
                    
                    VStack(spacing: 4) {
                        Text("Siphon")
                            .font(.geist(24, weight: .bold))
                        
                        Text(languageService.s("version") + " \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.2.0")")
                            .font(.geistMono(11, weight: .semibold))
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
                            .font(.geist(13, weight: .bold))
                    }
                    
                    Text(languageService.s("legal_disclaimer_message"))
                        .font(.geist(11))
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
                        .font(.geist(13, weight: .bold))
                    
                    HStack {
                        Text("Maintainer")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("marspater")
                            .font(.geist(13, weight: .medium))
                    }
                    .font(.geist(11))
                    
                    Divider()
                    
                    HStack {
                        Text(languageService.s("video_downloading"))
                            .foregroundColor(.secondary)
                        Spacer()
                        Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp") ?? URL(fileURLWithPath: "/"))
                            .font(.geist(13, weight: .medium))
                    }
                    .font(.geist(11))
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
                        .font(.geist(13, weight: .bold))
                    Text("GNU General Public License v3.0")
                        .font(.geist(11, weight: .semibold))
                    Text(languageService.s("license_desc"))
                        .font(.geist(10))
                        .foregroundColor(.secondary)
                    Link(languageService.s("view_license"), destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html") ?? URL(fileURLWithPath: "/"))
                        .font(.geist(11))
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
                HStack(spacing: 12) {
                    Link(destination: URL(string: "https://github.com/marspater/jolly-hopper") ?? URL(fileURLWithPath: "/")) {
                        Label("GitHub", systemImage: "link")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }
                    Link(destination: URL(string: "https://github.com/marspater/jolly-hopper/blob/main/README.md") ?? URL(fileURLWithPath: "/")) {
                        Label("README", systemImage: "doc.text")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.indigo.opacity(0.1))
                            .cornerRadius(8)
                    }
                    Link(destination: URL(string: "https://github.com/marspater/jolly-hopper/blob/main/SUPPORTED_SITES.md") ?? URL(fileURLWithPath: "/")) {
                        Label(languageService.s("supported_sites"), systemImage: "globe")
                            .padding(.horizontal, 14)
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

final class BrowserUtils: Sendable {
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
