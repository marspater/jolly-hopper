//
//  YtdlpProcessRunner.swift
//  Siphon
//

import Foundation
import Darwin

public final class DownloadProcessController: @unchecked Sendable {
    private enum State {
        case idle
        case running(Process, pid_t)
        case cancelled
    }

    private var state: State = .idle
    private let lock = NSLock()

    public init() {}

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
        let resolvedPID = (pid != nil && pid! > 0) ? pid! : (proc?.processIdentifier ?? 0)
        guard resolvedPID > 0 || proc?.isRunning == true else { return }

        // 1. Terminate main parent process immediately
        if let proc, proc.isRunning {
            proc.terminate()
        }
        if resolvedPID > 0 {
            kill(resolvedPID, SIGTERM)
        }

        // 2. Multi-pass descendant reaping: catch initial descendants and late spawns during shutdown
        var allSignaledPIDs: Set<pid_t> = []
        if resolvedPID > 0 {
            for pass in 0..<3 {
                let currentDescendants = getDescendantPIDs(for: resolvedPID)
                for child in currentDescendants {
                    if !allSignaledPIDs.contains(child) {
                        allSignaledPIDs.insert(child)
                        kill(child, SIGTERM)
                    }
                }
                if currentDescendants.isEmpty && pass > 0 {
                    break
                }
                // Short yield before next sweep to allow processes to terminate
                if pass < 2 {
                    usleep(25_000) // 25ms
                }
            }
        }
    }

    /// Starts the process atomically under the controller's lock.
    /// If the controller has already been cancelled, throws without starting the process.
    public func start(_ proc: Process) throws {
        lock.lock()
        switch state {
        case .cancelled:
            lock.unlock()
            throw YtdlpError.downloadFailed("Download was stopped.")
        case .running:
            lock.unlock()
            throw YtdlpError.downloadFailed("Process already running.")
        case .idle:
            break
        }

        do {
            try proc.run()
            let pid = proc.processIdentifier
            state = .running(proc, pid)
            lock.unlock()
        } catch {
            state = .idle
            lock.unlock()
            throw error
        }
    }

    /// Registers the process with the controller (backwards-compatible).
    /// Returns `true` if successfully attached and uncancelled, or `false` if already cancelled.
    @discardableResult
    public func attachProcess(_ proc: Process) -> Bool {
        lock.lock()
        let shouldTerminate: Bool
        let success: Bool
        switch state {
        case .cancelled:
            shouldTerminate = proc.isRunning
            success = false
        case .idle:
            state = .running(proc, proc.processIdentifier)
            shouldTerminate = false
            success = true
        case .running:
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
        switch state {
        case .idle, .cancelled:
            break
        case .running:
            state = .idle
        }
    }

    /// Requests cancellation of the process and any active child process.
    public func cancel() {
        lock.lock()
        let previousState = state
        state = .cancelled
        lock.unlock()

        if case .running(let proc, let pid) = previousState {
            Self.terminateProcessTree(proc, pid: pid)
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = state { return true }
        return false
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
    ) async throws -> String
}

public struct DefaultYtdlpProcessRunner: YtdlpProcessRunning {
    public init() {}

    public func runCommand(_ args: [String]) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        let controller = DownloadProcessController()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
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
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let safeContinuation = SafeContinuation(continuation)

            if processController?.isCancelled == true {
                safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download was stopped."))
                return
            }

            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.currentDirectoryURL = saveFolder
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.environment = YtdlpService.createSanitizedEnvironment()

            let outputState = ThreadSafeOutputState()

            let processOutputLine: @Sendable (String) -> Void = { line in
                if line.contains("SIPHON_FINAL_PATH:") {
                    let parts = line.components(separatedBy: "SIPHON_FINAL_PATH:")
                    if parts.count > 1 {
                        let extracted = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !extracted.isEmpty {
                            outputState.setFinalPath(extracted)
                        }
                    }
                    return
                }

                if line.contains("SIPHON_PROG:") {
                    let parts = line.components(separatedBy: "SIPHON_PROG:")
                    if parts.count > 1 {
                        let fields = parts[1].components(separatedBy: "|")
                        let percentStr = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
                        let stripped = percentStr.hasSuffix("%") ? String(percentStr.dropLast()) : percentStr
                        let normalized = stripped.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                        let speed = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : nil
                        let eta = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : nil
                        if normalized != "NA" && !normalized.isEmpty, let percent = Double(normalized), !percent.isNaN && !percent.isInfinite {
                            let safeSpeed = (speed == "NA" || speed?.isEmpty == true) ? nil : speed
                            let safeEta = (eta == "NA" || eta?.isEmpty == true) ? nil : eta
                            onProgress(max(0.0, min(1.0, percent / 100.0)), safeSpeed, safeEta)
                        }
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

                if line.contains("[download] Destination:") {
                    let parts = line.components(separatedBy: "[download] Destination: ")
                    if parts.count > 1 {
                        outputState.addCandidatePath(parts[1])
                    }
                }

                if line.contains("has already been downloaded") {
                    let parts = line.components(separatedBy: "[download] ")
                    if parts.count > 1 {
                        let pathPart = parts[1].components(separatedBy: " has already been downloaded")
                        if !pathPart.isEmpty {
                            outputState.addCandidatePath(pathPart[0])
                        }
                    }
                }

                if line.contains("[Merger] Merging formats into") {
                    let parts = line.components(separatedBy: "\"")
                    if parts.count > 1 {
                        outputState.addCandidatePath(parts[1])
                    }
                }

                if line.contains("[ExtractAudio] Destination:") {
                    let parts = line.components(separatedBy: "[ExtractAudio] Destination: ")
                    if parts.count > 1 {
                        outputState.addCandidatePath(parts[1])
                    }
                }

                if line.contains(" to \"") {
                    let parts = line.components(separatedBy: " to \"")
                    if let target = parts.last?.components(separatedBy: "\"").first, !target.isEmpty {
                        outputState.addCandidatePath(target)
                    }
                }

                DispatchQueue.main.async {
                    onOutput(line)

                    if line.contains("%") {
                        let components = line.split(whereSeparator: \.isWhitespace).map(String.init)
                        if let percentIndex = components.firstIndex(where: { $0.hasSuffix("%") }) {
                            let percentStr = components[percentIndex].dropLast()
                            if let percent = Double(percentStr), !percent.isNaN && !percent.isInfinite {
                                let speed = components.indices.contains(percentIndex + 3) ? components[percentIndex + 3] : nil
                                let eta = components.indices.contains(percentIndex + 5) ? components[percentIndex + 5] : nil
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
                processController?.detach()
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
                if processController?.isCancelled == true {
                    safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download was stopped."))
                    return
                }
                if proc.terminationReason == .uncaughtSignal {
                    safeContinuation.resume(throwing: YtdlpError.downloadFailed("Process terminated unexpectedly with signal (exit code \(proc.terminationStatus))."))
                    return
                }

                let fm = FileManager.default
                var finalURL: URL? = nil

                // 1. Check deterministic final path emitted by yt-dlp
                if let directPath = outputState.getFinalPath() {
                    let rawURL = directPath.hasPrefix("/") ? URL(fileURLWithPath: directPath) : saveFolder.appendingPathComponent(directPath)
                    let resolved = rawURL.standardizedFileURL.resolvingSymlinksInPath()
                    if fm.fileExists(atPath: resolved.path),
                       let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
                       values.isRegularFile == true,
                       YtdlpService.isMediaFilePath(resolved.path),
                       YtdlpService.isPathContained(targetURL: resolved, inside: saveFolder) {
                        finalURL = resolved
                    }
                }

                // 2. Fallback to candidate paths parsed from output
                if finalURL == nil {
                    let candidates = outputState.getCandidatePaths()
                    for candidate in candidates.reversed() {
                        let rawURL = candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : saveFolder.appendingPathComponent(candidate)
                        let resolved = rawURL.standardizedFileURL.resolvingSymlinksInPath()

                        if fm.fileExists(atPath: resolved.path),
                           let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
                           values.isRegularFile == true,
                           YtdlpService.isMediaFilePath(resolved.path),
                           YtdlpService.isPathContained(targetURL: resolved, inside: saveFolder) {
                            finalURL = resolved
                            break
                        }
                    }
                }

                let errorOutput = outputState.getErrorText()

                if proc.terminationStatus == 0 {
                    if let resolvedURL = finalURL {
                        safeContinuation.resume(returning: resolvedURL.path)
                    } else {
                        safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download process completed, but no valid media file was verified in the target destination."))
                    }
                } else {
                    let lower = errorOutput.lowercased()
                    if errorOutput.contains("Cloudflare") || (errorOutput.contains("403") && (errorOutput.contains("anti-bot") || errorOutput.contains("Forbidden") || lower.contains("bot"))) || lower.contains("sign in to confirm you're not a bot") || lower.contains("sign in to confirm you’re not a bot") {
                        safeContinuation.resume(throwing: YtdlpError.cloudflareBlocked)
                    } else if errorOutput.contains("429") || errorOutput.contains("Too Many Requests") {
                        safeContinuation.resume(throwing: YtdlpError.tooManyRequests)
                    } else if errorOutput.contains("subtitle") || errorOutput.contains("caption") {
                        safeContinuation.resume(throwing: YtdlpError.subtitleError(errorOutput))
                    } else {
                        let cleanError = errorOutput.components(separatedBy: "\n")
                            .filter { $0.contains("ERROR:") }
                            .last?
                            .replacingOccurrences(of: "ERROR: ", with: "")
                            ?? errorOutput
                        safeContinuation.resume(throwing: YtdlpError.downloadFailed(cleanError.isEmpty ? "Process exited with code \(proc.terminationStatus)" : cleanError))
                    }
                }
            }

            do {
                if let controller = processController {
                    try controller.start(process)
                } else {
                    try process.run()
                }
            } catch {
                processController?.detach()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
                process.terminationHandler = nil
                safeContinuation.resume(throwing: error)
            }
        }
    }
}
