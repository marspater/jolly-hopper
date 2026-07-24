import Foundation
import UserNotifications

class NotificationService: NSObject, UNUserNotificationCenterDelegate {
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
        // Set ourselves as the delegate so notifications show even when app is in foreground
        if let center = notificationCenter {
            center.delegate = self
        }
    }

    // This delegate method allows notifications to be shown even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner and play sound even when app is active
        completionHandler([.banner, .sound])
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

    func sendDownloadCompleted(filename: String, languageService: LanguageService) {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.showNotifications) as? Bool ?? true else {
            logMessage("Notifications disabled by user setting", level: .warning)
            return
        }
        guard let center = notificationCenter else { return }

        let content = UNMutableNotificationContent()
        content.title = languageService.s("download_completed_title")
        content.body = String(format: languageService.s("download_completed_body"), filename)
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error = error {
                self?.logMessage("Notification send error: \(error.localizedDescription)", level: .error)
            } else {
                self?.logMessage("Notification sent: \(filename)", level: .info)
            }
        }
    }

    func sendEncodingCompleted(filename: String, codec: String, languageService: LanguageService) {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.showNotifications) as? Bool ?? true else { return }
        guard let center = notificationCenter else { return }

        let content = UNMutableNotificationContent()
        content.title = "⚡ Video Conversion Complete"
        content.body = "\(filename) was successfully converted to \(codec) codec."
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    func sendDownloadFailed(filename: String, languageService: LanguageService) {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.showNotifications) as? Bool ?? true else {
            logMessage("Notifications disabled by user setting", level: .warning)
            return
        }
        guard let center = notificationCenter else { return }

        let content = UNMutableNotificationContent()
        content.title = languageService.s("download_failed_title")
        content.body = String(format: languageService.s("download_failed_body"), filename)
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error = error {
                self?.logMessage("Notification send error: \(error.localizedDescription)", level: .error)
            } else {
                self?.logMessage("Notification sent (failed): \(filename)", level: .info)
            }
        }
    }

    func sendDownloadStopped(filename: String, languageService: LanguageService) {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.showNotifications) as? Bool ?? true else {
            logMessage("Notifications disabled by user setting", level: .warning)
            return
        }
        guard let center = notificationCenter else { return }

        let content = UNMutableNotificationContent()
        content.title = languageService.s("download_stopped_title")
        content.body = String(format: languageService.s("download_stopped_body"), filename)
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error = error {
                self?.logMessage("Notification send error: \(error.localizedDescription)", level: .error)
            } else {
                self?.logMessage("Notification sent (stopped): \(filename)", level: .info)
            }
        }
    }
    func sendYtdlpUpdateSucceeded(version: String) {
        sendYtdlpUpdateNotification(title: "yt-dlp Updated", body: "Installed yt-dlp version \(version).")
    }

    func sendYtdlpUpdateFailed(reason: String) {
        sendYtdlpUpdateNotification(title: "yt-dlp Update Failed", body: reason)
    }

    private func sendYtdlpUpdateNotification(title: String, body: String) {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.showNotifications) as? Bool ?? true else {
            logMessage("Notifications disabled by user setting", level: .warning)
            return
        }
        guard let center = notificationCenter else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error = error {
                self?.logMessage("yt-dlp update notification send error: \(error.localizedDescription)", level: .error)
            }
        }
    }

}
