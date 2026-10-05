//
//  ProcessLifecycleTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

final class ProcessLifecycleTests: XCTestCase {

    func testFfmpegProgressHandlesDurationUnknownValuesAndCarriageReturns() {
        let parser = FfmpegDownloadProgress()
        XCTAssertNil(parser.parse("frame=10 time=00:00:10.00 speed=2x"))
        XCTAssertNil(parser.parse("  Duration: 00:01:00.00, start: 0.000000, bitrate: 100 kb/s"))
        let progress = parser.parse("frame=10 fps=30 time=00:00:15.00 bitrate=100kbits/s speed=2x")
        XCTAssertEqual(progress?.fraction, 0.25)
        XCTAssertEqual(progress?.speed, "2x")
        XCTAssertEqual(progress?.eta, "22s")
        XCTAssertNil(parser.parse("frame=10 time=N/A speed=N/A"))
        XCTAssertEqual(parser.parse("size=1024kB time=00:01:30.00 speed=N/A")?.fraction, 1)
        XCTAssertNil(parser.parse("file time=00:00:15.00"))
        XCTAssertNil(parser.parse("Duration: N/A, start: 0.0"))
        XCTAssertNil(parser.parse("frame=10 time=00:00:15.00 speed=2x"))

        let buffer = StreamBuffer()
        XCTAssertEqual(buffer.appendAndExtractLines(Data("frame=1\rframe=2\r".utf8)), ["frame=1", "frame=2"])
        XCTAssertEqual(buffer.appendAndExtractLines(Data("frame=3\r\n".utf8)), ["frame=3"])
    }

    func testRunnerDeliversFfmpegStderrProgressBeforeProcessExits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = root.appendingPathComponent("progress-received")
        let media = root.appendingPathComponent("video.mp4")
        let script = "printf 'Duration: 00:01:00.00, start: 0.0\\n' >&2; " +
            "printf 'frame=10 time=00:00:15.00 speed=2x\\r' >&2; " +
            "for i in $(seq 1 100); do test -f '\(gate.path)' && break; sleep 0.02; done; " +
            "test -f '\(gate.path)' || exit 1; touch '\(media.path)'; echo 'SIPHON_FINAL_PATH:\(media.path)'"
        let result = try await DefaultYtdlpProcessRunner().runDownloadProcess(
            args: ["/bin/sh", "-c", script], saveFolder: root, processController: DownloadProcessController(),
            onProgress: { fraction, speed, eta in
                XCTAssertEqual(fraction, 0.25)
                XCTAssertEqual(speed, "2x")
                XCTAssertEqual(eta, "22s")
                _ = FileManager.default.createFile(atPath: gate.path, contents: Data())
            }, onOutput: { _ in }
        )
        XCTAssertEqual(result.primaryPath, media.path)
    }

    @MainActor
    func testCommandUsesSharedControllerAndAllowsMainActorCancellation() async throws {
        let controller = DownloadProcessController()
        let task = Task {
            try await DefaultYtdlpProcessRunner().runCommand(["/bin/sleep", "30"], processController: controller)
        }
        defer { task.cancel(); controller.cancel() }
        for _ in 0..<200 {
            if controller.lifecycleState.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.lifecycleState.isRunning, "Command must start without blocking the main actor")
        controller.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled post-processing must not succeed")
        } catch {
            XCTAssertTrue(controller.isCancelled)
            XCTAssertTrue(controller.lifecycleState.isTerminated, "Awaiting cancellation must include process teardown")
        }
    }

    func testInitialLifecycleStateIsCreated() {
        let controller = DownloadProcessController()
        XCTAssertEqual(controller.lifecycleState, .created)
        XCTAssertFalse(controller.lifecycleState.isRunning)
        XCTAssertFalse(controller.lifecycleState.isCancelling)
        XCTAssertFalse(controller.lifecycleState.isTerminated)
        XCTAssertFalse(controller.lifecycleState.isFailed)
        XCTAssertTrue(controller.lifecycleState.canCancel)
        XCTAssertFalse(controller.isCancelled)
    }

    func testLifecycleTransitionStartingToRunningToTerminated() throws {
        let controller = DownloadProcessController()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")

        proc.terminationHandler = { process in
            controller.transitionToTerminated(exitCode: process.terminationStatus, reason: process.terminationReason)
        }

        XCTAssertNoThrow(try controller.start(proc))
        if case .running(let pid) = controller.lifecycleState {
            XCTAssertGreaterThan(pid, 0)
        } else {
            XCTFail("State must be .running after start()")
        }

        proc.waitUntilExit()

        // Wait briefly for termination handler callback to finish
        let exp = expectation(description: "Wait for termination")
        DispatchQueue.global().async {
            while !controller.lifecycleState.isTerminated {
                usleep(5_000)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(controller.lifecycleState, .terminated(exitCode: 0, reason: .exit))
    }

    func testTerminatedControllerCanBeReusedForRecoveryWhenNotCancelled() throws {
        let controller = DownloadProcessController()
        controller.transitionToTerminated(exitCode: 1, reason: .exit)

        let recoveryProc = Process()
        recoveryProc.executableURL = URL(fileURLWithPath: "/usr/bin/true")

        XCTAssertNoThrow(try controller.start(recoveryProc))
        recoveryProc.waitUntilExit()
        XCTAssertEqual(recoveryProc.terminationStatus, 0)
    }

    func testCancelledControllerCannotRestartAfterTermination() {
        let controller = DownloadProcessController()
        controller.cancel()
        controller.transitionToTerminated(exitCode: 15, reason: .uncaughtSignal)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")

        XCTAssertThrowsError(try controller.start(proc)) { error in
            guard let ytdlpErr = error as? YtdlpError,
                  case .downloadFailed(let reason) = ytdlpErr else {
                XCTFail("Expected downloadFailed, got \(error)")
                return
            }
            XCTAssertEqual(reason, "Download was stopped.")
        }
    }

    func testCancellationBetweenRecoveryAttemptsSurvivesDetach() {
        // A previous recovery attempt already finished; the user stops the job
        // before the next attempt launches.
        let controller = DownloadProcessController()
        controller.transitionToTerminated(exitCode: 1, reason: .exit)
        controller.cancel()
        XCTAssertTrue(controller.isCancelled)

        // The runner detaches after a rejected start. That must not clear the
        // stop request and let a later attempt launch a new process.
        let rejected = Process()
        rejected.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try controller.start(rejected))
        controller.detach()
        XCTAssertTrue(controller.isCancelled, "detach() must not clear a requested cancellation")

        let nextAttempt = Process()
        nextAttempt.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try controller.start(nextAttempt))
        XCTAssertFalse(nextAttempt.isRunning)
    }

    func testDownloadFailureClassificationIgnoresSubtitleWarnings() {
        let stderr = """
        WARNING: [youtube] abc123: There are no subtitles for the requested languages
        WARNING: [youtube] abc123: Some automatic captions are missing
        ERROR: unable to download video data: HTTP Error 503: Service Unavailable
        """
        guard case .downloadFailed(let message) = DefaultYtdlpProcessRunner.classifyFailure(errorOutput: stderr, exitCode: 1) else {
            XCTFail("A network failure must stay recoverable, not become a subtitle error")
            return
        }
        XCTAssertTrue(message.contains("HTTP Error 503"))
    }

    func testDownloadFailureClassificationIgnoresWarningsWithoutErrorLine() {
        let stderr = """
        WARNING: [youtube] abc123: There are no subtitles for the requested languages
        Traceback (most recent call last):
        MemoryError
        """
        guard case .downloadFailed = DefaultYtdlpProcessRunner.classifyFailure(errorOutput: stderr, exitCode: 1) else {
            XCTFail("A crash without an ERROR: line must stay a recoverable download failure")
            return
        }
    }

    func testDownloadFailureClassificationIgnoresIncidental429() {
        let stderr = """
        WARNING: [generic] Falling back on generic information extractor for 4290ab
        ERROR: Unsupported URL: https://example.com/watch/4290ab
        """
        guard case .downloadFailed(let message) = DefaultYtdlpProcessRunner.classifyFailure(errorOutput: stderr, exitCode: 1) else {
            XCTFail("A '429' substring outside the error line must not be treated as rate limiting")
            return
        }
        XCTAssertTrue(message.hasPrefix("Unsupported URL"))
    }

    func testDownloadFailureClassificationKeepsRealRateLimitAndSubtitleErrors() {
        guard case .tooManyRequests = DefaultYtdlpProcessRunner.classifyFailure(
            errorOutput: "ERROR: [youtube] abc123: HTTP Error 429: Too Many Requests",
            exitCode: 1
        ) else {
            XCTFail("An HTTP 429 error line must map to tooManyRequests")
            return
        }
        guard case .subtitleError = DefaultYtdlpProcessRunner.classifyFailure(
            errorOutput: "ERROR: Unable to download video subtitles for 'en': HTTP Error 404: Not Found",
            exitCode: 1
        ) else {
            XCTFail("A subtitle error line must map to subtitleError")
            return
        }
        guard case .downloadFailed(let message) = DefaultYtdlpProcessRunner.classifyFailure(errorOutput: "", exitCode: 2) else {
            XCTFail("Empty stderr must still produce a download failure")
            return
        }
        XCTAssertEqual(message, "Process exited with code 2")
    }

    func testRunnerSurfacesRealErrorWhenStderrHasSubtitleWarnings() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("classify_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = "echo 'WARNING: There are no subtitles for the requested languages' >&2; " +
            "echo 'ERROR: unable to download video data: HTTP Error 503: Service Unavailable' >&2; exit 1"
        do {
            _ = try await DefaultYtdlpProcessRunner().runDownloadProcess(
                args: ["/bin/sh", "-c", script],
                saveFolder: tempDir,
                processController: DownloadProcessController(),
                onProgress: { _, _, _ in /* Progress ignored in test */ },
                onOutput: { _ in /* Output ignored in test */ }
            )
            XCTFail("A failing process must throw")
        } catch YtdlpError.downloadFailed(let message) {
            XCTAssertTrue(message.contains("HTTP Error 503"))
        } catch {
            XCTFail("Expected downloadFailed so recovery strategies can run, got \(error)")
        }
    }

    func testRunnerKeepsFinishedPlaylistEntriesWhenAnotherEntryFails() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("partial_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let first = tempDir.appendingPathComponent("One [a1].mp4").path
        let second = tempDir.appendingPathComponent("Two [b2].mp4").path
        let script = "touch '\(first)' '\(second)'; " +
            "echo 'SIPHON_FINAL_PATH:\(first)'; " +
            "echo 'ERROR: [youtube] c3: Private video' >&2; " +
            "echo 'SIPHON_FINAL_PATH:\(second)'; exit 1"
        let result = try await DefaultYtdlpProcessRunner().runDownloadProcess(
            args: ["/bin/sh", "-c", script],
            saveFolder: tempDir,
            processController: DownloadProcessController(),
            onProgress: { _, _, _ in /* Progress ignored in test */ },
            onOutput: { _ in /* Output ignored in test */ }
        )
        XCTAssertEqual(result.allPaths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["One [a1].mp4", "Two [b2].mp4"])
        XCTAssertEqual(result.partialFailure, "[youtube] c3: Private video")
    }

    func testRunnerStillFailsWhenNoEntryFinished() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("partial_none_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A half-written file named on a Destination line is not a finished entry.
        let partial = tempDir.appendingPathComponent("Half.mp4").path
        let script = "touch '\(partial)'; echo '[download] Destination: \(partial)'; " +
            "echo 'ERROR: unable to download video data' >&2; exit 1"
        do {
            _ = try await DefaultYtdlpProcessRunner().runDownloadProcess(
                args: ["/bin/sh", "-c", script],
                saveFolder: tempDir,
                processController: DownloadProcessController(),
                onProgress: { _, _, _ in /* Progress ignored in test */ },
                onOutput: { _ in /* Output ignored in test */ }
            )
            XCTFail("A run with no finished entry must throw")
        } catch YtdlpError.downloadFailed(let message) {
            XCTAssertTrue(message.contains("unable to download video data"))
        } catch {
            XCTFail("Expected downloadFailed, got \(error)")
        }
    }

    func testStreamDrainBarrierRunsOnceAfterEveryStreamFinishes() {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var runs = 0
            func hit() { lock.withLock { runs += 1 } }
            var value: Int { lock.withLock { runs } }
        }

        // Completion registered before the streams finish (process exit first).
        let early = StreamDrainBarrier(streams: 2)
        let earlyRuns = Counter()
        early.whenDrained { earlyRuns.hit() }
        early.streamFinished()
        XCTAssertEqual(earlyRuns.value, 0, "One open stream may still hold the last bytes")
        early.streamFinished()
        XCTAssertEqual(earlyRuns.value, 1)

        // Completion registered after both streams already hit EOF.
        let late = StreamDrainBarrier(streams: 2)
        let lateRuns = Counter()
        late.streamFinished()
        late.streamFinished()
        late.whenDrained { lateRuns.hit() }
        XCTAssertEqual(lateRuns.value, 1)

        // A process that never launched leaves the barrier pending; releasing it must be safe.
        _ = StreamDrainBarrier(streams: 2)
    }

    func testRunnerDeliversFinalStderrLineBeforeReturning() async {
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
            func append(_ line: String) { lock.withLock { all.append(line) } }
            var value: [String] { lock.withLock { all } }
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stderr_tail_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lines = Lines()
        _ = try? await DefaultYtdlpProcessRunner().runDownloadProcess(
            args: ["/bin/sh", "-c", "echo 'ERROR: final stderr line' >&2; exit 1"],
            saveFolder: tempDir,
            processController: DownloadProcessController(),
            onProgress: { _, _, _ in /* Progress ignored in test */ },
            onOutput: { lines.append($0) }
        )
        XCTAssertTrue(
            lines.value.contains("[ERROR] ERROR: final stderr line"),
            "The last stderr line must reach the caller before the final log flush"
        )
    }

    func testRunnerStopsWaitingWhenDescendantHoldsOutputOpen() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("drain_timeout_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // The background sleep inherits stdout/stderr, so EOF never arrives on its own.
        let runner = DefaultYtdlpProcessRunner(streamDrainTimeout: 0.5)
        let started = Date()
        do {
            _ = try await runner.runDownloadProcess(
                args: ["/bin/sh", "-c", "sleep 30 & echo 'ERROR: parent failed' >&2; exit 1"],
                saveFolder: tempDir,
                processController: DownloadProcessController(),
                onProgress: { _, _, _ in /* Progress ignored in test */ },
                onOutput: { _ in /* Output ignored in test */ }
            )
            XCTFail("A failing process must throw")
        } catch YtdlpError.downloadFailed(let message) {
            XCTAssertTrue(message.contains("parent failed"))
        } catch {
            XCTFail("Expected downloadFailed, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)

        let commandStarted = Date()
        let output = try? await runner.runCommand(["/bin/sh", "-c", "sleep 30 & echo done"])
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "done")
        XCTAssertLessThan(Date().timeIntervalSince(commandStarted), 10)
    }

    func testCancelDoesNotWaitOutTheTerminationGracePeriods() throws {
        let controller = DownloadProcessController()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Ignoring SIGTERM forces the slowest path: sweeps, then SIGKILL (~100 ms).
        proc.arguments = ["-c", "trap '' TERM; sleep 30"]
        try controller.start(proc)

        let started = Date()
        controller.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "cancel() runs on the main actor for Stop All")

        DownloadProcessController.waitForPendingTerminations()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationReason, .uncaughtSignal)
    }

    func testTreeKillSkipsAlreadyReapedProcess() throws {
        // A cancel can queue the tree kill just before the process exits on its own.
        // Once reaped, its PID may name another process: model that reuse with a
        // live bystander and make sure it is not signalled.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()

        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["30"]
        try bystander.run()

        DownloadProcessController.terminateProcessTree(exited, pid: bystander.processIdentifier)
        kill(bystander.processIdentifier, SIGKILL)
        bystander.waitUntilExit()
        XCTAssertEqual(bystander.terminationStatus, SIGKILL, "The stale PID must not be signalled")
    }

    func testProcessStartTimeIdentifiesOneProcessNotItsPID() throws {
        // Descendants are escalated to SIGKILL only while their PID still carries the
        // start time recorded when they were first signalled.
        let first = Process()
        first.executableURL = URL(fileURLWithPath: "/bin/sleep")
        first.arguments = ["30"]
        try first.run()
        let recorded = try XCTUnwrap(DownloadProcessController.processStartTime(first.processIdentifier))
        XCTAssertEqual(DownloadProcessController.processStartTime(first.processIdentifier), recorded)
        first.terminate()
        first.waitUntilExit()

        XCTAssertNotEqual(DownloadProcessController.processStartTime(first.processIdentifier), recorded,
                          "An exited process never matches its recorded identity")
        XCTAssertNil(DownloadProcessController.processStartTime(0))
    }

    func testCancelBeforeStartTransitionsToCancelling() {
        let controller = DownloadProcessController()
        controller.cancel()

        XCTAssertTrue(controller.lifecycleState.isCancelling)
        XCTAssertTrue(controller.isCancelled)
        XCTAssertFalse(controller.lifecycleState.canCancel)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try controller.start(proc)) { error in
            guard let ytdlpErr = error as? YtdlpError,
                  case .downloadFailed(let reason) = ytdlpErr else {
                XCTFail("Expected downloadFailed, got \(error)")
                return
            }
            XCTAssertEqual(reason, "Download was stopped.")
        }
    }

    func testLifecycleTransitionRunningToCancellingToTerminated() throws {
        let controller = DownloadProcessController()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["10"]

        proc.terminationHandler = { process in
            controller.transitionToTerminated(exitCode: process.terminationStatus, reason: process.terminationReason)
        }

        try controller.start(proc)
        guard case .running(let pid) = controller.lifecycleState else {
            XCTFail("Expected .running")
            return
        }
        XCTAssertGreaterThan(pid, 0)

        controller.cancel()
        XCTAssertTrue(controller.isCancelled)

        proc.waitUntilExit()

        let exp = expectation(description: "Wait for termination after cancel")
        DispatchQueue.global().async {
            while !controller.lifecycleState.isTerminated {
                usleep(5_000)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(controller.lifecycleState.isTerminated)
    }

    func testStartFailureTransitionsToFailed() {
        let controller = DownloadProcessController()
        let invalidProc = Process()
        invalidProc.executableURL = URL(fileURLWithPath: "/nonexistent/binary/\(UUID().uuidString)")

        XCTAssertThrowsError(try controller.start(invalidProc))
        XCTAssertTrue(controller.lifecycleState.isFailed)

        // Verifying recovery: a subsequent start with a valid binary succeeds
        let validProc = Process()
        validProc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertNoThrow(try controller.start(validProc))
        validProc.waitUntilExit()
    }
}
