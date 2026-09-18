//
//  ProcessLifecycleTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

final class ProcessLifecycleTests: XCTestCase {

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
