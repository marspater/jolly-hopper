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
    func testRecoveryPreservesOwnedScratchDirectoryBrowserSourceAndCreationDate() throws {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let scratch = ScratchDirectoryPolicy.makeURL()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var options = DownloadOptions.default
        options.rawCookies = "session=secret"
        options.rawUserAgent = "FixtureBrowser/1.0"
        options.browserCookieSource = "firefox"
        options.additionalArguments = "--add-header Authorization: secret"

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let download = Download(
            url: "https://example.com/recover",
            options: options,
            title: "Recover",
            createdAt: createdAt
        )
        download.status = .downloading
        download.progress = 0.42
        download.scratchDirectory = scratch

        store.persist(activeJobs: [download])
        let restored = try XCTUnwrap(store.loadInterruptedJobs().first)

        XCTAssertEqual(restored.createdAt, createdAt)
        XCTAssertEqual(restored.scratchDirectory?.standardizedFileURL.path, scratch.standardizedFileURL.path)
        XCTAssertEqual(restored.options.browserCookieSource, "firefox")
        XCTAssertNil(restored.options.rawCookies)
        XCTAssertNil(restored.options.rawUserAgent)
        XCTAssertNil(restored.options.additionalArguments)
    }

    func testRecoveryRejectsUnownedScratchDirectory() throws {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let unowned = FileManager.default.temporaryDirectory
            .appendingPathComponent("siphon_scratch_not-a-uuid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unowned) }

        let download = Download(url: "https://example.com/recover", options: .default)
        download.status = .downloading
        download.scratchDirectory = unowned

        store.persist(activeJobs: [download])
        let restored = try XCTUnwrap(store.loadInterruptedJobs().first)
        XCTAssertNil(restored.scratchDirectory)
    }

    func testRecoveryReplacesStaleHistoryCopyForSameJob() throws {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let id = UUID()
        let scratch = ScratchDirectoryPolicy.makeURL()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var recoveredOptions = DownloadOptions.default
        recoveredOptions.customFilename = "Recovered Name"
        recoveredOptions.browserCookieSource = "firefox"
        let recovered = Download(
            url: "https://example.com/active",
            options: recoveredOptions,
            title: "Recovered",
            id: id
        )
        recovered.status = .downloading
        recovered.progress = 0.67
        recovered.scratchDirectory = scratch
        store.persist(activeJobs: [recovered])

        let stale = Download(
            url: "https://example.com/active",
            options: .default,
            title: "Stale History",
            id: id
        )
        stale.status = .paused
        let historyData = try JSONEncoder().encode([HistoricDownload(download: stale)])
        UserDefaults.standard.set(historyData, forKey: UserDefaultsKeys.downloadHistory)

        let manager = DownloadManager(recoveryFileURL: recoveryFileURL)
        manager.ytdlpService.isUpdating = true
        defer { manager.shutdown() }
        manager.initialize(languageService: LanguageService())
        manager.recoverInterruptedJobs()

        let restored = try XCTUnwrap(manager.downloads.first(where: { $0.id == id }))
        XCTAssertEqual(restored.status, .queued)
        XCTAssertEqual(restored.progress, 0.67)
        XCTAssertEqual(restored.options.customFilename, "Recovered Name")
        XCTAssertEqual(restored.options.browserCookieSource, "firefox")
        XCTAssertEqual(restored.scratchDirectory?.standardizedFileURL.path, scratch.standardizedFileURL.path)
    }

    func testQueueReorderIsPersistedForCrashRecovery() {
        let manager = DownloadManager(recoveryFileURL: recoveryFileURL)
        manager.ytdlpService.isUpdating = true
        defer { manager.shutdown() }

        let first = Download(url: "https://example.com/1", options: .default, title: "First")
        let second = Download(url: "https://example.com/2", options: .default, title: "Second")
        let third = Download(url: "https://example.com/3", options: .default, title: "Third")
        manager.downloads = [first, second, third]
        manager.persistQueueRecoveryState()

        manager.moveDownloadToTop(third)

        let restoredOrder = manager.recoveryStore.loadInterruptedJobs().map(\.title)
        XCTAssertEqual(restoredOrder, ["Third", "First", "Second"])
    }

    func testClearHistoryPreservesPausedJobPersistence() throws {
        let manager = DownloadManager(recoveryFileURL: recoveryFileURL)
        defer { manager.shutdown() }

        let scratch = ScratchDirectoryPolicy.makeURL()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var pausedOptions = DownloadOptions.default
        pausedOptions.browserCookieSource = "firefox"
        let paused = Download(url: "https://example.com/paused", options: pausedOptions, title: "Paused")
        paused.status = .paused
        paused.progress = 0.48
        paused.scratchDirectory = scratch

        let completed = Download(url: "https://example.com/completed", options: .default, title: "Completed")
        completed.status = .completed

        manager.downloads = [paused, completed]
        manager.addToHistory(paused)
        manager.addToHistory(completed)

        manager.clearHistory()

        XCTAssertEqual(manager.downloads.map(\.id), [paused.id])
        XCTAssertEqual(manager.history.map(\.id), [paused.id])

        let stored = try XCTUnwrap(manager.historyStore.loadHistory().first)
        let restored = stored.toDownload()
        XCTAssertEqual(restored.id, paused.id)
        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.progress, 0.48)
        XCTAssertEqual(restored.options.browserCookieSource, "firefox")
        XCTAssertEqual(restored.scratchDirectory?.standardizedFileURL.path, scratch.standardizedFileURL.path)
    }


    func testTerminationStopAllPreservesPausedScratchWork() throws {
        let manager = DownloadManager(recoveryFileURL: recoveryFileURL)
        defer { manager.shutdown() }

        let scratch = ScratchDirectoryPolicy.makeURL()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let partial = scratch.appendingPathComponent("video.mp4.part")
        try Data("partial".utf8).write(to: partial)

        let paused = Download(url: "https://example.com/paused", options: .default, title: "Paused")
        paused.status = .paused
        paused.progress = 0.45
        paused.scratchDirectory = scratch
        manager.downloads = [paused]

        manager.stopAllDownloads(preservePaused: true)

        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.scratchDirectory?.standardizedFileURL.path, scratch.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRecoveryIsKeptUntilDurableHistoryCommitForNonActiveStates() throws {
        let manager = DownloadManager(recoveryFileURL: recoveryFileURL)
        manager.ytdlpService.isUpdating = true
        defer { manager.shutdown() }

        let download = Download(
            url: "https://example.com/crash-consistency",
            options: .default,
            title: "Crash Consistency"
        )
        manager.downloads = [download]

        let durableStatuses: [DownloadStatus] = [
            .paused, .completed, .failed, .stopped, .fileExists
        ]

        for status in durableStatuses {
            download.status = .downloading
            manager.persistQueueRecoveryState()
            XCTAssertEqual(
                manager.recoveryStore.loadInterruptedJobs().count,
                1,
                "Precondition failed for \(status.rawValue)"
            )

            manager.executorDidUpdateStatus(for: download, to: status)

            XCTAssertEqual(
                manager.recoveryStore.loadInterruptedJobs().count,
                1,
                "Recovery must remain available until \(status.rawValue) is durably written to history"
            )

            manager.executorDidRequestAddToHistory(download, skipSave: false)

            XCTAssertTrue(
                manager.recoveryStore.loadInterruptedJobs().isEmpty,
                "Recovery should be cleared only after \(status.rawValue) history is durable"
            )
            XCTAssertEqual(
                manager.historyStore.loadHistory().first(where: { $0.id == download.id })?.status,
                status
            )
        }
    }

    func testFileExistsHistoryRestoresActionRequiredState() throws {
        let store = DownloadHistoryStore()
        let download = Download(
            url: "https://example.com/existing",
            options: .default,
            title: "Existing"
        )
        download.status = .fileExists

        let historic = HistoricDownload(download: download)
        let restored = try XCTUnwrap(
            DownloadHistoryStore.restoreDownloads(from: [historic], existingDownloads: []).first
        )

        XCTAssertEqual(restored.id, download.id)
        XCTAssertEqual(restored.status, .fileExists)
    }

}
