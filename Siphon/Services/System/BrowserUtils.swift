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
    case chromiumBased = "chromium-based"
    case arc = "arc"

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
        case .chromiumBased: return "Chromium-based"
        case .arc: return "Arc"
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
        case .chromiumBased: return "net.imput.helium"
        case .arc: return "company.thebrowser.Browser"
        }
    }

    /// Backward compatibility alias for Helium browser option
    public static var helium: SupportedBrowser {
        .chromiumBased
    }

    /// Pre-compiled set of all supported browser raw values to eliminate heap allocation during validation passes.
    nonisolated public static let allowedRawValues: Set<String> = Set(allCases.map(\.rawValue))
}

public actor BrowserUtils {
    public static let shared = BrowserUtils()

    private var cachedBrowsers: [SupportedBrowser]?

    public init() {
        // Intentionally empty: singleton and test instantiation (swift:S1186)
    }

    public func getInstalledBrowsers() -> [SupportedBrowser] {
        if let cached = cachedBrowsers {
            return cached
        }

        let workspace = NSWorkspace.shared
        var installed: [SupportedBrowser] = []

        for browser in SupportedBrowser.allCases {
            if browser == .chromiumBased {
                let candidateIDs = [
                    "net.imput.helium",
                    "org.chromium.Chromium",
                    "company.thebrowser.Browser",
                    "org.thorium.Thorium",
                    "io.github.ungoogled-software.ungoogled-chromium"
                ]
                if candidateIDs.contains(where: { workspace.urlForApplication(withBundleIdentifier: $0) != nil }) {
                    installed.append(browser)
                }
            } else if workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil {
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
