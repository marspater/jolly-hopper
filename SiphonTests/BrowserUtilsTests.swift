import XCTest
@testable import Siphon

final class BrowserUtilsTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await BrowserUtils.shared.clearCache()
    }

    override func tearDown() async throws {
        await BrowserUtils.shared.clearCache()
        try await super.tearDown()
    }

    func testGetInstalledBrowsersReturnsNonNil() async {
        let installed = await BrowserUtils.shared.getInstalledBrowsers()
        XCTAssertFalse(installed.isEmpty, "At least Safari should be installed on macOS environment")
        XCTAssertTrue(installed.contains(.safari))
    }

    func testGetInstalledBrowsersUsesCacheOnSecondCall() async {
        let firstResult = await BrowserUtils.shared.getInstalledBrowsers()
        let secondResult = await BrowserUtils.shared.getInstalledBrowsers()

        XCTAssertEqual(firstResult, secondResult)
    }

    func testClearCacheResetsCache() async {
        let firstResult = await BrowserUtils.shared.getInstalledBrowsers()
        await BrowserUtils.shared.clearCache()
        let secondResult = await BrowserUtils.shared.getInstalledBrowsers()

        XCTAssertEqual(firstResult, secondResult)
    }

    func testSupportedBrowserHeliumProperties() {
        let helium = SupportedBrowser.helium
        XCTAssertEqual(helium.rawValue, "helium")
        XCTAssertEqual(helium.displayName, "Helium")
        XCTAssertEqual(helium.bundleIdentifier, "net.imput.helium")
        XCTAssertTrue(SupportedBrowser.allCases.contains(.helium))
    }
}
