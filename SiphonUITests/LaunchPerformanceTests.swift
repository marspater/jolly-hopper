import XCTest

final class LaunchPerformanceTests: XCTestCase {
    @MainActor
    func testAppLaunch() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonLaunchPerf-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments += ["--siphon-ui-test-root", root.path]
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
