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

    /// The first click on a window that is not yet key only activates it, so allow a retry.
    private func select(_ tab: XCUIElement) -> Bool {
        for _ in 0..<3 {
            tab.click()
            if tab.wait(for: \.isSelected, toEqual: true, timeout: 3) { return true }
        }
        return false
    }

    /// The queue is only reachable from the sidebar, which starts hidden.
    private func openQueue(in app: XCUIApplication) {
        let queued = element("sidebar-queued", in: app)
        if !queued.exists { element("sidebar-toggle", in: app).click() }
        XCTAssertTrue(queued.waitForExistence(timeout: 10))
        queued.click()
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
        XCTAssertTrue(select(advanced), app.debugDescription)
        XCTAssertTrue(select(element("settings-tab-about", in: app)), app.debugDescription)
    }

    func testRemovingSeededQueueItem() throws {
        try seedQueue(status: "paused")
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        openQueue(in: app)
        let title = element("queue-row-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.rightClick()
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

        openQueue(in: app)
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
