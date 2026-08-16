import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @State private var url: String = ""
    @State private var selectedType: String = "video"
    @State private var selectedPreset: String = "best_quality"
    @AppStorage(UserDefaultsKeys.theme) private var theme: String = "system"
    @AppStorage("customPresets") private var customPresetsData: Data = Data()
    
    // Bug #11 fix: Use State to prevent heavy computation in View body
    @State private var customPresets: [CustomPreset] = []
    
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 10) {
                urlInput
                optionsCard
            }
            
            downloadButton
            
            Divider()
                .opacity(0.5)
            
            footer
        }
        .padding(14)
        .frame(width: 360)
        .preferredColorScheme(theme == "light" ? .light : (theme == "dark" ? .dark : nil))
        .background(.ultraThinMaterial)
        .onAppear {
            customPresets = CustomPreset.loadAll()
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
    
    private var urlInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            TextField(languageService.s("url_hint"), text: $url)
                .textFieldStyle(.plain)
                .font(.geist(12))
            
            Button {
                if let clipboard = NSPasteboard.general.string(forType: .string) {
                    url = clipboard
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(languageService.s("paste_from_clipboard"))
            .accessibilityLabel(languageService.s("paste_from_clipboard"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var optionsCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text(languageService.s("format"))
                    .font(.geist(12, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Picker("", selection: $selectedType) {
                    Text(languageService.s("video")).tag("video")
                    Text(languageService.s("audio")).tag("audio")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            
            Divider()
                .opacity(0.4)
            
            HStack {
                Text(languageService.s("preset"))
                    .font(.geist(12, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
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
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
    
    private var downloadButton: some View {
        Button {
            guard !url.isEmpty else { return }
            
            if selectedPreset.hasPrefix("custom_") {
                let idString = String(selectedPreset.dropFirst(7))
                if let preset = customPresets.first(where: { $0.id.uuidString == idString }) {
                    downloadManager.addDownload(url: url, options: DownloadOptions(
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
                downloadManager.addDownload(url: url, options: DownloadOptions(
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
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                Text(languageService.s("download_btn"))
                    .font(.geist(13, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(url.isEmpty)
        .shadow(color: .blue.opacity(url.isEmpty ? 0.0 : 0.2), radius: 6, y: 2)
    }
    
    private func getSaveFolder() -> URL {
        let defaultPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultSaveFolder) ?? ""
        return defaultPath.isEmpty ? 
            (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")) :
            URL(fileURLWithPath: defaultPath)
    }
    
    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                MenuBarManager.shared.closePopover()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.className != "NSStatusBarWindow" }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    if let url = URL(string: "siphon://show") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11, weight: .semibold))
                    Text(languageService.s("show_main_window"))
                        .font(.geist(11, weight: .medium))
                        .lineLimit(1)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(languageService.s("show_main_window"))
            .accessibilityLabel(languageService.s("show_main_window"))
            
            if downloadManager.downloadingDownloads.count > 0 {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                    Text("\(downloadManager.downloadingDownloads.count)")
                        .font(.geist(11, weight: .bold))
                        .monospacedDigit()
                    Text(languageService.s("downloading"))
                        .font(.geist(11, weight: .medium))
                        .lineLimit(1)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.accentColor)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                )
            }
            
            Spacer(minLength: 0)
            
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                    Text(languageService.s("quit"))
                        .font(.geist(11, weight: .semibold))
                        .lineLimit(1)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(.red)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.red.opacity(0.12))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.red.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(languageService.s("quit"))
            .accessibilityLabel(languageService.s("quit"))
        }
    }
}
