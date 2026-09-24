import Foundation
import AppKit
import Combine
import SwiftUI



@MainActor
class DownloadManager: ObservableObject {

    // Bolt Performance Optimization: Maintain O(1) Set lookup cache for download IDs to avoid linear scans
    @Published var downloads: [Download] = [] {
        didSet {
            downloadIDs = Set(downloads.map { $0.id })
        }
    }
    private(set) var downloadIDs: Set<UUID> = []
    @Published var history: [HistoricDownload] = []
    let ytdlpService = YtdlpService()
    let historyStore = DownloadHistoryStore()
    let queue = DownloadQueue()
    let recoveryStore: QueueRecoveryStore
    @Published var showQueueRecoveryAlert: Bool = false
    @Published var recoverableJobsCount: Int = 0
    var pendingRecoveryJobs: [Download] = []
    private var executor: DownloadExecutor!
    private var cancellables = Set<AnyCancellable>()
    private var isShuttingDown = false
    private var isInitialized = false
    private let userDefaults = UserDefaults.standard

    var activeExecutionCount: Int {
        executor.activeExecutionCount
    }

    func executionState(for downloadID: UUID) -> DownloadExecutionState {
        executor.executionState(for: downloadID)
    }

    private var isProcessingQueue = false
    var languageService: LanguageService?

    init(recoveryFileURL: URL = QueueRecoveryStore.defaultFileURL) {
        self.recoveryStore = QueueRecoveryStore(fileURL: recoveryFileURL)
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

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !NotificationService.isRunningTests else { return }
                self?.stopAllDownloads(preservePaused: true, suppressNotification: true)
                self?.shutdown()
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
        // Each new main window runs this again. While the app is running, the
        // recovery snapshot lists live jobs, so a second pass would offer to
        // "recover" (or discard) downloads that are still executing.
        guard !isInitialized else { return }
        isInitialized = true
        self.languageService = languageService
        loadHistory()
        checkQueueRecovery()
    }

    func checkQueueRecovery() {
        let interrupted = recoveryStore.loadInterruptedJobs()
        guard !interrupted.isEmpty else { return }
        pendingRecoveryJobs = interrupted
        recoverableJobsCount = interrupted.count
        showQueueRecoveryAlert = true
    }

    func recoverInterruptedJobs() {
        let jobsToRecover = pendingRecoveryJobs
        pendingRecoveryJobs.removeAll()
        recoverableJobsCount = 0
        showQueueRecoveryAlert = false

        for job in jobsToRecover {
            job.status = .queued
            job.errorMessage = nil
            if let existingIndex = downloads.firstIndex(where: { $0.id == job.id }) {
                // History may contain a stale copy of the same job. Recovery is
                // authoritative because it carries resumable scratch state and
                // the most recent active-job options.
                downloads[existingIndex] = job
            } else {
                downloads.append(job)
            }
        }
        // Atomically replace the interrupted snapshot with the restored
        // queued state. Deleting first creates a crash window with no recovery file.
        persistQueueRecoveryState()
        objectWillChange.send()
        processQueue()
    }

    func discardInterruptedJobs() {
        let jobsToDiscard = pendingRecoveryJobs
        let discardedIDs = Set(jobsToDiscard.map(\.id))
        pendingRecoveryJobs.removeAll()
        recoverableJobsCount = 0
        showQueueRecoveryAlert = false

        // "Discard" means the interrupted work is no longer resumable. Delete
        // only validated Siphon-owned scratch directories and remove any stale
        // same-ID history copy that was loaded before recovery was evaluated.
        for job in jobsToDiscard {
            job.status = .stopped
            DownloadExecutor.cleanupTemporaryFiles(for: job)
        }
        downloads.removeAll { discardedIDs.contains($0.id) }
        history.removeAll { discardedIDs.contains($0.id) }
        saveHistory()

        // Atomically replace the old interrupted snapshot with whatever
        // active queue remains after discard. Do not delete-then-rewrite.
        persistQueueRecoveryState()
        objectWillChange.send()
    }

    func persistQueueRecoveryState() {
        guard !isShuttingDown else { return }
        var activeJobs = downloads.filter { download in
            switch download.status {
            case .queued, .fetching, .downloading, .processing:
                return true
            default:
                return false
            }
        }
        if !pendingRecoveryJobs.isEmpty {
            let activeIDs = Set(activeJobs.map(\.id))
            let remainingPending = pendingRecoveryJobs.filter { !activeIDs.contains($0.id) }
            activeJobs.append(contentsOf: remainingPending)
        }
        recoveryStore.persist(activeJobs: activeJobs)
    }

    func addDownload(url: String, options: DownloadOptions, mediaInfo: MediaInfo? = nil) {
        let download = Download(url: url, options: options, title: mediaInfo?.title ?? "___FETCHING___")
        if let info = mediaInfo {
            download.mediaInfo = info
            download.thumbnailURL = info.thumbnailURL
            download.duration = info.durationString
        }
        downloads.append(download)
        persistQueueRecoveryState()
        processQueue()
    }


    func addDownloads(urls: [String], options: DownloadOptions) {
        let newDownloads = urls.map { Download(url: $0, options: options) }
        downloads.append(contentsOf: newDownloads)
        persistQueueRecoveryState()
        processQueue()
    }

    func quickDownload(
        url: String,
        rawCookies: String? = nil,
        rawUserAgent: String? = nil,
        browserCookieSource: String? = nil
    ) {
        // Same defaults as the Add sheet and the Home drop target: the selected
        // preset writes its codec/resolution/file type into these preferences.
        var options = DownloadOptions.defaultFromPreferences(userDefaults: userDefaults)
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
        if !downloadIDs.contains(download.id) {
            downloads.append(download)
            persistQueueRecoveryState()
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
        download.progress = 0
        download.errorMessage = nil
        download.log = ""
        download.mediaInfo = nil
        updateStatus(for: download, to: .queued)
        objectWillChange.send()

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
        persistQueueRecoveryState()
        processQueue()
    }

    func moveDownloadDown(_ download: Download) {
        guard queue.moveDown(download: download, in: &downloads) else { return }
        objectWillChange.send()
        persistQueueRecoveryState()
        processQueue()
    }

    func moveDownloadToTop(_ download: Download) {
        guard queue.moveToTop(download: download, in: &downloads) else { return }
        objectWillChange.send()
        persistQueueRecoveryState()
        processQueue()
    }

    func moveDownloadToBottom(_ download: Download) {
        guard queue.moveToBottom(download: download, in: &downloads) else { return }
        objectWillChange.send()
        persistQueueRecoveryState()
        processQueue()
    }

    func moveDownload(from source: IndexSet, to destination: Int) {
        queue.move(from: source, to: destination, in: &downloads)
        objectWillChange.send()
        persistQueueRecoveryState()
        processQueue()
    }

    func resumeWithOverwrite(_ download: Download) {
        download.options.forceOverwrite = true
        // .fileExists pruned the formats. Reusing that copy turns a video-only
        // selectedFormatId into a silent download and keeps stale signed URLs.
        download.mediaInfo = nil
        updateStatus(for: download, to: .queued)
        objectWillChange.send()
        processQueue()
    }
    
    func resumeWithNewName(_ download: Download) {
        let (candidateName, _) = planUniqueOutputPath(for: download, forceIncrement: true)
        download.options.customFilename = candidateName
        download.options.forceOverwrite = false
        download.mediaInfo = nil
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
        // Cancelled tasks never reach their cleanup once the app exits, and no
        // one else owns these directories. Paused/queued jobs keep theirs.
        for download in downloads where DownloadExecutor.shouldCleanupTemporaryFiles(for: download.status) {
            DownloadExecutor.cleanupTemporaryFiles(for: download)
        }
        if pendingRecoveryJobs.isEmpty {
            recoveryStore.markCleanShutdown()
        } else {
            recoveryStore.persist(activeJobs: pendingRecoveryJobs)
        }
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
    
    func stopAllDownloads(preservePaused: Bool = false, suppressNotification: Bool = false) {
        let queuedToStop = downloads.filter {
            $0.status == .queued || (!preservePaused && $0.status == .paused)
        }
        for download in downloadingDownloads + queuedToStop {
            stopDownload(download, suppressNotification: suppressNotification, skipSaveAndBroadcast: true)
        }
        if preservePaused {
            for download in downloads where download.status == .paused {
                addToHistory(download, skipSave: true)
            }
        }
        objectWillChange.send()
        saveHistory()
        // stopDownload(..., skipSaveAndBroadcast: true) deliberately defers
        // recovery removal until this batched history write is durable.
        persistQueueRecoveryState()
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
        persistQueueRecoveryState()
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
        // Paused downloads are live resumable jobs, not disposable history.
        // Keep a sanitized persistence record for them while clearing terminal entries.
        history = downloads
            .filter { $0.status == .paused }
            .map { HistoricDownload(download: $0) }
        historyStore.saveHistory(history)

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

        // Paused, terminal, and action-required states are persisted through
        // history. Keep the previous active recovery snapshot until that history
        // write succeeds so a crash between the status transition and history
        // commit cannot make the job disappear.
        switch status {
        case .paused, .completed, .failed, .stopped, .fileExists:
            break
        default:
            persistQueueRecoveryState()
        }
    }
}

extension DownloadManager: DownloadExecutorDelegate {
    func executorDidUpdateStatus(for download: Download, to status: DownloadStatus) {
        updateStatus(for: download, to: status)
    }

    func executorDidRequestAddToHistory(_ download: Download, skipSave: Bool) {
        // Cancellation can finish after the user removed the job from the app.
        guard downloadIDs.contains(download.id) else { return }
        addToHistory(download, skipSave: skipSave)

        // For normal single-job transitions, history is durable at this point,
        // so recovery can now drop the old active snapshot. Batched callers
        // persist recovery only after their shared saveHistory() call.
        if !skipSave {
            persistQueueRecoveryState()
        }
    }

    func executorDidRequestRecoveryPersist() {
        persistQueueRecoveryState()
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
