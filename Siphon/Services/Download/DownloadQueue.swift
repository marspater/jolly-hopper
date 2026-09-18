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

    func planUniqueOutputPath(
        for download: Download,
        forceIncrement: Bool = false,
        fileManager: FileManager = .default
    ) -> (resolvedBaseName: String, candidatePath: String) {
        let rawBaseName = download.options.customFilename ?? download.title
        let sanitizedBase = YtdlpService.sanitizeFilename(rawBaseName)
        let folder = download.options.saveFolder
        let ext = YtdlpService.resolvedOutputFileExtension(for: download.options)

        let existingFiles = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let existingBaseNames = Set(existingFiles.compactMap { file -> String? in
            guard YtdlpService.isMediaFilePath(file.path) else { return nil }
            return Self.filenameCollisionKey(file.deletingPathExtension().lastPathComponent)
        })

        if download.options.forceOverwrite == true && !forceIncrement {
            var candidateName = sanitizedBase
            var candidatePath = folder.appendingPathComponent("\(candidateName).\(ext)").path
            var counter = 1
            while isPathReserved(candidatePath) {
                candidateName = "\(sanitizedBase) (\(counter))"
                candidatePath = folder.appendingPathComponent("\(candidateName).\(ext)").path
                counter += 1
            }
            return (candidateName, candidatePath)
        }

        var counter = 1
        var candidateName = sanitizedBase
        if forceIncrement {
            candidateName = "\(sanitizedBase) (\(counter))"
            counter += 1
        }
        var candidatePath = folder.appendingPathComponent("\(candidateName).\(ext)").path

        while existingBaseNames.contains(Self.filenameCollisionKey(candidateName)) ||
              fileManager.fileExists(atPath: candidatePath) ||
              isPathReserved(candidatePath) {
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

    @discardableResult
    func moveUp(download: Download, in downloads: inout [Download]) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index > 0 else { return false }
        downloads.swapAt(index, index - 1)
        return true
    }

    @discardableResult
    func moveDown(download: Download, in downloads: inout [Download]) -> Bool {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index < downloads.count - 1 else { return false }
        downloads.swapAt(index, index + 1)
        return true
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
