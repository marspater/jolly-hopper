//
//  DownloadExecutor.swift
//  Siphon
//

import Foundation
import AppKit
import ImageIO

@MainActor
protocol DownloadExecutorDelegate: AnyObject {
    func executorDidUpdateStatus(for download: Download, to status: DownloadStatus)
    func executorDidRequestAddToHistory(_ download: Download, skipSave: Bool)
    func executorDidRequestRecoveryPersist()
    func executorDidFinishDownload()
    func executorDidRequestBroadcast()
}

extension DownloadExecutorDelegate {
    func executorDidRequestRecoveryPersist() {}
}

enum DownloadExecutionState: Equatable {
    case idle
    case active
    case cancelling
}

/// Thread-safe coalescer that batches high-frequency progress and log updates to minimize MainActor thread churn.
///
/// Background producers only append to the pending buffer. Pending events are
/// delivered exclusively by `flushRemaining()`, which the coalescer schedules on
/// the main queue. The executor's final `flushRemaining()` also runs on the main
/// actor, so no delivery can still be in flight after it returns and land after
/// the download has left its active status.
final class DownloadEventCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingProgress: (progress: Double, speed: String?, eta: String?)?
    private var pendingLogLines: [String] = []
    private var pendingLogBytes: Int = 0
    private let maxPendingLines = 500
    private let maxPendingBytes = 1_048_576 // 1MB

    private var drainScheduled = false
    private let onFlush: @Sendable (Double?, String?, String?, [String]) -> Void

    init(onFlush: @escaping @Sendable (Double?, String?, String?, [String]) -> Void) {
        self.onFlush = onFlush
    }

    /// Caller must hold `lock`.
    private func scheduleDrainIfNeeded() {
        if drainScheduled { return }
        drainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.100) { [weak self] in
            self?.flushRemaining()
        }
    }

    func recordProgress(progress: Double, speed: String?, eta: String?) {
        lock.lock()
        pendingProgress = (progress, speed, eta)
        scheduleDrainIfNeeded()
        lock.unlock()
    }

    func recordLogLine(_ line: String) {
        lock.lock()
        pendingLogLines.append(line)
        pendingLogBytes += line.utf8.count

        // Bolt Performance Optimization: Calculate total lines to drop upfront and perform a single `removeFirst(dropCount)`
        // memory move instead of executing repeated O(N) array shifts in a loop for each dropped line.
        if pendingLogLines.count > maxPendingLines || pendingLogBytes > maxPendingBytes {
            var dropCount = 0
            while (pendingLogLines.count - dropCount > maxPendingLines || pendingLogBytes > maxPendingBytes) && dropCount < pendingLogLines.count {
                pendingLogBytes -= pendingLogLines[dropCount].utf8.count
                dropCount += 1
            }
            if dropCount > 0 {
                pendingLogLines.removeFirst(dropCount)
            }
        }

        scheduleDrainIfNeeded()
        lock.unlock()
    }

    /// Delivers everything pending. Call on the main thread in production so
    /// delivery stays ordered with the executor's status transitions.
    func flushRemaining() {
        lock.lock()
        drainScheduled = false
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

extension URLSession {
    /// `data(for:)` with a response-body cap, for pages and images fetched
    /// outside yt-dlp.
    func boundedData(
        for request: URLRequest,
        delegate: (any URLSessionTaskDelegate)? = nil,
        limit: Int = 8 * 1024 * 1024
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await self.bytes(for: request, delegate: delegate)
        guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw URLError(.dataLengthExceedsMaximum) }
        }
        return (data, response)
    }
}

/// Refuses redirects that leave the public network boundary.
private final class PublicRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, ExternalDownloadTargetPolicy.isAllowed(url) else { return nil }
        return request
    }
}

@MainActor
final class DownloadExecutor: ObservableObject {
    private(set) var activeControllers: [UUID: DownloadProcessController] = [:]
    private(set) var activeTasks: [UUID: Task<Void, Never>] = [:]

    var activeExecutionCount: Int {
        activeTasks.count
    }

    func executionState(for downloadID: UUID) -> DownloadExecutionState {
        if activeTasks[downloadID]?.isCancelled == true || activeControllers[downloadID]?.isCancelled == true {
            return .cancelling
        }
        if activeTasks[downloadID] != nil || activeControllers[downloadID] != nil {
            return .active
        }
        return .idle
    }

    func hasActiveTask(for downloadID: UUID) -> Bool {
        activeTasks[downloadID] != nil
    }

    private let ytdlpService: YtdlpService
    private let notificationService: NotificationService
    private var lastRecoveryProgressBucket: [UUID: Int] = [:]
    weak var delegate: DownloadExecutorDelegate?

    nonisolated static func recoveryProgressBucket(for progress: Double) -> Int {
        let safeProgress = progress.isNaN ? 0 : max(0, min(1, progress))
        return Int((safeProgress * 20).rounded(.down))
    }

    private func persistRecoveryProgressIfNeeded(for download: Download) {
        let bucket = Self.recoveryProgressBucket(for: download.progress)
        let previousBucket = lastRecoveryProgressBucket[download.id] ?? bucket
        guard bucket > previousBucket else { return }
        lastRecoveryProgressBucket[download.id] = bucket
        delegate?.executorDidRequestRecoveryPersist()
    }

    init(
        ytdlpService: YtdlpService,
        notificationService: NotificationService = .shared,
        delegate: DownloadExecutorDelegate? = nil
    ) {
        self.ytdlpService = ytdlpService
        self.notificationService = notificationService
        self.delegate = delegate
    }

    // MARK: - Task Scheduling

    func startDownloadTask(
        _ download: Download,
        queue: DownloadQueue,
        ytdlpVersion: String?,
        languageService: LanguageService?
    ) {
        let downloadId = download.id
        guard download.status == .queued else {
            queue.releaseSlot(for: downloadId)
            return
        }
        guard activeTasks[downloadId] == nil else { return }

        let task = Task { [weak self, weak download] in
            guard let self, let download else {
                await MainActor.run {
                    queue.releaseSlot(for: downloadId)
                    self?.activeTasks.removeValue(forKey: downloadId)
                    self?.delegate?.executorDidFinishDownload()
                }
                return
            }
            await self.executeDownload(
                download,
                queue: queue,
                ytdlpVersion: ytdlpVersion,
                languageService: languageService
            )
        }
        activeTasks[downloadId] = task
    }

    // Bolt Performance Optimization: Pre-compile static DateFormatter instance to eliminate
    // object allocation and ICU locale initialization overhead on every log timestamp formatting call.
    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func logTimestamp() -> String {
        return logDateFormatter.string(from: Date())
    }

    private static func appendToLog(for download: Download, text: String) {
        let sanitized = LoggerService.sanitizeDiagnosticText(text)
        if download.log.count + sanitized.count > 50_000 {
            download.log = String(download.log.suffix(25_000))
        }
        download.log.append(sanitized)
    }

    // MARK: - Download Execution

    func executeDownload(
        _ download: Download,
        queue: DownloadQueue,
        ytdlpVersion: String?,
        languageService: LanguageService?
    ) async {
        let downloadId = download.id
        let downloadCopy = download
        defer {
            queue.releaseSlot(for: downloadId)
            activeTasks.removeValue(forKey: downloadId)
            activeControllers.removeValue(forKey: downloadId)
            lastRecoveryProgressBucket.removeValue(forKey: downloadId)
            if download.status != .paused && download.status != .queued {
                Self.cleanupTemporaryFiles(for: downloadCopy)
            }
            delegate?.executorDidFinishDownload()
        }

        guard !Task.isCancelled else { return }
        guard download.status == .queued || download.status == .fetching else { return }

        delegate?.executorDidUpdateStatus(for: download, to: .fetching)
        delegate?.executorDidRequestBroadcast()

        let startMsg = "[\(Self.logTimestamp())] [INFO] Initializing metadata extraction for \(LoggerService.sanitizeURLForLog(download.url))\n"
        if download.log.isEmpty {
            download.log = startMsg
        } else {
            Self.appendToLog(for: download, text: "\n" + startMsg)
        }

        var eventCoalescer: DownloadEventCoalescer?
        do {
            let info: MediaInfo
            let proxyURL = download.options.enforcePublicNetworkBoundary ? try await ytdlpService.egressProxyURL() : nil
            if let existing = download.mediaInfo {
                info = existing
            } else {
                info = try await ytdlpService.fetchInfo(
                    url: download.url,
                    rawCookies: download.options.rawCookies,
                    rawUserAgent: download.options.rawUserAgent,
                    browserCookieSource: download.options.browserCookieSource,
                    proxy: proxyURL
                )
            }

            guard !Task.isCancelled else { return }
            guard download.status == .fetching else { return }

            Self.populateDiagnostics(for: download, info: info, ytdlpVersion: ytdlpVersion)

            let rawBaseName = download.options.customFilename ?? download.title
            let sanitizedBaseName = YtdlpService.sanitizeFilename(rawBaseName)
            let folderPath = download.options.saveFolder

            // Same rule as the queue's collision planning, so a name the
            // queue would rename is reported here. Playlist entries are named
            // per entry by yt-dlp, so the job title says nothing about a collision.
            let options = download.options
            let isPlaylist = info.playlist != nil
            let fileExists = await Task.detached {
                !isPlaylist && DownloadQueue.mediaFileCollides(
                    baseName: sanitizedBaseName,
                    options: options,
                    existingMediaFileKeys: DownloadQueue.existingMediaFileKeys(in: folderPath)
                )
            }.value

            guard !Task.isCancelled else { return }
            guard download.status == .fetching else { return }

            if fileExists && download.options.forceOverwrite != true {
                delegate?.executorDidUpdateStatus(for: download, to: .fileExists)
                delegate?.executorDidRequestBroadcast()
                // File-exists is action-required state, not disposable runtime
                // state. Persist it before allowing recovery to drop the prior
                // active snapshot so a crash does not make the job disappear.
                delegate?.executorDidRequestAddToHistory(download, skipSave: false)
                return
            }

            let (resolvedBaseName, candidateKey) = queue.planUniqueOutputPath(for: download)
            if resolvedBaseName != sanitizedBaseName {
                download.options.customFilename = resolvedBaseName
            }
            queue.reserveOutputPath(candidateKey)
            defer {
                queue.unreserveOutputPath(candidateKey)
            }

            if download.scratchDirectory == nil {
                download.scratchDirectory = ScratchDirectoryPolicy.makeURL()
            }

            // The .downloading transition persists recovery state. Allocate the
            // scratch path first so a crash immediately after launch can still
            // reconnect to resumable partial data.
            delegate?.executorDidUpdateStatus(for: download, to: .downloading)
            lastRecoveryProgressBucket[download.id] = Self.recoveryProgressBucket(for: download.progress)
            delegate?.executorDidRequestBroadcast()
            Self.appendToLog(for: download, text: "[\(Self.logTimestamp())] [INFO] Metadata acquired. Starting download stream...\n")

            let controller = DownloadProcessController()
            activeControllers[download.id] = controller

            LoggerService.shared.log("Starting download for URL: \(LoggerService.sanitizeURLForLog(download.url))", level: .info)

            let coalescer = DownloadEventCoalescer { [weak self, weak download] progress, speed, eta, lines in
                let apply: @MainActor @Sendable () -> Void = { [weak self, weak download] in
                    guard let self, let download else { return }
                    guard download.status == .downloading || download.status == .fetching || download.status == .processing else {
                        return
                    }
                    if let progress {
                        if download.progress != progress {
                            download.progress = progress
                        }
                        if download.speed != speed {
                            download.speed = speed
                        }
                        if download.eta != eta {
                            download.eta = eta
                        }
                        if let speed, !speed.isEmpty, download.diagnostics.peakSpeed != speed {
                            download.diagnostics.peakSpeed = speed
                        }
                        self.persistRecoveryProgressIfNeeded(for: download)
                    }
                    if !lines.isEmpty {
                        let combined = lines.joined(separator: "\n") + "\n"
                        Self.appendToLog(for: download, text: combined)
                        if download.status == .downloading {
                            for line in lines {
                                if Self.isPostprocessingOutput(line) {
                                    self.delegate?.executorDidUpdateStatus(for: download, to: .processing)
                                    self.delegate?.executorDidRequestBroadcast()
                                    break
                                }
                            }
                        }
                    }
                }
                // The final flush runs on the main actor right before the status
                // leaves .downloading. Applied asynchronously it would land after
                // that change and be dropped, losing the job's last log lines.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { apply() }
                } else {
                    DispatchQueue.main.async { apply() }
                }
            }
            eventCoalescer = coalescer

            let downloadResult = try await ytdlpService.download(
                url: download.url,
                options: download.options,
                mediaInfo: download.mediaInfo,
                processController: controller,
                temporaryDirectory: download.scratchDirectory,
                onProgress: { progress, speed, eta in
                    let safeProgress = progress.isNaN ? 0 : max(0, min(1, progress))
                    coalescer.recordProgress(progress: safeProgress, speed: speed, eta: eta)
                },
                onOutput: { line in
                    coalescer.recordLogLine(line)
                }
            )

            coalescer.flushRemaining()

            guard Self.shouldFinalizeSuccessfulDownload(
                taskIsCancelled: Task.isCancelled,
                status: download.status
            ) else {
                return
            }

            if !downloadResult.files.isEmpty {
                download.filePaths = downloadResult.files
            } else if let primary = downloadResult.primaryFile {
                download.filePaths = [primary]
            }
            download.diagnostics.exitStatus = "Completed (0)"
            delegate?.executorDidUpdateStatus(for: download, to: .completed)
            download.progress = 1.0

            if download.options.embedThumbnail, let finalURL = download.primaryFilePath, let thumbURL = download.thumbnailURL {
                Self.attachFinderIcon(from: thumbURL, to: finalURL)
            }

            if download.diagnostics.resolution == nil, let maxH = download.mediaInfo?.downloadableFormats.compactMap({ $0.parsedHeight }).max() {
                download.diagnostics.resolution = "\(maxH)p"
            }

            download.mediaInfo = download.mediaInfo?.prunedForCompletion()
            if download.log.count > 2000 {
                download.log = String(download.log.suffix(2000))
            }
            delegate?.executorDidRequestBroadcast()

            LoggerService.shared.log("Download completed successfully: \(download.displayTitle.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.displayTitle)", level: .info)

            delegate?.executorDidRequestAddToHistory(download, skipSave: false)

            let lang = languageService ?? .shared
            notificationService.sendDownloadCompleted(
                filename: download.displayTitle.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.displayTitle,
                languageService: lang
            )

        } catch let error as YtdlpError {
            eventCoalescer?.flushRemaining()
            if download.status == .stopped || download.status == .paused || Task.isCancelled {
                LoggerService.shared.log("Download stopped or paused by user (\(LoggerService.sanitizeURLForLog(download.url)))", level: .info)
                download.diagnostics.exitStatus = "Stopped by user"
                if download.status == .stopped {
                    if download.title.isEmpty || download.title == Download.fetchingPlaceholder {
                        download.title = download.displayTitle
                    }
                    delegate?.executorDidRequestAddToHistory(download, skipSave: false)
                }
                return
            }
            if download.title.isEmpty || download.title == Download.fetchingPlaceholder {
                download.title = download.displayTitle
            }
            download.diagnostics.exitStatus = "Failed: \(error.localizedDescription)"
            delegate?.executorDidUpdateStatus(for: download, to: .failed)
            delegate?.executorDidRequestBroadcast()

            let errorMsg = Self.errorMessage(for: error, languageService: languageService)
            download.errorMessage = errorMsg
            var failureLog = "[\(Self.logTimestamp())] [ERROR] \(errorMsg)\n"
            if let desc = error.errorDescription, desc != errorMsg {
                failureLog += "[\(Self.logTimestamp())] [DETAILS] \(desc)\n"
            }
            switch error {
            case .commandFailed(let output), .downloadFailed(let output), .subtitleError(let output):
                if !output.isEmpty {
                    failureLog += "[\(Self.logTimestamp())] [DIAGNOSTIC OUTPUT]\n\(output)\n"
                }
            default:
                break
            }
            Self.appendToLog(for: download, text: failureLog)
            LoggerService.shared.log("Download failed (\(LoggerService.sanitizeURLForLog(download.url))): \(errorMsg)", level: .error)
            let lang = languageService ?? .shared
            notificationService.sendDownloadFailed(filename: download.displayTitle.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.displayTitle, languageService: lang)
            delegate?.executorDidRequestAddToHistory(download, skipSave: false)
        } catch {
            eventCoalescer?.flushRemaining()
            if download.status == .stopped || download.status == .paused || Task.isCancelled {
                LoggerService.shared.log("Download stopped or paused by user (\(LoggerService.sanitizeURLForLog(download.url)))", level: .info)
                if download.status == .stopped {
                    if download.title.isEmpty || download.title == Download.fetchingPlaceholder {
                        download.title = download.displayTitle
                    }
                    delegate?.executorDidRequestAddToHistory(download, skipSave: false)
                }
                return
            }
            if download.title.isEmpty || download.title == Download.fetchingPlaceholder {
                download.title = download.displayTitle
            }
            download.diagnostics.exitStatus = "Failed: \(error.localizedDescription)"
            delegate?.executorDidUpdateStatus(for: download, to: .failed)
            delegate?.executorDidRequestBroadcast()

            let errorMsg = Self.errorMessage(for: error, languageService: languageService)
            download.errorMessage = errorMsg
            let failureLog = "[\(Self.logTimestamp())] [ERROR] \(errorMsg)\n[\(Self.logTimestamp())] [DETAILS] \(error.localizedDescription)\n"
            Self.appendToLog(for: download, text: failureLog)
            LoggerService.shared.log("Download failed with error (\(LoggerService.sanitizeURLForLog(download.url))): \(error.localizedDescription)", level: .error)
            let lang = languageService ?? .shared
            notificationService.sendDownloadFailed(filename: download.displayTitle.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.displayTitle, languageService: lang)
            delegate?.executorDidRequestAddToHistory(download, skipSave: false)
        }
    }

    // MARK: - Lifecycle & Control

    static func isPostprocessingOutput(_ line: String) -> Bool {
        // Only yt-dlp's post-download steps; subtitle/thumbnail conversion and
        // SponsorBlock run before the media transfer.
        ["[Merger]", "[Fixup", "[ExtractAudio]", "[VideoRemuxer]", "[VideoConvertor]", "[EmbedSubtitle]",
         "[ModifyChapters]", "[Metadata]", "[EmbedThumbnail]", "[SplitChapters]"]
            .contains { line.hasPrefix($0) }
    }

    func stopDownload(
        _ download: Download,
        queue: DownloadQueue,
        languageService: LanguageService? = nil,
        suppressNotification: Bool = false,
        skipSaveAndBroadcast: Bool = false
    ) {
        guard download.status == .downloading || download.status == .fetching || download.status == .processing || download.status == .queued || download.status == .paused else {
            return
        }
        let previousStatus = download.status

        // Task/process ownership stays with executeDownload until its defer runs.
        // Releasing the slot or removing the task here can allow a replacement
        // download to start while the cancelled metadata/process work is still unwinding.
        delegate?.executorDidUpdateStatus(for: download, to: .stopped)
        if activeTasks[download.id] == nil {
            queue.releaseSlot(for: download.id)
            delegate?.executorDidFinishDownload()
        }
        activeTasks[download.id]?.cancel()
        activeControllers[download.id]?.cancel()
        if !skipSaveAndBroadcast {
            delegate?.executorDidRequestBroadcast()
        }
        delegate?.executorDidRequestAddToHistory(download, skipSave: skipSaveAndBroadcast)

        if activeTasks[download.id] == nil && (previousStatus == .queued || previousStatus == .paused) {
            Self.cleanupTemporaryFiles(for: download)
        }

        if !suppressNotification {
            let lang = languageService ?? .shared
            let rawTitle = download.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholder = rawTitle.isEmpty || rawTitle == Download.fetchingPlaceholder
            let filename = isPlaceholder ? LoggerService.sanitizeURLForLog(download.url) : rawTitle
            notificationService.sendDownloadStopped(
                filename: filename,
                languageService: lang
            )
        }
    }

    func pauseDownload(
        _ download: Download,
        queue: DownloadQueue
    ) {
        guard download.status == .downloading || download.status == .fetching || download.status == .processing || download.status == .queued else {
            return
        }
        delegate?.executorDidUpdateStatus(for: download, to: .paused)
        if activeTasks[download.id] == nil {
            queue.releaseSlot(for: download.id)
            delegate?.executorDidFinishDownload()
        }
        activeTasks[download.id]?.cancel()
        activeControllers[download.id]?.cancel()
        delegate?.executorDidRequestAddToHistory(download, skipSave: false)
        delegate?.executorDidRequestBroadcast()
    }

    func shutdown() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        for (_, controller) in activeControllers {
            controller.cancel()
        }
        // Shutdown precedes app exit, and yt-dlp runs in its own process group,
        // so the app's exit would not take it down.
        DownloadProcessController.waitForPendingTerminations()
        // Do not clear ownership eagerly. Active tasks remove themselves from
        // activeTasks/activeControllers only after process teardown completes.
    }

    // MARK: - Helpers

    nonisolated static func shouldFinalizeSuccessfulDownload(
        taskIsCancelled: Bool,
        status: DownloadStatus
    ) -> Bool {
        guard !taskIsCancelled else { return false }
        return status == .downloading || status == .processing
    }

    static func populateDiagnostics(
        for download: Download,
        info: MediaInfo,
        ytdlpVersion: String?
    ) {
        download.title = info.title
        download.duration = info.durationString
        download.thumbnailURL = info.thumbnailURL
        download.mediaInfo = info

        let selectedFormats = info.resolveSelectedFormats(options: download.options)
        let primaryFormat = selectedFormats.first(where: { !$0.isAudioOnly }) ?? selectedFormats.first
        download.diagnostics.ytdlpVersion = ytdlpVersion
        download.diagnostics.extractor = info.uploader ?? download.sourceDomain
        download.diagnostics.formatId = download.options.selectedFormatId ?? primaryFormat?.formatId
        download.diagnostics.videoCodec = primaryFormat?.vcodec ?? download.options.videoCodec?.rawValue
        download.diagnostics.audioCodec = selectedFormats.first(where: { $0.isAudioOnly || $0.acodec != "none" })?.acodec ?? download.options.audioCodec?.rawValue
        download.diagnostics.container = download.options.fileType.rawValue
        download.diagnostics.fps = primaryFormat?.fps
        download.diagnostics.dynamicRange = primaryFormat?.dynamicRange
        download.diagnostics.colorSpace = primaryFormat?.colorSpace
        download.diagnostics.bitDepth = primaryFormat?.bitDepth
        download.diagnostics.duration = info.durationString

        let ceilingCheck = info.formatResolutionExceedsCeiling(options: download.options)
        if ceilingCheck.exceeded, let req = ceilingCheck.requestedHeight, let act = ceilingCheck.actualHeight {
            let warnMsg = "[Siphon Warning] Requested \(req)p was unavailable. Downloading \(act)p instead.\n"
            appendToLog(for: download, text: warnMsg)
            LoggerService.shared.log("Requested \(req)p format unavailable for '\(download.title)'; downloading \(act)p instead.", level: .warning)
            download.diagnostics.resolution = "\(act)p (requested \(req)p unavailable)"
        } else {
            download.diagnostics.resolution = primaryFormat?.resolution
        }
    }

    static func attachFinderIcon(from thumbURL: URL, to fileURL: URL) {
        Task.detached(priority: .utility) {
            if let data = await fetchThumbnailData(from: thumbURL), let img = NSImage(data: data) {
                let squareIcon = YtdlpService.createAspectFitIcon(from: img)
                await MainActor.run {
                    _ = NSWorkspace.shared.setIcon(squareIcon, forFile: fileURL.path, options: [])
                }
            }
        }
    }

    nonisolated static let maxThumbnailBytes = 5 * 1024 * 1024
    nonisolated static let maxThumbnailPixelDimension = 4096

    /// Thumbnail URLs come from untrusted site metadata. Only fetch public
    /// targets (re-checked on every redirect), bound the body size, and refuse
    /// images whose pixel dimensions would make decoding expensive.
    nonisolated static func fetchThumbnailData(from url: URL, session: URLSession = .shared) async -> Data? {
        await fetchThumbnailData(for: URLRequest(url: url, timeoutInterval: 15), session: session)
    }

    nonisolated static func fetchThumbnailData(for request: URLRequest, session: URLSession = .shared) async -> Data? {
        guard let url = request.url, ExternalDownloadTargetPolicy.isAllowed(url),
              let (data, response) = try? await session.boundedData(
                  for: request,
                  delegate: PublicRedirectPolicy(),
                  limit: maxThumbnailBytes
              ),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              hasAcceptableDimensions(source) else {
            return nil
        }
        return data
    }

    /// Loads a thumbnail file from scratch (written by Siphon or by yt-dlp)
    /// under the same size and dimension limits as a fetched one.
    nonisolated static func loadThumbnailImage(at url: URL) -> NSImage? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= maxThumbnailBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              hasAcceptableDimensions(source) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// Reads only the image header, so nothing oversized is ever decoded.
    private nonisolated static func hasAcceptableDimensions(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return false
        }
        return width <= maxThumbnailPixelDimension && height <= maxThumbnailPixelDimension
    }

    static func errorMessage(for error: Error, languageService: LanguageService?) -> String {
        let lang = languageService ?? .shared
        if let ytdlpError = error as? YtdlpError {
            switch ytdlpError {
            case .safariCookiesFullDiskAccessRequired:
                return lang.s("safari_fda_required")
            case .tooManyRequests:
                return lang.s("too_many_requests")
            case .cloudflareBlocked:
                return lang.s("cloudflare_blocked")
            case .protectedSiteNeedsBrowserCookies:
                return lang.s("browser_cookies_required")
            case .protectedSiteLoginRequired:
                return lang.s("site_sign_in_required")
            case .notFound:
                return lang.s("ytdlp_not_found")
            case .parseError:
                return lang.s("parse_error")
            case .noDownloadableFormats:
                return lang.s("no_downloadable_formats")
            case .ffmpegInstallationFailed:
                return lang.s("ffmpeg_error")
            case .securityViolation(let message):
                return String(format: lang.s("security_violation"), message)
            case .subtitleError(let details):
                return String(format: lang.s("subtitle_download_failed"), details)
            case .downloadFailed(let reason), .commandFailed(let reason):
                let lower = reason.lowercased()
                if lower.contains("cloudflare") || lower.contains("cf-chl-") || lower.contains("anti-bot") || lower.contains("captcha") || lower.contains("turnstile") || lower.contains("just a moment...") {
                    return lang.s("cloudflare_blocked")
                } else if lower.contains("sign in") || lower.contains("private video") || lower.contains("login") || lower.contains("members-only") || lower.contains("403 forbidden") || lower.contains("http error 403") {
                    return lang.s("login_required")
                } else if lower.contains("drm") || lower.contains("widevine") || lower.contains("playready") || lower.contains("fairplay") || lower.contains("encrypted media") || lower.contains("drm protected") || lower.contains("drm-protected") {
                    return lang.s("drm_protected")
                } else if lower.contains("unavailable") || lower.contains("removed") || lower.contains("404 not found") || lower.contains("http error 404") {
                    return lang.s("video_unavailable")
                } else if lower.contains("no space left") || lower.contains("disk full") {
                    return lang.s("disk_full")
                } else if lower.contains("permission denied") {
                    return lang.s("permission_denied")
                } else if lower.contains("unsupported url") {
                    return lang.s("unsupported_url")
                } else if lower.contains("timed out") || lower.contains("timeout") {
                    return lang.s("network_timeout")
                } else {
                    return String(
                        format: lang.s("download_failed_error"),
                        LoggerService.sanitizeDiagnosticText(reason)
                    )
                }
            }
        }

        let errorText = error.localizedDescription
        let lower = errorText.lowercased()
        if lower.contains("no space left") || lower.contains("disk full") {
            return lang.s("disk_full")
        } else if lower.contains("permission denied") {
            return lang.s("permission_denied")
        } else if lower.contains("timed out") || lower.contains("timeout") {
            return lang.s("network_timeout")
        } else {
            return String(
                format: lang.s("download_failed_error"),
                LoggerService.sanitizeDiagnosticText(errorText)
            )
        }
    }

    // MARK: - Temporary Files Cleanup

    nonisolated static func extractVideoId(from urlString: String) -> String? {
        if let url = URL(string: urlString),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            return components.queryItems?.first(where: { $0.name == "v" })?.value ?? url.lastPathComponent
        }
        return nil
    }

    nonisolated static func isTemporaryFileName(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return lower.hasSuffix(".part") ||
               lower.hasSuffix(".ytdl") ||
               lower.hasSuffix(".temp") ||
               lower.hasSuffix(".tmp")
    }

    nonisolated static func isMatchingTemporaryFile(
        fileName: String,
        rawBaseName: String,
        sanitizedBaseName: String,
        videoId _: String? = nil
    ) -> Bool {
        guard isTemporaryFileName(fileName) else { return false }

        let trimmedRaw = rawBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRaw.isEmpty,
           fileName.hasPrefix("\(trimmedRaw).") || fileName == "\(trimmedRaw).part" || fileName == "\(trimmedRaw).ytdl" {
            return true
        }

        let trimmedSanitized = sanitizedBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSanitized.isEmpty,
           fileName.hasPrefix("\(trimmedSanitized).") || fileName == "\(trimmedSanitized).part" || fileName == "\(trimmedSanitized).ytdl" {
            return true
        }

        return false
    }

    nonisolated static func shouldCleanupTemporaryFiles(for status: DownloadStatus) -> Bool {
        return status == .stopped || status == .failed
    }

    static func cleanupTemporaryFiles(for download: Download) {
        guard download.status != .paused && download.status != .queued,
              let directory = download.scratchDirectory else { return }
        guard ScratchDirectoryPolicy.isOwned(directory) else {
            LoggerService.shared.log(
                "Refusing to delete unowned scratch directory: \(directory.lastPathComponent)",
                level: .warning
            )
            download.scratchDirectory = nil
            return
        }
        // Delete only the directory allocated to this job, never scan the save folder.
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            download.scratchDirectory = nil
        } catch {
            LoggerService.shared.log("Could not remove download scratch directory: \(error.localizedDescription)", level: .warning)
        }
    }
}
