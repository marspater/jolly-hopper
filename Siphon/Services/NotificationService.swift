import Foundation
@preconcurrency import UserNotifications
import AppKit

final class NotificationService: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private func logMessage(_ message: String, level: LoggerService.LogLevel) {
        Task { @MainActor in
            LoggerService.shared.log(message, level: level)
        }
    }

    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else {
            logMessage("Notifications unavailable: no bundle identifier", level: .warning)
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    private override init() {
        super.init()
        if let center = notificationCenter {
            center.delegate = self
        }
    }

    // Foreground notification presentation handler for macOS
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound, .list, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        completionHandler()
    }

    func setup() {
        guard let center = notificationCenter else { return }
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                self?.requestPermission()
            } else if settings.authorizationStatus == .authorized {
                self?.logMessage("Notification permission already authorized.", level: .info)
            }
        }
        logMessage("NotificationService initialized, delegate registered.", level: .info)
    }

    func requestPermission() {
        guard let center = notificationCenter else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if granted {
                self?.logMessage("Notification permission granted.", level: .info)
            } else if let error = error {
                self?.logMessage("Notification permission error: \(error.localizedDescription)", level: .error)
            } else {
                self?.logMessage("Notification permission denied by user.", level: .warning)
            }
        }
    }

    private func sendNotification(content: UNMutableNotificationContent, identifier: String = UUID().uuidString, logName: String) {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.showNotifications) as? Bool ?? true else {
            logMessage("Notifications disabled by user setting", level: .warning)
            return
        }
        guard let center = notificationCenter else { return }

        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                self.logMessage("Notification permission not determined. Requesting permission now...", level: .info)
                center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
                    guard let self = self else { return }
                    if granted {
                        self.logMessage("Notification permission granted upon request. Posting notification...", level: .info)
                        self.postNotificationRequest(center: center, content: content, identifier: identifier, logName: logName)
                    } else if let error = error {
                        self.logMessage("Notification permission error: \(error.localizedDescription)", level: .error)
                    } else {
                        self.logMessage("Notification permission denied by user upon request.", level: .warning)
                    }
                }
            case .authorized, .provisional:
                self.postNotificationRequest(center: center, content: content, identifier: identifier, logName: logName)
            case .denied:
                self.logMessage("Notification permission is denied in macOS Settings for Siphon.", level: .warning)
            @unknown default:
                self.postNotificationRequest(center: center, content: content, identifier: identifier, logName: logName)
            }
        }
    }

    private func postNotificationRequest(center: UNUserNotificationCenter, content: UNMutableNotificationContent, identifier: String, logName: String) {
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error = error {
                self?.logMessage("Notification send error (\(logName)): \(error.localizedDescription)", level: .error)
            } else {
                self?.logMessage("Notification posted: \(logName)", level: .info)
            }
        }
    }

    func sendDownloadCompleted(filename: String, languageService: LanguageService? = nil) {
        Task { @MainActor in
            let cleanFilename = filename.decodingHTMLEntities()
            let lang = languageService ?? LanguageService()
            let content = UNMutableNotificationContent()
            content.title = lang.s("download_completed_title")
            content.body = String(format: lang.s("download_completed_body"), cleanFilename)
            content.categoryIdentifier = "download"
            self.sendNotification(content: content, logName: "Completed: \(cleanFilename)")
        }
    }

    func sendEncodingCompleted(filename: String, codec: String, languageService: LanguageService? = nil) {
        let cleanFilename = filename.decodingHTMLEntities()
        let content = UNMutableNotificationContent()
        content.title = "⚡ Video Conversion Complete"
        content.body = "\(cleanFilename) was successfully converted to \(codec) codec."
        sendNotification(content: content, logName: "Conversion: \(cleanFilename)")
    }

    func sendDownloadFailed(filename: String, languageService: LanguageService? = nil) {
        Task { @MainActor in
            let cleanFilename = filename.decodingHTMLEntities()
            let lang = languageService ?? LanguageService()
            let content = UNMutableNotificationContent()
            content.title = lang.s("download_failed_title")
            content.body = String(format: lang.s("download_failed_body"), cleanFilename)
            content.categoryIdentifier = "download"
            self.sendNotification(content: content, logName: "Failed: \(cleanFilename)")
        }
    }

    func sendDownloadStopped(filename: String, languageService: LanguageService? = nil) {
        Task { @MainActor in
            let cleanFilename = filename.decodingHTMLEntities()
            let lang = languageService ?? LanguageService()
            let content = UNMutableNotificationContent()
            content.title = lang.s("download_stopped_title")
            content.body = String(format: lang.s("download_stopped_body"), cleanFilename)
            content.categoryIdentifier = "download"
            self.sendNotification(content: content, logName: "Stopped: \(cleanFilename)")
        }
    }

    func sendYtdlpUpdateSucceeded(version: String) {
        sendYtdlpUpdateNotification(title: "yt-dlp Updated", body: "Installed yt-dlp version \(version).")
    }

    func sendYtdlpUpdateFailed(reason: String) {
        sendYtdlpUpdateNotification(title: "yt-dlp Update Failed", body: reason)
    }

    private func sendYtdlpUpdateNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        sendNotification(content: content, logName: title)
    }
}
