//
//  DownloadQueue.swift
//  Siphon
//

import Foundation

@MainActor
final class DownloadQueue: ObservableObject {
    private(set) var reservedDownloadSlots: Set<UUID> = []
    private(set) var reservedOutputPaths: Set<String> = []
    private let userDefaults: UserDefaults

    var maxConcurrentDownloads: Int {
        let val = userDefaults.integer(forKey: UserDefaultsKeys.maxConcurrentDownloads)
        return val > 0 ? val : 3
    }

    var activeSlotCount: Int {
        reservedDownloadSlots.count
    }

    var availableSlots: Int {
        max(0, maxConcurrentDownloads - reservedDownloadSlots.count)
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Slot Management

    func isSlotReserved(for id: UUID) -> Bool {
        reservedDownloadSlots.contains(id)
    }

    @discardableResult
    func reserveSlot(for id: UUID) -> Bool {
        reservedDownloadSlots.insert(id).inserted
    }

    func releaseSlot(for id: UUID) {
        reservedDownloadSlots.remove(id)
    }

    func clearReservedSlots() {
        reservedDownloadSlots.removeAll()
    }

    /// Selects the next queued downloads that can be started within the available concurrency limit,
    /// and reserves their slots atomically.
    func scheduleNextDownloads(from downloads: [Download]) -> [Download] {
        let available = availableSlots
        guard available > 0 else { return [] }

        var toStart: [Download] = []
        for download in downloads where download.status == .queued && !reservedDownloadSlots.contains(download.id) {
            if toStart.count >= available { break }
            reservedDownloadSlots.insert(download.id)
            toStart.append(download)
        }
        return toStart
    }

    // MARK: - Output Path Planning & Reservation

    nonisolated static func reservationKey(for path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    nonisolated static func filenameCollisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Collision keys (full filename) of the finished media files in `folder`.
    nonisolated static func existingMediaFileKeys(
        in folder: URL,
        fileManager: FileManager = .default
    ) -> Set<String> {
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Set(files.compactMap { file in
            YtdlpService.isMediaFilePath(file.path) ? filenameCollisionKey(file.lastPathComponent) : nil
        })
    }

    private nonisolated static let videoContainerExtensions = ["mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "ts"]

    /// The one "file exists" rule shared by the queue, the executor and the
    /// Add Download sheet. Audio jobs always convert to their exact
    /// extension. A video job keeps the source container when yt-dlp does not
    /// merge, so it collides with a video file of that name in any container,
    /// but never with audio: `Song.mp3` does not block `Song.mp4`.
    nonisolated static func mediaFileCollides(
        baseName: String,
        options: DownloadOptions,
        existingMediaFileKeys: Set<String>
    ) -> Bool {
        collisionExtensions(for: options).contains {
            existingMediaFileKeys.contains(filenameCollisionKey("\(baseName).\($0)"))
        }
    }

    /// The file on disk that makes `mediaFileCollides` true, if any.
    nonisolated static func collidingMediaFile(
        baseName: String,
        options: DownloadOptions,
        in folder: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let keys = Set(collisionExtensions(for: options).map { filenameCollisionKey("\(baseName).\($0)") })
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first {
            YtdlpService.isMediaFilePath($0.path) && keys.contains(filenameCollisionKey($0.lastPathComponent))
        }
    }

    private nonisolated static func collisionExtensions(for options: DownloadOptions) -> [String] {
        options.fileType.isVideo
            ? videoContainerExtensions
            : [YtdlpService.resolvedOutputFileExtension(for: options)]
    }

    /// Other jobs' reservations block a name by the same rule as files on
    /// disk: a video job holding `Movie.mp4` blocks `Movie.mkv`.
    private func isOutputReserved(baseName: String, in folder: URL, options: DownloadOptions) -> Bool {
        Self.collisionExtensions(for: options).contains {
            isPathReserved(folder.appendingPathComponent("\(baseName).\($0)").path)
        }
    }

    func planUniqueOutputPath(
        for download: Download,
        forceIncrement: Bool = false,
        fileManager: FileManager = .default
    ) -> (resolvedBaseName: String, candidatePath: String) {
        let rawBaseName = download.options.customFilename ?? download.title
        let sanitizedBase = YtdlpService.sanitizeFilename(rawBaseName)
        let folder = download.options.saveFolder
        let ext = YtdlpService.resolvedOutputFileExtension(for: download.options)

        let existingFiles = Self.existingMediaFileKeys(in: folder, fileManager: fileManager)
        // Overwrite consents to replacing the original name only. A name bumped
        // past another job's reservation must be free on disk too, or
        // --force-overwrites would clobber an unrelated file.
        let overwritesOriginal = download.options.forceOverwrite == true

        var counter = 1
        var candidateName = sanitizedBase
        if forceIncrement {
            candidateName = "\(sanitizedBase) (\(counter))"
            counter += 1
        }
        var candidatePath = folder.appendingPathComponent("\(candidateName).\(ext)").path

        while isOutputReserved(baseName: candidateName, in: folder, options: download.options) ||
              (!(overwritesOriginal && candidateName == sanitizedBase) &&
               (Self.mediaFileCollides(baseName: candidateName, options: download.options, existingMediaFileKeys: existingFiles) ||
                fileManager.fileExists(atPath: candidatePath))) {
            candidateName = "\(sanitizedBase) (\(counter))"
            candidatePath = folder.appendingPathComponent("\(candidateName).\(ext)").path
            counter += 1
        }

        return (candidateName, candidatePath)
    }

    @discardableResult
    func reserveUniqueOutputPath(
        for download: Download,
        forceIncrement: Bool = false,
        fileManager: FileManager = .default
    ) -> (resolvedBaseName: String, candidatePath: String) {
        let (candidateName, candidatePath) = planUniqueOutputPath(
            for: download,
            forceIncrement: forceIncrement,
            fileManager: fileManager
        )
        reserveOutputPath(candidatePath)
        download.options.customFilename = candidateName
        return (candidateName, candidatePath)
    }

    func reserveOutputPath(_ path: String) {
        reservedOutputPaths.insert(Self.reservationKey(for: path))
    }

    func unreserveOutputPath(_ path: String) {
        reservedOutputPaths.remove(Self.reservationKey(for: path))
    }

    func isPathReserved(_ path: String) -> Bool {
        reservedOutputPaths.contains(Self.reservationKey(for: path))
    }

    func clearReservedOutputPaths() {
        reservedOutputPaths.removeAll()
    }

    // MARK: - Reordering Helpers

    /// Rows shown on the Queue tab. Up/Down reorder relative to these only, so
    /// a move never swaps with a hidden active, finished, or failed download.
    static func isQueueTabMember(_ download: Download) -> Bool {
        download.status == .queued || download.status == .paused
    }

    @discardableResult
    func moveUp(download: Download, in downloads: inout [Download]) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }),
              let neighbor = downloads[..<index].lastIndex(where: Self.isQueueTabMember) else { return false }
        downloads.swapAt(index, neighbor)
        return true
    }

    @discardableResult
    func moveDown(download: Download, in downloads: inout [Download]) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }),
              let neighbor = downloads[(index + 1)...].firstIndex(where: Self.isQueueTabMember) else { return false }
        downloads.swapAt(index, neighbor)
        return true
    }

    func canMoveUp(download: Download, in downloads: [Download]) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }) else { return false }
        return downloads[..<index].contains(where: Self.isQueueTabMember)
    }

    func canMoveDown(download: Download, in downloads: [Download]) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }) else { return false }
        return downloads[(index + 1)...].contains(where: Self.isQueueTabMember)
    }

    @discardableResult
    func moveToTop(download: Download, in downloads: inout [Download]) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index > 0 else { return false }
        let item = downloads.remove(at: index)
        downloads.insert(item, at: 0)
        return true
    }

    @discardableResult
    func moveToBottom(download: Download, in downloads: inout [Download]) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index < downloads.count - 1 else { return false }
        let item = downloads.remove(at: index)
        downloads.append(item)
        return true
    }

    func move(from source: IndexSet, to destination: Int, in downloads: inout [Download]) {
        downloads.move(fromOffsets: source, toOffset: destination)
    }
}
