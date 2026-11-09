import Foundation
import AppKit
import SiphonCore

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
