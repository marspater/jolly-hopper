import SwiftUI
import AppKit

struct PreferencesWindowConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
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
    func updateNSView(_: NSView, context _: Context) {
        // No-op: Window configuration does not require dynamic view updates
    }
}

struct PreferencesView: View {
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    @AppStorage(UserDefaultsKeys.defaultSaveFolder) private var defaultSaveFolder: String = ""
    @AppStorage(UserDefaultsKeys.maxConcurrentDownloads) private var maxConcurrentDownloads: Int = 3
    @AppStorage(UserDefaultsKeys.embedThumbnail) private var embedThumbnail: Bool = true
    @AppStorage(UserDefaultsKeys.embedMetadata) private var embedMetadata: Bool = true
    @AppStorage(UserDefaultsKeys.defaultFileType) private var defaultFileType: String = "mp4"
    @AppStorage(UserDefaultsKeys.defaultVideoResolution) private var defaultVideoResolution: String = "r1080p"
    @AppStorage(UserDefaultsKeys.resolutionFallbackPolicy) private var resolutionFallbackPolicy: String = ResolutionFallbackPolicy.strictCeiling.rawValue
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
    @AppStorage(UserDefaultsKeys.customYtdlpPath) private var customYtdlpPath: String = ""

    @EnvironmentObject var languageService: LanguageService
    @EnvironmentObject var updateChecker: UpdateChecker
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var showLanguageChangeAlert = false
    @State private var previousLanguage: Language?
    @State private var installedBrowsers: [SupportedBrowser] = []
    @ObservedObject private var logger = LoggerService.shared
    @State private var customPresets: [CustomPreset] = []
    @State private var showCreatePresetSheet = false
    @State private var showUpdateRestartAlert = false
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
    @State private var editingPreset: CustomPreset?
    @State private var hasFullDiskAccess: Bool = YtdlpService.hasFullDiskAccess
    @State private var isCheckingPermission: Bool = false
    @State private var permissionCheckMessage: String?
    @State private var isClearingAllSites: Bool = false
    @State private var showAllSitesClearedFeedback: Bool = false
    @State private var showClearAllSitesConfirmation: Bool = false

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

        var icon: String? {
            switch self {
            case .general: return "gearshape.fill"
            case .download: return "arrow.down.circle.fill"
            case .advanced: return "wrench.and.screwdriver.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    @State private var selectedTab: PreferenceTab

    init(initialTab: PreferenceTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SiphonSegmentedPicker(
                selection: $selectedTab,
                options: [
                    (.general, languageService.s("general")),
                    (.download, languageService.s("download")),
                    (.advanced, languageService.s("advanced")),
                    (.about, languageService.s("about"))
                ],
                horizontalPadding: SiphonTheme.spacing8,
                icon: \.icon,
                isLarge: true
            )
            .padding(.top, SiphonTheme.spacing10)
            .padding(.bottom, SiphonTheme.spacing10)

            SiphonTheme.subtleDivider

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
            .animation(SiphonAnimation.fluidSpring, value: selectedTab)
        }
        .padding(.horizontal, SiphonTheme.spacing16)
        .padding(.bottom, SiphonTheme.spacing16)
        .frame(minWidth: 500, idealWidth: 520, maxWidth: 620, minHeight: 670, idealHeight: 686, maxHeight: 780)
        .siphonAdaptiveRendering()
        .background(PreferencesWindowConfigurator())
        .siphonWindowBackground()
        .onReceive(NotificationCenter.default.publisher(for: .siphonShowPreferencesTab)) { notification in
            if let tab = notification.object as? PreferenceTab {
                selectedTab = tab
            }
        }
        .onChange(of: languageService.selectedLanguage) { _, newValue in
            if previousLanguage != nil && previousLanguage != newValue {
                showLanguageChangeAlert = true
            }
            previousLanguage = newValue
        }
        .onChange(of: theme) { _, newTheme in
            SiphonTheme.applyTheme(newTheme)
        }
        .onChange(of: showMenuBarIcon) { _, visible in
            MenuBarManager.shared.setVisible(visible)
        }
        .onChange(of: updateChecker.needsRestart) { _, ready in
            showUpdateRestartAlert = ready
        }
        .onAppear {
            showUpdateRestartAlert = updateChecker.needsRestart
            SiphonTheme.applyTheme(theme)
            previousLanguage = languageService.selectedLanguage
            customPresets = CustomPreset.loadAll()
            hasFullDiskAccess = YtdlpService.hasFullDiskAccess
            Task {
                await BrowserUtils.shared.clearCache()
                installedBrowsers = await BrowserUtils.shared.getInstalledBrowsers()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let access = YtdlpService.hasFullDiskAccess
            hasFullDiskAccess = access
            if access {
                permissionCheckMessage = nil
                downloadManager.ytdlpService.resetCookieDenial(for: "safari")
            }
        }
        .onChange(of: browserForCookies) { _, _ in
            let access = YtdlpService.hasFullDiskAccess
            hasFullDiskAccess = access
            if access {
                permissionCheckMessage = nil
                downloadManager.ytdlpService.resetCookieDenial(for: "safari")
            }
        }
        .sheet(isPresented: $showCreatePresetSheet, onDismiss: resetPresetForm) {
            createPresetSheet
        }
        .alert(languageService.s("update_ready_title"), isPresented: $showUpdateRestartAlert) {
            Button(languageService.s("restart_siphon")) {
                updateChecker.restartApp()
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
        .alert(languageService.s("clear_all_sites_confirm_title"), isPresented: $showClearAllSitesConfirmation) {
            Button(languageService.s("cancel"), role: .cancel) {
                // Dialog dismissal is handled automatically by SwiftUI
            }
            Button(languageService.s("clear_all"), role: .destructive) {
                clearAllSitesCookies()
            }
        } message: {
            Text(languageService.s("clear_all_sites_confirm_message"))
        }
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
        Section(siphonHeader: languageService.s("other")) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(languageService.s("launch_at_login"))
                        .font(.siphonStandardMedium)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { LoginItemHelper.shared.isEnabled },
                    set: { LoginItemHelper.shared.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(languageService.s("launch_at_login"))
            }

            if LoginItemHelper.shared.isEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(languageService.s("start_in_background"))
                            .font(.siphonStandardMedium)
                        Text(languageService.s("start_in_background_desc"))
                            .font(.siphonMetadata)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $startInBackground)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(languageService.s("start_in_background"))
                }
                .padding(.leading, 12)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(languageService.s("notifications"))
                        .font(.siphonStandardMedium)
                }
                Spacer()
                if showNotifications {
                    Button(languageService.s("test_notification")) {
                        NotificationService.shared.sendDownloadCompleted(filename: "Siphon Test", languageService: languageService)
                    }
                    .buttonStyle(.plain)
                    .font(.siphonMetadataMedium)
                    .foregroundColor(SiphonTheme.accentText)
                    .padding(.trailing, 8)
                }
                Toggle("", isOn: $showNotifications)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(languageService.s("notifications"))
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(languageService.s("show_menubar_icon"))
                        .font(.siphonStandardMedium)
                }
                Spacer()
                Toggle("", isOn: $showMenuBarIcon)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(languageService.s("show_menubar_icon"))
            }
        }
    }

    private var themeSection: some View {
        Section(siphonHeader: languageService.s("appearance")) {
            HStack {
                Text(languageService.s("theme"))
                    .font(.siphonStandardMedium)
                    .foregroundColor(.primary)

                Spacer()

                SiphonSegmentedPicker(
                    selection: $theme,
                    options: [
                        ("system", languageService.s("system")),
                        ("light", languageService.s("light")),
                        ("dark", languageService.s("dark"))
                    ]
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel(languageService.s("theme"))
            }
        }
    }

    private var saveFolderSection: some View {
        Section(siphonHeader: languageService.s("save_folder")) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(SiphonTheme.accentText)
                        .font(.siphonPrimary)

                    Text(defaultSaveFolder.isEmpty ? "~/Downloads" : defaultSaveFolder)
                        .font(.siphonSecondaryMonoMedium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(defaultSaveFolder.isEmpty ? "~/Downloads" : defaultSaveFolder)
                        .layoutPriority(1)

                    Spacer(minLength: SiphonTheme.spacing4)

                    if !defaultSaveFolder.isEmpty {
                        Button {
                            defaultSaveFolder = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.siphonPrimary)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(languageService.s("reset_save_folder"))
                        .accessibilityLabel(languageService.s("reset_save_folder"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .padding(.horizontal, SiphonTheme.spacing12)
                .padding(.vertical, SiphonTheme.spacing8)
                .background(
                    SiphonTheme.fieldBackground(cornerRadius: SiphonTheme.radiusControl)
                )
                .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous))
                .overlay(
                    SiphonTheme.fieldBorder(cornerRadius: SiphonTheme.radiusControl)
                )

                Button {
                    selectFolder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text(languageService.s("choose_folder"))
                    }
                }
                .buttonStyle(.siphonSecondary)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 2)
        }
    }

    private var appUpdatesSection: some View {
        Section(siphonHeader: languageService.s("updates")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(languageService.s("app_updates"))
                            .font(.siphonStandardMedium)
                            .foregroundColor(.primary)

                        Text("v\(updateChecker.currentVersion)")
                            .font(.siphonMetadataMonoSemibold)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(SiphonTheme.Opacity.fillPill)))
                    }

                    if let latestVersion = updateChecker.latestVersion, updateChecker.hasUpdate {
                        Text("\(languageService.s("latest")): v\(latestVersion)")
                            .font(.siphonMetadataMonoSemibold)
                            .foregroundColor(SiphonTheme.statusQueuedText)
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
                        .font(.siphonMetadataMedium)
                        .foregroundColor(SiphonTheme.statusCompletedText)
                } else {
                    Button {
                        Task {
                            await updateChecker.checkForUpdates(manual: true)
                        }
                    } label: {
                        Text(languageService.s("check_updates"))
                            .font(.siphonSecondaryMedium)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .siphonInteractiveGlass(cornerRadius: SiphonTheme.radiusControl)
                    }
                    .buttonStyle(.bouncy(scale: 0.95, hover: 1.025))
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
                        .font(.siphonMetadata)
                }
                .frame(width: 200)
            } else if updateChecker.isInstalling {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(languageService.s("installing_update"))
                        .font(.siphonMetadata)
                        .foregroundColor(SiphonTheme.statusQueuedText)
                }
            } else if updateChecker.needsRestart {
                Label(languageService.s("update_ready_title"), systemImage: "checkmark.circle.fill")
                    .font(.siphonMetadata)
                    .foregroundColor(SiphonTheme.statusCompletedText)
            } else {
                Button(languageService.s("update_now")) {
                    Task {
                        await updateChecker.downloadAndInstallUpdate()
                    }
                }
                .buttonStyle(.siphonPrimary)
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
        Section(siphonHeader: languageService.s("download_presets")) {
            Picker("", selection: $selectedPreset) {
                ForEach(DownloadPreset.allCases) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title(lang: languageService))
                                .font(.siphonStandardMedium)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(preset.description(lang: languageService))
                                .font(.siphonMetadata)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        Spacer()
                    }
                    .tag(preset.rawValue)
                    .accessibilityElement(children: .combine)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel(languageService.s("download_presets"))
            .onChange(of: selectedPreset) { _, newValue in
                if let preset = DownloadPreset(rawValue: newValue) {
                    selectedCustomPresetIdString = ""
                    applyPreset(preset)
                }
            }
        }
    }

    private var customPresetsSection: some View {
        Section(siphonHeader: languageService.s("custom_presets")) {
            if customPresets.isEmpty {
                Text(languageService.s("no_custom_presets"))
                    .foregroundColor(.secondary)
                    .font(.siphonMetadata)
            } else {
                ForEach(customPresets) { preset in
                    customPresetRow(preset)
                }
            }

            Button {
                resetPresetForm()
                showCreatePresetSheet = true
            } label: {
                Label(languageService.s("create_preset"), systemImage: "plus.circle")
                    .foregroundColor(SiphonTheme.accentText)
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
                        .foregroundColor(selectedCustomPresetIdString == preset.id.uuidString ? SiphonTheme.accentText : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.siphonStandardMedium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(preset.name)
                        Text("\(preset.videoCodec.title(lang: languageService)) + \(preset.audioCodec.title(lang: languageService)) • \(preset.videoResolution.title(lang: languageService))\(preset.downloadSubtitles == true ? " • CC: \(preset.subtitleLanguage ?? "")" : "")\(preset.splitChapters == true ? " • \(languageService.s("split_chapters"))" : "")\(preset.sponsorBlock == true ? " • \(languageService.s("sponsorblock"))" : "")")
                            .font(.siphonMetadata)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selectedCustomPresetIdString == preset.id.uuidString ? [.isButton, .isSelected] : [.isButton])

            Spacer()

            HStack(spacing: 12) {
                Button {
                    startEditingPreset(preset)
                } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(SiphonTheme.accentText)
                }
                .buttonStyle(.borderless)
                .help(languageService.s("edit_preset"))
                .accessibilityLabel(languageService.s("edit_preset"))

                Button {
                    deleteCustomPreset(preset)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(SiphonTheme.statusFailedText)
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
            SiphonMenuPicker(
                languageService.s("file_type"), selection: $defaultFileType,
                options: MediaFileType.allCases.map { type in (value: type.rawValue.lowercased(), title: type.rawValue) }
            )

            SiphonMenuPicker(
                languageService.s("video_quality"), selection: $defaultVideoResolution,
                options: VideoResolution.allCases.map { res in (value: res.rawValue, title: res.title(lang: languageService)) }
            )

            SiphonMenuPicker(
                languageService.s("res_fallback_policy"), selection: $resolutionFallbackPolicy,
                options: ResolutionFallbackPolicy.allCases.map { policy in (value: policy.rawValue, title: policy.title(lang: languageService)) }
            )

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
                .font(.siphonStandardSemibold)
        }
    }

    private var codecSettingsSection: some View {
        Section(siphonHeader: languageService.s("codec_settings")) {
            SiphonMenuPicker(
                languageService.s("preferred_video_codec"), selection: $defaultVideoCodec,
                options: VideoCodec.allCases.map { codec in (value: codec.rawValue, title: codec.title(lang: languageService)) }
            )

            SiphonMenuPicker(
                languageService.s("preferred_audio_codec"), selection: $defaultAudioCodec,
                options: AudioCodec.allCases.map { codec in (value: codec.rawValue, title: codec.title(lang: languageService)) }
            )

            Text(languageService.s("codec_fallback_note"))
                .font(.siphonMetadata)
                .foregroundColor(.secondary)
        }
    }

    private var embedOptionsSection: some View {
        Section(siphonHeader: languageService.s("embed_options")) {
            Toggle(languageService.s("embed_thumbnail"), isOn: $embedThumbnail)
            Toggle(languageService.s("embed_metadata"), isOn: $embedMetadata)
        }
    }

    private var concurrentDownloadsSection: some View {
        Section(siphonHeader: languageService.s("concurrent_downloads")) {
            Stepper("\(languageService.s("max")): \(maxConcurrentDownloads)", value: $maxConcurrentDownloads, in: 1...10)
        }
    }

    private var speedLimiterSection: some View {
        Section(siphonHeader: languageService.s("speed_limiter")) {
            SiphonMenuPicker(
                languageService.s("max_download_speed"), selection: $downloadSpeedLimit,
                options: [
                    (value: 0, title: languageService.s("unlimited")),
                    (value: 1024, title: "1 MB/s (1024 KB/s)"),
                    (value: 5120, title: "5 MB/s (5120 KB/s)"),
                    (value: 10240, title: "10 MB/s (10240 KB/s)"),
                    (value: 25600, title: "25 MB/s (25600 KB/s)"),
                    (value: 51200, title: "50 MB/s (51200 KB/s)")
                ]
            )
            Text(languageService.s("speed_limiter_desc"))
                .font(.siphonMetadata)
                .foregroundColor(.secondary)
        }
    }

    private var createPresetSheet: some View {
        VStack(spacing: 16) {
            Text(editingPreset == nil ? languageService.s("create_preset") : languageService.s("edit_preset"))
                .font(.siphonHeadline)

            TextField(languageService.s("preset_name"), text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 350)

            SiphonTheme.subtleDivider

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
                .buttonStyle(.siphonPrimary)
                .disabled(newPresetName.isEmpty)
            }
        }
        .padding()
        .frame(width: 450, height: 500)
        .siphonWindowBackground()
    }

    private var presetFormatSection: some View {
        Section(siphonHeader: languageService.s("format_settings")) {
            SiphonMenuPicker(
                languageService.s("file_type"), selection: $presetFileType,
                options: MediaFileType.allCases.map { type in (value: type, title: type.rawValue) }
            )

            SiphonMenuPicker(
                languageService.s("video_quality"), selection: $presetVideoResolution,
                options: presetFilteredResolutions.map { res in (value: res, title: res.title(lang: languageService)) }
            )
        }
    }

    private var presetCodecSection: some View {
        Section(siphonHeader: languageService.s("codec_settings")) {
            SiphonMenuPicker(
                languageService.s("video_codec"), selection: $presetVideoCodec,
                options: VideoCodec.allCases.map { codec in (value: codec, title: codec.title(lang: languageService)) }
            )
            .onChange(of: presetVideoCodec) { _, _ in
                if !presetFilteredResolutions.contains(presetVideoResolution) {
                    presetVideoResolution = .r1080p
                }
            }

            SiphonMenuPicker(
                languageService.s("audio_codec"), selection: $presetAudioCodec,
                options: AudioCodec.allCases.map { codec in (value: codec, title: codec.title(lang: languageService)) }
            )

            if presetVideoCodec == .h264 {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(SiphonTheme.accentText)
                        .accessibilityHidden(true)
                    Text(languageService.s("h264_preset_info"))
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var presetSubtitleSection: some View {
        Section(siphonHeader: languageService.s("subtitles")) {
            Toggle(languageService.s("download_subtitles"), isOn: $presetEmbedSubtitles)

            if presetEmbedSubtitles {
                HStack {
                    Text(languageService.s("subtitle_output"))
                        .font(.siphonStandardMedium)
                    Spacer()
                    SiphonSegmentedPicker(
                        selection: Binding(
                            get: { presetSubtitleLang.hasPrefix("embed:") },
                            set: { isEmbed in
                                let lang = presetSubtitleLang.replacingOccurrences(of: "embed:", with: "")
                                presetSubtitleLang = isEmbed ? "embed:\(lang)" : lang
                            }
                        ),
                        options: [
                            (false, languageService.s("subtitle_external")),
                            (true, languageService.s("subtitle_embedded"))
                        ]
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(languageService.s("subtitle_output"))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(languageService.s("languages"))
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)

                    TextField(languageService.s("subtitle_lang_hint"), text: Binding(
                        get: { presetSubtitleLang.replacingOccurrences(of: "embed:", with: "") },
                        set: { newLang in
                            let isEmbed = presetSubtitleLang.hasPrefix("embed:")
                            presetSubtitleLang = isEmbed ? "embed:\(newLang)" : newLang
                        }
                    ))
                    .textFieldStyle(.roundedBorder)

                    SiphonMenuPicker(
                        languageService.s("subtitle_format"), selection: $presetSubtitleFormat,
                        options: SubtitleFormat.allCases.map { format in (value: format, title: format.displayName) }
                    )
                }
            }
        }
    }

    private var presetAdvancedSection: some View {
        Section(siphonHeader: languageService.s("extra_settings")) {
            Toggle(languageService.s("split_chapters"), isOn: $presetSplitChapters)
            Toggle(languageService.s("sponsorblock"), isOn: $presetSponsorBlock)
        }
    }

    private func resetPresetForm() {
        editingPreset = nil
        presetEmbedSubtitles = false
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
        presetVideoCodec = preset.videoCodec
        presetVideoResolution = presetFilteredResolutions.contains(preset.videoResolution) ? preset.videoResolution : .r1080p
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
                if selectedCustomPresetIdString == editing.id.uuidString {
                    applyCustomPreset(customPresets[index])
                }
            }
            editingPreset = nil
        } else {
            let config = CustomPresetConfiguration(
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
            let preset = CustomPreset(configuration: config)
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
        resolutionFallbackPolicy = ResolutionFallbackPolicy.strictCeiling.rawValue
        defaultVideoCodec = "h264"
        defaultAudioCodec = "aac"
        defaultAdditionalArguments = ""
    }

    private var advancedTab: some View {
        Form {
            Section(siphonHeader: "SponsorBlock") {
                Toggle(languageService.s("sponsorblock_desc"), isOn: $sponsorBlock)
            }

            if DependencyChecksums.managedYtdlpEnabled {
                ytdlpUpdateSection
            } else {
                ytdlpSourceSection
            }
            browserCookiesSection
            siteCookiesSection
            debugLogsSection
        }
        .siphonFormStyle()
        .padding()
    }

    private var debugLogsSection: some View {
        Section(siphonHeader: languageService.s("debugging_and_logs")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(languageService.s("app_and_download_logs"))
                        .font(.siphonStandardMedium)
                    Text(languageService.s("debug_logs_desc"))
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(languageService.s("view_debug_logs")) {
                    DebugLogWindowManager.shared.showDebugLogWindow()
                }
                // Secondary push buttons and menus drop the window's accent tint:
                // tinted, their label is accent text on tinted glass, which is
                // hard to read in Dark Mode. Untinted they use the system label.
                .tint(nil)
            }
        }
    }

    private var ytdlpSourceSection: some View {
        Section(siphonHeader: languageService.s("ytdlp_source")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let path = downloadManager.ytdlpService.ytdlpPath {
                        Text(path.path)
                            .font(.siphonMetadataMonoMedium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let version = appState.ytdlpVersion {
                            Text("\(languageService.s("version")): \(version)")
                                .font(.siphonMetadataMonoMedium)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(languageService.s("ytdlp_missing"))
                            .font(.siphonStandardMedium)
                    }
                    Text(languageService.s("ytdlp_source_hint"))
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !customYtdlpPath.isEmpty {
                    Button(languageService.s("ytdlp_auto_detect")) {
                        guard downloadManager.activeExecutionCount == 0 else { return }
                        customYtdlpPath = ""
                        reloadYtdlp()
                    }
                    .tint(nil)
                    .disabled(downloadManager.activeExecutionCount > 0)
                }
                Button(languageService.s("ytdlp_choose")) {
                    selectYtdlp()
                }
                .tint(nil)
                .disabled(downloadManager.activeExecutionCount > 0)
            }
        }
    }

    private var ytdlpUpdateSection: some View {
        Section(siphonHeader: languageService.s("ytdlp_update")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("yt-dlp")
                        .font(.siphonStandardMedium)
                    if let version = appState.ytdlpVersion {
                        Text("\(languageService.s("version")): \(version)")
                            .font(.siphonMetadataMonoMedium)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if appState.isUpdatingYtdlp {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: max(0, min(1, appState.ytdlpUpdateProgress)))
                            .frame(width: 120)
                        Text("\(Int(appState.ytdlpUpdateProgress * 100))%")
                            .font(.siphonMicroMonoSemibold)
                            .foregroundColor(.secondary)
                    }
                } else if downloadManager.activeExecutionCount > 0 {
                    Text(languageService.s("ytdlp_update_blocked_active"))
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else if let message = appState.ytdlpUpdateMessage?.message {
                    Text(message)
                        .font(.siphonMetadata)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    Button(languageService.s("update_now")) {
                        updateYtdlp()
                    }
                    .tint(nil)
                }
            }
        }
    }

    private var browserCookiesSection: some View {
        Section(siphonHeader: languageService.s("browser_cookies")) {
            SiphonMenuPicker(
                languageService.s("browser"), selection: $browserForCookies,
                options: [(value: "none", title: languageService.s("none"))]
                    + installedBrowsers.map { browser in (value: browser.id, title: browser.displayName) }
            )
            .accessibilityLabel(languageService.s("browser_cookies"))

            VStack(alignment: .leading, spacing: 8) {
                Text(languageService.s("browser_hint"))
                    .font(.siphonMetadata)
                    .foregroundColor(.secondary)

                if browserForCookies == "safari" {
                    safariWarningView
                } else if browserForCookies == "helium" || browserForCookies == "chromium-based" {
                    chromiumHintView
                }
            }
        }
    }

    private var chromiumHintView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundColor(SiphonTheme.accentText)
                    .font(.siphonStandard)
                Text(languageService.s("chromium_extension_supported"))
                    .font(.siphonMetadataSemibold)
                    .foregroundColor(SiphonTheme.accentText)
            }
            Text(languageService.s("chromium_hint"))
                .font(.siphonMetadata)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .siphonCallout(tint: SiphonTheme.accent)
    }

    private var safariWarningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasFullDiskAccess {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(SiphonTheme.statusCompletedText)
                        .font(.siphonStandard)
                    Text(languageService.s("safari_fda_granted_feedback"))
                        .font(.siphonMetadataSemibold)
                        .foregroundColor(SiphonTheme.statusCompletedText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .siphonCallout(tint: SiphonTheme.statusCompleted)
            } else {
                Text(languageService.s("safari_warning"))
                    .font(.siphonMetadata)
                    .foregroundColor(SiphonTheme.statusQueuedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button(languageService.s("open_system_settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.siphonPrimary)
                    .controlSize(.small)

                    Button {
                        performPermissionCheck()
                    } label: {
                        HStack(spacing: 4) {
                            if isCheckingPermission {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(languageService.s("check_permission"))
                        }
                    }
                    .buttonStyle(.siphonSecondary)
                    .controlSize(.small)
                    .tint(nil)
                    .disabled(isCheckingPermission)

                    Button(languageService.s("restart_siphon")) {
                        updateChecker.restartApp()
                    }
                    .buttonStyle(.siphonSecondary)
                    .controlSize(.small)
                    .tint(nil)
                }

                permissionFeedbackView

                Text(languageService.s("safari_fda_restart_hint"))
                    .font(.siphonMetadata)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func performPermissionCheck() {
        isCheckingPermission = true
        let granted = YtdlpService.hasFullDiskAccess
        hasFullDiskAccess = granted
        if granted {
            downloadManager.ytdlpService.resetCookieDenial(for: "safari")
        }
        isCheckingPermission = false
        withAnimation(SiphonAnimation.snappySpring) {
            if granted {
                permissionCheckMessage = languageService.s("safari_fda_granted_feedback")
            } else {
                permissionCheckMessage = languageService.s("safari_fda_not_detected_hint")
            }
        }
    }

    @ViewBuilder
    private var permissionFeedbackView: some View {
        if let message = permissionCheckMessage {
            permissionFeedbackContent(message: message)
        }
    }

    @ViewBuilder
    private func permissionFeedbackContent(message: String) -> some View {
        let statusColor: Color = hasFullDiskAccess ? SiphonTheme.statusCompleted : SiphonTheme.statusQueued
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(hasFullDiskAccess ? SiphonTheme.statusCompletedText : SiphonTheme.statusQueuedText)
                .font(.siphonMetadata)
            Text(message)
                .font(.siphonMetadata)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .siphonCallout(tint: statusColor)
    }

    @ViewBuilder
    private var siteCookiesSection: some View {
        Section(siphonHeader: languageService.s("site_sessions")) {
            allSitesCookieRow
        }
    }

    private var allSitesCookieRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(languageService.s("all_sites_cookies_title"))
                    .font(.siphonStandardMedium)
                Text(languageService.s("all_sites_cookies_desc"))
                    .font(.siphonMetadata)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isClearingAllSites {
                ProgressView()
                    .controlSize(.small)
            } else if showAllSitesClearedFeedback {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .foregroundColor(SiphonTheme.statusCompletedText)
                    Text(languageService.s("cleared"))
                        .font(.siphonMetadataSemibold)
                        .foregroundColor(SiphonTheme.statusCompletedText)
                }
            } else {
                Button(languageService.s("clear_all")) {
                    showClearAllSitesConfirmation = true
                }
                .tint(nil)
                .accessibilityLabel(languageService.s("clear_all"))
            }
        }
    }

    private func clearAllSitesCookies() {
        guard !isClearingAllSites else { return }
        isClearingAllSites = true
        Task {
            await downloadManager.ytdlpService.clearAllProtectedSitesWebData()
            isClearingAllSites = false
            withAnimation(SiphonAnimation.snappySpring) {
                showAllSitesClearedFeedback = true
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(SiphonAnimation.snappySpring) {
                showAllSitesClearedFeedback = false
            }
        }
    }

    private var aboutTab: some View {
        VStack(spacing: 0) {
            VStack(spacing: SiphonTheme.spacing8) {
                RadiantSiphonLogoView()
                    .accessibilityHidden(true)

                VStack(spacing: SiphonTheme.spacing4) {
                    Text("Siphon")
                        .font(.siphonSheetTitle)

                    SiphonTagBadge(
                        text: "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.5.0")",
                        tintColor: SiphonTheme.accent,
                        isMonospaced: true
                    )
                }

                Text(languageService.s("app_desc"))
                    .font(.siphonSecondary)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SiphonTheme.spacing20)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Form {
                Section(siphonHeader: languageService.s("credits")) {
                    HStack {
                        Text(languageService.s("maintainer"))
                            .font(.siphonStandardMedium)
                        Spacer()
                        Text("marspater")
                            .font(.siphonSecondaryMedium)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text(languageService.s("video_downloading"))
                            .font(.siphonStandardMedium)
                        Spacer()
                        Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp") ?? URL(fileURLWithPath: "/"))
                            .font(.siphonSecondarySemibold)
                            .foregroundColor(SiphonTheme.accentForeground(for: colorScheme))
                    }
                }

                Section(siphonHeader: languageService.s("legal_disclaimer_title")) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(SiphonTheme.statusQueuedText)
                            .font(.siphonStandard)
                            .padding(.top, 1)

                        Text(languageService.s("legal_disclaimer_message"))
                            .font(.siphonMetadata)
                            .foregroundColor(.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(languageService.s("license"))
                                .font(.siphonStandardMedium)
                            Spacer()
                            Text("GNU GPL v3.0")
                                .font(.siphonSecondaryMedium)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text(languageService.s("license_desc"))
                                .font(.siphonMetadata)
                                .foregroundColor(.secondary)
                            Spacer()
                            Link(languageService.s("view_license"), destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html") ?? URL(fileURLWithPath: "/"))
                                .font(.siphonMetadataMedium)
                                .foregroundColor(SiphonTheme.accentText)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .siphonFormStyle()
            .padding(.horizontal)

            VStack(spacing: 12) {
                HStack(spacing: SiphonTheme.spacing10) {
                    Link(destination: URL(string: "https://github.com/marspater/jolly-hopper") ?? URL(fileURLWithPath: "/")) {
                        Label("GitHub", systemImage: "link")
                            .font(.siphonMetadataSemibold)
                            .foregroundColor(SiphonTheme.accentText)
                            .padding(.horizontal, SiphonTheme.spacing12)
                            .padding(.vertical, 6)
                            .siphonInteractiveGlass(cornerRadius: SiphonTheme.radiusControl)
                    }
                    .buttonStyle(.plain)

                    Link(destination: URL(string: "https://github.com/marspater/jolly-hopper/blob/main/README.md") ?? URL(fileURLWithPath: "/")) {
                        Label("README", systemImage: "doc.text")
                            .font(.siphonMetadataSemibold)
                            .foregroundColor(SiphonTheme.accentText)
                            .padding(.horizontal, SiphonTheme.spacing12)
                            .padding(.vertical, 6)
                            .siphonInteractiveGlass(cornerRadius: SiphonTheme.radiusControl)
                    }
                    .buttonStyle(.plain)

                    Link(destination: URL(string: "https://github.com/marspater/jolly-hopper/blob/main/SUPPORTED_SITES.md") ?? URL(fileURLWithPath: "/")) {
                        Label(languageService.s("supported_sites"), systemImage: "globe")
                            .font(.siphonMetadataSemibold)
                            .foregroundColor(SiphonTheme.accentText)
                            .padding(.horizontal, SiphonTheme.spacing12)
                            .padding(.vertical, 6)
                            .siphonInteractiveGlass(cornerRadius: SiphonTheme.radiusControl)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                Text("© 2026 marspater")
                    .font(.siphonMetadata)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .padding(.bottom, 12)
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

    private func selectYtdlp() {
        guard downloadManager.activeExecutionCount == 0 else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        // Unix executables have no extension filter; dot-dirs hold pipx/venv builds.
        panel.showsHiddenFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            customYtdlpPath = url.path
            reloadYtdlp()
        }
    }

    private func reloadYtdlp() {
        Task {
            await appState.reloadYtdlp(using: downloadManager.ytdlpService,
                                       activeExecutionCount: downloadManager.activeExecutionCount)
        }
    }

    private func updateYtdlp() {
        Task {
            await appState.updateYtdlp(
                using: downloadManager.ytdlpService,
                activeExecutionCount: downloadManager.activeExecutionCount,
                languageService: languageService
            )
        }
    }
}

#Preview {
    PreferencesView()
}
