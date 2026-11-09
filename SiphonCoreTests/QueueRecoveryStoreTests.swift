//
//  QueueRecoveryStoreTests.swift
//  SiphonTests
//

import XCTest
@testable import SiphonCore

@MainActor
final class QueueRecoveryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var recoveryFileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("QueueRecoveryTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        recoveryFileURL = tempDir.appendingPathComponent("queue_recovery_test.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    /// Escape answers an alert with its cancel button. Here that must be "Later",
    /// which keeps the interrupted jobs and their partial data for next launch.

    func testDecodedTitlesSurviveHistoryRecoveryAndPruning() throws {
        let info = MediaInfo(id: "fixture", title: "&amp;lt; &amp;#39;")
        XCTAssertEqual(info.title, "&lt; &#39;")
        XCTAssertEqual(info.prunedForCompletion().title, info.title)
        var job = Download(url: "https://example.com/video", options: .default, title: info.title, titleIsDecoded: true)
        for _ in 0..<3 {
            job = try JSONDecoder().decode(HistoricDownload.self, from: JSONEncoder().encode(HistoricDownload(download: job))).toDownload()
            XCTAssertEqual(job.title, info.title)
        }
        let recovered = QueueRecoveryRecord(download: job).toDownload()
        XCTAssertEqual(recovered.title, info.title)
    }

    func testFailedJobWithReviewedArgumentsKeepsItsStatus() {
        let job = Download(url: "https://example.com/playlist", options: .default)
        job.options.additionalArguments = "--limit-rate 1M"
        job.status = .failed
        job.hasPartialFailure = true
        job.filePaths = [URL(fileURLWithPath: "/tmp/finished.mp4")]
        let restored = HistoricDownload(download: job).toDownload()
        XCTAssertEqual(restored.status, .failed, "Only jobs that would run on their own are held as paused")
        XCTAssertTrue(restored.requiresAdvancedArgumentsReview)
        XCTAssertTrue(restored.hasPlayableOutput)

        let queued = Download(url: "https://example.com/video", options: .default)
        queued.options.additionalArguments = "--limit-rate 1M"
        queued.status = .queued
        XCTAssertEqual(HistoricDownload(download: queued).toDownload().status, .paused)
    }

    func testOwnedOutputFilesSurvivePausedHistoryAndRecovery() throws {
        let output = URL(fileURLWithPath: "/tmp/owned-output.mp4")
        let job = Download(url: "https://example.com/video", options: .default)
        job.status = .paused
        job.ownedOutputFiles = [output: 4242]
        let fromHistory = try JSONDecoder().decode(HistoricDownload.self,
                                                   from: JSONEncoder().encode(HistoricDownload(download: job))).toDownload()
        XCTAssertEqual(fromHistory.ownedOutputFiles, [output: 4242])
        let record = try JSONDecoder().decode(QueueRecoveryRecord.self,
                                              from: JSONEncoder().encode(QueueRecoveryRecord(download: job)))
        XCTAssertEqual(record.toDownload().ownedOutputFiles, [output: 4242])

        job.status = .failed
        XCTAssertTrue(HistoricDownload(download: job).toDownload().ownedOutputFiles.isEmpty,
                      "Only a resumed pause may reuse its output")
    }

    func testUnreadableRecoveryEntryDoesNotDropOtherJobs() throws {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let first = Download(url: "https://example.com/one", options: .default)
        first.status = .downloading
        let second = Download(url: "https://example.com/two", options: .default)
        second.status = .queued
        XCTAssertTrue(store.persist(activeJobs: [first, second]))

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recoveryFileURL)) as? [String: Any])
        var jobs = try XCTUnwrap(json["jobs"] as? [[String: Any]])
        jobs[0]["options"] = "not options"
        json["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: json).write(to: recoveryFileURL)

        XCTAssertEqual(store.loadInterruptedJobs().map(\.id), [second.id])
    }

    func testUnreadableRecoverySnapshotIsPreservedBeforeOverwrite() throws {
        try Data("{ not json".utf8).write(to: recoveryFileURL)
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        XCTAssertTrue(store.loadInterruptedJobs().isEmpty)
        let backup = recoveryFileURL.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not json")
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

    func testRecoveryRecordKeepsOnlyTheLogTail() {
        let download = Download(url: "https://example.com/long-log", options: .default, title: "Long Log")
        download.log = String(repeating: "a", count: 40_000) + "last line"

        let record = QueueRecoveryRecord(download: download)

        XCTAssertEqual(record.log.count, QueueRecoveryRecord.maxLogCharacters)
        XCTAssertTrue(record.log.hasSuffix("last line"))
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

    func testUnsupportedSchemaVersionSnapshotPreservedAndNotOverwrittenOnShutdown() throws {
        let v2JSON = """
        {
            "version": 2,
            "timestamp": "2026-10-24T00:00:00Z",
            "isCleanShutdown": false,
            "jobs": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "url": "https://example.com/future-job",
                    "status": "downloading"
                }
            ]
        }
        """
        try v2JSON.write(to: recoveryFileURL, atomically: true, encoding: .utf8)

        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let recoverable = store.loadInterruptedJobs()
        XCTAssertTrue(recoverable.isEmpty, "Unsupported schema version should yield empty list in older store")
        XCTAssertTrue(store.hasUnsupportedSchemaSnapshot, "Store must record presence of unsupported schema snapshot")

        let backupURL = recoveryFileURL.appendingPathExtension("unsupported-v2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "Unsupported snapshot must be backed up")

        let cleanShutdownSucceeded = store.markCleanShutdown()
        XCTAssertTrue(cleanShutdownSucceeded)

        let dataAfterShutdown = try Data(contentsOf: recoveryFileURL)
        let jsonAfterShutdown = try JSONSerialization.jsonObject(with: dataAfterShutdown) as? [String: Any]
        XCTAssertEqual(jsonAfterShutdown?["version"] as? Int, 2, "Unsupported future-version snapshot must not be overwritten by clean shutdown")
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

    func testFileExistsHistoryRestoresActionRequiredState() throws {
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

    func testPersistFailureOnUnwritableDirectory() throws {
        // A regular file where the parent directory belongs fails for every user, including root.
        let blocker = tempDir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let unwritableFile = blocker.appendingPathComponent("nested/recovery.json")

        let store = QueueRecoveryStore(fileURL: unwritableFile)
        let dl = Download(url: "https://example.com/video", options: .default, title: "Test")
        dl.status = .queued

        let persisted = store.persist(activeJobs: [dl])
        XCTAssertFalse(persisted, "persist() should return false when the directory is not writable")

        let shutdown = store.markCleanShutdown()
        XCTAssertFalse(shutdown, "markCleanShutdown() should return false when the directory is not writable")
    }

    func testQueueRecoveryFileHasRestrictedPermissions() throws {
        let store = QueueRecoveryStore(fileURL: recoveryFileURL)
        let download = Download(url: "https://example.com/video", options: .default, title: "Permissions Test")
        XCTAssertTrue(store.persist(activeJobs: [download]))

        let attrs = try FileManager.default.attributesOfItem(atPath: recoveryFileURL.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600, "Queue recovery snapshot file must have strict 0o600 permissions")
    }
}
