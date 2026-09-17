//
//  YtdlpProcessRunner.swift
//  Siphon
//

import Foundation
import Darwin

public final class DownloadProcessController: @unchecked Sendable {
    private var internalLifecycle: ProcessLifecycleState = .created
    private var activeProcess: Process?
    private var wasCancelled: Bool = false
    private let lock = NSLock()

    public init() {
        // Default initializer for ProcessController
    }

    public var lifecycleState: ProcessLifecycleState {
        lock.lock()
        defer { lock.unlock() }
        return internalLifecycle
    }

    public func transitionToTerminated(exitCode: Int32, reason: Process.TerminationReason) {
        lock.lock()
        defer { lock.unlock() }
        activeProcess = nil
        internalLifecycle = .terminated(exitCode: exitCode, reason: reason)
    }

    private static func getDescendantPIDs(for parentPID: pid_t) -> [pid_t] {
        guard parentPID > 0 else { return [] }
        var descendants: [pid_t] = []
        var seenPIDs: Set<pid_t> = []
        var queue: [pid_t] = [parentPID]

        while !queue.isEmpty {
            let currentParent = queue.removeFirst()
            let byteCount = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(currentParent), nil, 0)
            guard byteCount > 0 else { continue }
            let pidCount = Int(byteCount) / MemoryLayout<pid_t>.size
            var pids = [pid_t](repeating: 0, count: pidCount)
            let actualBytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(currentParent), &pids, byteCount)
            guard actualBytes > 0 else { continue }
            let actualCount = Int(actualBytes) / MemoryLayout<pid_t>.size
            for i in 0..<actualCount {
                let child = pids[i]
                if child > 0 && seenPIDs.insert(child).inserted {
                    descendants.append(child)
                    queue.append(child)
                }
            }
        }
        return descendants
    }

    public static func terminateProcessTree(_ proc: Process?, pid: pid_t? = nil) {
        let resolvedPID: pid_t = if let pid, pid > 0 { pid } else { proc?.processIdentifier ?? 0 }
        guard resolvedPID > 0 || proc?.isRunning == true else { return }

        // 1. Gather all descendants BEFORE terminating the parent to prevent reparenting to launchd (PID 1)
        var allSignaledPIDs: Set<pid_t> = []
        if resolvedPID > 0 {
            let descendants = getDescendantPIDs(for: resolvedPID)
            for child in descendants {
                allSignaledPIDs.insert(child)
                kill(child, SIGTERM)
            }

            // Also signal process group if distinct from main process group and verified as group leader
            let pgid = getpgid(resolvedPID)
            let appPgrp = getpgrp()
            if pgid > 0 && pgid == resolvedPID && pgid != appPgrp {
                kill(-pgid, SIGTERM)
            }
        }

        // 2. Terminate main parent process
        if let proc, proc.isRunning {
            proc.terminate()
        }
        if resolvedPID > 0 {
            kill(resolvedPID, SIGTERM)
        }

        // 3. Multi-pass sweep to catch any late spawns during shutdown
        if resolvedPID > 0 {
            for _ in 0..<2 {
                usleep(25_000) // 25ms grace period
                let currentDescendants = getDescendantPIDs(for: resolvedPID)
                for child in currentDescendants {
                    if allSignaledPIDs.insert(child).inserted {
                        kill(child, SIGTERM)
                    }
                }
            }

            // 4. Forceful SIGKILL escalation if processes refuse SIGTERM
            var lingering = allSignaledPIDs.filter { kill($0, 0) == 0 }
            if kill(resolvedPID, 0) == 0 {
                lingering.insert(resolvedPID)
            }
            if !lingering.isEmpty {
                usleep(50_000) // 50ms final grace period
                for targetPID in lingering {
                    if kill(targetPID, 0) == 0 {
                        kill(targetPID, SIGKILL)
                    }
                }
                let pgid = getpgid(resolvedPID)
                let appPgrp = getpgrp()
                if pgid > 0 && pgid == resolvedPID && pgid != appPgrp {
                    kill(-pgid, SIGKILL)
                }
            }
        }
    }

    /// Starts the process atomically under the controller's lock.
    /// If the controller has already been cancelled, throws without starting the process.
    public func start(_ proc: Process) throws {
        lock.lock()
        if wasCancelled {
            lock.unlock()
            throw YtdlpError.downloadFailed("Download was stopped.")
        }
        switch internalLifecycle {
        case .cancelling, .terminated:
            lock.unlock()
            throw YtdlpError.downloadFailed("Download was stopped.")
        case .running, .starting:
            lock.unlock()
            throw YtdlpError.downloadFailed("Process already running.")
        case .created, .failed:
            internalLifecycle = .starting
            activeProcess = proc
        }

        do {
            try proc.run()
            let pid = proc.processIdentifier
            internalLifecycle = .running(pid: pid)
            lock.unlock()
        } catch {
            internalLifecycle = .failed(error.localizedDescription)
            activeProcess = nil
            lock.unlock()
            throw error
        }
    }

    /// Registers the process with the controller (backwards-compatible).
    /// Returns `true` if successfully attached and uncancelled, or `false` if already cancelled.
    @discardableResult
    public func attachProcess(_ proc: Process) -> Bool {
        lock.lock()
        if wasCancelled {
            let shouldTerminate = proc.isRunning
            lock.unlock()
            if shouldTerminate {
                Self.terminateProcessTree(proc, pid: proc.processIdentifier)
            }
            return false
        }
        let shouldTerminate: Bool
        let success: Bool
        switch internalLifecycle {
        case .cancelling, .terminated:
            shouldTerminate = proc.isRunning
            success = false
        case .created, .failed:
            let pid = proc.processIdentifier
            internalLifecycle = .running(pid: pid)
            activeProcess = proc
            shouldTerminate = false
            success = true
        case .running, .starting:
            shouldTerminate = false
            success = false
        }
        lock.unlock()

        if shouldTerminate {
            Self.terminateProcessTree(proc, pid: proc.processIdentifier)
        }
        return success
    }

    /// Detaches the process upon completion or cleanup.
    public func detach() {
        lock.lock()
        defer { lock.unlock() }
        activeProcess = nil
        wasCancelled = false
        switch internalLifecycle {
        case .running:
            internalLifecycle = .created
        case .created, .cancelling, .terminated, .failed, .starting:
            break
        }
    }

    /// Requests cancellation of the process and any active child process.
    public func cancel() {
        lock.lock()
        wasCancelled = true
        let procToKill: Process?
        let pidToKill: pid_t
        switch internalLifecycle {
        case .cancelling, .terminated:
            lock.unlock()
            return
        case .created, .failed:
            internalLifecycle = .cancelling(pid: 0)
            procToKill = nil
            pidToKill = 0
        case .starting:
            internalLifecycle = .cancelling(pid: 0)
            procToKill = activeProcess
            pidToKill = activeProcess?.processIdentifier ?? 0
        case .running(let pid):
            internalLifecycle = .cancelling(pid: pid)
            procToKill = activeProcess
            pidToKill = pid
        }
        lock.unlock()

        if let proc = procToKill, proc.isRunning || pidToKill > 0 {
            Self.terminateProcessTree(proc, pid: pidToKill)
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasCancelled || internalLifecycle.isCancelling
    }
}

public struct DownloadProcessResult: Sendable {
    public let primaryPath: String
    public let allPaths: [String]

    public init(primaryPath: String, allPaths: [String] = []) {
        let validPaths = allPaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let validPrimary = primaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : primaryPath
        self.allPaths = validPaths.isEmpty ? (validPrimary.map { [$0] } ?? []) : validPaths
        self.primaryPath = validPrimary ?? self.allPaths.first ?? ""
    }

    public var isEmpty: Bool {
        primaryPath.isEmpty || allPaths.isEmpty
    }

    public var count: Int {
        allPaths.count
    }
}

public protocol YtdlpProcessRunning: Sendable {
    func runCommand(_ args: [String]) async throws -> String
    func runDownloadProcess(
        args: [String],
        saveFolder: URL,
        processController: DownloadProcessController?,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DownloadProcessResult
}

public struct DefaultYtdlpProcessRunner: YtdlpProcessRunning {
    public init() {
        // Default initializer for DefaultYtdlpProcessRunner
    }

    public static func helperExecutableURL() -> URL? {
        // 1. Auxiliary executable in application bundle
        if let url = Bundle.main.url(forAuxiliaryExecutable: "siphon-pgrp"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        // 2. Contents/Helpers/siphon-pgrp in main bundle
        let helperInBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/siphon-pgrp")
        if FileManager.default.isExecutableFile(atPath: helperInBundle.path) {
            return helperInBundle
        }
        // 3. In built products / test bundle directory
        let testDir = Bundle(for: DownloadProcessController.self).bundleURL.deletingLastPathComponent()
        let inBuiltProducts = testDir.appendingPathComponent("siphon-pgrp")
        if FileManager.default.isExecutableFile(atPath: inBuiltProducts.path) {
            return inBuiltProducts
        }
        return nil
    }

    public static func ensureProcessGroupHelper() -> URL? {
        helperExecutableURL()
    }

    public static func configureProcessCommand(_ process: Process, args: [String]) {
        if let helperURL = ensureProcessGroupHelper() {
            let appBundleURL = Bundle.main.bundleURL
            let testBundleURL = Bundle(for: DownloadProcessController.self).bundleURL.deletingLastPathComponent()
            let isSafe = YtdlpService.isPathContained(targetURL: helperURL, inside: appBundleURL) ||
                         YtdlpService.isPathContained(targetURL: helperURL, inside: testBundleURL)
            if isSafe {
                process.executableURL = helperURL
                process.arguments = ["/usr/bin/env"] + args
                return
            } else {
                Task { @MainActor in
                    LoggerService.shared.log("Process group helper at \(helperURL.path) is outside trusted bundle directory; falling back to /usr/bin/env.", level: .warning)
                }
            }
        }
        Task { @MainActor in
            LoggerService.shared.log("Native process group helper unavailable; running directly via /usr/bin/env.", level: .warning)
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
    }

    public func runCommand(_ args: [String]) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        let controller = DownloadProcessController()

        Self.configureProcessCommand(process, args: args)
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = YtdlpService.createSanitizedEnvironment()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let safeContinuation = SafeContinuation(continuation)

                if Task.isCancelled || controller.isCancelled {
                    safeContinuation.resume(throwing: YtdlpError.downloadFailed("Command was cancelled."))
                    return
                }

                let outputBuffer = ThreadSafeDataBuffer()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty {
                        outputBuffer.append(data)
                    }
                }

                process.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil

                    let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
                    try? pipe.fileHandleForReading.close()
                    proc.terminationHandler = nil

                    if !remainingData.isEmpty {
                        outputBuffer.append(remainingData)
                    }

                    let output = outputBuffer.getString()
                    controller.transitionToTerminated(exitCode: proc.terminationStatus, reason: proc.terminationReason)

                    if Task.isCancelled || controller.isCancelled || proc.terminationReason == .uncaughtSignal {
                        safeContinuation.resume(throwing: YtdlpError.downloadFailed("Command was cancelled."))
                    } else if proc.terminationStatus == 0 {
                        safeContinuation.resume(returning: output)
                    } else {
                        safeContinuation.resume(throwing: YtdlpError.commandFailed(output))
                    }
                }

                do {
                    if Task.isCancelled {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        try? pipe.fileHandleForReading.close()
                        process.terminationHandler = nil
                        safeContinuation.resume(throwing: YtdlpError.downloadFailed("Command was cancelled."))
                        return
                    }
                    try controller.start(process)
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    try? pipe.fileHandleForReading.close()
                    process.terminationHandler = nil
                    safeContinuation.resume(throwing: error)
                }
            }
        } onCancel: {
            controller.cancel()
        }
    }

    public func runDownloadProcess(
        args: [String],
        saveFolder: URL,
        processController: DownloadProcessController?,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DownloadProcessResult {
        let controller = processController ?? DownloadProcessController()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let safeContinuation = SafeContinuation(continuation)

                if Task.isCancelled || controller.isCancelled {
                    safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download was stopped."))
                    return
                }

            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            Self.configureProcessCommand(process, args: args)
            process.currentDirectoryURL = saveFolder
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.environment = YtdlpService.createSanitizedEnvironment()

            let outputState = ThreadSafeOutputState()

            // Bolt Performance Optimization: Process output lines using Substring slices and range searches to eliminate intermediate String array allocations during real-time output stream handling
            let processOutputLine: @Sendable (String) -> Void = { line in
                if let range = line.range(of: "SIPHON_FINAL_PATH:") {
                    let extracted = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !extracted.isEmpty {
                        outputState.addFinalPath(extracted)
                    }
                    onOutput(line)
                    return
                }

                if let range = line.range(of: "SIPHON_PROG:") {
                    let fields = line[range.upperBound...].split(separator: "|", omittingEmptySubsequences: false)
                    let percentSub = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
                    let stripped = percentSub.hasSuffix("%") ? String(percentSub.dropLast()) : percentSub
                    let normalized = stripped.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                    let speed = fields.count > 1 ? String(fields[1]).trimmingCharacters(in: .whitespaces) : nil
                    let eta = fields.count > 2 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : nil
                    if normalized != "NA" && !normalized.isEmpty, let percent = Double(normalized), !percent.isNaN && !percent.isInfinite {
                        let safeSpeed = (speed == "NA" || speed?.isEmpty == true) ? nil : speed
                        let safeEta = (eta == "NA" || eta?.isEmpty == true) ? nil : eta
                        onProgress(max(0.0, min(1.0, percent / 100.0)), safeSpeed, safeEta)
                    }
                    return
                }

                // Parse aria2c multi-connection progress lines (e.g. "[#50a1f3 18MiB/220MiB(8%) CN:16 DL:27MiB ETA:7s]")
                if (line.hasPrefix("[#") || line.contains("CN:")) && line.contains("DL:") {
                    if let openParen = line.range(of: "("),
                       let closeParen = line.range(of: "%)", range: openParen.upperBound..<line.endIndex) {
                        let percentStr = String(line[openParen.upperBound..<closeParen.lowerBound]).trimmingCharacters(in: .whitespaces)
                        if let percentVal = Double(percentStr), !percentVal.isNaN && !percentVal.isInfinite {
                            let safePercent = max(0.0, min(1.0, percentVal / 100.0))

                            var speedStr: String? = nil
                            if let dlRange = line.range(of: "DL:") {
                                let afterDl = line[dlRange.upperBound...]
                                if let token = afterDl.split(whereSeparator: { $0.isWhitespace || $0 == "]" }).first {
                                    speedStr = String(token) + "/s"
                                }
                            }

                            var etaStr: String? = nil
                            if let etaRange = line.range(of: "ETA:") {
                                let afterEta = line[etaRange.upperBound...]
                                if let token = afterEta.split(whereSeparator: { $0.isWhitespace || $0 == "]" }).first {
                                    etaStr = String(token)
                                }
                            }

                            onOutput(line)
                            onProgress(safePercent, speedStr, etaStr)
                            return
                        }
                    }
                }

                if line.contains("[info] Writing video thumbnail") ||
                   line.contains("[info] Writing video subtitle") ||
                   line.contains("[info] Writing video description") ||
                   line.contains("[ThumbnailsConvertor]") ||
                   line.contains("[EmbedThumbnail]") ||
                   line.contains("[EmbedSubtitle]") {
                    onOutput(line)
                    return
                }

                if let range = line.range(of: "[download] Destination: ") {
                    outputState.addCandidatePath(String(line[range.upperBound...]))
                }

                if let range = line.range(of: " has already been downloaded"),
                   let dlRange = line.range(of: "[download] "),
                   dlRange.upperBound <= range.lowerBound {
                    let pathPart = String(line[dlRange.upperBound..<range.lowerBound])
                    if !pathPart.isEmpty {
                        outputState.addCandidatePath(pathPart)
                    }
                }

                if line.contains("[Merger] Merging formats into") {
                    let parts = line.split(separator: "\"")
                    if parts.count > 1 {
                        outputState.addCandidatePath(String(parts[1]))
                    }
                }

                if let range = line.range(of: "[ExtractAudio] Destination: ") {
                    outputState.addCandidatePath(String(line[range.upperBound...]))
                }

                if let range = line.range(of: " to \"", options: .backwards) {
                    let afterTo = line[range.upperBound...]
                    if let endQuote = afterTo.firstIndex(of: "\"") {
                        let target = String(afterTo[..<endQuote])
                        if !target.isEmpty {
                            outputState.addCandidatePath(target)
                        }
                    }
                }

                onOutput(line)

                DispatchQueue.main.async {
                    if line.contains("%") {
                        let components = line.split(whereSeparator: \.isWhitespace)
                        if let percentIndex = components.firstIndex(where: { $0.hasSuffix("%") }) {
                            let percentStr = components[percentIndex].dropLast()
                            if let percent = Double(percentStr), !percent.isNaN && !percent.isInfinite {
                                let speed = components.indices.contains(percentIndex + 3) ? String(components[percentIndex + 3]) : nil
                                let eta = components.indices.contains(percentIndex + 5) ? String(components[percentIndex + 5]) : nil
                                onProgress(max(0.0, min(1.0, percent / 100.0)), speed, eta)
                            }
                        }
                    } else if line.contains("[EmbedThumbnail]") {
                        onProgress(0.99, "Embedding thumbnail...", "Finalizing file")
                    } else if line.contains("[Metadata]") {
                        onProgress(0.99, "Adding metadata...", "Finalizing file")
                    } else if line.contains("[Merger]") {
                        onProgress(0.99, "Merging video & audio...", "Please wait")
                    } else if line.contains("[VideoConvertor]") || line.contains("Converting video") {
                        onProgress(0.99, "Converting video...", "Please wait")
                    } else if line.contains("[ThumbnailsConvertor]") {
                        onProgress(0.99, "Preparing thumbnail...", "Please wait")
                    } else if line.contains("[EmbedSubtitle]") {
                        onProgress(0.99, "Embedding subtitles...", "Please wait")
                    } else if line.contains("[ffmpeg]") {
                        onProgress(0.99, "Processing media...", "Please wait")
                    }
                }
            }

            let outputBuffer = StreamBuffer()
            let errorBuffer = StreamBuffer()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in outputBuffer.appendAndExtractLines(data) {
                    processOutputLine(line)
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in errorBuffer.appendAndExtractLines(data) {
                    outputState.appendError(line + "\n")
                    DispatchQueue.main.async { onOutput("[ERROR] \(line)") }
                }
            }

            process.terminationHandler = { proc in
                controller.transitionToTerminated(exitCode: proc.terminationStatus, reason: proc.terminationReason)
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingOutput.isEmpty {
                    for line in outputBuffer.appendAndExtractLines(remainingOutput) {
                        processOutputLine(line)
                    }
                }
                for line in outputBuffer.flush() {
                    processOutputLine(line)
                }

                let remainingError = errorPipe.fileHandleForReading.readDataToEndOfFile()
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                proc.terminationHandler = nil

                if !remainingError.isEmpty {
                    for line in errorBuffer.appendAndExtractLines(remainingError) {
                        outputState.appendError(line + "\n")
                        DispatchQueue.main.async { onOutput("[ERROR] \(line)") }
                    }
                }
                for line in errorBuffer.flush() {
                    outputState.appendError(line + "\n")
                    DispatchQueue.main.async { onOutput("[ERROR] \(line)") }
                }

                // If user requested cancellation or process was terminated via signal, resume with appropriate error
                if Task.isCancelled || controller.isCancelled {
                    safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download was stopped."))
                    return
                }
                if proc.terminationReason == .uncaughtSignal {
                    safeContinuation.resume(throwing: YtdlpError.downloadFailed("Process terminated unexpectedly with signal (exit code \(proc.terminationStatus))."))
                    return
                }

                let fm = FileManager.default
                var verifiedFinalPaths: [String] = []

                // 1. Check deterministic final path(s) emitted by yt-dlp
                for directPath in outputState.getFinalPaths() {
                    let rawURL = directPath.hasPrefix("/") ? URL(fileURLWithPath: directPath) : saveFolder.appendingPathComponent(directPath)
                    let resolved = rawURL.standardizedFileURL.resolvingSymlinksInPath()
                    if fm.fileExists(atPath: resolved.path),
                       let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
                       values.isRegularFile == true,
                       YtdlpService.isMediaFilePath(resolved.path),
                       YtdlpService.isPathContained(targetURL: resolved, inside: saveFolder) {
                        if !verifiedFinalPaths.contains(resolved.path) {
                            verifiedFinalPaths.append(resolved.path)
                        }
                    }
                }

                // 2. Fallback to candidate paths parsed from output if no direct final paths verified
                if verifiedFinalPaths.isEmpty {
                    let candidates = outputState.getCandidatePaths()
                    for candidate in candidates.reversed() {
                        let rawURL = candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : saveFolder.appendingPathComponent(candidate)
                        let resolved = rawURL.standardizedFileURL.resolvingSymlinksInPath()

                        if fm.fileExists(atPath: resolved.path),
                           let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
                           values.isRegularFile == true,
                           YtdlpService.isMediaFilePath(resolved.path),
                           YtdlpService.isPathContained(targetURL: resolved, inside: saveFolder) {
                            verifiedFinalPaths.append(resolved.path)
                            break
                        }
                    }
                }

                let errorOutput = outputState.getErrorText()

                if proc.terminationStatus == 0 {
                    if let primary = verifiedFinalPaths.first {
                        safeContinuation.resume(returning: DownloadProcessResult(primaryPath: primary, allPaths: verifiedFinalPaths))
                    } else {
                        safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download process completed, but no valid media file was verified in the target destination."))
                    }
                } else {
                    let lower = errorOutput.lowercased()
                    if errorOutput.contains("Cloudflare") || (errorOutput.contains("403") && (errorOutput.contains("anti-bot") || lower.contains("cloudflare") || lower.contains("turnstile") || lower.contains("bot"))) || lower.contains("sign in to confirm you're not a bot") || lower.contains("sign in to confirm you’re not a bot") {
                        safeContinuation.resume(throwing: YtdlpError.cloudflareBlocked)
                    } else if errorOutput.contains("429") || errorOutput.contains("Too Many Requests") {
                        safeContinuation.resume(throwing: YtdlpError.tooManyRequests)
                    } else if errorOutput.contains("subtitle") || errorOutput.contains("caption") {
                        safeContinuation.resume(throwing: YtdlpError.subtitleError(errorOutput))
                    } else {
                        let cleanError = errorOutput.split(whereSeparator: \.isNewline)
                            .reversed()
                            .first(where: { $0.contains("ERROR:") })
                            .map { String($0).replacingOccurrences(of: "ERROR: ", with: "") }
                            ?? errorOutput
                        safeContinuation.resume(throwing: YtdlpError.downloadFailed(cleanError.isEmpty ? "Process exited with code \(proc.terminationStatus)" : cleanError))
                    }
                }
            }

            do {
                try controller.start(process)
            } catch {
                controller.detach()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                process.terminationHandler = nil
                safeContinuation.resume(throwing: error)
            }
        }
    }, onCancel: {
        controller.cancel()
    })
    }
}
