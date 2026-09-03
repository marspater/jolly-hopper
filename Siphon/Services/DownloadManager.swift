import Foundation
import AppKit
import Combine
import SwiftUI

struct ReleaseFeature: Identifiable, Sendable {
    let id: UUID
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    init(id: UUID = UUID(), icon: String, iconColor: Color, title: String, description: String) {
        self.id = id
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.description = description
    }
}


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


    private var maxConcurrentDownloads: Int {
        let val = userDefaults.integer(forKey: UserDefaultsKeys.maxConcurrentDownloads)
        return val > 0 ? val : 3
    }
    private let userDefaults = UserDefaults.standard
    var activeControllers: [UUID: DownloadProcessController] = [:]
    var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var reservedDownloadSlots: Set<UUID> = []
    private var isProcessingQueue = false
    var languageService: LanguageService?
    private var reservedOutputPaths: Set<String> = []

    init() {
        ytdlpService.$isUpdating
            .assign(to: &$isUpdatingYtdlp)
        ytdlpService.$updateProgress
            .assign(to: &$ytdlpUpdateProgress)

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.processQueue()
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



    func initialize(languageService: LanguageService) async {
        self.languageService = languageService

        await ytdlpService.setupBinaries()
        // Wait a bit for version to be populated if needed, or better, fetch it explicitly
        await ytdlpService.getVersion()
        ytdlpVersion = ytdlpService.version


        loadHistory()

        await checkAndFetchWhatsNew()
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.1.0"
    }

    static let defaultFeatures: [ReleaseFeature] = [
        ReleaseFeature(
            icon: "textformat",
            iconColor: .purple,
            title: "Native Geist Typography",
            description: "Integrated Vercel Geist and Geist Mono font families natively across all views, controls, and badges."
        ),
        ReleaseFeature(
            icon: "macwindow",
            iconColor: .cyan,
            title: "Translucent Liquid Glass",
            description: "Deep desktop translucency, smooth materials, and refined responsive split-view layouts."
        ),
        ReleaseFeature(
            icon: "bolt.fill",
            iconColor: .blue,
            title: "Multi-Stream & Anti-Bot Engine",
            description: "Chrome Client Hints emulation, multi-connection pooling, and automatic video-only audio multiplexing."
        ),
        ReleaseFeature(
            icon: "menubar.rectangle",
            iconColor: .indigo,
            title: "Control Center Menu Bar",
            description: "Instant download initiation directly from the macOS status bar with quality presets and quick controls."
        ),
        ReleaseFeature(
            icon: "shield.checkerboard",
            iconColor: .green,
            title: "Hardened Security & Cookie Isolation",
            description: "Automated session cookie cleanup, sensitive header redaction in logs, and cryptographic validation."
        ),
        ReleaseFeature(
            icon: "accessibility",
            iconColor: .orange,
            title: "Speed & Accessibility",
            description: "Optimized HTML entity decoding, full VoiceOver screen reader support, and fluid animation feedback."
        )
    ]

    func parseReleaseFeatures(from text: String) -> [ReleaseFeature] {
        var features: [ReleaseFeature] = []
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("---") || trimmed.hasPrefix("===") {
                continue
            }

            var cleanLine = trimmed
            if cleanLine.hasPrefix("- ") || cleanLine.hasPrefix("* ") || cleanLine.hasPrefix("• ") {
                cleanLine = String(cleanLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }

            if let colonIndex = cleanLine.firstIndex(of: ":") {
                let rawTitle = String(cleanLine[..<colonIndex])
                let rawDesc = String(cleanLine[cleanLine.index(after: colonIndex)...])

                let cleanTitle = rawTitle.replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let cleanDesc = rawDesc.replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !cleanTitle.isEmpty && !cleanDesc.isEmpty else { continue }

                let lower = cleanTitle.lowercased() + " " + cleanDesc.lowercased()
                let icon: String
                let color: Color
                if lower.contains("font") || lower.contains("typography") || lower.contains("rebrand") || lower.contains("geist") {
                    icon = "textformat"
                    color = .purple
                } else if lower.contains("glass") || lower.contains("translucen") || lower.contains("material") || lower.contains("ui") || lower.contains("layout") {
                    icon = "macwindow"
                    color = .cyan
                } else if lower.contains("anti-bot") || lower.contains("stream") || lower.contains("engine") || lower.contains("download") || lower.contains("speed") {
                    icon = "bolt.fill"
                    color = .blue
                } else if lower.contains("menu bar") || lower.contains("status bar") || lower.contains("menubar") {
                    icon = "menubar.rectangle"
                    color = .indigo
                } else if lower.contains("security") || lower.contains("cookie") || lower.contains("privacy") || lower.contains("sandbox") {
                    icon = "shield.checkerboard"
                    color = .green
                } else if lower.contains("accessib") || lower.contains("voiceover") || lower.contains("tooltip") || lower.contains("optim") {
                    icon = "accessibility"
                    color = .orange
                } else {
                    icon = "sparkles"
                    color = .blue
                }

                features.append(ReleaseFeature(icon: icon, iconColor: color, title: cleanTitle, description: cleanDesc))
            }
        }

        return features.isEmpty ? DownloadManager.defaultFeatures : features
    }

    func checkAndFetchWhatsNew() async {
        let currentVersion = appVersion
        let lastSeenVersion = userDefaults.string(forKey: UserDefaultsKeys.lastSeenVersion)

        let isFirstEverRun = (lastSeenVersion == nil || lastSeenVersion?.isEmpty == true || lastSeenVersion == "0.0.0")
        let isAppUpdated = (lastSeenVersion != nil && lastSeenVersion != currentVersion && !isFirstEverRun)

        // Only show if app was updated or during the first ever app run after installation
        guard isFirstEverRun || isAppUpdated else {
            return
        }

        whatsNewTitle = languageService?.s("whats_new_title") ?? "What's New in Siphon"
        whatsNewFeatures = DownloadManager.defaultFeatures

        // Proactively fetch NEW info from GitHub releases for current version only
        isFetchingWhatsNew = true
        if let releaseInfo = await fetchReleaseNotesFromGitHub(version: currentVersion) {
            let parsed = parseReleaseFeatures(from: releaseInfo.body)
            if !parsed.isEmpty {
                whatsNewFeatures = parsed
            }
        }
        isFetchingWhatsNew = false

        showWhatsNew = true
        userDefaults.set(currentVersion, forKey: UserDefaultsKeys.lastSeenVersion)
    }

    private func fetchReleaseNotesFromGitHub(version: String) async -> (title: String, body: String)? {
        guard let url = URL(string: "https://api.github.com/repos/marspater/jolly-hopper/releases/tags/v\(version)") else {
            return nil
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Siphon-App/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            guard let tagName = json["tag_name"] as? String else { return nil }
            let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
            // Strictly guard against displaying older release notes for newer app version
            if cleanTag.compare(version, options: .numeric) == .orderedAscending {
                return nil
            }

            let title = (json["name"] as? String) ?? "What's New in Siphon"
            var rawBody = (json["body"] as? String) ?? ""
            rawBody = sanitizeReleaseNotes(rawBody)

            if !rawBody.isEmpty {
                return (title: title, body: rawBody)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func sanitizeReleaseNotes(_ text: String) -> String {
        var sanitized = text.replacingOccurrences(of: "\r\n", with: "\n")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
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
        let currentActive = reservedDownloadSlots.count
        let availableSlots = max(0, limit - currentActive)
        guard availableSlots > 0 else { return }

        var started = 0
        for download in downloads where download.status == .queued && !reservedDownloadSlots.contains(download.id) {
            if started >= availableSlots { break }
            reservedDownloadSlots.insert(download.id)
            startDownloadTask(download)
            started += 1
        }
    }

    private func startDownloadTask(_ download: Download) {
        let downloadId = download.id
        guard download.status == .queued else {
            reservedDownloadSlots.remove(downloadId)
            return
        }
        guard activeTasks[downloadId] == nil else { return }

        let task = Task { [weak self, weak download] in
            guard let self else { return }
            guard let download else {
                await MainActor.run {
                    self.reservedDownloadSlots.remove(downloadId)
                    self.activeTasks.removeValue(forKey: downloadId)
                    self.processQueue()
                }
                return
            }
            await self.executeDownload(download)
        }
        activeTasks[downloadId] = task
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

    private func executeDownload(_ download: Download) async {
        let downloadId = download.id
        let downloadCopy = download
        defer {
            reservedDownloadSlots.remove(downloadId)
            activeTasks.removeValue(forKey: downloadId)
            activeControllers.removeValue(forKey: downloadId)
            if download.status == .stopped || download.status == .failed {
                cleanupTemporaryFiles(for: downloadCopy)
            }
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
            
            let selectedFormats = info.resolveSelectedFormats(options: download.options)
            let primaryFormat = selectedFormats.first(where: { !$0.isAudioOnly }) ?? selectedFormats.first
            download.diagnostics.ytdlpVersion = self.ytdlpVersion
            download.diagnostics.extractor = info.uploader ?? download.sourceDomain
            download.diagnostics.formatId = download.options.selectedFormatId ?? primaryFormat?.formatId
            download.diagnostics.videoCodec = primaryFormat?.vcodec ?? download.options.videoCodec?.rawValue
            download.diagnostics.audioCodec = selectedFormats.first(where: { $0.isAudioOnly || $0.acodec != "none" })?.acodec ?? download.options.audioCodec?.rawValue
            download.diagnostics.container = download.options.fileType.rawValue
            download.diagnostics.resolution = primaryFormat?.resolution
            download.diagnostics.fps = primaryFormat?.fps
            download.diagnostics.dynamicRange = primaryFormat?.dynamicRange
            download.diagnostics.colorSpace = primaryFormat?.colorSpace
            download.diagnostics.bitDepth = primaryFormat?.bitDepth
            download.diagnostics.duration = info.durationString

            let (resolvedBaseName, candidateKey) = resolveUniqueOutputPath(for: download)
            let rawBaseName = download.options.customFilename ?? download.title
            let sanitizedBaseName = YtdlpService.sanitizeFilename(rawBaseName)
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
                        if let speed, !speed.isEmpty {
                            download.diagnostics.peakSpeed = speed
                        }
                    }
                    if !lines.isEmpty {
                        let combined = lines.joined(separator: "\n") + "\n"
                        if download.log.count + combined.count > 50_000 {
                            download.log = String(download.log.suffix(25_000))
                        }
                        download.log.append(combined)
                        if download.status == .downloading {
                            for line in lines {
                                if line.contains("[EmbedThumbnail]") || line.contains("[Metadata]") || line.contains("[Merger]") || line.contains("[VideoConvertor]") || line.contains("[ThumbnailsConvertor]") || line.contains("[EmbedSubtitle]") {
                                    download.status = .processing
                                    break
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
            download.diagnostics.exitStatus = "Completed (0)"
            updateStatus(for: download, to: .completed)
            download.progress = 1.0

            // Attach Finder file icon if embed thumbnail is requested and thumbnail is available
            if download.options.embedThumbnail, let finalURL = download.filePath {
                if let thumbURL = download.thumbnailURL {
                    Task.detached(priority: .utility) {
                        if let data = try? Data(contentsOf: thumbURL), let img = NSImage(data: data) {
                            let squareIcon = YtdlpService.createAspectFitIcon(from: img)
                            await MainActor.run {
                                _ = NSWorkspace.shared.setIcon(squareIcon, forFile: finalURL.path, options: [])
                            }
                        }
                    }
                }
            }

            // Retain key metadata in diagnostics before pruning mediaInfo
            if download.diagnostics.resolution == nil, let maxH = download.mediaInfo?.formats?.compactMap({ $0.parsedHeight }).max() {
                download.diagnostics.resolution = "\(maxH)p"
            }

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
                download.diagnostics.exitStatus = "Stopped by user"
                if download.status == .stopped {
                    addToHistory(download)
                }
                return
            }
            download.diagnostics.exitStatus = "Failed: \(error.localizedDescription)"
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
        if activeTasks[download.id] == nil {
            reservedDownloadSlots.remove(download.id)
            processQueue()
        }
        activeTasks[download.id]?.cancel()
        activeControllers[download.id]?.cancel()
        if !skipSaveAndBroadcast {
            objectWillChange.send()
        }
        addToHistory(download, skipSave: skipSaveAndBroadcast)

        if previousStatus == .queued {
            cleanupTemporaryFiles(for: download)
        }

        if !suppressNotification {
            let lang = languageService ?? LanguageService()
            NotificationService.shared.sendDownloadStopped(filename: download.title.isEmpty ? LoggerService.sanitizeURLForLog(download.url) : download.title, languageService: lang)
        }
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
        guard download.status == .downloading || download.status == .fetching || download.status == .processing || download.status == .queued else {
            return
        }
        updateStatus(for: download, to: .paused)
        if activeTasks[download.id] == nil {
            reservedDownloadSlots.remove(download.id)
            processQueue()
        }
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
        processQueue()
    }

    func moveDownloadDown(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index < downloads.count - 1 else { return }
        downloads.swapAt(index, index + 1)
        objectWillChange.send()
        processQueue()
    }

    func moveDownloadToTop(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index > 0 else { return }
        let item = downloads.remove(at: index)
        downloads.insert(item, at: 0)
        objectWillChange.send()
        processQueue()
    }

    func moveDownloadToBottom(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index < downloads.count - 1 else { return }
        let item = downloads.remove(at: index)
        downloads.append(item)
        objectWillChange.send()
        processQueue()
    }

    func moveDownload(from source: IndexSet, to destination: Int) {
        downloads.move(fromOffsets: source, toOffset: destination)
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
        let rawBase = download.options.customFilename ?? download.title
        let sanitizedBase = YtdlpService.sanitizeFilename(rawBase)
        let folder = download.options.saveFolder
        let ext = download.options.fileType.fileExtension

        var counter = 1
        var candidateName = "\(sanitizedBase) (\(counter))"
        var candidatePath = folder.appendingPathComponent("\(candidateName).\(ext)").path

        let existingFiles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let existingBaseNames = Set(existingFiles.compactMap { file -> String? in
            guard YtdlpService.isMediaFilePath(file.path) else { return nil }
            return file.deletingPathExtension().lastPathComponent
        })

        while existingBaseNames.contains(candidateName) || FileManager.default.fileExists(atPath: candidatePath) || reservedOutputPaths.contains(candidatePath) {
            counter += 1
            candidateName = "\(sanitizedBase) (\(counter))"
            candidatePath = folder.appendingPathComponent("\(candidateName).\(ext)").path
        }

        download.options.customFilename = candidateName
        download.options.forceOverwrite = false
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
        let rawBaseName = download.options.customFilename ?? download.title
        let sanitizedBaseName = YtdlpService.sanitizeFilename(rawBaseName)

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

    nonisolated static func shouldCleanupTemporaryFiles(for status: DownloadStatus) -> Bool {
        return status == .stopped || status == .failed
    }

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
               lower.hasSuffix(".tmp") ||
               (lower.range(of: #"\.f\d+\.part$"#, options: .regularExpression) != nil) ||
               (lower.range(of: #"\.f\d+\.ytdl$"#, options: .regularExpression) != nil) ||
               (lower.range(of: #"\.f\d+\.temp$"#, options: .regularExpression) != nil) ||
               (lower.range(of: #"\.f\d+\.tmp$"#, options: .regularExpression) != nil)
    }

    nonisolated static func isMatchingTemporaryFile(
        fileName: String,
        rawBaseName: String,
        sanitizedBaseName: String,
        videoId: String?
    ) -> Bool {
        let matchesPrefix = (!rawBaseName.isEmpty && fileName.hasPrefix(rawBaseName)) ||
                            (!sanitizedBaseName.isEmpty && fileName.hasPrefix(sanitizedBaseName))
        let matchesId: Bool
        if let vid = videoId, !vid.isEmpty {
            matchesId = fileName.contains(vid)
        } else {
            matchesId = false
        }

        return (matchesPrefix || matchesId) && isTemporaryFileName(fileName)
    }

    private func cleanupTemporaryFiles(for download: Download) {
        guard Self.shouldCleanupTemporaryFiles(for: download.status) else { return }

        let folder = download.options.saveFolder
        let title = download.title
        let rawBaseName = download.options.customFilename ?? title
        let urlString = download.url

        Task.detached {
            let fileManager = FileManager.default
            let videoId = Self.extractVideoId(from: urlString)
            let sanitizedBaseName = YtdlpService.sanitizeFilename(rawBaseName)

            do {
                let contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                
                for file in contents {
                    let fileName = file.lastPathComponent

                    if Self.isMatchingTemporaryFile(
                        fileName: fileName,
                        rawBaseName: rawBaseName,
                        sanitizedBaseName: sanitizedBaseName,
                        videoId: videoId
                    ) {
                        try? fileManager.removeItem(at: file)
                    }
                }
            } catch {
                await MainActor.run {
                    LoggerService.shared.log("Error during temporary files cleanup: \(error.localizedDescription)", level: .error)
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
                    download.options.rawCookies = nil // Purge any legacy session cookies from restored history
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
        downloads.removeAll {
            switch $0.status {
            case .completed, .failed, .stopped, .fileExists:
                return true
            default:
                return false
            }
        }
        objectWillChange.send()
        saveHistory()
    }

    func removeFromHistory(_ download: HistoricDownload) {
        history.removeAll { $0.id == download.id }
        downloads.removeAll { $0.id == download.id }
        objectWillChange.send()
        saveHistory()
    }



    func openFile(_ path: URL) {
        guard YtdlpService.isMediaFilePath(path.path) else {
            LoggerService.shared.log("Refusing to open non-media file via NSWorkspace: \(path.path)", level: .warning)
            return
        }
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
