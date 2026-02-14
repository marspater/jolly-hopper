import Foundation
import UserNotifications

class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    
    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else {
            print("⚠️ Notifications unavailable: no bundle identifier")
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
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ Notification permission granted.")
            } else if let error = error {
                print("❌ Notification permission error: \(error.localizedDescription)")
            } else {
                print("⚠️ Notification permission denied by user.")
            }
        }
    }
    
    func sendDownloadCompleted(filename: String, languageService: LanguageService) {
        guard UserDefaults.standard.object(forKey: "showNotifications") as? Bool ?? true else {
            print("⚠️ Notifications disabled by user setting")
            return
        }
        guard let center = notificationCenter else { return }
        
        let content = UNMutableNotificationContent()
        content.title = languageService.s("download_completed_title")
        content.body = String(format: languageService.s("download_completed_body"), filename)
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                print("❌ Notification send error: \(error.localizedDescription)")
            } else {
                print("✅ Notification sent: \(filename)")
            }
        }
    }
    
    func sendDownloadFailed(filename: String, languageService: LanguageService) {
        guard UserDefaults.standard.object(forKey: "showNotifications") as? Bool ?? true else {
            print("⚠️ Notifications disabled by user setting")
            return
        }
        guard let center = notificationCenter else { return }
        
        let content = UNMutableNotificationContent()
        content.title = languageService.s("download_failed_title")
        content.body = String(format: languageService.s("download_failed_body"), filename)
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                print("❌ Notification send error: \(error.localizedDescription)")
            } else {
                print("✅ Notification sent (failed): \(filename)")
            }
        }
    }
}
