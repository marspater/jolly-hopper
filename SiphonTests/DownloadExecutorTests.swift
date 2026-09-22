//
//  DownloadExecutorTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

@MainActor
final class DownloadExecutorTests: XCTestCase {

    func testErrorMappingLocalization() {
        let lang = LanguageService()

        let errNotFound = YtdlpError.notFound
        XCTAssertEqual(DownloadExecutor.errorMessage(for: errNotFound, languageService: lang), lang.s("ytdlp_not_found"))

        let errTooMany = YtdlpError.tooManyRequests
        XCTAssertEqual(DownloadExecutor.errorMessage(for: errTooMany, languageService: lang), lang.s("too_many_requests"))

        let errCloudflare = YtdlpError.downloadFailed("Cloudflare protection 403 Forbidden")
        XCTAssertEqual(DownloadExecutor.errorMessage(for: errCloudflare, languageService: lang), lang.s("cloudflare_blocked"))

        let errDiskFull = NSError(domain: "POSIX", code: 28, userInfo: [NSLocalizedDescriptionKey: "No space left on device"])
        XCTAssertEqual(DownloadExecutor.errorMessage(for: errDiskFull, languageService: lang), lang.s("disk_full"))
    }

    func testRecoveryProgressBucketUsesFivePercentCheckpoints() {
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: -0.5), 0)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: .nan), 0)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: 0.0), 0)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: 0.049), 0)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: 0.05), 1)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: 0.249), 4)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: 0.25), 5)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: 0.999), 19)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: 1.0), 20)
        XCTAssertEqual(DownloadExecutor.recoveryProgressBucket(for: 1.5), 20)
    }

    func testTemporaryFileMatching() {
        XCTAssertTrue(DownloadExecutor.isTemporaryFileName("video.mp4.part"))
        XCTAssertTrue(DownloadExecutor.isTemporaryFileName("video.mp4.ytdl"))
        XCTAssertTrue(DownloadExecutor.isTemporaryFileName("video.mp4.temp"))
        XCTAssertTrue(DownloadExecutor.isTemporaryFileName("video.mp4.tmp"))
        XCTAssertFalse(DownloadExecutor.isTemporaryFileName("video.mp4"))

        XCTAssertTrue(DownloadExecutor.shouldCleanupTemporaryFiles(for: .stopped))
        XCTAssertTrue(DownloadExecutor.shouldCleanupTemporaryFiles(for: .failed))
        XCTAssertFalse(DownloadExecutor.shouldCleanupTemporaryFiles(for: .downloading))
        XCTAssertFalse(DownloadExecutor.shouldCleanupTemporaryFiles(for: .completed))

        XCTAssertTrue(DownloadExecutor.isMatchingTemporaryFile(
            fileName: "MyVideo.mp4.part",
            rawBaseName: "MyVideo",
            sanitizedBaseName: "MyVideo",
            videoId: "12345"
        ))

        XCTAssertFalse(DownloadExecutor.isMatchingTemporaryFile(
            fileName: "SomeOther_12345.mp4.part",
            rawBaseName: "MyVideo",
            sanitizedBaseName: "MyVideo",
            videoId: "12345"
        ), "Must not match unrelated file with videoId substring")

        XCTAssertFalse(DownloadExecutor.isMatchingTemporaryFile(
            fileName: "Unrelated.mp4.part",
            rawBaseName: "MyVideo",
            sanitizedBaseName: "MyVideo",
            videoId: "12345"
        ))
    }

    func testCleanupNeverDeletesUnownedSaveFolderPartials() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let partial = tempDir.appendingPathComponent("MyVideo.mp4.part")
        try Data("pre-existing partial".utf8).write(to: partial)

        var options = DownloadOptions.default
        options.saveFolder = tempDir
        options.customFilename = "MyVideo"
        let download = Download(url: "https://example.com/video", options: options, title: "MyVideo")
        download.status = .failed

        DownloadExecutor.cleanupTemporaryFiles(for: download)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partial.path),
            "Cleanup must not infer ownership from a filename and delete another process's partial"
        )
    }

    func testVideoIdExtraction() {
        XCTAssertEqual(DownloadExecutor.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(DownloadExecutor.extractVideoId(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(DownloadExecutor.extractVideoId(from: "invalid_url"), "invalid_url")
    }

    final class ResultBox: @unchecked Sendable {
        var progress: Double?
        var speed: String?
        var lines: [String] = []
    }

    func testCoalescerFlushesProperly() async {
        let box = ResultBox()

        let coalescer = DownloadEventCoalescer { prog, speed, _, lines in
            box.progress = prog
            box.speed = speed
            box.lines = lines
        }

        coalescer.recordProgress(progress: 0.25, speed: "5MB/s", eta: "01:00")
        coalescer.recordLogLine("line 1")
        coalescer.recordLogLine("line 2")
        coalescer.recordProgress(progress: 0.50, speed: "10MB/s", eta: "00:30")

        coalescer.flushRemaining()

        XCTAssertEqual(box.progress, 0.50)
        XCTAssertEqual(box.speed, "10MB/s")
        XCTAssertEqual(box.lines, ["line 1", "line 2"])
    }

    func testOwnedScratchSurvivesPauseAndIsCleanedOnStopOrCompletion() throws {
        let unrelatedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unrelatedRoot) }
        let unrelated = unrelatedRoot.appendingPathComponent("unrelated.part")
        try Data("keep".utf8).write(to: unrelated)

        for terminalStatus in [DownloadStatus.stopped, .completed, .failed] {
            let download = Download(url: "https://example.com/video", options: .default)
            let scratch = ScratchDirectoryPolicy.makeURL()
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let partial = scratch.appendingPathComponent("video.mp4.part")
            try Data("partial".utf8).write(to: partial)
            download.scratchDirectory = scratch
            for status in [DownloadStatus.paused, .queued] {
                download.status = status
                DownloadExecutor.cleanupTemporaryFiles(for: download)
                XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
                XCTAssertEqual(download.scratchDirectory, scratch)
            }
            download.status = terminalStatus
            DownloadExecutor.cleanupTemporaryFiles(for: download)
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
            XCTAssertNil(download.scratchDirectory)
            DownloadExecutor.cleanupTemporaryFiles(for: download)
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        }
    }

    func testCleanupRefusesUnownedScratchDirectory() throws {
        let unowned = FileManager.default.temporaryDirectory
            .appendingPathComponent("siphon_scratch_not-a-uuid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unowned) }

        let marker = unowned.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let download = Download(url: "https://example.com/video", options: .default)
        download.status = .failed
        download.scratchDirectory = unowned

        DownloadExecutor.cleanupTemporaryFiles(for: download)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(download.scratchDirectory)
    }

    func testExecutorDelegateInvocations() {
        class MockDelegate: DownloadExecutorDelegate {
            var updatedStatuses: [(Download, DownloadStatus)] = []
            var historyDownloads: [Download] = []
            var finishedCount = 0
            var broadcastCount = 0

            func executorDidUpdateStatus(for download: Download, to status: DownloadStatus) {
                updatedStatuses.append((download, status))
            }
            func executorDidRequestAddToHistory(_ download: Download, skipSave: Bool) {
                historyDownloads.append(download)
            }
            func executorDidFinishDownload() {
                finishedCount += 1
            }
            func executorDidRequestBroadcast() {
                broadcastCount += 1
            }
        }

        let mockDelegate = MockDelegate()
        let service = YtdlpService()
        let executor = DownloadExecutor(ytdlpService: service, delegate: mockDelegate)
        let queue = DownloadQueue()
        let download = Download(url: "https://example.com/test", options: .default)

        download.status = .downloading
        executor.pauseDownload(download, queue: queue)

        XCTAssertEqual(mockDelegate.updatedStatuses.count, 1)
        XCTAssertEqual(mockDelegate.updatedStatuses.first?.1, .paused)
        XCTAssertEqual(mockDelegate.broadcastCount, 1)
    }

    func testStoppingActiveFetchKeepsOwnershipUntilTaskTeardown() async {
        final class MockDelegate: DownloadExecutorDelegate {
            var finishedCount = 0

            func executorDidUpdateStatus(for download: Download, to status: DownloadStatus) {
                download.status = status
            }

            func executorDidRequestAddToHistory(_ download: Download, skipSave: Bool) {}

            func executorDidFinishDownload() {
                finishedCount += 1
            }

            func executorDidRequestBroadcast() {}
        }

        let delegate = MockDelegate()
        let executor = DownloadExecutor(ytdlpService: YtdlpService(), delegate: delegate)
        let queue = DownloadQueue()
        let download = Download(url: "https://example.com/fetching", options: .default)
        download.status = .queued

        XCTAssertTrue(queue.reserveSlot(for: download.id))
        executor.startDownloadTask(
            download,
            queue: queue,
            ytdlpVersion: nil,
            languageService: nil
        )
        XCTAssertEqual(executor.executionState(for: download.id), .active)

        executor.stopDownload(
            download,
            queue: queue,
            languageService: nil,
            suppressNotification: true,
            skipSaveAndBroadcast: true
        )

        XCTAssertEqual(download.status, .stopped)
        XCTAssertEqual(executor.executionState(for: download.id), .cancelling, "Cancellation must not drop task ownership before teardown")
        XCTAssertTrue(queue.isSlotReserved(for: download.id), "Concurrency slot must remain reserved until teardown")
        XCTAssertEqual(delegate.finishedCount, 0, "Finish callback belongs to task teardown, not the cancellation request")

        for _ in 0..<20 {
            if executor.executionState(for: download.id) == .idle { break }
            await Task.yield()
        }

        XCTAssertEqual(executor.executionState(for: download.id), .idle)
        XCTAssertFalse(queue.isSlotReserved(for: download.id))
        XCTAssertEqual(delegate.finishedCount, 1)
    }

    func testShutdownRequestsCancellationWithoutDroppingOwnership() async {
        final class MockDelegate: DownloadExecutorDelegate {
            func executorDidUpdateStatus(for download: Download, to status: DownloadStatus) {
                download.status = status
            }

            func executorDidRequestAddToHistory(_ download: Download, skipSave: Bool) {}
            func executorDidFinishDownload() {}
            func executorDidRequestBroadcast() {}
        }

        let metadataJSON = """
        {
            "id": "shutdown-test",
            "title": "Shutdown Test",
            "duration": 10.0,
            "uploader": "Test"
        }
        """
        let runner = MockYtdlpProcessRunner(
            mockCommand: { _ in metadataJSON },
            mockDownloadResult: { _ in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return DownloadProcessResult(primaryPath: "/tmp/shutdown-test.mp4")
            }
        )
        let service = YtdlpService(processRunner: runner)
        service.ytdlpPath = URL(fileURLWithPath: "/usr/bin/true")
        service.ffmpegPath = URL(fileURLWithPath: "/usr/bin/true")
        service.ffprobePath = URL(fileURLWithPath: "/usr/bin/true")

        let delegate = MockDelegate()
        let executor = DownloadExecutor(ytdlpService: service, delegate: delegate)
        let queue = DownloadQueue()
        let download = Download(url: "https://example.com/shutdown-test", options: .default)

        XCTAssertTrue(queue.reserveSlot(for: download.id))
        executor.startDownloadTask(
            download,
            queue: queue,
            ytdlpVersion: "test",
            languageService: nil
        )

        for _ in 0..<100 {
            if executor.activeControllers[download.id] != nil { break }
            await Task.yield()
        }

        guard let controller = executor.activeControllers[download.id] else {
            XCTFail("Expected executor to own the process controller before shutdown")
            executor.shutdown()
            return
        }

        executor.shutdown()

        XCTAssertEqual(executor.executionState(for: download.id), .cancelling)
        XCTAssertNotNil(executor.activeTasks[download.id])
        XCTAssertNotNil(executor.activeControllers[download.id])
        XCTAssertTrue(controller.isCancelled)
        XCTAssertTrue(queue.isSlotReserved(for: download.id), "Shutdown must not release capacity before task teardown")

        for _ in 0..<100 {
            if executor.executionState(for: download.id) == .idle { break }
            await Task.yield()
        }

        XCTAssertEqual(executor.executionState(for: download.id), .idle)
        XCTAssertNil(executor.activeTasks[download.id])
        XCTAssertNil(executor.activeControllers[download.id])
        XCTAssertFalse(queue.isSlotReserved(for: download.id))
    }

    func testSuccessfulCompletionRespectsCancellationAndUserStatus() {
        XCTAssertTrue(DownloadExecutor.shouldFinalizeSuccessfulDownload(
            taskIsCancelled: false,
            status: .downloading
        ))
        XCTAssertTrue(DownloadExecutor.shouldFinalizeSuccessfulDownload(
            taskIsCancelled: false,
            status: .processing
        ))

        XCTAssertFalse(DownloadExecutor.shouldFinalizeSuccessfulDownload(
            taskIsCancelled: true,
            status: .downloading
        ))
        XCTAssertFalse(DownloadExecutor.shouldFinalizeSuccessfulDownload(
            taskIsCancelled: false,
            status: .paused
        ))
        XCTAssertFalse(DownloadExecutor.shouldFinalizeSuccessfulDownload(
            taskIsCancelled: false,
            status: .stopped
        ))
    }

    func testErrorMessagesSanitizeSignedURLs() {
        let lang = LanguageService()
        let error = YtdlpError.downloadFailed(
            "request failed https://cdn.example.com/video.m3u8?token=top_secret&expires=123"
        )
        let message = DownloadExecutor.errorMessage(for: error, languageService: lang)

        XCTAssertFalse(message.contains("top_secret"))
        XCTAssertFalse(message.contains("expires=123"))
        XCTAssertTrue(message.contains("https://cdn.example.com/video.m3u8"))
    }

    func testFailedDownloadPopulatesDownloadLog() async {
        final class MockDelegate: DownloadExecutorDelegate {
            func executorDidUpdateStatus(for download: Download, to status: DownloadStatus) {
                download.status = status
            }
            func executorDidRequestAddToHistory(_ download: Download, skipSave: Bool) {}
            func executorDidFinishDownload() {}
            func executorDidRequestBroadcast() {}
        }

        let runner = MockYtdlpProcessRunner(mockCommand: { _ in
            throw YtdlpError.commandFailed("ERROR: [generic] Got HTTP Error 403 caused by Cloudflare anti-bot challenge")
        })
        let service = YtdlpService(processRunner: runner)
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let delegate = MockDelegate()
        let executor = DownloadExecutor(ytdlpService: service, delegate: delegate)
        let queue = DownloadQueue()
        let download = Download(url: "https://example.com/blocked", options: .default)

        XCTAssertTrue(download.log.isEmpty)

        await executor.executeDownload(
            download,
            queue: queue,
            ytdlpVersion: "2026.09.01",
            languageService: LanguageService()
        )

        XCTAssertEqual(download.status, .failed)
        XCTAssertFalse(download.log.isEmpty, "Download log must be populated on failure")
        XCTAssertTrue(download.log.contains("[INFO] Initializing metadata extraction"), "Log should contain initialization line")
        XCTAssertTrue(download.log.contains("[ERROR]"), "Log should contain error line")
        XCTAssertTrue(download.log.contains("Cloudflare"), "Log should contain diagnostic output")
    }
}
