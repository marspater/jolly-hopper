import Foundation
import AppKit
import Combine
import SwiftUI



@MainActor
class DownloadManager: ObservableObject {

    @Published var downloads: [Download] = []
    @Published var history: [HistoricDownload] = []
    let ytdlpService = YtdlpService()
    let historyStore = DownloadHistoryStore()
    let queue = DownloadQueue()
    private var executor: DownloadExecutor!
    private var cancellables = Set<AnyCancellable>()
    private var isShuttingDown = false


    private var maxConcurrentDownloads: Int {
        queue.maxConcurrentDownloads
    }
    private let userDefaults = UserDefaults.standard

    var activeExecutionCount: Int {
        executor.activeExecutionCount
    }

    func executionState(for downloadID: UUID) -> DownloadExecutionState {
        executor.executionState(for: downloadID)
    }

    private var isProcessingQueue = false
    var languageService: LanguageService?

    init() {
        self.executor = DownloadExecutor(ytdlpService: ytdlpService)
        self.executor.delegate = self

        ytdlpService.$isUpdating
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isUpdating in
                guard !isUpdating else { return }
                Task { @MainActor [weak self] in
                    self?.processQueue()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.processQueue()
            }
        }
    }

    var downloadingDownloads: [Download] {
        downloads.filter { $0.status == .downloading || $0.status == .fetching || $0.status == .processing }
    }

    var queuedDownloads: [Download] {
        downloads.filter { $0.status == .queued || $0.status == .paused }
    }

    var completedDownloads: [Download] {
        downloads.filter { $0.status == .completed }
    }

    var failedDownloads: [Download] {
        downloads.filter { $0.status == .failed || $0.status == .stopped }
    }

    var actionRequiredDownloads: [Download] {
        downloads.filter { $0.status == .fileExists }
    }

    // Bolt Performance Optimization: Single-pass status counting to avoid 4 separate array reductions over downloads
    private var statusCounts: (downloading: Int, queued: Int, completed: Int, failed: Int) {
        var downloading = 0
        var queued = 0
        var completed = 0
        var failed = 0
        for download in downloads {
            switch download.status {
            case .downloading, .fetching, .processing:
                downloading += 1
            case .queued, .paused:
                queued += 1
            case .completed:
                completed += 1
            case .failed, .stopped:
                failed += 1
            default:
                break
            }
        }
        return (downloading, queued, completed, failed)
    }

    var downloadingCount: Int {
        statusCounts.downloading
    }
    var queuedCount: Int {
        statusCounts.queued
    }
    var completedCount: Int {
        statusCounts.completed
    }
    var failedCount: Int {
        statusCounts.failed
    }

    /// The most useful destination for the Home screen's "See All" actions.
    /// Active work takes precedence, followed by queued work and then failures.
    var mostRelevantNavigationItem: NavigationItem {
        let counts = statusCounts
        if counts.downloading > 0 { return .downloading }
        if counts.queued > 0 { return .queued }
        if counts.failed > 0 { return .failed }
        return .completed
    }



    func initialize(languageService: LanguageService) {
        self.languageService = languageService
        loadHistory()
    }



    func addDownload(url: String, options: DownloadOptions, mediaInfo: MediaInfo? = nil) {
        let download = Download(url: url, options: options, title: mediaInfo?.title ?? "___FETCHING___")
        if let info = mediaInfo {
            download.mediaInfo = info
            download.thumbnailURL = info.thumbnailURL
            download.duration = info.durationString
        }
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

        let resolution: VideoResolution
        if type != "video" {
            resolution = .worst
        } else if quality == "best" {
            resolution = .best
        } else if quality == "1080" {
            resolution = .r1080p
        } else {
            resolution = .r720p
        }

        let options = DownloadOptions(
            saveFolder: folder,
            fileType: type == "video" ? .mp4 : .m4a,
            videoFormat: nil,
            audioFormat: nil,
            videoResolution: resolution,
            audioQuality: .best,
            downloadSubtitles: false,
            subtitleLanguages: ["en"],
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

    func quickDownload(
        url: String,
        rawCookies: String? = nil,
        rawUserAgent: String? = nil,
        browserCookieSource: String? = nil
    ) {
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
            subtitleLanguages: ["en"],
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
        options.rawUserAgent = rawUserAgent
        options.browserCookieSource = AppState.normalizedBrowserCookieSource(browserCookieSource)
        addDownload(url: url, options: options)
    }

    /// Event-driven queue dispatcher: schedules queued downloads whenever a concurrent slot becomes available.
    func processQueue() {
        guard !isShuttingDown else { return }
        guard !ytdlpService.isUpdating else { return }
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        let nextDownloads = queue.scheduleNextDownloads(from: downloads)
        for download in nextDownloads {
            startDownloadTask(download)
        }
    }

    private func startDownloadTask(_ download: Download) {
        executor.startDownloadTask(
            download,
            queue: queue,
            ytdlpVersion: ytdlpService.version,
            languageService: languageService
        )
    }

    func processDownload(_ download: Download) async {
        if !downloads.contains(where: { $0.id == download.id }) {
            downloads.append(download)
        }
        processQueue()

        while download.status == .queued ||
              download.status == .fetching ||
              download.status == .downloading ||
              download.status == .processing ||
              executor.hasActiveTask(for: download.id) {
            if Task.isCancelled {
                return
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch is CancellationError {
                return
            } catch {
                LoggerService.shared.log("Unexpected wait failure while observing download lifecycle: \(error.localizedDescription)", level: .error)
                return
            }
        }
    }

    func executeDownload(_ download: Download) async {
        await executor.executeDownload(
            download,
            queue: queue,
            ytdlpVersion: ytdlpService.version,
            languageService: languageService
        )
    }

    func stopDownload(_ download: Download, suppressNotification: Bool = false, skipSaveAndBroadcast: Bool = false) {
        executor.stopDownload(
            download,
            queue: queue,
            languageService: languageService,
            suppressNotification: suppressNotification,
            skipSaveAndBroadcast: skipSaveAndBroadcast
        )
    }

    func retryDownload(_ download: Download) {
        guard download.status == .failed || download.status == .stopped || download.status == .fileExists else { return }
        download.options.forceOverwrite = false
        updateStatus(for: download, to: .queued)
        download.progress = 0
        objectWillChange.send()
        download.errorMessage = nil
        download.log = ""

        processQueue()
    }

    func pauseDownload(_ download: Download) {
        executor.pauseDownload(download, queue: queue)
        saveHistory()
    }

    func resumeDownload(_ download: Download) {
        guard download.status == .paused else { return }
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        processQueue()
    }

    func moveDownloadUp(_ download: Download) {
        guard queue.moveUp(download: download, in: &downloads) else { return }
        objectWillChange.send()
        processQueue()
    }

    func moveDownloadDown(_ download: Download) {
        guard queue.moveDown(download: download, in: &downloads) else { return }
        objectWillChange.send()
        processQueue()
    }

    func moveDownloadToTop(_ download: Download) {
        guard queue.moveToTop(download: download, in: &downloads) else { return }
        objectWillChange.send()
        processQueue()
    }

    func moveDownloadToBottom(_ download: Download) {
        guard queue.moveToBottom(download: download, in: &downloads) else { return }
        objectWillChange.send()
        processQueue()
    }

    func moveDownload(from source: IndexSet, to destination: Int) {
        queue.move(from: source, to: destination, in: &downloads)
        objectWillChange.send()
        processQueue()
    }

    func resumeWithOverwrite(_ download: Download) {
        download.options.forceOverwrite = true
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        processQueue()
    }
    
    func resumeWithNewName(_ download: Download) {
        let (candidateName, _) = planUniqueOutputPath(for: download, forceIncrement: true)
        download.options.customFilename = candidateName
        download.options.forceOverwrite = false
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        processQueue()
    }

    func shutdown() {
        isShuttingDown = true
        executor.shutdown()
        // Shutdown is terminal for this manager. Queue admission is disabled
        // before reservations are cleared, so cancelled work cannot be replaced
        // while executor-owned teardown is still unwinding.
        queue.clearReservedSlots()
        queue.clearReservedOutputPaths()
    }

    func planUniqueOutputPath(for download: Download, forceIncrement: Bool = false) -> (resolvedBaseName: String, candidatePath: String) {
        queue.planUniqueOutputPath(for: download, forceIncrement: forceIncrement)
    }

    @discardableResult
    func reserveUniqueOutputPath(for download: Download, forceIncrement: Bool = false) -> (resolvedBaseName: String, candidatePath: String) {
        queue.reserveUniqueOutputPath(for: download, forceIncrement: forceIncrement)
    }

    func resolveUniqueOutputPath(for download: Download) -> (resolvedBaseName: String, candidatePath: String) {
        queue.planUniqueOutputPath(for: download)
    }

    func reserveOutputPath(_ path: String) {
        queue.reserveOutputPath(path)
    }

    func unreserveOutputPath(_ path: String) {
        queue.unreserveOutputPath(path)
    }
    
    func stopAllDownloads() {
        for download in downloadingDownloads + queuedDownloads {
            stopDownload(download, suppressNotification: false, skipSaveAndBroadcast: true)
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
        let queued = queuedDownloads
        guard !queued.isEmpty else { return }
        clearDownloads(queued)
    }


    func clearCompletedDownloads() {
        clearDownloads(completedDownloads)
    }

    func clearFailedDownloads() {
        clearDownloads(failedDownloads)
    }

    func clearDownloads(_ items: [Download]) {
        if items.isEmpty { return }

        let itemIds = Set(items.map { $0.id })

        // Bolt Performance Optimization: Batch array mutations and broadcast once
        for item in items {
            if item.status == .downloading || item.status == .fetching || item.status == .processing || item.status == .queued || item.status == .paused {
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

    nonisolated static func shouldCleanupTemporaryFiles(for status: DownloadStatus) -> Bool {
        DownloadExecutor.shouldCleanupTemporaryFiles(for: status)
    }

    nonisolated static func extractVideoId(from urlString: String) -> String? {
        DownloadExecutor.extractVideoId(from: urlString)
    }

    nonisolated static func isTemporaryFileName(_ fileName: String) -> Bool {
        DownloadExecutor.isTemporaryFileName(fileName)
    }

    nonisolated static func isMatchingTemporaryFile(
        fileName: String,
        rawBaseName: String,
        sanitizedBaseName: String,
        videoId: String?
    ) -> Bool {
        DownloadExecutor.isMatchingTemporaryFile(
            fileName: fileName,
            rawBaseName: rawBaseName,
            sanitizedBaseName: sanitizedBaseName,
            videoId: videoId
        )
    }

    private func cleanupTemporaryFiles(for download: Download) {
        DownloadExecutor.cleanupTemporaryFiles(for: download)
    }



    func loadHistory() {
        history = historyStore.loadHistory()
        downloads = DownloadHistoryStore.restoreDownloads(from: history, existingDownloads: downloads)
    }

    func saveHistory() {
        historyStore.saveHistory(history)
    }

    func addToHistory(_ download: Download, skipSave: Bool = false) {
        historyStore.addToHistory(download, history: &history, skipSave: skipSave)
    }

    func clearHistory() {
        historyStore.clearHistory(history: &history)
        downloads.removeAll {
            switch $0.status {
            case .completed, .failed, .stopped, .fileExists:
                return true
            default:
                return false
            }
        }
        objectWillChange.send()
    }

    func removeFromHistory(_ download: HistoricDownload) {
        historyStore.removeFromHistory(id: download.id, history: &history)
        downloads.removeAll { $0.id == download.id }
        objectWillChange.send()
    }



    func openFile(_ path: URL) {
        guard YtdlpService.isMediaFilePath(path.path) else {
            LoggerService.shared.log("Refusing to open non-media file via NSWorkspace: \(path.path)", level: .warning)
            return
        }
        NSWorkspace.shared.open(path)
    }

    func showInFinder(_ path: URL) {
        showInFinder([path])
    }

    func showInFinder(_ paths: [URL]) {
        let validPaths = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validPaths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(validPaths)
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

extension DownloadManager: DownloadExecutorDelegate {
    func executorDidUpdateStatus(for download: Download, to status: DownloadStatus) {
        updateStatus(for: download, to: status)
    }

    func executorDidRequestAddToHistory(_ download: Download, skipSave: Bool) {
        // Cancellation can finish after the user removed the job from the app.
        guard downloads.contains(where: { $0.id == download.id }) else { return }
        addToHistory(download, skipSave: skipSave)
    }

    func executorDidFinishDownload() {
        processQueue()
    }

    func executorDidRequestBroadcast() {
        objectWillChange.send()
    }
}



final class ThreadSafePathCollector: @unchecked Sendable {
    private var paths: [URL] = []
    private let lock = NSLock()

    func add(_ url: URL) {
        lock.lock()
        if !paths.contains(url) {
            paths.append(url)
        }
        lock.unlock()
    }

    func getPaths() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return Array(paths)
    }
}
