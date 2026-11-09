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
        app.launchArguments += ["--siphon-ui-test-root", root.path, "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func seedQueue(status: String) throws {
        let seed = #"[{"url":"https://example.com/watch/1","title":"Seeded item","status":"\#(status)"}]"#
        try Data(seed.utf8).write(to: root.appendingPathComponent("queue_seed.json"))
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

    func testSwitchingSettingsTabs() {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let advanced = element("settings-tab-advanced", in: app)
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.click()
        XCTAssertTrue(app.buttons["view-debug-logs"].waitForExistence(timeout: 10))
        let about = element("settings-tab-about", in: app)
        about.click()
        XCTAssertTrue(app.staticTexts["marspater"].waitForExistence(timeout: 10))
    }

    func testRemovingSeededQueueItem() throws {
        try seedQueue(status: "paused")
        let app = launch()
        let segment = element("status-segment-queued", in: app)
        XCTAssertTrue(segment.waitForExistence(timeout: 15))
        segment.click()
        let title = element("queue-row-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        element("row-more", in: app).click()
        let remove = app.menuItems.matching(NSPredicate(format: "identifier == 'row-remove' OR title == 'Remove'")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10))
    }

    func testPausingAndResumingSeededItem() throws {
        try seedQueue(status: "downloading")
        let app = launch()
        let downloading = element("status-segment-downloading", in: app)
        XCTAssertTrue(downloading.waitForExistence(timeout: 15))
        downloading.click()
        let pause = element("row-pause", in: app)
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.click()

        element("status-segment-queued", in: app).click()
        let resume = element("row-resume", in: app)
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.click()
        // With no binaries in this mode the job then fails, leaving the queue tab.
        XCTAssertTrue(resume.waitForNonExistence(timeout: 10))
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
