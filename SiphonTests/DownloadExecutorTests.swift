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

        XCTAssertTrue(DownloadExecutor.isMatchingTemporaryFile(
            fileName: "SomeOther_12345.mp4.part",
            rawBaseName: "MyVideo",
            sanitizedBaseName: "MyVideo",
            videoId: "12345"
        ))

        XCTAssertFalse(DownloadExecutor.isMatchingTemporaryFile(
            fileName: "Unrelated.mp4.part",
            rawBaseName: "MyVideo",
            sanitizedBaseName: "MyVideo",
            videoId: "12345"
        ))
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
}
