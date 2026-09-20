import Foundation
@preconcurrency import UserNotifications
import AppKit

final class NotificationService: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private func logMessage(_ message: String, level: LoggerService.LogLevel) {
        DispatchQueue.main.async {
            LoggerService.shared.log(message, level: level)
        }
    }

    static var isRunningTests: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if NSClassFromString("XCTest") != nil {
            return true
        }
        if let bundleId = Bundle.main.bundleIdentifier, bundleId.contains("xctest") {
            return true
        }
        return false
    }

    var isNotificationCenterAvailable: Bool {
        return notificationCenter != nil
    }

    private var notificationCenter: UNUserNotificationCenter? {
        if Self.isRunningTests {
            return nil
        }
        guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty, !bundleId.contains("xctest") else {
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
    @objc func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list, .badge])
    }

    @objc func userNotificationCenter(
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

    private var isSetup = false

    func setup() {
        guard !isSetup else { return }
        isSetup = true
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

    private func logPermissionError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == UNErrorDomain && nsError.code == 1 {
            logMessage("Notification permission not available in current environment.", level: .debug)
        } else {
            logMessage("Notification permission error: \(error.localizedDescription)", level: .error)
        }
    }

    func requestPermission() {
        guard let center = notificationCenter else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if granted {
                self?.logMessage("Notification permission granted.", level: .info)
            } else if let error = error {
                self?.logPermissionError(error)
            } else {
                self?.logMessage("Notification permission denied by user.", level: .warning)
            }
        }
    }

    private func fallbackDisplayNotification(title: String, body: String) {
        guard !Self.isRunningTests else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let escapedTitle = title
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let escapedBody = body
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")

            let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"default\""
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    self?.logMessage("Fallback notification displayed: \(title)", level: .info)
                } else {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let details = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let details, !details.isEmpty {
                        self?.logMessage("Fallback notification failed: \(details)", level: .warning)
                    } else {
                        self?.logMessage(
                            "Fallback notification failed: osascript exited with status \(process.terminationStatus)",
                            level: .warning
                        )
                    }
                }
            } catch {
                self?.logMessage("Fallback notification failed: \(error.localizedDescription)", level: .warning)
            }
        }
    }

    private func sendNotification(content: UNMutableNotificationContent, identifier: String = UUID().uuidString, logName: String) {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.showNotifications) as? Bool ?? true else {
            logMessage("Notifications disabled by user setting", level: .warning)
            return
        }
        guard let center = notificationCenter else {
            fallbackDisplayNotification(title: content.title, body: content.body)
            return
        }

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
                    } else {
                        if let error = error {
                            self.logPermissionError(error)
                        } else {
                            self.logMessage("Notification permission denied by user upon request.", level: .warning)
                        }
                        self.fallbackDisplayNotification(title: content.title, body: content.body)
                    }
                }
            case .authorized, .provisional:
                self.postNotificationRequest(center: center, content: content, identifier: identifier, logName: logName)
            case .denied:
                self.logMessage("Notification permission is denied in macOS Settings for Siphon. Using fallback...", level: .warning)
                self.fallbackDisplayNotification(title: content.title, body: content.body)
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
                self?.logMessage("Notification send error (\(logName)): \(error.localizedDescription). Attempting fallback...", level: .error)
                self?.fallbackDisplayNotification(title: content.title, body: content.body)
            } else {
                self?.logMessage("Notification posted: \(logName)", level: .info)
            }
        }
    }

    func sendDownloadCompleted(filename: String, languageService: LanguageService? = nil) {
        let cleanFilename = filename.decodingHTMLEntities()
        let lang = languageService ?? LanguageService()
        let content = UNMutableNotificationContent()
        content.title = lang.s("download_completed_title")
        content.body = String(format: lang.s("download_completed_body"), cleanFilename)
        content.sound = .default
        content.categoryIdentifier = "download"
        self.sendNotification(content: content, logName: "Completed: \(cleanFilename)")
    }

    func sendEncodingCompleted(filename: String, codec: String, languageService: LanguageService? = nil) {
        let cleanFilename = filename.decodingHTMLEntities()
        let content = UNMutableNotificationContent()
        content.title = "⚡ Video Conversion Complete"
        content.body = "\(cleanFilename) was successfully converted to \(codec) codec."
        content.sound = .default
        sendNotification(content: content, logName: "Conversion: \(cleanFilename)")
    }

    func sendDownloadFailed(filename: String, languageService: LanguageService? = nil) {
        let cleanFilename = filename.decodingHTMLEntities()
        let lang = languageService ?? LanguageService()
        let content = UNMutableNotificationContent()
        content.title = lang.s("download_failed_title")
        content.body = String(format: lang.s("download_failed_body"), cleanFilename)
        content.sound = .default
        content.categoryIdentifier = "download"
        self.sendNotification(content: content, logName: "Failed: \(cleanFilename)")
    }

    func sendDownloadStopped(filename: String, languageService: LanguageService? = nil) {
        let cleanFilename = filename.decodingHTMLEntities()
        let lang = languageService ?? LanguageService()
        let content = UNMutableNotificationContent()
        content.title = lang.s("download_stopped_title")
        content.body = String(format: lang.s("download_stopped_body"), cleanFilename)
        content.sound = .default
        content.categoryIdentifier = "download"
        self.sendNotification(content: content, logName: "Stopped: \(cleanFilename)")
    }

    func sendYtdlpUpdateSucceeded(version: String) {
        sendYtdlpUpdateNotification(title: "yt-dlp Updated", body: "Installed yt-dlp version \(version).")
    }

    func sendYtdlpUpdateFailed(reason: String) {
        sendYtdlpUpdateNotification(title: "yt-dlp Update Failed", body: reason)
    }

    func sendAppUpdateNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        sendNotification(content: content, logName: title)
    }

    private func sendYtdlpUpdateNotification(title: String, body: String) {
        sendAppUpdateNotification(title: title, body: body)
    }
}
