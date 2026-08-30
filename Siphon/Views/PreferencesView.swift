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
            // Fluid Glass Segmented Tab Bar (38px height with targeted EDR accent glow)
            HStack(spacing: 3) {
                tabSegment(.general, title: languageService.s("general"), icon: "gearshape.fill")
                tabSegment(.download, title: languageService.s("download"), icon: "arrow.down.circle.fill")
                tabSegment(.advanced, title: languageService.s("advanced"), icon: "wrench.and.screwdriver.fill")
                tabSegment(.about, title: languageService.s("about"), icon: "info.circle.fill")
            }
            .padding(3)
            .frame(height: 38)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.04))
                    .background(Capsule().fill(.ultraThinMaterial))
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.04), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()
                .opacity(0.20)

            // Active Tab Content View
            ZStack {
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
            .clipped()
            .id(selectedTab)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(minWidth: 500, idealWidth: 520, maxWidth: 600, minHeight: 460, idealHeight: 500, maxHeight: 650)
        .preferredColorScheme(theme == "light" ? .light : (theme == "dark" ? .dark : nil))
        .accentColor(SiphonTheme.accent)
        .background(PreferencesWindowConfigurator())
        .background(.ultraThinMaterial)
        .siphonEnvironmentalBackdrop()
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
            withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.geist(12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(selectedTab == tab ? .white : .secondary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selectedTab == tab {
                    ZStack {
                        Capsule()
                            .fill(SiphonTheme.accent.opacity(0.30))
                            .blur(radius: 6)
                            .padding(-1)
                            .allowedDynamicRange(AdaptiveRenderingEnvironment.shared.capabilities.supportsEDR ? .high : .standard)

                        Capsule()
                            .fill(SiphonTheme.primaryGradient)
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .matchedGeometryEffect(id: "activeTabBubble", in: tabNamespace)
                }
            }
            .contentShape(Capsule())
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
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(languageService.s("launch_at_login"))
                        .font(.geist(13, weight: .medium))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { LoginItemHelper.shared.isEnabled },
                    set: { LoginItemHelper.shared.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            
            if LoginItemHelper.shared.isEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(languageService.s("start_in_background"))
                            .font(.geist(13, weight: .medium))
                        Text(languageService.s("start_in_background_desc"))
                            .font(.geist(11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $startInBackground)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.leading, 12)
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(languageService.s("notifications"))
                        .font(.geist(13, weight: .medium))
                }
                Spacer()
                if showNotifications {
                    Button(languageService.s("test_notification")) {
                        NotificationService.shared.sendDownloadCompleted(filename: "Siphon Test", languageService: languageService)
                    }
                    .buttonStyle(.plain)
                    .font(.geist(11, weight: .medium))
                    .foregroundColor(SiphonTheme.accent)
                    .padding(.trailing, 8)
                }
                Toggle("", isOn: $showNotifications)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(languageService.s("show_menubar_icon"))
                        .font(.geist(13, weight: .medium))
                }
                Spacer()
                Toggle("", isOn: $showMenuBarIcon)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .tint(SiphonTheme.accent)
    }

    private var themeSection: some View {
        Section(languageService.s("theme")) {
            Picker(languageService.s("theme"), selection: $theme) {
                Text(languageService.s("system")).tag("system")
                Text(languageService.s("light")).tag("light")
                Text(languageService.s("dark")).tag("dark")
            }
            .pickerStyle(.segmented)
            .tint(SiphonTheme.accent)
        }
    }

    private var saveFolderSection: some View {
        Section(languageService.s("save_folder")) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(SiphonTheme.accent)
                        .font(.geist(14))

                    Text(defaultSaveFolder.isEmpty ? "~/Downloads" : defaultSaveFolder)
                        .font(.geistMono(12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer(minLength: 4)

                    if !defaultSaveFolder.isEmpty {
                        Button {
                            defaultSaveFolder = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.geist(14))
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
                    SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusControl)
                )
                .cornerRadius(SiphonTheme.radiusControl)
                .overlay(
                    SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusControl)
                )

                Button {
                    selectFolder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text(languageService.s("select"))
                    }
                    .font(.geist(12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        SiphonTheme.primaryGradient
                    )
                    .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(languageService.s("app_updates"))
                        .font(.geist(13, weight: .medium))
                        .foregroundColor(.primary)
                    if let latestVersion = updateChecker.latestVersion {
                        Text("\(languageService.s("latest")): \(latestVersion)")
                            .font(.geistMono(11, weight: .semibold))
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
                        .font(.geist(11, weight: .medium))
                        .foregroundColor(.green)
                } else {
                    Button {
                        Task {
                            await updateChecker.checkForUpdates(manual: true)
                        }
                    } label: {
                        Text(languageService.s("check_updates"))
                            .font(.geist(12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .siphonInteractiveGlass(cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
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
                        .font(.geist(11))
                }
                .frame(width: 200)
            } else if updateChecker.isInstalling {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(languageService.s("installing_update"))
                        .font(.geist(11))
                        .foregroundColor(.orange)
                }
            } else if updateChecker.needsRestart {
                Text("✅ \(languageService.s("update_ready_title"))")
                    .font(.geist(11))
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
                                .font(.geist(11))
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
                    .font(.geist(11))
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
                        .foregroundColor(selectedCustomPresetIdString == preset.id.uuidString ? SiphonTheme.accent : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text("\(preset.videoCodec.title(lang: languageService)) + \(preset.audioCodec.title(lang: languageService)) • \(preset.videoResolution.title(lang: languageService))\(preset.downloadSubtitles == true ? " • CC: \(preset.subtitleLanguage ?? "")" : "")\(preset.splitChapters == true ? " • 📑" : "")\(preset.sponsorBlock == true ? " • 🚫" : "")")
                            .font(.geist(11))
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
                        .foregroundColor(SiphonTheme.accent)
                }
                .buttonStyle(.borderless)
                .help(languageService.s("edit_preset"))
                .accessibilityLabel(languageService.s("edit_preset"))
                
                Button {
                    deleteCustomPreset(preset)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(SiphonTheme.statusFailed)
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
                .font(.geist(11))
                .foregroundColor(.secondary)
        }
    }

    private var embedOptionsSection: some View {
        Section(languageService.s("embed_options")) {
            Toggle(languageService.s("embed_thumbnail"), isOn: $embedThumbnail)
            Toggle(languageService.s("embed_metadata"), isOn: $embedMetadata)
        }
        .tint(SiphonTheme.accent)
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
                .font(.geist(11))
                .foregroundColor(.secondary)
        }
    }
    
    private var createPresetSheet: some View {
        VStack(spacing: 16) {
            Text(editingPreset == nil ? languageService.s("create_preset") : languageService.s("edit_preset"))
                .font(.geist(15, weight: .bold))
            
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
        .background(.ultraThinMaterial)
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
                        .foregroundColor(SiphonTheme.accent)
                    Text(languageService.s("h264_preset_info"))
                        .font(.geist(11))
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
                        .font(.geist(11))
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
            .tint(SiphonTheme.accent)
            
            ytdlpUpdateSection
            browserCookiesSection
            debugLogsSection
        }
        .siphonFormStyle()
        .padding()
    }

    private var debugLogsSection: some View {
        Section("Debugging & Logs") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Application & Download Logs")
                        .fontWeight(.medium)
                    Text("View or export debug logs to report issues.")
                        .font(.geist(11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("View Debug Logs") {
                    DebugLogWindowManager.shared.showDebugLogWindow()
                }
            }
        }
    }

    private var ytdlpUpdateSection: some View {
        Section(languageService.s("ytdlp_update")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("yt-dlp")
                        .fontWeight(.medium)
                    if let version = downloadManager.ytdlpVersion {
                        Text("\(languageService.s("version")): \(version)")
                            .font(.geistMono(11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if downloadManager.isUpdatingYtdlp {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: max(0, min(1, downloadManager.ytdlpUpdateProgress)))
                            .frame(width: 120)
                        Text("\(Int(downloadManager.ytdlpUpdateProgress * 100))%")
                            .font(.geistMono(10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                } else if let message = downloadManager.ytdlpUpdateMessage?.message {
                    Text(message)
                        .font(.geist(11))
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
                    .font(.geist(11))
                    .foregroundColor(.secondary)
                
                if browserForCookies == "safari" {
                    safariWarningView
                }
            }
        }
    }

    private var hasFullDiskAccess: Bool {
        YtdlpService.hasFullDiskAccess
    }

    private var safariWarningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasFullDiskAccess {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(SiphonTheme.statusCompleted)
                        .font(.geist(13))
                    Text("Full Disk Access: Granted (Safari cookies enabled)")
                        .font(.geist(11, weight: .semibold))
                        .foregroundColor(SiphonTheme.statusCompleted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(SiphonTheme.statusCompleted.opacity(0.10))
                .cornerRadius(SiphonTheme.radiusControl)
                .overlay(
                    RoundedRectangle(cornerRadius: SiphonTheme.radiusControl)
                        .stroke(SiphonTheme.statusCompleted.opacity(0.25), lineWidth: 1)
                )
            } else {
                Text(languageService.s("safari_warning"))
                    .font(.geist(11))
                    .foregroundColor(SiphonTheme.statusQueued)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Button(languageService.s("open_system_settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SiphonTheme.accent)
                .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }
    

    
    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header section: Clean app branding & version
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .shadow(color: SiphonTheme.accent.opacity(0.35), radius: 16, x: 0, y: 4)

                    VStack(spacing: 4) {
                        Text("Siphon")
                            .font(.geist(20, weight: .bold))

                        Text(languageService.s("version") + " \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.0.0")")
                            .font(.geistMono(11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(SiphonTheme.accent.opacity(0.12))
                            .foregroundColor(SiphonTheme.accent)
                            .clipShape(Capsule())
                    }

                    Text(languageService.s("app_desc"))
                        .font(.geist(12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 6)
                .padding(.bottom, 2)

                // Section 1: Credits & Engine (Grouped Settings Style Card)
                VStack(alignment: .leading, spacing: 8) {
                    Text(languageService.s("credits"))
                        .font(.geist(13, weight: .semibold))
                        .foregroundColor(.primary)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Maintainer")
                                .font(.geist(13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            Text("marspater")
                                .font(.geist(12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)

                        SiphonTheme.subtleDivider

                        HStack {
                            Text(languageService.s("video_downloading"))
                                .font(.geist(13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp") ?? URL(fileURLWithPath: "/"))
                                .font(.geist(12, weight: .semibold))
                                .foregroundColor(SiphonTheme.accent)
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(
                        SiphonTheme.cardBackground(cornerRadius: SiphonTheme.radiusCard)
                    )
                    .cornerRadius(SiphonTheme.radiusCard)
                    .overlay(
                        SiphonTheme.cardBorder(cornerRadius: SiphonTheme.radiusCard)
                    )
                }

                // Section 2: Legal & License (Grouped Settings Style Card)
                VStack(alignment: .leading, spacing: 8) {
                    Text(languageService.s("legal_disclaimer_title"))
                        .font(.geist(13, weight: .semibold))
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(SiphonTheme.statusQueued)
                                .font(.geist(13))
                                .padding(.top, 1)

                            Text(languageService.s("legal_disclaimer_message"))
                                .font(.geist(11))
                                .foregroundColor(.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        SiphonTheme.subtleDivider

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(languageService.s("license"))
                                    .font(.geist(13, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("GNU GPL v3.0")
                                    .font(.geist(12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }

                            HStack {
                                Text(languageService.s("license_desc"))
                                    .font(.geist(10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Link(languageService.s("view_license"), destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html") ?? URL(fileURLWithPath: "/"))
                                    .font(.geist(11, weight: .medium))
                                    .foregroundColor(SiphonTheme.accent)
                            }
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

                // Quick links & Footer
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Link(destination: URL(string: "https://github.com/marspater/jolly-hopper") ?? URL(fileURLWithPath: "/")) {
                            Label("GitHub", systemImage: "link")
                                .font(.geist(11, weight: .semibold))
                                .foregroundColor(SiphonTheme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .siphonInteractiveGlass(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)

                        Link(destination: URL(string: "https://github.com/marspater/jolly-hopper/blob/main/README.md") ?? URL(fileURLWithPath: "/")) {
                            Label("README", systemImage: "doc.text")
                                .font(.geist(11, weight: .semibold))
                                .foregroundColor(SiphonTheme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .siphonInteractiveGlass(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)

                        Link(destination: URL(string: "https://github.com/marspater/jolly-hopper/blob/main/SUPPORTED_SITES.md") ?? URL(fileURLWithPath: "/")) {
                            Label(languageService.s("supported_sites"), systemImage: "globe")
                                .font(.geist(11, weight: .semibold))
                                .foregroundColor(SiphonTheme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .siphonInteractiveGlass(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)

                    Text("© 2026 marspater • All rights reserved")
                        .font(.geist(10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.bottom, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
        .clipped()
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
    
    private let lock = NSLock()
    private nonisolated(unsafe) var cachedBrowsers: [SupportedBrowser]?

    func getInstalledBrowsers() -> [SupportedBrowser] {
        lock.lock()
        if let cached = cachedBrowsers {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Bolt Performance Optimization: Querying NSWorkspace for installed applications
        // is expensive I/O. Cache the result in memory thread-safely to avoid redundant disk/workspace lookups.
        let workspace = NSWorkspace.shared
        var installed: [SupportedBrowser] = []
        
        for browser in SupportedBrowser.allCases {
            if let _ = workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
                installed.append(browser)
            }
        }
        
        lock.lock()
        cachedBrowsers = installed
        lock.unlock()

        return installed
    }

    func clearCache() {
        lock.lock()
        cachedBrowsers = nil
        lock.unlock()
    }
}
