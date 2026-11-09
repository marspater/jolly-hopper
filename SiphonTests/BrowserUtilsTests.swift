import Testing
@testable import Siphon
@testable import SiphonCore

extension Tag {
    @Tag static var smoke: Self
}

// Serialized: every test clears the shared browser cache.
@Suite(.serialized, .tags(.smoke))
struct BrowserUtilsTests {
    init() async {
        await BrowserUtils.shared.clearCache()
    }

    @Test func getInstalledBrowsersReturnsNonNil() async {
        let installed = await BrowserUtils.shared.getInstalledBrowsers()
        #expect(!installed.isEmpty, "At least Safari should be installed on macOS environment")
        #expect(installed.contains(.safari))
    }

    @Test func getInstalledBrowsersUsesCacheOnSecondCall() async {
        let firstResult = await BrowserUtils.shared.getInstalledBrowsers()
        let secondResult = await BrowserUtils.shared.getInstalledBrowsers()

        #expect(firstResult == secondResult)
    }

    @Test func clearCacheResetsCache() async {
        let firstResult = await BrowserUtils.shared.getInstalledBrowsers()
        await BrowserUtils.shared.clearCache()
        let secondResult = await BrowserUtils.shared.getInstalledBrowsers()

        #expect(firstResult == secondResult)
    }

    @Test func supportedBrowserChromiumBasedProperties() {
        let chromiumBased = SupportedBrowser.chromiumBased
        #expect(chromiumBased.rawValue == "chromium-based")
        #expect(chromiumBased.displayName == "Chromium-based")
        #expect(chromiumBased.bundleIdentifier == "net.imput.helium")
        #expect(SupportedBrowser.allCases.contains(.chromiumBased))

        // Backward compatibility alias
        let helium = SupportedBrowser.helium
        #expect(helium == .chromiumBased)
    }
}
