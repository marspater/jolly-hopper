//
//  YtdlpProcessRunner.swift
//  Siphon
//

import Foundation

public protocol YtdlpProcessRunning: Sendable {
    func runCommand(_ args: [String]) async throws -> String
    func runDownloadProcess(
        args: [String],
        saveFolder: URL,
        isCancelled: (@Sendable () -> Bool)?,
        onProcessCreated: @escaping @Sendable (Process) -> Void,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

public struct DefaultYtdlpProcessRunner: YtdlpProcessRunning {
    public init() {}

    public func runCommand(_ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let safeContinuation = SafeContinuation(continuation)
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = YtdlpService.createSanitizedEnvironment()

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
                if !remainingData.isEmpty {
                    outputBuffer.append(remainingData)
                }

                let output = outputBuffer.getString()

                if proc.terminationStatus == 0 {
                    safeContinuation.resume(returning: output)
                } else {
                    safeContinuation.resume(throwing: YtdlpError.commandFailed(output))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                safeContinuation.resume(throwing: error)
            }
        }
    }

    public func runDownloadProcess(
        args: [String],
        saveFolder: URL,
        isCancelled: (@Sendable () -> Bool)?,
        onProcessCreated: @escaping @Sendable (Process) -> Void,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let safeContinuation = SafeContinuation(continuation)

            if isCancelled?() == true {
                safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download was cancelled before process initialization."))
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

            onProcessCreated(process)

            if isCancelled?() == true {
                safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download was cancelled before process launch."))
                return
            }
            let outputState = ThreadSafeOutputState()

            let processOutputLine: @Sendable (String) -> Void = { line in
                if line.contains("[info] Writing video thumbnail") ||
                   line.contains("[info] Writing video subtitle") ||
                   line.contains("[info] Writing video description") ||
                   line.contains("[ThumbnailsConvertor]") ||
                   line.contains("[EmbedThumbnail]") ||
                   line.contains("[EmbedSubtitle]") {
                    DispatchQueue.main.async { onOutput(line) }
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
                        // Bolt Performance Optimization: Replace allocations of intermediate strings
                        // and arrays during high-frequency parsing with substring mapping
                        let components = line.split(whereSeparator: \.isWhitespace).map(String.init)

                        if let percentStr = components.first {
                            let cleanPercent = percentStr.hasSuffix("%") ? String(percentStr.dropLast()) : percentStr
                            if let percent = Double(cleanPercent) {
                                let speed = components.count > 1 ? components[1] : nil
                                let eta = components.count > 2 ? components[2] : nil
                                onProgress(percent / 100.0, speed, eta)
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

                let fm = FileManager.default
                var finalURL: URL? = nil

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
                try process.run()
                if isCancelled?() == true {
                    process.terminate()
                    safeContinuation.resume(throwing: YtdlpError.downloadFailed("Download was cancelled immediately after process launch."))
                    return
                }
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                safeContinuation.resume(throwing: error)
            }
        }
    }
}
