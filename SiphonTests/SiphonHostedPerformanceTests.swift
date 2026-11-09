import SiphonCore
import XCTest
@testable import Siphon

/// Run through the Performance test plan only.
@MainActor
final class SiphonHostedPerformanceTests: XCTestCase {
    private let metrics: [XCTMetric] = [XCTClockMetric(), XCTMemoryMetric()]

    func testQueueAdmissionOfThousandItems() {
        TestState.defaults.set(1_000, forKey: UserDefaultsKeys.maxConcurrentDownloads)
        defer { TestState.defaults.removeObject(forKey: UserDefaultsKeys.maxConcurrentDownloads) }
        let downloads = (0..<1_000).map { Download(url: "https://example.com/\($0)", options: .default, title: "t", titleIsDecoded: true) }
        measure(metrics: metrics) {
            let queue = DownloadQueue(userDefaults: TestState.defaults)
            _ = queue.scheduleNextDownloads(from: downloads)
        }
    }

    func testRecoveryLoadOfLargeFixture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonPerf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QueueRecoveryStore(fileURL: url)
        let records = (0..<1_000).map { QueueRecoveryRecord(download: Download(url: "https://example.com/\($0)", options: .default)) }
        try JSONEncoder().encode(QueueRecoverySnapshot(jobs: records)).write(to: url)
        measure(metrics: metrics) {
            _ = store.loadInterruptedJobs()
        }
    }

    /// The other #612 intervals need a real download, so they are read from a trace.
    func testRecoveryLoadSignpost() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonPerf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let records = (0..<1_000).map { QueueRecoveryRecord(download: Download(url: "https://example.com/\($0)", options: .default)) }
        try JSONEncoder().encode(QueueRecoverySnapshot(jobs: records)).write(to: url)
        let manager = DownloadManager.forTesting(recoveryFileURL: url)
        defer { manager.shutdown() }
        let metric = XCTOSSignpostMetric(subsystem: "com.marspater.siphon", category: "Pipeline", name: "Recovery load")
        measure(metrics: [metric, XCTClockMetric()]) {
            manager.checkQueueRecovery()
        }
    }
}
