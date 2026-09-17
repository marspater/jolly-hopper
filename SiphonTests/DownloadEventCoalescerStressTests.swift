//
//  DownloadEventCoalescerStressTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

private actor TestAccumulator {
    var progressCount: Int = 0
    var lineCount: Int = 0

    func record(progress: Double?, lines: [String]) {
        if progress != nil {
            progressCount += 1
        }
        lineCount += lines.count
    }

    var counts: (progress: Int, lines: Int) {
        (progressCount, lineCount)
    }
}

final class DownloadEventCoalescerStressTests: XCTestCase {

    func testConcurrentProgressAndLogUpdates() async {
        let accumulator = TestAccumulator()

        let coalescer = DownloadEventCoalescer { progress, speed, eta, lines in
            Task {
                await accumulator.record(progress: progress, lines: lines)
            }
        }

        // Spawn 50 concurrent tasks pushing progress and log lines
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    for j in 0..<20 {
                        coalescer.recordProgress(
                            progress: Double(i * 20 + j) / 1000.0,
                            speed: "1.2 MB/s",
                            eta: "00:30"
                        )
                        coalescer.recordLogLine("Log line from task \(i) iteration \(j)")
                    }
                }
            }
        }

        coalescer.flushRemaining()

        // Allow async tasks in flush to settle
        try? await Task.sleep(nanoseconds: 50_000_000)

        let (flushedProgress, flushedLines) = await accumulator.counts
        XCTAssertGreaterThan(flushedLines, 0, "Expected flushed lines")
        XCTAssertGreaterThan(flushedProgress, 0, "Expected flushed progress")
    }

    func testInterleavedFlushRemainingAndUpdates() async {
        let coalescer = DownloadEventCoalescer { _, _, _, _ in }

        await withTaskGroup(of: Void.self) { group in
            // Writer tasks
            for i in 0..<20 {
                group.addTask {
                    for j in 0..<50 {
                        coalescer.recordProgress(progress: Double(j), speed: nil, eta: nil)
                        coalescer.recordLogLine("Stress log line \(i)-\(j)")
                    }
                }
            }
            // Interleaved flusher tasks
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<10 {
                        coalescer.flushRemaining()
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                }
            }
        }

        coalescer.flushRemaining()
    }

    func testRapidAllocationAndDeallocationUnderLoad() async {
        // Repeatedly instantiate, hammer with calls, and let deinit execute
        for _ in 0..<20 {
            let coalescer = DownloadEventCoalescer { _, _, _, _ in }
            for i in 0..<30 {
                coalescer.recordProgress(progress: Double(i) / 30.0, speed: "5MB/s", eta: "10s")
                coalescer.recordLogLine("Fast dealloc line \(i)")
            }
            // Deliberately do not call flushRemaining on all iterations to exercise deinit cancellation
        }
    }

    func testBoundedLogBufferEnforcement() {
        final class LineBox: @unchecked Sendable {
            var lines: [String] = []
            let lock = NSLock()
            func append(_ newLines: [String]) {
                lock.lock()
                lines.append(contentsOf: newLines)
                lock.unlock()
            }
        }
        let box = LineBox()
        let coalescer = DownloadEventCoalescer { _, _, _, lines in
            box.append(lines)
        }

        // Push 1,000 long lines without giving the timer time to flush
        for i in 0..<1000 {
            coalescer.recordLogLine("High-volume log entry \(i) with repeated padding text to consume buffer bytes 1234567890")
        }

        coalescer.flushRemaining()
        // The coalescer max line cap is 500 lines
        box.lock.lock()
        let count = box.lines.count
        box.lock.unlock()
        XCTAssertLessThanOrEqual(count, 500, "Log buffer must remain bounded to maxPendingLines (500)")
    }
}
