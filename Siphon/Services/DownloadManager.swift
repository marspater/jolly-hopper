import Foundation
import AppKit
import Combine
import SwiftUI



@MainActor
class DownloadManager: ObservableObject {

    @Published var downloads: [Download] = []
    @Published var history: [HistoricDownload] = []
    @Published var ytdlpVersion: String?
    @Published var showWhatsNew: Bool = false
    @Published var whatsNewTitle: String = ""
    @Published var whatsNewMessage: String = ""
    @Published var whatsNewFeatures: [ReleaseFeature] = []
    @Published var isFetchingWhatsNew: Bool = false
    @Published var ytdlpUpdateMessage: YtdlpUpdateMessage?
    @Published var isUpdatingYtdlp: Bool = false
    @Published var ytdlpUpdateProgress: Double = 0


    let ytdlpService = YtdlpService()
    var urlSession: URLSession = .shared
    let historyStore = DownloadHistoryStore()
    let releaseNotesService = ReleaseNotesService()
    let dependencyCoordinator = DependencyUpdateCoordinator()
    let queue = DownloadQueue()
    var executor: DownloadExecutor!


    private var maxConcurrentDownloads: Int {
        queue.maxConcurrentDownloads
    }
    private let userDefaults = UserDefaults.standard
    var activeControllers: [UUID: DownloadProcessController] {
        get { executor.activeControllers }
        set { executor.activeControllers = newValue }
    }
    var activeTasks: [UUID: Task<Void, Never>] {
        get { executor.activeTasks }
        set { executor.activeTasks = newValue }
    }
    private var isProcessingQueue = false
    var languageService: LanguageService?

    init() {
        self.executor = DownloadExecutor(ytdlpService: ytdlpService)
        self.executor.delegate = self
        dependencyCoordinator.bind(to: ytdlpService)
        dependencyCoordinator.$isUpdating
            .receive(on: RunLoop.main)
            .assign(to: &$isUpdatingYtdlp)
        dependencyCoordinator.$updateProgress
            .receive(on: RunLoop.main)
            .assign(to: &$ytdlpUpdateProgress)
        dependencyCoordinator.$version
            .receive(on: RunLoop.main)
            .assign(to: &$ytdlpVersion)
        dependencyCoordinator.$updateMessage
            .receive(on: RunLoop.main)
            .assign(to: &$ytdlpUpdateMessage)

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
        downloads.filter { $0.status == .queued }
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
            case .queued:
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



    func initialize(languageService: LanguageService, skipBinarySetup: Bool = false) async {
        self.languageService = languageService

        await dependencyCoordinator.initialize(service: ytdlpService, skipBinarySetup: skipBinarySetup)
        ytdlpVersion = dependencyCoordinator.version

        loadHistory()

        await checkAndFetchWhatsNew()
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.2.0"
    }

    static var defaultFeatures: [ReleaseFeature] {
        ReleaseNotesService.defaultFeatures
    }

    func parseReleaseFeatures(from text: String) -> [ReleaseFeature] {
        releaseNotesService.parseReleaseFeatures(from: text)
    }

    func checkAndFetchWhatsNew() async {
        isFetchingWhatsNew = true
        if let result = await releaseNotesService.checkAndFetchWhatsNew(appVersion: appVersion, languageService: languageService, session: urlSession) {
            whatsNewTitle = result.title
            whatsNewFeatures = result.features
            showWhatsNew = result.shouldShow
        }
        isFetchingWhatsNew = false
    }

    func fetchReleaseNotesFromGitHub(version: String, session: URLSession = .shared) async -> (title: String, body: String)? {
        await releaseNotesService.fetchReleaseNotesFromGitHub(version: version, session: session)
    }

    func updateYtdlp() async {
        await dependencyCoordinator.updateYtdlp(service: ytdlpService)
        ytdlpVersion = dependencyCoordinator.version
        ytdlpUpdateMessage = dependencyCoordinator.updateMessage
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

        let options = DownloadOptions(
            saveFolder: folder,
            fileType: type == "video" ? .mp4 : .m4a,
            videoFormat: nil,
            audioFormat: nil,
            videoResolution: type == "video" ? (quality == "best" ? .best : (quality == "1080" ? .r1080p : .r720p)) : .worst,
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
        addDownload(url: url, options: options)
    }

    /// Event-driven queue dispatcher: schedules queued downloads whenever a concurrent slot becomes available.
    func processQueue() {
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
            ytdlpVersion: ytdlpVersion,
            languageService: languageService
        )
    }

    func processDownload(_ download: Download) async {
        if !downloads.contains(where: { $0.id == download.id }) {
            downloads.append(download)
        }
        processQueue()

        while download.status == .queued || download.status == .fetching || download.status == .downloading || download.status == .processing {
            if let task = activeTasks[download.id] {
                await task.value
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func executeDownload(_ download: Download) async {
        await executor.executeDownload(
            download,
            queue: queue,
            ytdlpVersion: ytdlpVersion,
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
        executor.shutdown()
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
