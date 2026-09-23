//
//  ProcessLifecycleTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

final class ProcessLifecycleTests: XCTestCase {

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
