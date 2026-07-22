import Foundation
import AppKit
import Combine


@MainActor
class DownloadManager: ObservableObject {

    @Published var downloads: [Download] = []
    @Published var history: [HistoricDownload] = []
    @Published var showDisclaimer: Bool = false
    @Published var ytdlpVersion: String?
    @Published var showWhatsNew: Bool = false
    @Published var ytdlpUpdateMessage: YtdlpUpdateMessage?
    @Published var isUpdatingYtdlp: Bool = false
    @Published var ytdlpUpdateProgress: Double = 0


    let ytdlpService = YtdlpService()


    private let maxConcurrentDownloads = 3
    private let userDefaults = UserDefaults.standard
    private var activeProcesses: [UUID: Process] = [:]
    private var languageService: LanguageService?
    private var failedDownloadsMap: [UUID: Download] = [:]

    init() {
        ytdlpService.$isUpdating
            .assign(to: &$isUpdatingYtdlp)
        ytdlpService.$updateProgress
            .assign(to: &$ytdlpUpdateProgress)
    }

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


        if !userDefaults.bool(forKey: UserDefaultsKeys.disclaimerAcknowledged) && !languageService.isFirstLaunch {
            showDisclaimer = true
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.0.0"
        let lastSeenVersion = userDefaults.string(forKey: UserDefaultsKeys.lastSeenVersion) ?? "0.0.0"

        if currentVersion != lastSeenVersion {
            showWhatsNew = true
            userDefaults.set(currentVersion, forKey: UserDefaultsKeys.lastSeenVersion)
        }
    }

    func acknowledgeDisclaimer() {
        userDefaults.set(true, forKey: UserDefaultsKeys.disclaimerAcknowledged)
        showDisclaimer = false
    }

    func updateYtdlp() async {
        guard !isUpdatingYtdlp else { return }
        ytdlpUpdateMessage = nil
        do {
            let installedVersion = try await ytdlpService.updateYtdlp()
            ytdlpVersion = installedVersion
            ytdlpUpdateMessage = YtdlpUpdateMessage(
                title: "yt-dlp Updated",
                message: "Installed yt-dlp version \(installedVersion)."
            )
            NotificationService.shared.sendYtdlpUpdateSucceeded(version: installedVersion)
        } catch {
            let reason = error.localizedDescription
            ytdlpUpdateMessage = YtdlpUpdateMessage(
                title: "yt-dlp Update Failed",
                message: reason
            )
            NotificationService.shared.sendYtdlpUpdateFailed(reason: reason)
        }
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
        let defaultPath = userDefaults.string(forKey: UserDefaultsKeys.defaultSaveFolder) ?? ""
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
        let defaultPath = userDefaults.string(forKey: UserDefaultsKeys.defaultSaveFolder) ?? ""
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

        updateStatus(for: download, to: .fetching)
        objectWillChange.send()

        do {

            let info = try await ytdlpService.fetchInfo(url: download.url)

            download.title = info.title
            download.duration = info.durationString
            download.thumbnailURL = info.thumbnailURL
            updateStatus(for: download, to: .downloading)
            objectWillChange.send()


            LoggerService.shared.log("Starting download for URL: \(download.url)", level: .info)
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
                    download.progress = max(0, min(1, progress))
                    download.speed = speed
                    download.eta = eta
                },
                onOutput: { line in
                    download.log += line + "\n"
                }
            )

            activeProcesses.removeValue(forKey: download.id)

            download.filePath = outputPath
            updateStatus(for: download, to: .completed)
            download.progress = 1.0
            objectWillChange.send()

            LoggerService.shared.log("Download completed successfully: \(download.title.isEmpty ? download.url : download.title)", level: .info)

            addToHistory(download)

            // Send notification
            if let lang = languageService {
                NotificationService.shared.sendDownloadCompleted(filename: download.title.isEmpty ? download.url : download.title, languageService: lang)
            }

        } catch let error as YtdlpError {
            updateStatus(for: download, to: .failed)
            objectWillChange.send()
            if let lang = languageService {
                switch error {
                case .tooManyRequests:
                    download.errorMessage = lang.s("too_many_requests")
                case .cloudflareBlocked:
                    download.errorMessage = "Blocked by Cloudflare anti-bot protection. Please select your browser as cookie source in Settings > Advanced and try again."
                case .boyfriendTVNeedsBrowserCookies:
                    download.errorMessage = "boyfriend.tv often requires signed-in browser cookies. Open Settings > Advanced > Browser Cookies, choose your browser, then try again."
                case .subtitleError(let details):
                    download.errorMessage = String(format: lang.s("subtitle_download_failed"), details)
                case .downloadFailed(let reason):
                    if download.url.lowercased().contains("boyfriendtv.com") {
                        download.errorMessage = "boyfriend.tv often requires signed-in browser cookies. Open Settings > Advanced > Browser Cookies, choose your browser, then try again."
                    } else if reason.contains("Cloudflare") || reason.contains("403") {
                        download.errorMessage = "Blocked by Cloudflare. Please select your browser as cookie source in Settings > Advanced and try again."
                    } else {
                        download.errorMessage = String(format: lang.s("download_failed_error"), reason)
                    }
                default:
                    download.errorMessage = error.localizedDescription
                }

                LoggerService.shared.log("Download failed (\(download.url)): \(download.errorMessage ?? error.localizedDescription)", level: .error)
                // Send notification for failure
                NotificationService.shared.sendDownloadFailed(filename: download.title.isEmpty ? download.url : download.title, languageService: lang)

            } else {
                download.errorMessage = error.localizedDescription
                LoggerService.shared.log("Download failed (\(download.url)): \(error.localizedDescription)", level: .error)
            }
            addToHistory(download)
        } catch {
            updateStatus(for: download, to: .failed)
            objectWillChange.send()
            download.errorMessage = error.localizedDescription
            LoggerService.shared.log("Download failed with error (\(download.url)): \(error.localizedDescription)", level: .error)

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
        updateStatus(for: download, to: .stopped)
        objectWillChange.send()
        addToHistory(download)
    }


    func retryDownload(_ download: Download) {
        updateStatus(for: download, to: .queued)
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
            updateStatus(for: download, to: .stopped)
        }
        objectWillChange.send()
    }


    func retryFailedDownloads() {
        for download in failedDownloadsMap.values {
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
        if items.isEmpty { return }

        let itemIds = Set(items.map { $0.id })

        for item in items {
            stopDownload(item)

            // Asenkron temizlik: Prosesin tamamen durması ve dosya kilitlerinin kalkması için kısa bir süre bekle
            let downloadCopy = item
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms bekle
                cleanupTemporaryFiles(for: downloadCopy)
            }
            failedDownloadsMap.removeValue(forKey: item.id)
        }

        downloads.removeAll { itemIds.contains($0.id) }
        history.removeAll { itemIds.contains($0.id) }
        saveHistory()
    }


    func removeDownload(_ download: Download) {
        clearDownloads([download])
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
            LoggerService.shared.log("Error cleaning up files: \(error)", level: .error)
        }
    }



    private func loadHistory() {
        if let data = userDefaults.data(forKey: UserDefaultsKeys.downloadHistory),
           let decoded = try? JSONDecoder().decode([HistoricDownload].self, from: data) {
            history = decoded
            // Restore as Download objects for UI, reversing so newest is at the top
            let restored = decoded.reversed().map { $0.toDownload() }
            downloads.append(contentsOf: restored)

            for download in restored {
                if download.status == .failed {
                    failedDownloadsMap[download.id] = download
                }
            }
        }
    }

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(history) {
            userDefaults.set(encoded, forKey: UserDefaultsKeys.downloadHistory)
        }
    }

    private func addToHistory(_ download: Download) {
        let historic = HistoricDownload(download: download)

        // Remove existing if any (upsert)
        if let index = history.firstIndex(where: { $0.id == download.id }) {
            history.remove(at: index)
        }
        history.append(historic)

        if history.count > 500 { // Increased limit for better user experience
            history.removeFirst(history.count - 500)
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

    private func updateStatus(for download: Download, to status: DownloadStatus) {
        download.status = status
        if status == .failed {
            failedDownloadsMap[download.id] = download
        } else {
            failedDownloadsMap.removeValue(forKey: download.id)
        }
    }
}


struct YtdlpUpdateMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
