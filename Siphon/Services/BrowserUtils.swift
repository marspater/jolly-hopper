import Foundation
import AppKit

enum SupportedBrowser: String, CaseIterable, Identifiable {
    case chrome = "chrome"
    case firefox = "firefox"
    case opera = "opera"
    case edge = "edge"
    case brave = "brave"
    case vivaldi = "vivaldi"
    case safari = "safari"
    case chromium = "chromium"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .firefox: return "Mozilla Firefox"
        case .opera: return "Opera"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .vivaldi: return "Vivaldi"
        case .safari: return "Safari"
        case .chromium: return "Chromium"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .opera: return "com.operasoftware.Opera"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .safari: return "com.apple.Safari"
        case .chromium: return "org.chromium.Chromium"
        }
    }
}

final class BrowserUtils: Sendable {
    static let shared = BrowserUtils()

    private let lock = NSLock()
    private nonisolated(unsafe) var cachedBrowsers: [SupportedBrowser]?

    func getInstalledBrowsers() -> [SupportedBrowser] {
        lock.lock()
        if let cached = cachedBrowsers {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Bolt Performance Optimization: Querying NSWorkspace for installed applications
        // is expensive I/O. Cache the result in memory thread-safely to avoid redundant disk/workspace lookups.
        let workspace = NSWorkspace.shared
        var installed: [SupportedBrowser] = []

        for browser in SupportedBrowser.allCases {
            if let _ = workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
                installed.append(browser)
            }
        }

        lock.lock()
        cachedBrowsers = installed
        lock.unlock()

        return installed
    }

    func clearCache() {
        lock.lock()
        cachedBrowsers = nil
        lock.unlock()
    }
}
