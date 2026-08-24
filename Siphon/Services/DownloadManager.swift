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


    private var maxConcurrentDownloads: Int {
        let val = userDefaults.integer(forKey: UserDefaultsKeys.maxConcurrentDownloads)
        return val > 0 ? val : 3
    }
    private let userDefaults = UserDefaults.standard
    private var activeProcesses: [UUID: Process] = [:]
    private var activeCancellations: [UUID: CancellationBox] = [:]
    private var languageService: LanguageService?
    private var failedDownloadsMap: [UUID: Download] = [:]
    private var reservedOutputPaths: Set<String> = []

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
        downloads.filter { $0.status == .failed || $0.status == .stopped || $0.status == .fileExists }
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

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.2.0"
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
        // Bolt Performance Optimization: Batch array mutation to avoid synchronous UI broadcasts and redundant layout passes
        let newDownloads = urls.map { Download(url: $0, options: options) }
        downloads.append(contentsOf: newDownloads)

        for download in newDownloads {
            Task {
                await processDownload(download)
            }
        }
    }

    func menuDownload(url: String, type: String, quality: String) {
        // Get default save folder
        let defaultPath = userDefaults.string(forKey: UserDefaultsKeys.defaultSaveFolder) ?? ""
        let folder = defaultPath.isEmpty ?
            (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")) :
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
            downloadThumbnail: false,
            embedThumbnail: true,
            embedMetadata: true,
            splitChapters: false,
            sponsorBlock: true,
            timeFrameStart: nil,
            timeFrameEnd: nil,
            customFilename: nil,
            videoCodec: type == "video" ? .auto : .none,
            audioCodec: .auto,
            forceOverwrite: false
        )
        addDownload(url: url, options: options)
    }

    func quickDownload(url: String, rawCookies: String? = nil) {
        let preset = DownloadPreset.maxCompatibility

        // Get default save folder from AppStorage
        let defaultPath = userDefaults.string(forKey: UserDefaultsKeys.defaultSaveFolder) ?? ""
        let saveFolderURL: URL
        if !defaultPath.isEmpty {
            saveFolderURL = URL(fileURLWithPath: defaultPath)
        } else {
            saveFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        }

        var options = DownloadOptions(
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
        options.rawCookies = rawCookies
        addDownload(url: url, options: options)
    }



    private func processDownload(_ download: Download) async {

        while downloadingCount >= maxConcurrentDownloads {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Bug #2 fix: If user cancelled while queued, don't proceed
        guard download.status == .queued else { return }

        updateStatus(for: download, to: .fetching)
        objectWillChange.send()

        do {

            let info = try await ytdlpService.fetchInfo(url: download.url)

            // Bug #5 fix: If user cancelled during fetchInfo, don't proceed
            guard download.status == .fetching else { return }

            download.title = info.title
            download.duration = info.durationString
            download.thumbnailURL = info.thumbnailURL
            download.mediaInfo = info
            let sanitize: (String) -> String = { input in
                let invalidChars = CharacterSet(charactersIn: "\\/:*?\"<>|")
                return input.components(separatedBy: invalidChars).joined(separator: "_")
            }
            let rawBaseName = download.options.customFilename ?? download.title
            let sanitizedBaseName = sanitize(rawBaseName)
            
            let folderPath = download.options.saveFolder
            var resolvedBaseName = sanitizedBaseName
            var counter = 1
            var candidateKey = folderPath.appendingPathComponent("\(resolvedBaseName).\(download.options.fileType.fileExtension)").path
            while reservedOutputPaths.contains(candidateKey) {
                resolvedBaseName = "\(sanitizedBaseName)_\(counter)"
                candidateKey = folderPath.appendingPathComponent("\(resolvedBaseName).\(download.options.fileType.fileExtension)").path
                counter += 1
            }
            if resolvedBaseName != sanitizedBaseName {
                download.options.customFilename = resolvedBaseName
            }
            reservedOutputPaths.insert(candidateKey)
            defer {
                reservedOutputPaths.remove(candidateKey)
            }

            let fileExists = await Task.detached {
                if let contents = try? FileManager.default.contentsOfDirectory(at: folderPath, includingPropertiesForKeys: nil) {
                    let matches = contents.filter { file in
                        let nameWithoutExt = file.deletingPathExtension().lastPathComponent
                        let isExactMatch = nameWithoutExt == resolvedBaseName || nameWithoutExt == rawBaseName
                        let isPart = file.lastPathComponent.hasSuffix(".part") || file.lastPathComponent.hasSuffix(".ytdl")
                        return isExactMatch && !isPart
                    }
                    return !matches.isEmpty
                }
                return false
            }.value

            if fileExists && download.options.forceOverwrite != true {
                updateStatus(for: download, to: .fileExists)
                objectWillChange.send()
                return // Pause here. The UI will show a button to resume with forceOverwrite = true or add a number.
            }

            updateStatus(for: download, to: .downloading)
            objectWillChange.send()

            let cancelBox = CancellationBox()
            activeCancellations[download.id] = cancelBox
            defer {
                activeCancellations.removeValue(forKey: download.id)
            }

            LoggerService.shared.log("Starting download for URL: \(LoggerService.sanitizeURLForLog(download.url))", level: .info)
            let outputPath = try await ytdlpService.download(
                url: download.url,
                options: download.options,
                mediaInfo: download.mediaInfo,
                isCancelled: {
                    cancelBox.isCancelled
                },
                onProcessCreated: { [weak self, weak download] process in
                    Task { @MainActor in
                        guard let self = self, let download = download else { return }
                        if download.status == .stopped || cancelBox.isCancelled {
                            process.terminate()
                        } else {
                            self.activeProcesses[download.id] = process
                        }
                    }
                },
                onProgress: { progress, speed, eta in
                    // Bug #3 fix: Guard against NaN progress values
                    // Bug #4 fix: Dispatch to main actor for @Published property writes
                    let safeProgress = progress.isNaN ? 0 : max(0, min(1, progress))
                    DispatchQueue.main.async {
                        download.progress = safeProgress
                        download.speed = speed
                        download.eta = eta
                    }
                },
                onOutput: { line in
                    // Bug #4 fix: Dispatch to main actor for @Published property writes
                    DispatchQueue.main.async {
                        download.log += line + "\n"
                        if line.contains("[EmbedThumbnail]") || line.contains("[Metadata]") || line.contains("[Merger]") || line.contains("[VideoConvertor]") || line.contains("[ThumbnailsConvertor]") || line.contains("[EmbedSubtitle]") {
                            if download.status == .downloading {
                                download.status = .processing
                            }
                        }
                    }
                }
            )

            // Bug #7 fix: Always clean up process reference (moved from only success path)
            activeProcesses.removeValue(forKey: download.id)

            download.filePath = outputPath
            updateStatus(for: download, to: .completed)
            download.progress = 1.0
            objectWillChange.send()

            LoggerService.shared.log("Download completed successfully: \(download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title)", level: .info)

            addToHistory(download)

            // Send notification
            let lang = languageService ?? LanguageService()
            NotificationService.shared.sendDownloadCompleted(filename: download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title, languageService: lang)

        } catch let error as YtdlpError {
            // Bug #7 fix: Always clean up process reference on error
            activeProcesses.removeValue(forKey: download.id)

            if download.status == .stopped {
                LoggerService.shared.log("Download stopped by user (\(LoggerService.sanitizeURLForLog(download.url)))", level: .info)
                addToHistory(download)
                return
            }
            updateStatus(for: download, to: .failed)
            objectWillChange.send()

            let lang = languageService ?? LanguageService()
            switch error {
            case .tooManyRequests:
                download.errorMessage = lang.s("too_many_requests")
            case .cloudflareBlocked:
                download.errorMessage = "Blocked by Cloudflare anti-bot protection. Please select your browser as cookie source in Settings > Advanced and try again."
            case .boyfriendTVNeedsBrowserCookies:
                download.errorMessage = "This site requires signed-in browser cookies. Open Settings > Advanced > Browser Cookies, choose your browser, then try again."
            case .subtitleError(let details):
                download.errorMessage = String(format: lang.s("subtitle_download_failed"), details)
            case .downloadFailed(let reason):
                if reason.contains("Cloudflare") || reason.contains("403") {
                    download.errorMessage = "Blocked by anti-bot protection. Please select your browser as cookie source in Settings > Advanced and try again."
                } else {
                    download.errorMessage = String(format: lang.s("download_failed_error"), reason)
                }
            default:
                download.errorMessage = error.localizedDescription
            }

            LoggerService.shared.log("Download failed (\(LoggerService.sanitizeURLForLog(download.url))): \(download.errorMessage ?? error.localizedDescription)", level: .error)
            // Send notification for failure
            NotificationService.shared.sendDownloadFailed(filename: download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title, languageService: lang)
            addToHistory(download)
        } catch {
            // Bug #7 fix: Always clean up process reference on error
            activeProcesses.removeValue(forKey: download.id)

            if download.status == .stopped {
                LoggerService.shared.log("Download stopped by user (\(LoggerService.sanitizeURLForLog(download.url)))", level: .info)
                addToHistory(download)
                return
            }
            updateStatus(for: download, to: .failed)
            objectWillChange.send()
            download.errorMessage = error.localizedDescription
            LoggerService.shared.log("Download failed with error (\(LoggerService.sanitizeURLForLog(download.url))): \(error.localizedDescription)", level: .error)

            let lang = languageService ?? LanguageService()
            NotificationService.shared.sendDownloadFailed(filename: download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title, languageService: lang)

            addToHistory(download)
        }
    }




    func stopDownload(_ download: Download, suppressNotification: Bool = false, skipSaveAndBroadcast: Bool = false) {
        let previousStatus = download.status
        guard previousStatus == .downloading || previousStatus == .fetching || previousStatus == .processing || previousStatus == .queued else {
            return
        }
        updateStatus(for: download, to: .stopped)
        activeCancellations.removeValue(forKey: download.id)?.cancel()
        if let process = activeProcesses.removeValue(forKey: download.id) {
            process.terminate()
            Task.detached { [weak process] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let proc = process, proc.isRunning {
                    proc.terminate()
                }
            }
        }
        if !skipSaveAndBroadcast {
            objectWillChange.send()
        }
        addToHistory(download, skipSave: skipSaveAndBroadcast)

        let downloadCopy = download
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            cleanupTemporaryFiles(for: downloadCopy)
        }

        if !suppressNotification {
            let lang = languageService ?? LanguageService()
            NotificationService.shared.sendDownloadStopped(filename: download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title, languageService: lang)
        }
    }


    func retryDownload(_ download: Download) {
        guard download.status == .failed || download.status == .stopped || download.status == .fileExists else { return }
        updateStatus(for: download, to: .queued)
        download.progress = 0
        objectWillChange.send()
        download.errorMessage = nil
        download.log = ""

        Task {
            await processDownload(download)
        }
    }


    func resumeWithOverwrite(_ download: Download) {
        download.options.forceOverwrite = true
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        Task {
            await processDownload(download)
        }
    }
    
    func resumeWithNewName(_ download: Download) {
        let uniqueSuffix = " (\(Int(Date().timeIntervalSince1970) % 10000))"
        let base = download.options.customFilename ?? download.title
        download.options.customFilename = "\(base)\(uniqueSuffix)"
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        Task {
            await processDownload(download)
        }
    }
    
    func stopAllDownloads() {
        // Bolt Performance Optimization: Avoid synchronous disk I/O and redundant UI broadcasts inside loops by batching operations
        for download in downloadingDownloads {
            stopDownload(download, suppressNotification: false, skipSaveAndBroadcast: true)
        }
        for download in queuedDownloads {
            updateStatus(for: download, to: .stopped)
        }
        objectWillChange.send()
        saveHistory()
    }


    func retryFailedDownloads() {
        for download in failedDownloads {
            retryDownload(download)
        }
    }


    func clearQueuedDownloads() {
        for download in queuedDownloads {
            updateStatus(for: download, to: .stopped)
        }
        downloads.removeAll { $0.status == .stopped }
    }


    func clearCompletedDownloads() {
        clearDownloads(completedDownloads + failedDownloads)
    }

    func clearDownloads(_ items: [Download]) {
        if items.isEmpty { return }

        let itemIds = Set(items.map { $0.id })

        // Bolt Performance Optimization: Batch array mutations and broadcast once
        for item in items {
            if item.status == .downloading || item.status == .fetching || item.status == .processing || item.status == .queued {
                stopDownload(item, suppressNotification: true, skipSaveAndBroadcast: true)
            }
            failedDownloadsMap.removeValue(forKey: item.id)
        }

        downloads.removeAll { itemIds.contains($0.id) }
        history.removeAll { itemIds.contains($0.id) }
        objectWillChange.send()
        saveHistory()
    }


    func removeDownload(_ download: Download) {
        clearDownloads([download])
    }

    private func cleanupTemporaryFiles(for download: Download) {
        guard download.status == .stopped || download.status == .failed else { return }

        let folder = download.options.saveFolder
        let title = download.title
        let rawBaseName = download.options.customFilename ?? title
        let urlString = download.url

        Task.detached {
            let fileManager = FileManager.default
            
            let sanitize: (String) -> String = { input in
                let invalidChars = CharacterSet(charactersIn: "\\/:*?\"<>|")
                return input.components(separatedBy: invalidChars).joined(separator: "_")
            }

            let videoId: String? = {
                if let url = URL(string: urlString),
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    return components.queryItems?.first(where: { $0.name == "v" })?.value ?? url.lastPathComponent
                }
                return nil
            }()

            let sanitizedBaseName = sanitize(rawBaseName)

            do {
                let contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                
                for file in contents {
                    let fileName = file.lastPathComponent

                    let matchesPrefix = (!rawBaseName.isEmpty && fileName.hasPrefix(rawBaseName)) || (!sanitizedBaseName.isEmpty && fileName.hasPrefix(sanitizedBaseName))
                    let matchesId: Bool
                    if let vid = videoId, !vid.isEmpty {
                        matchesId = fileName.contains(vid)
                    } else {
                        matchesId = false
                    }

                    if matchesPrefix || matchesId {
                        let lower = fileName.lowercased()
                        let isTemp = lower.contains(".part") ||
                                     lower.contains(".ytdl") ||
                                     lower.contains(".temp") ||
                                     lower.contains(".tmp") ||
                                     (lower.range(of: #"\.f\d+\."#, options: .regularExpression) != nil)

                        if isTemp {
                            try? fileManager.removeItem(at: file)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    LoggerService.shared.log("Error cleaning up files: \(error)", level: .error)
                }
            }
        }
    }



    func loadHistory() {
        if let data = userDefaults.data(forKey: UserDefaultsKeys.downloadHistory),
           let decoded = try? JSONDecoder().decode([HistoricDownload].self, from: data) {
            history = decoded
            // Restore as Download objects for UI, reversing so newest is at the top
            let restored = decoded.reversed().map { $0.toDownload() }
            downloads.append(contentsOf: restored)

            for download in restored {
                // Bug #8 fix: Mark any "active" status as stopped on relaunch
                // (no backend process exists for them anymore)
                switch download.status {
                case .downloading, .fetching, .processing, .queued:
                    download.status = .stopped
                    failedDownloadsMap[download.id] = download
                case .failed, .stopped, .fileExists:
                    failedDownloadsMap[download.id] = download
                default:
                    break
                }
            }
        }
    }

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(history) {
            userDefaults.set(encoded, forKey: UserDefaultsKeys.downloadHistory)
        }
    }

    private func addToHistory(_ download: Download, skipSave: Bool = false) {
        let historic = HistoricDownload(download: download)

        // Remove existing if any (upsert)
        if let index = history.firstIndex(where: { $0.id == download.id }) {
            history.remove(at: index)
        }
        history.append(historic)

        if history.count > 500 { // Increased limit for better user experience
            history.removeFirst(history.count - 500)
        }

        if !skipSave {
            saveHistory()
        }
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
