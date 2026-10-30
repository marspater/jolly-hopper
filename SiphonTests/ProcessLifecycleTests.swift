//
//  ProcessLifecycleTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

final class ProcessLifecycleTests: XCTestCase {
    func testFixupParserUsesTheQuotedDestinationInsteadOfIntoInTheSourceTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("finished.mp4")
        try Data("media".utf8).write(to: output)
        let script = #"printf '[Fixup] Converting "into old.mp4" into "%s"\n' "$1""#
        let result = try await DefaultYtdlpProcessRunner().runDownloadProcess(
            args: ["/bin/sh", "-c", script, "--", output.path], saveFolder: root,
            processController: DownloadProcessController(), onProgress: { _, _, _ in }, onOutput: { _ in })
        XCTAssertEqual(result.primaryPath, output.path)
    }


    func testBotMatchingNeedsTheWord() {
        XCTAssertTrue(DefaultYtdlpProcessRunner.mentionsBot("Sign in to confirm you're not a bot"))
        XCTAssertTrue(DefaultYtdlpProcessRunner.mentionsBot("blocked by anti-bot protection"))
        XCTAssertFalse(DefaultYtdlpProcessRunner.mentionsBot("both formats; robot; abbott"))
        let forbidden = "WARNING: merging both formats\nERROR: unable to download video data: HTTP Error 403: Forbidden"
        guard case .downloadFailed = DefaultYtdlpProcessRunner.classifyFailure(errorOutput: forbidden, exitCode: 1) else {
            return XCTFail("A plain 403 is not an anti-bot block")
        }
    }

    /// A descendant can keep the output pipes open after yt-dlp exits; Stop
    /// in that window must end it instead of waiting for the drain timeout.
    func testCancelDuringOutputDrainStopsThePipeHolders() throws {
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", "setpgrp(0, 0); sleep 30"]
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        for _ in 0..<100 where getpgid(holder.processIdentifier) != holder.processIdentifier {
            usleep(10_000)
        }
        XCTAssertEqual(getpgid(holder.processIdentifier), holder.processIdentifier)

        let controller = DownloadProcessController()
        controller.transitionToTerminated(exitCode: 0, reason: .exit, drainingProcessGroup: holder.processIdentifier)
        controller.cancel()
        holder.waitUntilExit()
        XCTAssertEqual(holder.terminationReason, .uncaughtSignal)

        // After the drain the group is forgotten and never signalled.
        controller.endDrain()
        controller.cancel()
    }

    /// A cancel that lands after the process exited but before its termination
    /// handler ran finds no live process to signal; the exit must stop the group.
    func testCancelJustBeforeExitStopsThePipeHolders() throws {
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", "setpgrp(0, 0); sleep 30"]
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        for _ in 0..<100 where getpgid(holder.processIdentifier) != holder.processIdentifier {
            usleep(10_000)
        }

        let controller = DownloadProcessController()
        controller.cancel()
        controller.transitionToTerminated(exitCode: 0, reason: .exit, drainingProcessGroup: holder.processIdentifier)
        holder.waitUntilExit()
        XCTAssertEqual(holder.terminationReason, .uncaughtSignal)
    }

    /// Runner level: a metadata command whose child keeps the pipe open is
    /// stopped by Stop at once, not after the drain timeout.
    func testCancelledCommandDoesNotWaitOutTheDrainTimeout() async throws {
        guard DefaultYtdlpProcessRunner.helperExecutableURL() != nil else {
            throw XCTSkip("Needs siphon-pgrp to own a process group")
        }
        let runner = DefaultYtdlpProcessRunner(streamDrainTimeout: 30)
        let controller = DownloadProcessController()
        let task = Task {
            try await runner.runCommand(["/bin/sh", "-c", "sleep 30 & echo done"], processController: controller)
        }
        // Cancel only once the parent has exited and the child holds the pipe.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .terminated = controller.lifecycleState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .terminated = controller.lifecycleState else {
            task.cancel()
            return XCTFail("The parent never exited")
        }
        let cancelled = Date()
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
    }

    func testFfmpegProgressHandlesDurationUnknownValuesAndCarriageReturns() {
        let parser = FfmpegDownloadProgress()
        XCTAssertNil(parser.parse("frame=10 time=00:00:10.00 speed=2x"))
        XCTAssertNil(parser.parse("  Duration: 00:01:00.00, start: 0.000000, bitrate: 100 kb/s"))
        let progress = parser.parse("frame=10 fps=30 time=00:00:15.00 bitrate=100kbits/s speed=2x")
        XCTAssertEqual(progress?.fraction, 0.25)
        XCTAssertNil(progress?.speed)
        XCTAssertEqual(progress?.eta, "00:22")
        XCTAssertNil(parser.parse("frame=10 time=N/A speed=N/A"))
        XCTAssertEqual(parser.parse("size=1024kB time=00:01:30.00 speed=N/A")?.fraction, 1)
        XCTAssertNil(parser.parse("file time=00:00:15.00"))
        XCTAssertNil(parser.parse("Duration: N/A, start: 0.0"))
        XCTAssertEqual(parser.parse("frame=10 time=00:00:15.00 speed=2x")?.fraction, 0.25)
        XCTAssertNil(parser.parse("Duration: 00:00:00.04, start: 0.0"))
        XCTAssertEqual(parser.parse("frame=10 time=00:00:15.00 speed=2x")?.fraction, 0.25)
        XCTAssertNil(parser.parse("Duration: 00:02:00.00, start: 0.0"))
        XCTAssertEqual(parser.parse("frame=10 time=00:00:15.00 speed=2x")?.fraction, 0.125)

        // A trimmed download writes only its section, whatever the source length.
        XCTAssertEqual(FfmpegDownloadProgress.sectionDuration(in: ["--download-sections", "*1:00-1:30", "--"]), 30)
        XCTAssertEqual(FfmpegDownloadProgress.sectionDuration(in: ["--download-sections", "*1:00:00-1:00:45.5"]), 45.5)
        XCTAssertNil(FfmpegDownloadProgress.sectionDuration(in: ["--download-sections", "*bad-1"]))
        let section = FfmpegDownloadProgress(sectionDuration: 30)
        XCTAssertNil(section.parse("  Duration: 01:00:00.00, start: 0.0"))
        XCTAssertEqual(section.parse("frame=10 time=00:00:15.00 speed=1x")?.fraction, 0.5)

        // Each playlist entry's FFmpeg run starts from its own Duration.
        XCTAssertNil(parser.parse("Input #0, hls, from 'https://example.com/b.m3u8':"))
        XCTAssertNil(parser.parse("  Duration: 00:00:30.00, start: 0.0"))
        XCTAssertEqual(parser.parse("frame=10 time=00:00:15.00 speed=2x")?.fraction, 0.5)

        let buffer = StreamBuffer()
        XCTAssertEqual(buffer.appendAndExtractLines(Data("frame=1\rframe=2\r".utf8)), ["frame=1", "frame=2"])
        XCTAssertEqual(buffer.appendAndExtractLines(Data("frame=3\r\n".utf8)), ["frame=3"])
    }

    func testProgressFieldsHidePlaceholdersAndShareOneEtaStyle() {
        for placeholder in ["NA", " N/A", " Unknown", " Unknown B/s", "--:--:--", "  "] {
            XCTAssertNil(DefaultYtdlpProcessRunner.progressField(placeholder), placeholder)
        }
        XCTAssertEqual(DefaultYtdlpProcessRunner.progressField(" 5.21MiB/s "), "5.21MiB/s")
        XCTAssertEqual(DefaultYtdlpProcessRunner.formatETA(291), "04:51")
        XCTAssertEqual(DefaultYtdlpProcessRunner.formatETA(3723), "01:02:03")
        XCTAssertEqual(DefaultYtdlpProcessRunner.ariaSeconds("4m51s").flatMap(DefaultYtdlpProcessRunner.formatETA), "04:51")
        XCTAssertEqual(DefaultYtdlpProcessRunner.ariaSeconds("1h2m3s"), 3723)
        XCTAssertNil(DefaultYtdlpProcessRunner.ariaSeconds("n/a"))
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
                XCTAssertNil(speed)
                XCTAssertEqual(eta, "00:22")
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

    func testOutputOverflowStopsTheWholeProcessTree() async throws {
        let perl = "/usr/bin/perl"
        guard FileManager.default.isExecutableFile(atPath: perl) else { throw XCTSkip("Needs perl to leave the process group") }
        // A child in its own process group keeps the pipe open. Signalling only the
        // root (and its group) misses it, so the command would wait out the 30 s
        // drain timeout; the tree kill finds it by parentage.
        let runner = DefaultYtdlpProcessRunner(streamDrainTimeout: 30)
        let started = Date()
        do {
            _ = try await runner.runCommand(["/bin/sh", "-c", "\(perl) -e 'setpgrp(0,0); exec(\"sleep\", \"30\")' & sleep 0.3; yes"])
            XCTFail("Unbounded output must fail")
        } catch YtdlpError.downloadFailed(let message) {
            XCTAssertTrue(message.contains("32 MB"), message)
        } catch {
            XCTFail("Expected downloadFailed, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
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

    func testCancelAllRunningStopsCommandsNoJobOwns() throws {
        let controller = DownloadProcessController()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try controller.start(proc)

        DownloadProcessController.cancelAllRunning()
        DownloadProcessController.waitForPendingTerminations()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationReason, .uncaughtSignal)
        XCTAssertTrue(controller.isCancelled)
    }

    func testReaperStopsOnlyOrphanedCopiesOfTheGivenTools() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reaper_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("yt-dlp")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: tool)
        // A copied platform binary is killed at launch until it is re-signed.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", tool.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw XCTSkip("Needs codesign to run a copied tool") }

        // The shell exits at once and launchd adopts the tool, as after a crash.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "\"$0\" 30 >/dev/null 2>&1 & echo $!", tool.path]
        let pipe = Pipe()
        launcher.standardOutput = pipe
        try launcher.run()
        launcher.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let orphan = try XCTUnwrap(pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let orphanStart = try XCTUnwrap(DownloadProcessController.processStartTime(orphan))
        defer {
            if DownloadProcessController.processStartTime(orphan) == orphanStart { kill(orphan, SIGKILL) }
        }

        // The same tool under a live parent belongs to a running Siphon.
        let parented = Process()
        parented.executableURL = tool
        parented.arguments = ["30"]
        try parented.run()
        defer {
            parented.terminate()
            parented.waitUntilExit()
        }

        XCTAssertEqual(DownloadProcessController.reapOrphanedProcesses(executablePaths: [tool]), [orphan])
        XCTAssertTrue(parented.isRunning)
        let deadline = Date().addingTimeInterval(5)
        while DownloadProcessController.processStartTime(orphan) == orphanStart, Date() < deadline {
            usleep(20_000) // launchd reaps the stopped orphan
        }
        XCTAssertNotEqual(DownloadProcessController.processStartTime(orphan), orphanStart)
    }
}
