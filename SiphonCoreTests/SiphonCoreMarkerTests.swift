import SiphonCore
import XCTest

final class SiphonCoreMarkerTests: XCTestCase {
    func testFrameworkLinks() {
        XCTAssertEqual(SiphonCoreMarker.name, "SiphonCore")
    }
}
