import XCTest
import AppKit
@testable import Siphon

final class ImageUtilitiesTests: XCTestCase {

    func testGenerateThumbnailForNonExistentFileReturnsNil() async {
        let fakeURL = URL(fileURLWithPath: "/non/existent/file_\(UUID().uuidString).mp4")
        let thumbnail = await ImageUtilities.generateThumbnail(for: fakeURL)
        XCTAssertNil(thumbnail)
    }

    func testCreateAspectFitIconWithWideImage() {
        let wideImage = NSImage(size: NSSize(width: 1000, height: 500))
        let icon = ImageUtilities.createAspectFitIcon(from: wideImage, targetSize: 512)
        XCTAssertEqual(icon.size.width, 512)
        XCTAssertEqual(icon.size.height, 512)
    }

    func testCreateAspectFitIconWithTallImage() {
        let tallImage = NSImage(size: NSSize(width: 500, height: 1000))
        let icon = ImageUtilities.createAspectFitIcon(from: tallImage, targetSize: 512)
        XCTAssertEqual(icon.size.width, 512)
        XCTAssertEqual(icon.size.height, 512)
    }

    func testCreateAspectFitIconWithSquareImage() {
        let squareImage = NSImage(size: NSSize(width: 800, height: 800))
        let icon = ImageUtilities.createAspectFitIcon(from: squareImage, targetSize: 512)
        XCTAssertEqual(icon.size.width, 512)
        XCTAssertEqual(icon.size.height, 512)
    }

    func testCreateAspectFitIconWithZeroSizeReturnsOriginal() {
        let zeroImage = NSImage(size: NSSize(width: 0, height: 0))
        let icon = ImageUtilities.createAspectFitIcon(from: zeroImage, targetSize: 512)
        XCTAssertEqual(icon.size.width, 0)
        XCTAssertEqual(icon.size.height, 0)
    }
}
