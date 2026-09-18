//
//  UpdateDownloader.swift
//  Siphon
//

import Foundation

public enum UpdateDownloadError: LocalizedError, Sendable {
    case invalidURL
    case downloadCancelled
    case checksumUnavailable(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid update download URL"
        case .downloadCancelled:
            return "Update download was cancelled"
        case .checksumUnavailable(let msg):
            return "Could not verify update checksum: \(msg)"
        case .downloadFailed(let msg):
            return "Update download failed: \(msg)"
        }
    }
}

public final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()

    private static func log(_ message: String, level: LoggerService.LogLevel) {
        Task { @MainActor in
            LoggerService.shared.log(message, level: level)
        }
    }
    private var activeSession: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var destinationURL: URL?

    public override init() {
        super.init()
    }

    public static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()

        if host == "github.com" {
            return path.hasPrefix("/marspater/jolly-hopper/")
        }
        if host == "api.github.com" {
            return path.hasPrefix("/repos/marspater/jolly-hopper/")
        }
        if host == "raw.githubusercontent.com" {
            return path.hasPrefix("/marspater/jolly-hopper/")
        }
        if host == "objects.githubusercontent.com" {
            return true
        }
        return false
    }

    static func stagedFileURL(
        for sourceURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        let sourceExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedName = sourceExtension.isEmpty
            ? "Siphon_Update_\(UUID().uuidString)"
            : "Siphon_Update_\(UUID().uuidString).\(sourceExtension)"
        return temporaryDirectory.appendingPathComponent(stagedName)
    }

    static func parseExpectedChecksum(
        from text: String,
        targetAssetName: String,
        checksumFileName: String
    ) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
        let lowerTarget = targetAssetName.lowercased()
        let lowerChecksumFileName = checksumFileName.lowercased()
        let isAssetSpecificChecksumFile = !lowerTarget.isEmpty && lowerChecksumFileName.hasPrefix(lowerTarget)

        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first, first.count == 64 else { continue }
            let hash = String(first).lowercased()
            guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }

            if isAssetSpecificChecksumFile && parts.count <= 2 {
                return hash
            }

            if parts.count >= 2 {
                let manifestFilename = parts.dropFirst().joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^\\*", with: "", options: .regularExpression)
                    .lowercased()
                if manifestFilename == lowerTarget ||
                    URL(fileURLWithPath: manifestFilename).lastPathComponent.lowercased() == lowerTarget {
                    return hash
                }
            }
        }
        return nil
    }

    /// Fetches and parses a SHA-256 checksum from a GitHub release checksum file.
    public static func fetchExpectedChecksum(from checksumURL: URL, targetAssetName: String) async throws -> String {
        guard isTrustedGitHubURL(checksumURL) else {
            throw UpdateDownloadError.invalidURL
        }

        var request = URLRequest(url: checksumURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Siphon-Updater", forHTTPHeaderField: "User-Agent")
        let (cData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateDownloadError.checksumUnavailable("checksum endpoint returned HTTP \(status)")
        }
        guard let text = String(data: cData, encoding: .utf8) else {
            throw UpdateDownloadError.checksumUnavailable("checksum response was not valid UTF-8")
        }

        if let checksum = parseExpectedChecksum(
            from: text,
            targetAssetName: targetAssetName,
            checksumFileName: checksumURL.lastPathComponent
        ) {
            return checksum
        }

        throw UpdateDownloadError.checksumUnavailable("no SHA-256 entry matched \(targetAssetName)")
    }

    /// Downloads a release asset to a temporary staged location with progress streaming.
    public func download(
        from url: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard Self.isTrustedGitHubURL(url) else {
            throw UpdateDownloadError.invalidURL
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: UpdateDownloadError.downloadCancelled)
                    return
                }
                if self.activeTask != nil || self.continuation != nil {
                    lock.unlock()
                    continuation.resume(throwing: UpdateDownloadError.downloadFailed("A download task is already in progress"))
                    return
                }

                self.destinationURL = Self.stagedFileURL(for: url)
                self.progressHandler = onProgress
                self.continuation = continuation

                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                self.activeSession = session
                let task = session.downloadTask(with: url)
                self.activeTask = task
                lock.unlock()

                task.resume()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    /// Cancels any in-flight download task and cleans up sessions.
    public func cancel() {
        lock.lock()
        activeTask?.cancel()
        activeTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
        progressHandler = nil
        destinationURL = nil
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(throwing: UpdateDownloadError.downloadCancelled)
        } else {
            lock.unlock()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = max(0.0, min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        progressHandler?(progress)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        session.finishTasksAndInvalidate()

        lock.lock()
        let stagedFile = destinationURL
        lock.unlock()

        guard let stagedFile else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: stagedFile.path) {
                try FileManager.default.removeItem(at: stagedFile)
            }
            try FileManager.default.moveItem(at: location, to: stagedFile)

            lock.lock()
            activeTask = nil
            activeSession = nil
            progressHandler = nil
            destinationURL = nil
            let cont = continuation
            continuation = nil
            lock.unlock()

            if let cont {
                cont.resume(returning: stagedFile)
            } else {
                do {
                    try FileManager.default.removeItem(at: stagedFile)
                } catch {
                    Self.log("Failed to remove an unclaimed staged update: \(error.localizedDescription)", level: .warning)
                }
            }
        } catch {
            lock.lock()
            activeTask = nil
            activeSession = nil
            progressHandler = nil
            destinationURL = nil
            let cont = continuation
            continuation = nil
            lock.unlock()

            cont?.resume(throwing: UpdateDownloadError.downloadFailed("Failed to move downloaded file: \(error.localizedDescription)"))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        lock.lock()
        activeTask = nil
        activeSession = nil
        progressHandler = nil
        destinationURL = nil
        let cont = continuation
        continuation = nil
        lock.unlock()

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                cont?.resume(throwing: UpdateDownloadError.downloadCancelled)
            } else {
                cont?.resume(throwing: UpdateDownloadError.downloadFailed(error.localizedDescription))
            }
        }
    }
}
