import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var languageService: LanguageService
    @State private var url: String = ""
    @State private var selectedType: String = "video"
    @State private var selectedPreset: String = "max_compatibility"
    @AppStorage("customPresets") private var customPresetsData: Data = Data()
    
    private var customPresets: [CustomPreset] {
        CustomPreset.loadAll()
    }
    
    var body: some View {
        VStack(spacing: 16) {
            header
            
            VStack(alignment: .leading, spacing: 12) {
                urlInput
                optionsList
            }
            
            downloadButton
            
            Divider()
            
            footer
        }
        .padding()
        .frame(width: 320)
        .background(VisualEffectView(material: .menu, blendingMode: .behindWindow).ignoresSafeArea())
        .onChange(of: selectedType) { newValue in
            if newValue == "audio" {
                selectedPreset = "audio_only"
            } else {
                selectedPreset = "max_compatibility"
            }
        }
    }
    
    private var header: some View {
        HStack {
            // Using AppIcon might be too large or not intended for small display, 
            // but let's use a nice styled circle with M or a better icon if available.
            // For now, let's use the actual app Icon if possible or a stylized version.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            
            Text("Macabolic")
                .font(.system(size: 18, weight: .bold))
            
            Spacer()
            
            Button {
                MenuBarManager.shared.closePopover()
                // Restore dock icon when showing main window
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                // If the app has no window, we might need to show it via AppDelegate/App methods
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.className != "NSStatusBarWindow" }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    // This is a bit tricky in SwiftUI without a reference to the window group, 
                    // but usually openURL with macabolic:// triggers it.
                    if let url = URL(string: "macabolic://show") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help(languageService.s("show_main_window"))
        }
    }
    
    private var urlInput: some View {
        HStack {
            TextField(languageService.s("url_hint"), text: $url)
                .textFieldStyle(.roundedBorder)
            
            Button {
                if let clipboard = NSPasteboard.general.string(forType: .string) {
                    url = clipboard
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .help(languageService.s("paste_from_clipboard"))
        }
    }
    
    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(languageService.s("format") + ":")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
                
                Picker("", selection: $selectedType) {
                    Text(languageService.s("video")).tag("video")
                    Text(languageService.s("audio")).tag("audio")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            
            HStack {
                Text(languageService.s("preset") + ":")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
                
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
                .controlSize(.small)
                .labelsHidden()
            }
        }
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
                        subtitleLanguages: [preset.subtitleLanguage ?? "en"],
                        subtitleFormat: preset.subtitleFormat ?? .srt,
                        embedSubtitles: preset.downloadSubtitles ?? false,
                        downloadThumbnail: true,
                        embedThumbnail: true,
                        embedMetadata: true,
                        splitChapters: preset.splitChapters ?? false,
                        sponsorBlock: preset.sponsorBlock ?? false,
                        timeFrameStart: nil,
                        timeFrameEnd: nil,
                        customFilename: nil,
                        videoCodec: preset.videoCodec,
                        audioCodec: preset.audioCodec,
                        forceOverwrite: false,
                        additionalArguments: preset.additionalArguments
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
                    subtitleLanguages: ["en", "tr"],
                    subtitleFormat: .srt,
                    embedSubtitles: false,
                    downloadThumbnail: true,
                    embedThumbnail: true,
                    embedMetadata: true,
                    splitChapters: false,
                    sponsorBlock: true,
                    timeFrameStart: nil,
                    timeFrameEnd: nil,
                    customFilename: nil,
                    videoCodec: preset.videoCodec,
                    audioCodec: preset.audioCodec,
                    forceOverwrite: false,
                    additionalArguments: nil
                ))
            }
            
            url = ""
            MenuBarManager.shared.closePopover()
        } label: {
            HStack {
                Image(systemName: "arrow.down.to.line.compact")
                Text(languageService.s("download_btn"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(url.isEmpty)
    }
    
    private func getSaveFolder() -> URL {
        let defaultPath = UserDefaults.standard.string(forKey: "defaultSaveFolder") ?? ""
        return defaultPath.isEmpty ? 
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first! :
            URL(fileURLWithPath: defaultPath)
    }
    
    private var footer: some View {
        HStack {
            Button(languageService.s("quit")) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            
            Spacer()
            
            if downloadManager.downloadingDownloads.count > 0 {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(downloadManager.downloadingDownloads.count) \(languageService.s("downloading"))")
                        .font(.caption2)
                }
            }
        }
    }
}
