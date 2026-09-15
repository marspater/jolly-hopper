import Foundation

enum UserDefaultsKeys {
    static let showMenuBarIcon = "showMenuBarIcon"
    static let showNotifications = "showNotifications"
    static let customPresets = "customPresets"
    static let defaultSaveFolder = "defaultSaveFolder"
    static let lastSeenVersion = "lastSeenVersion_v3"
    static let downloadHistory = "downloadHistory"
    static let browserForCookies = "browserForCookies"
    static let launchAtLogin = "launchAtLogin"
    static let theme = "theme"
    static let maxConcurrentDownloads = "maxConcurrentDownloads"
    static let embedThumbnail = "embedThumbnail"
    static let embedMetadata = "embedMetadata"
    static let defaultFileType = "defaultFileType"
    static let defaultVideoResolution = "defaultVideoResolution"
    static let defaultVideoCodec = "defaultVideoCodec"
    static let defaultAudioCodec = "defaultAudioCodec"
    static let selectedPreset = "selectedPreset"
    static let sponsorBlock = "sponsorBlock"
    static let defaultAdditionalArguments = "defaultAdditionalArguments"
    static let startInBackground = "startInBackground"
    static let selectedCustomPresetId = "selectedCustomPresetId"
    static let downloadSpeedLimit = "downloadSpeedLimit"
    static let resolutionFallbackPolicy = "resolutionFallbackPolicy"
}

// Compatibility extension for the repaired DownloadManager. These methods were
// accidentally dropped from DownloadManager.swift in the previous fix pass.
extension DownloadManager {
    func saveHistory() {
        do {
            let encoded = try JSONEncoder().encode(history)
            UserDefaults.standard.set(encoded, forKey: UserDefaultsKeys.downloadHistory)
        } catch {
            LoggerService.shared.log("Failed to encode download history: \(error.localizedDescription)", level: .error)
        }
    }

    func addToHistory(_ download: Download, skipSave: Bool = false) {
        let historic = HistoricDownload(download: download)

        if let index = history.firstIndex(where: { $0.id == download.id }) {
            history.remove(at: index)
        }
        history.append(historic)

        if history.count > 500 {
            history.removeFirst(history.count - 500)
        }

        if !skipSave {
            saveHistory()
        }
    }

    func restoreDownloadFromHistory(_ historic: HistoricDownload) {
        let download = historic.toDownload()
        download.options.rawCookies = nil

        guard !downloads.contains(where: { $0.id == download.id }) else { return }

        switch download.status {
        case .downloading, .fetching, .processing, .queued:
            download.status = .stopped
        default:
            break
        }
        downloads.append(download)
    }
}
