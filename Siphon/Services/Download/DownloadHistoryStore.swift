//
//  DownloadHistoryStore.swift
//  Siphon
//

import Foundation

@MainActor
final class DownloadHistoryStore {
    private let userDefaults: UserDefaults
    private let historyKey: String
    static let maxHistoryCount = 500

    init(userDefaults: UserDefaults = .standard, historyKey: String = UserDefaultsKeys.downloadHistory) {
        self.userDefaults = userDefaults
        self.historyKey = historyKey
    }

    func loadHistory() -> [HistoricDownload] {
        guard let data = userDefaults.data(forKey: historyKey) else { return [] }
        let decoder = JSONDecoder()
        // Fast path: Attempt direct batch decoding of valid history arrays.
        // Avoids O(N) Foundation object deserializations, intermediate Data allocations,
        // and per-item JSONDecoder invocations when history is uncorrupted.
        if let decoded = try? decoder.decode([HistoricDownload].self, from: data) {
            return decoded
        }
        // Fallback path: If batch decoding fails (e.g. malformed or corrupted entry),
        // deserialize item-by-item to salvage valid history items and purge bad ones.
        do {
            guard let rawItems = try JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
            var decoded: [HistoricDownload] = []
            var skippedCount = 0
            decoded.reserveCapacity(rawItems.count)
            for rawItem in rawItems {
                guard JSONSerialization.isValidJSONObject(rawItem),
                      let itemData = try? JSONSerialization.data(withJSONObject: rawItem),
                      let item = try? decoder.decode(HistoricDownload.self, from: itemData) else {
                    skippedCount += 1
                    continue
                }
                decoded.append(item)
            }
            if skippedCount > 0 {
                LoggerService.shared.log("Skipped invalid download history entries while restoring history.", level: .warning)
                do {
                    let repairedData = try JSONEncoder().encode(decoded)
                    userDefaults.set(repairedData, forKey: historyKey)
                } catch {
                    LoggerService.shared.log("Failed to persist repaired download history: \(error.localizedDescription)", level: .error)
                }
            }
            return decoded
        } catch {
            LoggerService.shared.log("Failed to restore download history: \(error.localizedDescription)", level: .error)
            return []
        }
    }

    func saveHistory(_ history: [HistoricDownload]) {
        do {
            let encoded = try JSONEncoder().encode(history)
            userDefaults.set(encoded, forKey: historyKey)
        } catch {
            LoggerService.shared.log("Failed to encode download history: \(error.localizedDescription)", level: .error)
        }
    }

    func addToHistory(_ download: Download, history: inout [HistoricDownload], skipSave: Bool = false) {
        let historic = HistoricDownload(download: download)

        // Upsert: remove existing if present
        if let index = history.firstIndex(where: { $0.id == download.id }) {
            history.remove(at: index)
        }
        history.append(historic)

        if history.count > Self.maxHistoryCount {
            // Paused jobs are live, resumable work with scratch data on disk, not
            // history: evict the oldest finished entries instead.
            var excess = history.count - Self.maxHistoryCount
            history.removeAll { entry in
                guard excess > 0, entry.status != .paused else { return false }
                excess -= 1
                return true
            }
        }

        if !skipSave {
            saveHistory(history)
        }
    }

    func clearHistory(history: inout [HistoricDownload]) {
        history.removeAll()
        saveHistory(history)
    }

    static func restoreDownloads(from history: [HistoricDownload], existingDownloads: [Download]) -> [Download] {
        // History is stored oldest-first and `downloads` is in queue (arrival)
        // order, so restore chronologically: new jobs append after it.
        let restored = history.map { $0.toDownload() }
        var result = existingDownloads
        var existingIds = Set(result.lazy.map { $0.id })

        for download in restored {
            download.options.rawCookies = nil // Purge any legacy session cookies from restored history
            if download.title.isEmpty || download.title == Download.fetchingPlaceholder {
                download.title = download.displayTitle
            }
            if !existingIds.contains(download.id) {
                switch download.status {
                case .downloading, .fetching, .processing, .queued:
                    download.status = .stopped
                default:
                    break
                }
                result.append(download)
                existingIds.insert(download.id)
            }
        }
        return result
    }
}
