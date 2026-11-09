import XCTest

final class LaunchPerformanceTests: XCTestCase {
    @MainActor
    func testAppLaunch() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonLaunchPerf-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Preferences", isDirectory: true), withIntermediateDirectories: true)
        app.launchArguments += ["--siphon-ui-test-root", root.path, "-ApplePersistenceIgnoreState", "YES"]
        // AppKit saves window and split-view geometry straight to the standard domain, which
        // the launch argument cannot redirect. These move that domain under the root.
        app.launchEnvironment["CFFIXED_USER_HOME"] = root.path
        app.launchEnvironment["__CFPREFERENCES_AVOID_DAEMON"] = "1"
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
