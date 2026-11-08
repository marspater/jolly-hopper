import Foundation

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
    /// Uses `lazy.map` to stream elements directly into the `Set` without creating an intermediate array allocation on the heap.
    nonisolated public static let allowedRawValues: Set<String> = Set(allCases.lazy.map(\.rawValue))

    /// A browser name that is safe to persist or pass on, or nil.
    /// A Helium handoff reads Helium only; "chromium-based" searches every Chromium browser.
    public static func normalizedCookieSource(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let browser = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if browser == "helium" { return browser }
        return allowedRawValues.contains(browser) ? browser : nil
    }
}
