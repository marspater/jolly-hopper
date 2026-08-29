import Foundation
import AppKit
import Combine


final class DownloadEventCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingProgress: (progress: Double, speed: String?, eta: String?)?
    private var pendingLogLines: [String] = []
    private var pendingLogBytes: Int = 0
    private let maxPendingLines = 500
    private let maxPendingBytes = 1_048_576 // 1MB
    
    private var lastProgressFlush = Date()
    private var lastLogFlush = Date()
    private var scheduledFlushWorkItem: DispatchWorkItem?
    private let onFlush: @Sendable (Double?, String?, String?, [String]) -> Void
    
    init(onFlush: @escaping @Sendable (Double?, String?, String?, [String]) -> Void) {
        self.onFlush = onFlush
    }

    deinit {
        scheduledFlushWorkItem?.cancel()
    }

    private func scheduleFlushIfNeeded() {
        if scheduledFlushWorkItem != nil { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.performTimerFlush()
        }
        scheduledFlushWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.150, execute: workItem)
    }

    private func performTimerFlush() {
        lock.lock()
        scheduledFlushWorkItem = nil
        let now = Date()
        var progressToFlush: (progress: Double, speed: String?, eta: String?)? = nil
        if pendingProgress != nil && now.timeIntervalSince(lastProgressFlush) >= 0.100 {
            lastProgressFlush = now
            progressToFlush = pendingProgress
            pendingProgress = nil
        }
        
        var linesToFlush: [String] = []
        if !pendingLogLines.isEmpty && now.timeIntervalSince(lastLogFlush) >= 0.200 {
            lastLogFlush = now
            linesToFlush = pendingLogLines
            pendingLogLines.removeAll(keepingCapacity: true)
            pendingLogBytes = 0
        }
        
        if pendingProgress != nil || !pendingLogLines.isEmpty {
            scheduleFlushIfNeeded()
        }
        lock.unlock()

        if progressToFlush != nil || !linesToFlush.isEmpty {
            onFlush(progressToFlush?.progress, progressToFlush?.speed, progressToFlush?.eta, linesToFlush)
        }
    }

    func recordProgress(progress: Double, speed: String?, eta: String?) {
        lock.lock()
        pendingProgress = (progress, speed, eta)
        let now = Date()
        let shouldFlush = now.timeIntervalSince(lastProgressFlush) >= 0.100 // 100ms
        var toFlush: (progress: Double, speed: String?, eta: String?)? = nil
        if shouldFlush {
            lastProgressFlush = now
            toFlush = pendingProgress
            pendingProgress = nil
        } else {
            scheduleFlushIfNeeded()
        }
        lock.unlock()

        if let p = toFlush {
            onFlush(p.progress, p.speed, p.eta, [])
        }
    }

    func recordLogLine(_ line: String) {
        lock.lock()
        pendingLogLines.append(line)
        pendingLogBytes += line.utf8.count
        
        // Bounded queue: drop oldest lines if exceeding line cap or byte cap
        while pendingLogLines.count > maxPendingLines || pendingLogBytes > maxPendingBytes {
            if let dropped = pendingLogLines.first {
                pendingLogBytes -= dropped.utf8.count
                pendingLogLines.removeFirst()
            } else {
                break
            }
        }

        let now = Date()
        let shouldFlush = now.timeIntervalSince(lastLogFlush) >= 0.200 // 200ms
        var linesToFlush: [String] = []
        if shouldFlush {
            lastLogFlush = now
            linesToFlush = pendingLogLines
            pendingLogLines.removeAll(keepingCapacity: true)
            pendingLogBytes = 0
        } else {
            scheduleFlushIfNeeded()
        }
        lock.unlock()

        if !linesToFlush.isEmpty {
            onFlush(nil, nil, nil, linesToFlush)
        }
    }

    func flushRemaining() {
        lock.lock()
        scheduledFlushWorkItem?.cancel()
        scheduledFlushWorkItem = nil
        let p = pendingProgress
        let lines = pendingLogLines
        pendingProgress = nil
        pendingLogLines.removeAll()
        pendingLogBytes = 0
        lock.unlock()

        if p != nil || !lines.isEmpty {
            onFlush(p?.progress, p?.speed, p?.eta, lines)
        }
    }
}

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
    var activeControllers: [UUID: DownloadProcessController] = [:]
    var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var isProcessingQueue = false
    var languageService: LanguageService?
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

    var downloadingCount: Int {
        downloads.reduce(0) { $0 + (($1.status == .downloading || $1.status == .fetching || $1.status == .processing) ? 1 : 0) }
    }
    var queuedCount: Int {
        downloads.reduce(0) { $0 + ($1.status == .queued ? 1 : 0) }
    }
    var completedCount: Int {
        downloads.reduce(0) { $0 + ($1.status == .completed ? 1 : 0) }
    }
    var failedCount: Int {
        downloads.reduce(0) { $0 + (($1.status == .failed || $1.status == .stopped || $1.status == .fileExists) ? 1 : 0) }
    }



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
        processQueue()
    }


    func addDownloads(urls: [String], options: DownloadOptions) {
        let newDownloads = urls.map { Download(url: $0, options: options) }
        downloads.append(contentsOf: newDownloads)
        processQueue()
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

    /// Event-driven queue dispatcher: schedules queued downloads whenever a concurrent slot becomes available.
    func processQueue() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        let limit = maxConcurrentDownloads
        let currentActive = downloadingCount
        let availableSlots = max(0, limit - currentActive)
        guard availableSlots > 0 else { return }

        var started = 0
        for download in downloads where download.status == .queued {
            if started >= availableSlots { break }
            startDownloadTask(download)
            started += 1
        }
    }

    private func startDownloadTask(_ download: Download) {
        guard download.status == .queued else { return }
        guard activeTasks[download.id] == nil else { return }

        let downloadId = download.id
        let task = Task { [weak self, weak download] in
            guard let self, let download else { return }
            await self.executeDownload(download)
        }
        activeTasks[downloadId] = task
    }

    func processDownload(_ download: Download) async {
        guard download.status == .queued else { return }
        if !downloads.contains(where: { $0.id == download.id }) {
            downloads.append(download)
        }
        guard activeTasks[download.id] == nil else { return }

        let downloadId = download.id
        let task = Task { [weak self, weak download] in
            guard let self, let download else { return }
            await self.executeDownload(download)
        }
        activeTasks[downloadId] = task
        await task.value
    }

    private func executeDownload(_ download: Download) async {
        let downloadId = download.id
        defer {
            activeTasks.removeValue(forKey: downloadId)
            activeControllers.removeValue(forKey: downloadId)
            processQueue()
        }

        guard !Task.isCancelled else { return }
        guard download.status == .queued || download.status == .fetching else { return }

        updateStatus(for: download, to: .fetching)
        objectWillChange.send()

        do {
            let info = try await ytdlpService.fetchInfo(url: download.url, rawCookies: download.options.rawCookies)

            guard !Task.isCancelled else { return }
            guard download.status == .fetching else { return }

            download.title = info.title
            download.duration = info.durationString
            download.thumbnailURL = info.thumbnailURL
            download.mediaInfo = info
            let (resolvedBaseName, candidateKey) = resolveUniqueOutputPath(for: download)
            let sanitize: (String) -> String = { input in
                let invalidChars = CharacterSet(charactersIn: "\\/:*?\"<>|")
                return input.components(separatedBy: invalidChars).joined(separator: "_")
            }
            let rawBaseName = download.options.customFilename ?? download.title
            let sanitizedBaseName = sanitize(rawBaseName)
            if resolvedBaseName != sanitizedBaseName {
                download.options.customFilename = resolvedBaseName
            }
            reserveOutputPath(candidateKey)
            defer {
                unreserveOutputPath(candidateKey)
            }

            let folderPath = download.options.saveFolder
            let fileExists = await Task.detached {
                if let contents = try? FileManager.default.contentsOfDirectory(at: folderPath, includingPropertiesForKeys: nil) {
                    let matches = contents.filter { file in
                        let nameWithoutExt = file.deletingPathExtension().lastPathComponent
                        let isExactMatch = nameWithoutExt == resolvedBaseName
                        let isPart = file.lastPathComponent.hasSuffix(".part") || file.lastPathComponent.hasSuffix(".ytdl")
                        let isMedia = YtdlpService.isMediaFilePath(file.path)
                        return isExactMatch && !isPart && isMedia
                    }
                    return !matches.isEmpty
                }
                return false
            }.value

            guard !Task.isCancelled else { return }
            guard download.status == .fetching else { return }

            if fileExists && download.options.forceOverwrite != true {
                updateStatus(for: download, to: .fileExists)
                objectWillChange.send()
                return // Paused: UI will show button to resume with overwrite or add a number
            }

            updateStatus(for: download, to: .downloading)
            objectWillChange.send()

            let controller = DownloadProcessController()
            activeControllers[download.id] = controller

            LoggerService.shared.log("Starting download for URL: \(LoggerService.sanitizeURLForLog(download.url))", level: .info)

            let coalescer = DownloadEventCoalescer { [weak download] progress, speed, eta, lines in
                DispatchQueue.main.async { [weak download] in
                    guard let download else { return }
                    if let progress {
                        download.progress = progress
                        download.speed = speed
                        download.eta = eta
                    }
                    if !lines.isEmpty {
                        let combined = lines.joined(separator: "\n") + "\n"
                        if download.log.count + combined.count > 50_000 {
                            download.log = String(download.log.suffix(25_000))
                        }
                        download.log += combined
                        for line in lines {
                            if line.contains("[EmbedThumbnail]") || line.contains("[Metadata]") || line.contains("[Merger]") || line.contains("[VideoConvertor]") || line.contains("[ThumbnailsConvertor]") || line.contains("[EmbedSubtitle]") {
                                if download.status == .downloading {
                                    download.status = .processing
                                }
                            }
                        }
                    }
                }
            }

            let outputPath = try await ytdlpService.download(
                url: download.url,
                options: download.options,
                mediaInfo: download.mediaInfo,
                processController: controller,
                onProgress: { progress, speed, eta in
                    let safeProgress = progress.isNaN ? 0 : max(0, min(1, progress))
                    coalescer.recordProgress(progress: safeProgress, speed: speed, eta: eta)
                },
                onOutput: { line in
                    coalescer.recordLogLine(line)
                }
            )

            coalescer.flushRemaining()

            download.filePath = outputPath
            updateStatus(for: download, to: .completed)
            download.progress = 1.0

            // Memory optimization: Prune large formats/subtitles and bound log for completed download
            download.mediaInfo = download.mediaInfo?.prunedForCompletion()
            if download.log.count > 2000 {
                download.log = String(download.log.suffix(2000))
            }
            objectWillChange.send()

            LoggerService.shared.log("Download completed successfully: \(download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title)", level: .info)

            addToHistory(download)

            // Send notification
            let lang = languageService ?? LanguageService()
            NotificationService.shared.sendDownloadCompleted(filename: download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title, languageService: lang)

        } catch let error as YtdlpError {
            if download.status == .stopped || download.status == .paused || Task.isCancelled {
                LoggerService.shared.log("Download stopped or paused by user (\(LoggerService.sanitizeURLForLog(download.url)))", level: .info)
                if download.status == .stopped {
                    addToHistory(download)
                }
                return
            }
            updateStatus(for: download, to: .failed)
            objectWillChange.send()

            let lang = languageService ?? LanguageService()
            switch error {
            case .safariCookiesFullDiskAccessRequired:
                download.errorMessage = lang.s("safari_fda_required")
            case .tooManyRequests:
                download.errorMessage = lang.s("too_many_requests")
            case .cloudflareBlocked:
                download.errorMessage = lang.s("cloudflare_blocked")
            case .boyfriendTVNeedsBrowserCookies:
                download.errorMessage = "This site requires signed-in browser cookies. Open Settings > Advanced > Browser Cookies, choose your browser, then try again."
            case .boyfriendTVLoginRequired:
                download.errorMessage = lang.s("login_required")
            case .notFound:
                download.errorMessage = lang.s("ytdlp_not_found")
            case .parseError:
                download.errorMessage = lang.s("parse_error")
            case .ffmpegInstallationFailed:
                download.errorMessage = lang.s("ffmpeg_error")
            case .securityViolation(let message):
                download.errorMessage = "Security violation: \(message)"
            case .subtitleError(let details):
                download.errorMessage = String(format: lang.s("subtitle_download_failed"), details)
            case .downloadFailed(let reason), .commandFailed(let reason):
                let lower = reason.lowercased()
                if lower.contains("cloudflare") || lower.contains("403") || lower.contains("anti-bot") || lower.contains("captcha") {
                    download.errorMessage = lang.s("cloudflare_blocked")
                } else if lower.contains("sign in") || lower.contains("private video") || lower.contains("login") || lower.contains("members-only") {
                    download.errorMessage = lang.s("login_required")
                } else if lower.contains("drm") || lower.contains("encrypted") || lower.contains("protected") {
                    download.errorMessage = lang.s("drm_protected")
                } else if lower.contains("unavailable") || lower.contains("removed") || lower.contains("404") {
                    download.errorMessage = lang.s("video_unavailable")
                } else if lower.contains("no space left") || lower.contains("disk full") {
                    download.errorMessage = lang.s("disk_full")
                } else if lower.contains("permission denied") {
                    download.errorMessage = lang.s("permission_denied")
                } else if lower.contains("unsupported url") {
                    download.errorMessage = lang.s("unsupported_url")
                } else if lower.contains("timed out") || lower.contains("timeout") {
                    download.errorMessage = lang.s("network_timeout")
                } else {
                    download.errorMessage = String(format: lang.s("download_failed_error"), reason)
                }
            }

            LoggerService.shared.log("Download failed (\(LoggerService.sanitizeURLForLog(download.url))): \(download.errorMessage ?? error.localizedDescription)", level: .error)
            NotificationService.shared.sendDownloadFailed(filename: download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title, languageService: lang)
            addToHistory(download)
        } catch {
            if download.status == .stopped || download.status == .paused || Task.isCancelled {
                LoggerService.shared.log("Download stopped or paused by user (\(LoggerService.sanitizeURLForLog(download.url)))", level: .info)
                if download.status == .stopped {
                    addToHistory(download)
                }
                return
            }
            updateStatus(for: download, to: .failed)
            objectWillChange.send()

            let lang = languageService ?? LanguageService()
            let errorText = error.localizedDescription
            let lower = errorText.lowercased()
            if lower.contains("no space left") || lower.contains("disk full") {
                download.errorMessage = lang.s("disk_full")
            } else if lower.contains("permission denied") {
                download.errorMessage = lang.s("permission_denied")
            } else if lower.contains("timed out") || lower.contains("timeout") {
                download.errorMessage = lang.s("network_timeout")
            } else {
                download.errorMessage = String(format: lang.s("download_failed_error"), errorText)
            }
            LoggerService.shared.log("Download failed with error (\(LoggerService.sanitizeURLForLog(download.url))): \(error.localizedDescription)", level: .error)

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
        activeTasks[download.id]?.cancel()
        activeControllers[download.id]?.cancel()
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

        processQueue()
    }

    func pauseDownload(_ download: Download) {
        guard download.status == .downloading || download.status == .fetching || download.status == .processing || download.status == .queued else {
            return
        }
        updateStatus(for: download, to: .paused)
        activeTasks[download.id]?.cancel()
        activeControllers[download.id]?.cancel()
        objectWillChange.send()
    }

    func resumeDownload(_ download: Download) {
        guard download.status == .paused else { return }
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        processQueue()
    }

    func moveDownloadUp(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index > 0 else { return }
        downloads.swapAt(index, index - 1)
        objectWillChange.send()
    }

    func moveDownloadDown(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index < downloads.count - 1 else { return }
        downloads.swapAt(index, index + 1)
        objectWillChange.send()
    }

    func moveDownloadToTop(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index > 0 else { return }
        let item = downloads.remove(at: index)
        downloads.insert(item, at: 0)
        objectWillChange.send()
    }

    func moveDownloadToBottom(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index < downloads.count - 1 else { return }
        let item = downloads.remove(at: index)
        downloads.append(item)
        objectWillChange.send()
    }

    func moveDownload(from source: IndexSet, to destination: Int) {
        downloads.move(fromOffsets: source, toOffset: destination)
        objectWillChange.send()
    }


    func resumeWithOverwrite(_ download: Download) {
        download.options.forceOverwrite = true
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        processQueue()
    }
    
    func resumeWithNewName(_ download: Download) {
        let uniqueSuffix = " (\(Int(Date().timeIntervalSince1970) % 10000))"
        let base = download.options.customFilename ?? download.title
        download.options.customFilename = "\(base)\(uniqueSuffix)"
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        processQueue()
    }

    func shutdown() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        for (_, controller) in activeControllers {
            controller.cancel()
        }
        activeTasks.removeAll()
        activeControllers.removeAll()
    }

    func resolveUniqueOutputPath(for download: Download) -> (resolvedBaseName: String, candidatePath: String) {
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
        return (resolvedBaseName, candidateKey)
    }

    func reserveOutputPath(_ path: String) {
        reservedOutputPaths.insert(path)
    }

    func unreserveOutputPath(_ path: String) {
        reservedOutputPaths.remove(path)
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
                        let isTemp = lower.hasSuffix(".part") ||
                                     lower.hasSuffix(".ytdl") ||
                                     lower.hasSuffix(".temp") ||
                                     lower.hasSuffix(".tmp") ||
                                     (lower.range(of: #"\.f\d+\.part$"#, options: .regularExpression) != nil) ||
                                     (lower.range(of: #"\.f\d+\.ytdl$"#, options: .regularExpression) != nil) ||
                                     (lower.range(of: #"\.f\d+\.temp$"#, options: .regularExpression) != nil) ||
                                     (lower.range(of: #"\.f\d+\.tmp$"#, options: .regularExpression) != nil)

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
        if let data = userDefaults.data(forKey: UserDefaultsKeys.downloadHistory) {
            do {
                let decoded = try JSONDecoder().decode([HistoricDownload].self, from: data)
                history = decoded
                // Restore as Download objects for UI, reversing so newest is at the top
                let restored = decoded.reversed().map { $0.toDownload() }
                
                var existingIds = Set(downloads.map { $0.id })
                for download in restored {
                    if !existingIds.contains(download.id) {
                        switch download.status {
                        case .downloading, .fetching, .processing, .queued:
                            download.status = .stopped
                        default:
                            break
                        }
                        downloads.append(download)
                        existingIds.insert(download.id)
                    }
                }
            } catch {
                LoggerService.shared.log("Failed to decode download history: \(error.localizedDescription)", level: .error)
            }
        }
    }

    private func saveHistory() {
        do {
            let encoded = try JSONEncoder().encode(history)
            userDefaults.set(encoded, forKey: UserDefaultsKeys.downloadHistory)
        } catch {
            LoggerService.shared.log("Failed to encode download history: \(error.localizedDescription)", level: .error)
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
        switch status {
        case .completed, .failed, .stopped, .fileExists:
            download.mediaInfo = download.mediaInfo?.prunedForCompletion()
            if download.log.count > 2000 {
                download.log = String(download.log.suffix(2000))
            }
        default:
            break
        }
    }
}


struct YtdlpUpdateMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
