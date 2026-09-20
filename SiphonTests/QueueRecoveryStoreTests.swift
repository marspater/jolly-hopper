//
//  QueueRecoveryStoreTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

@MainActor
final class QueueRecoveryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var recoveryFileURL: URL!
    private var originalHistory: Any?

    override func setUp() async throws {
        try await super.setUp()
        originalHistory = UserDefaults.standard.object(forKey: UserDefaultsKeys.downloadHistory)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.downloadHistory)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("QueueRecoveryTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        recoveryFileURL = tempDir.appendingPathComponent("queue_recovery_test.json")
    }

    override func tearDown() async throws {
        if let originalHistory = originalHistory {
            UserDefaults.standard.set(originalHistory, forKey: UserDefaultsKeys.downloadHistory)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.downloadHistory)
        }
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testAtomicPersistenceAndCrashRecovery() {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)

        let dl1 = Download(url: "https://example.com/video1", options: .default, title: "Video 1")
        dl1.status = .queued
        let dl2 = Download(url: "https://example.com/video2", options: .default, title: "Video 2")
        dl2.status = .downloading
        dl2.progress = 0.42

        // Persist active jobs (simulating active download session before crash)
        store.persist(activeJobs: [dl1, dl2])

        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFileURL.path))

        // Create a new store instance pointing to same file (simulating app restart after crash)
        let restartStore = QueueRecoveryStore(fileURL: recoveryFileURL)
        let recoverable = restartStore.loadInterruptedJobs()

        XCTAssertEqual(recoverable.count, 2)
        XCTAssertEqual(recoverable[0].url, "https://example.com/video1")
        XCTAssertEqual(recoverable[0].title, "Video 1")
        XCTAssertEqual(recoverable[0].status, .queued)

        XCTAssertEqual(recoverable[1].url, "https://example.com/video2")
        XCTAssertEqual(recoverable[1].title, "Video 2")
        XCTAssertEqual(recoverable[1].progress, 0.42)
    }

    func testCleanShutdownPreventsCrashRecoveryPrompt() {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)

        let dl1 = Download(url: "https://example.com/video1", options: .default, title: "Video 1")
        dl1.status = .downloading

        store.persist(activeJobs: [dl1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFileURL.path))

        // Normal clean shutdown
        store.markCleanShutdown()

        let restartStore = QueueRecoveryStore(fileURL: recoveryFileURL)
        let recoverable = restartStore.loadInterruptedJobs()
        XCTAssertTrue(recoverable.isEmpty, "Clean shutdown must not offer recovery")
    }

    func testCorruptedFileRecoversGracefully() throws {
        try "not valid json {[[".write(to: recoveryFileURL, atomically: true, encoding: .utf8)

        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let recoverable = store.loadInterruptedJobs()
        XCTAssertTrue(recoverable.isEmpty, "Corrupt file must yield empty list without crashing")
    }

    func testClearRecoveryState() {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let dl = Download(url: "https://example.com/video1", options: .default, title: "Video 1")
        dl.status = .queued

        store.persist(activeJobs: [dl])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFileURL.path))

        store.clearRecoveryState()
        let restartStore = QueueRecoveryStore(fileURL: recoveryFileURL)
        XCTAssertTrue(restartStore.loadInterruptedJobs().isEmpty)
    }

    func testDownloadManagerIntegratesQueueRecovery() async throws {
        let manager = DownloadManager(recoveryFileURL: recoveryFileURL)
        defer { manager.shutdown() }

        let dl = Download(url: "https://example.com/active", options: .default, title: "Active Download")
        dl.status = .downloading
        manager.downloads = [dl]

        // Trigger persistence via state change
        manager.persistQueueRecoveryState()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFileURL.path))

        // Simulate crash restart with a new manager instance
        let restartedManager = DownloadManager(recoveryFileURL: recoveryFileURL)
        defer { restartedManager.shutdown() }

        let languageService = LanguageService()
        restartedManager.initialize(languageService: languageService)

        XCTAssertTrue(restartedManager.showQueueRecoveryAlert)
        XCTAssertEqual(restartedManager.recoverableJobsCount, 1)

        // User accepts recovery
        restartedManager.recoverInterruptedJobs()

        XCTAssertFalse(restartedManager.showQueueRecoveryAlert)
        XCTAssertEqual(restartedManager.downloads.count, 1)
        XCTAssertEqual(restartedManager.downloads.first?.url, "https://example.com/active")
        XCTAssertEqual(restartedManager.downloads.first?.status, .queued)
    }

    func testDownloadManagerDiscardRecovery() async throws {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let dl = Download(url: "https://example.com/discard", options: .default, title: "Discard Download")
        dl.status = .downloading
        store.persist(activeJobs: [dl])

        let manager = DownloadManager(recoveryFileURL: recoveryFileURL)
        defer { manager.shutdown() }

        let languageService = LanguageService()
        manager.initialize(languageService: languageService)

        XCTAssertTrue(manager.showQueueRecoveryAlert)
        manager.discardInterruptedJobs()

        XCTAssertFalse(manager.showQueueRecoveryAlert)
        XCTAssertEqual(manager.recoverableJobsCount, 0)
        XCTAssertTrue(manager.downloads.isEmpty)
    }
}
