import XCTest

/// Launches the Debug app with its state redirected to a temporary directory.
@MainActor
final class SmokeUITests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--siphon-ui-test-root", root.path]
        app.launch()
        return app
    }

    func testLaunchShowsMainWindow() {
        XCTAssertTrue(launch().windows.firstMatch.waitForExistence(timeout: 15))
    }

    func testEnteringURLEnablesHeroSubmit() {
        let app = launch()
        let field = app.textFields["hero-url-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.click()
        field.typeText("https://example.com/watch/1")
        XCTAssertTrue(app.buttons["hero-submit"].isEnabled)
    }

    func testOpeningSettings() {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["check-for-updates"].waitForExistence(timeout: 10))
    }

    func testAddDownloadShortcutOpensWindow() {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["add-download-url-field"].waitForExistence(timeout: 10))
    }

    func testSeededRecoveryFileShowsPrompt() throws {
        let job = """
        {"version":1,"timestamp":0,"isCleanShutdown":false,"jobs":[{"id":"\(UUID().uuidString)",\
        "url":"https://example.com/watch/1","title":"Seeded","createdAt":0,\
        "options":{"saveFolder":"\(root.absoluteString)","fileType":"MP4"},\
        "status":"downloading","progress":0.5,"log":""}]}
        """
        try Data(job.utf8).write(to: root.appendingPathComponent("queue_recovery.json"))
        let app = launch()
        XCTAssertTrue(app.buttons["queue-recovery-restore"].waitForExistence(timeout: 15))
    }
}
