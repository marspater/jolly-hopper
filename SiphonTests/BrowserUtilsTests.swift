import XCTest
@testable import Siphon

final class BrowserUtilsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BrowserUtils.shared.clearCache()
    }

    override func tearDown() {
        BrowserUtils.shared.clearCache()
        super.tearDown()
    }

    func testGetInstalledBrowsersReturnsNonNil() {
        let installed = BrowserUtils.shared.getInstalledBrowsers()
        XCTAssertFalse(installed.isEmpty, "At least Safari should be installed on macOS environment")
        XCTAssertTrue(installed.contains(.safari))
    }

    func testGetInstalledBrowsersUsesCacheOnSecondCall() {
        let firstResult = BrowserUtils.shared.getInstalledBrowsers()
        let secondResult = BrowserUtils.shared.getInstalledBrowsers()

        XCTAssertEqual(firstResult, secondResult)
    }

    func testClearCacheResetsCache() {
        let firstResult = BrowserUtils.shared.getInstalledBrowsers()
        BrowserUtils.shared.clearCache()
        let secondResult = BrowserUtils.shared.getInstalledBrowsers()

        XCTAssertEqual(firstResult, secondResult)
    }
}
