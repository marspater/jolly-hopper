import Foundation
import AppKit


@MainActor
class DownloadManager: ObservableObject {

    @Published var downloads: [Download] = []
    @Published var history: [HistoricDownload] = []
    @Published var showDisclaimer: Bool = false
    @Published var ytdlpVersion: String?
    @Published var showWhatsNew: Bool = false
    

    let ytdlpService = YtdlpService()
    

    private let maxConcurrentDownloads = 3
    private let userDefaults = UserDefaults.standard
    private var activeProcesses: [UUID: Process] = [:]
    private var languageService: LanguageService?
    

    
    var downloadingDownloads: [Download] {
        downloads.filter { $0.status == .downloading || $0.status == .fetching || $0.status == .processing }
    }
    
    var queuedDownloads: [Download] {
        downloads.filter { $0.status == .queued }
    }
    
    var completedDownloads: [Download] {
        downloads.filter { $0.status == .completed }
    }

    var failedDownloads: [Download] {
        downloads.filter { $0.status == .failed || $0.status == .stopped }
    }
    
    var downloadingCount: Int { downloadingDownloads.count }
    var queuedCount: Int { queuedDownloads.count }
    var completedCount: Int { completedDownloads.count }
    var failedCount: Int { failedDownloads.count }
    

    
    func initialize(languageService: LanguageService) async {
        self.languageService = languageService

        await ytdlpService.setupBinaries()
        // Wait a bit for version to be populated if needed, or better, fetch it explicitly
        await ytdlpService.getVersion()
        ytdlpVersion = ytdlpService.version
        

        loadHistory()
        

        if !userDefaults.bool(forKey: "disclaimerAcknowledged") && !languageService.isFirstLaunch {
            showDisclaimer = true
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.1.0"
        let lastSeenVersion = userDefaults.string(forKey: "lastSeenVersion_v3") ?? "0.0.0"
        
        if currentVersion != lastSeenVersion {
            showWhatsNew = true
            userDefaults.set(currentVersion, forKey: "lastSeenVersion_v3")
        }
    }
    
    func acknowledgeDisclaimer() {
        userDefaults.set(true, forKey: "disclaimerAcknowledged")
        showDisclaimer = false
    }
    

    

    func addDownload(url: String, options: DownloadOptions) {
        let download = Download(url: url, options: options)
        downloads.append(download)
        
        Task {
            await processDownload(download)
        }
    }
    

    func addDownloads(urls: [String], options: DownloadOptions) {
        for url in urls {
            addDownload(url: url, options: options)
        }
    }
    
    func menuDownload(url: String, type: String, quality: String) {
        // Get default save folder
        let defaultPath = userDefaults.string(forKey: "defaultSaveFolder") ?? ""
        let folder = defaultPath.isEmpty ? 
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first! :
            URL(fileURLWithPath: defaultPath)
            
        let options = DownloadOptions(
            saveFolder: folder,
            fileType: type == "video" ? .mp4 : .m4a,
            videoFormat: nil,
            audioFormat: nil,
            videoResolution: type == "video" ? (quality == "best" ? .best : (quality == "1080" ? .r1080p : .r720p)) : .worst,
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
            videoCodec: type == "video" ? .auto : .none,
            audioCodec: .auto,
            forceOverwrite: false,
            additionalArguments: nil
        )
        addDownload(url: url, options: options)
    }
    
    func quickDownload(url: String) {
        let preset = DownloadPreset.maxCompatibility
        
        // Get default save folder from AppStorage
        let defaultPath = userDefaults.string(forKey: "defaultSaveFolder") ?? ""
        let saveFolderURL: URL
        if !defaultPath.isEmpty {
            saveFolderURL = URL(fileURLWithPath: defaultPath)
        } else {
            saveFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        }
        
        let options = DownloadOptions(
            saveFolder: saveFolderURL,
            fileType: preset.fileType,
            downloadSubtitles: false,
            subtitleLanguages: ["tr", "en"],
            subtitleFormat: .srt,
            embedSubtitles: false,
            downloadThumbnail: false,
            embedThumbnail: true,
            embedMetadata: true,
            splitChapters: false,
            sponsorBlock: false,
            forceOverwrite: false
        )
        addDownload(url: url, options: options)
    }
    

    
    private func processDownload(_ download: Download) async {

        while downloadingCount >= maxConcurrentDownloads {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        download.status = .fetching
        objectWillChange.send()
        
        do {

            let info = try await ytdlpService.fetchInfo(url: download.url)
            
            download.title = info.title
            download.duration = info.durationString
            download.thumbnailURL = info.thumbnailURL
            download.status = .downloading
            objectWillChange.send()
            

            let outputPath = try await ytdlpService.download(
                url: download.url,
                options: download.options,
                onProcessCreated: { [weak self] process in
                    Task { @MainActor in
                        guard let self = self else { return }
                        // If the download finished before this Task ran, don't add it
                        if let d = self.downloads.first(where: { $0.id == download.id }),
                           d.status == .downloading || d.status == .fetching || d.status == .processing {
                            self.activeProcesses[download.id] = process
                        }
                    }
                },
                onProgress: { progress, speed, eta in
                    download.progress = progress
                    download.speed = speed
                    download.eta = eta
                },
                onOutput: { line in
                    download.log += line + "\n"
                }
            )
            
            activeProcesses.removeValue(forKey: download.id)
            
            download.filePath = outputPath
            download.status = .completed
            download.progress = 1.0
            objectWillChange.send()
            

            addToHistory(download)
            
            // Send notification
            if let lang = languageService {
                NotificationService.shared.sendDownloadCompleted(filename: download.title.isEmpty ? download.url : download.title, languageService: lang)
            }
            
        } catch let error as YtdlpError {
            download.status = .failed
            objectWillChange.send()
            if let lang = languageService {
                switch error {
                case .tooManyRequests:
                    download.errorMessage = lang.s("too_many_requests")
                case .subtitleError(let details):
                    download.errorMessage = String(format: lang.s("subtitle_download_failed"), details)
                case .downloadFailed(let reason):
                    download.errorMessage = String(format: lang.s("download_failed_error"), reason)
                default:
                    download.errorMessage = error.localizedDescription
                }
                
                // Send notification for failure
                NotificationService.shared.sendDownloadFailed(filename: download.title.isEmpty ? download.url : download.title, languageService: lang)
                
            } else {
                download.errorMessage = error.localizedDescription
            }
            addToHistory(download)
        } catch {
            download.status = .failed
            objectWillChange.send()
            download.errorMessage = error.localizedDescription
            
            if let lang = languageService {
                NotificationService.shared.sendDownloadFailed(filename: download.title.isEmpty ? download.url : download.title, languageService: lang)
            }
            
            addToHistory(download)
        }
    }
    

    

    func stopDownload(_ download: Download) {
        if let process = activeProcesses[download.id] {
            process.terminate()
            activeProcesses.removeValue(forKey: download.id)
        }
        download.status = .stopped
        objectWillChange.send()
        addToHistory(download)
    }
    

    func retryDownload(_ download: Download) {
        download.status = .queued
        download.progress = 0
        objectWillChange.send()
        download.errorMessage = nil
        download.log = ""
        
        Task {
            await processDownload(download)
        }
    }
    

    func stopAllDownloads() {
        for download in downloadingDownloads {
            stopDownload(download)
        }
        for download in queuedDownloads {
            download.status = .stopped
        }
        objectWillChange.send()
    }
    

    func retryFailedDownloads() {
        for download in downloads where download.status == .failed {
            retryDownload(download)
        }
    }
    

    func clearQueuedDownloads() {
        downloads.removeAll { $0.status == .queued }
    }
    

    func clearCompletedDownloads() {
        clearDownloads(completedDownloads + failedDownloads)
    }
    
    func clearDownloads(_ items: [Download]) {
        for item in items {
            removeDownload(item)
        }
    }
    

    func removeDownload(_ download: Download) {
        stopDownload(download)
        
        // Asenkron temizlik: Prosesin tamamen durması ve dosya kilitlerinin kalkması için kısa bir süre bekle
        let downloadCopy = download
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms bekle
            cleanupTemporaryFiles(for: downloadCopy)
        }
        
        downloads.removeAll { $0.id == download.id }
        history.removeAll { $0.id == download.id }
        saveHistory()
    }
    
    private func cleanupTemporaryFiles(for download: Download) {
        let fileManager = FileManager.default
        let folder = download.options.saveFolder
        
        // yt-dlp sanitization: Replace invalid characters with underscore
        let sanitize: (String) -> String = { input in
            let invalidChars = CharacterSet(charactersIn: "\\/:*?\"<>|")
            return input.components(separatedBy: invalidChars).joined(separator: "_")
        }
        
        // Extract video ID from URL if possible (common for YouTube)
        let videoId: String? = {
            if let url = URL(string: download.url),
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                return components.queryItems?.first(where: { $0.name == "v" })?.value ?? url.lastPathComponent
            }
            return nil
        }()
        
        let rawBaseName = download.options.customFilename ?? download.title
        let sanitizedBaseName = sanitize(rawBaseName)
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let tempExtensions = [".part", ".ytdl", ".webp", ".jpg", ".temp", ".vtt", ".srt", ".ass", ".f1", ".f2", ".f3"]
            
            for file in contents {
                let fileName = file.lastPathComponent
                
                // Kontrol kriterleri:
                // 1. Prefix eşleşmesi (Orijinal veya Sanitize edilmiş başlık)
                let matchesPrefix = fileName.hasPrefix(rawBaseName) || fileName.hasPrefix(sanitizedBaseName)
                
                // 2. ID eşleşmesi (Yt-dlp genellikle dosya adının sonuna [ID] ekler)
                let matchesId = videoId != nil && fileName.contains(videoId!)
                
                if matchesPrefix || matchesId {
                    let isTemp = tempExtensions.contains { ext in
                        fileName.lowercased().hasSuffix(ext)
                    }
                    if isTemp {
                        try? fileManager.removeItem(at: file)
                    }
                }
            }
        } catch {
            print("Error cleaning up files: \(error)")
        }
    }
    

    
    private func loadHistory() {
        if let data = userDefaults.data(forKey: "downloadHistory"),
           let decoded = try? JSONDecoder().decode([HistoricDownload].self, from: data) {
            history = decoded
            // Restore as Download objects for UI
            let restored = decoded.map { $0.toDownload() }
            downloads.append(contentsOf: restored)
        }
    }
    
    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(history) {
            userDefaults.set(encoded, forKey: "downloadHistory")
        }
    }
    
    private func addToHistory(_ download: Download) {
        let historic = HistoricDownload(download: download)
        
        // Remove existing if any (upsert)
        history.removeAll { $0.id == download.id }
        history.insert(historic, at: 0)
        
        if history.count > 500 { // Increased limit for better user experience
            history = Array(history.prefix(500))
        }
        
        saveHistory()
    }
    
    func clearHistory() {
        history.removeAll()
        saveHistory()
    }
    
    func removeFromHistory(_ download: HistoricDownload) {
        history.removeAll { $0.id == download.id }
        saveHistory()
    }
    

    
    func openFile(_ path: URL) {
        NSWorkspace.shared.open(path)
    }
    
    func showInFinder(_ path: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }
}
