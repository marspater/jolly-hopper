//
//  ReleaseNotesServiceTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

@MainActor
final class ReleaseNotesServiceTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.releasenotes.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        testDefaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testDefaultFeaturesCount() {
        XCTAssertEqual(ReleaseNotesService.defaultFeatures.count, 5)
    }

    func testSanitizeReleaseNotes() {
        let service = ReleaseNotesService(userDefaults: testDefaults)
        let input = "  Line 1\r\nLine 2\r\n\r\n  "
        let output = service.sanitizeReleaseNotes(input)
        XCTAssertEqual(output, "Line 1\nLine 2")
    }

    func testParseReleaseFeaturesExtractsFeatures() {
        let service = ReleaseNotesService(userDefaults: testDefaults)
        let markdown = """
        # Release 5.3.0
        - Security & Sandbox: Hardened cookie containment and credential redaction.
        - Typography & Geist: Added premium Geist variable font rendering.
        - Performance & Speed: Pre-compiled regexes and zero-allocation parsing.
        """

        let features = service.parseReleaseFeatures(from: markdown)
        XCTAssertEqual(features.count, 3)
        XCTAssertEqual(features[0].title, "Security & Sandbox")
        XCTAssertEqual(features[0].icon, "shield.checkerboard")
        XCTAssertEqual(features[1].title, "Typography & Geist")
        XCTAssertEqual(features[1].icon, "textformat")
        XCTAssertEqual(features[2].title, "Performance & Speed")
        XCTAssertEqual(features[2].icon, "bolt.fill")
    }

    func testCheckAndFetchWhatsNewFirstRun() async {
        let service = ReleaseNotesService(userDefaults: testDefaults)
        let result = await service.checkAndFetchWhatsNew(appVersion: "5.3.0", languageService: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.shouldShow, true)
        XCTAssertEqual(testDefaults.string(forKey: UserDefaultsKeys.lastSeenVersion), "5.3.0")
    }

    func testCheckAndFetchWhatsNewSameVersionDoesNotShow() async {
        testDefaults.set("5.3.0", forKey: UserDefaultsKeys.lastSeenVersion)
        let service = ReleaseNotesService(userDefaults: testDefaults)
        let result = await service.checkAndFetchWhatsNew(appVersion: "5.3.0", languageService: nil)
        XCTAssertNil(result)
    }
}
