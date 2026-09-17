import Foundation
import AppKit

public enum SupportedBrowser: String, CaseIterable, Identifiable, Sendable {
    case chrome = "chrome"
    case firefox = "firefox"
    case opera = "opera"
    case edge = "edge"
    case brave = "brave"
    case vivaldi = "vivaldi"
    case safari = "safari"
    case chromium = "chromium"

    public var id: String { rawValue }

    public var displayName: String {
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

    public var bundleIdentifier: String {
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

public actor BrowserUtils {
    public static let shared = BrowserUtils()

    private var cachedBrowsers: [SupportedBrowser]?

    public init() {}

    public func getInstalledBrowsers() -> [SupportedBrowser] {
        if let cached = cachedBrowsers {
            return cached
        }

        let workspace = NSWorkspace.shared
        var installed: [SupportedBrowser] = []

        for browser in SupportedBrowser.allCases {
            if let _ = workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
                installed.append(browser)
            }
        }

        cachedBrowsers = installed
        return installed
    }

    public func clearCache() {
        cachedBrowsers = nil
    }
}
