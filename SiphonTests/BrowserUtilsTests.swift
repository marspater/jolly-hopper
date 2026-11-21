import Foundation
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
    }
}

struct DeepLinkRouteTests {
    @Test func parsesDownloadAndFastDownloadWithoutCredentials() throws {
        let link = try #require(URL(string: "siphon://Fast-Download?url=https%3A%2F%2Fexample.com%2Fv&ua=UA&browser=chrome&cookies=secret"))
        #expect(DeepLinkRoute(link) == .download(url: "https://example.com/v", isFastDownload: true, userAgent: "UA", browserSource: "chrome"))
        let plain = try #require(URL(string: "siphon://download?url=https%3A%2F%2Fexample.com%2Fv"))
        #expect(DeepLinkRoute(plain) == .download(url: "https://example.com/v", isFastDownload: false, userAgent: nil, browserSource: nil))
    }

    @Test func unknownHostsAreOther() throws {
        #expect(DeepLinkRoute(try #require(URL(string: "siphon://settings"))) == .other)
        #expect(DeepLinkRoute(try #require(URL(string: "siphon:///download"))) == .other)
    }
}
