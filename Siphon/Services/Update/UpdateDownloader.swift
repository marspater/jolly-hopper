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
    // All attempt state is protected by lock; callbacks must match both identities.
    private let sessionFactory: @Sendable (any URLSessionDelegate) -> URLSession
    private var activeOperationID: UUID?
    private var activeSession: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var destinationURL: URL?

    public override init() {
        sessionFactory = { URLSession(configuration: .ephemeral, delegate: $0, delegateQueue: nil) }
        super.init()
    }

    init(sessionFactory: @escaping @Sendable (any URLSessionDelegate) -> URLSession) {
        self.sessionFactory = sessionFactory
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

        let operationID = UUID()
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

                self.activeOperationID = operationID
                self.destinationURL = Self.stagedFileURL(for: url)
                self.progressHandler = onProgress
                self.continuation = continuation

                let session = sessionFactory(self)
                self.activeSession = session
                let task = session.downloadTask(with: url)
                self.activeTask = task
                lock.unlock()

                task.resume()
            }
        }, onCancel: {
            self.cancel(operationID: operationID)
        })
    }

    /// Cancels the current attempt. Task cancellation is scoped to its own operation ID.
    public func cancel() {
        cancel(operationID: nil)
    }

    private func cancel(operationID: UUID?) {
        lock.lock()
        if let operationID, activeOperationID != operationID {
            lock.unlock()
            return
        }
        let task = activeTask
        let session = activeSession
        let cont = clearAttemptLocked()
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        cont?.resume(throwing: UpdateDownloadError.downloadCancelled)
    }

    /// Caller holds lock. Claim the continuation and clear ownership exactly once.
    private func clearAttemptLocked() -> CheckedContinuation<URL, Error>? {
        let cont = continuation
        continuation = nil
        activeOperationID = nil
        activeTask = nil
        activeSession = nil
        progressHandler = nil
        destinationURL = nil
        return cont
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let handler = activeSession === session && activeTask === downloadTask ? progressHandler : nil
        lock.unlock()
        let progress = max(0.0, min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        handler?(progress)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        guard activeSession === session, activeTask === downloadTask, let stagedFile = destinationURL else {
            lock.unlock()
            return
        }

        // Keep staging and claiming the result atomic with cancellation. The source
        // is URLSession's temporary file and the destination is unique to this attempt.
        let result: Result<URL, Error>
        do {
            try FileManager.default.moveItem(at: location, to: stagedFile)
            result = .success(stagedFile)
        } catch {
            result = .failure(UpdateDownloadError.downloadFailed("Failed to move downloaded file: \(error.localizedDescription)"))
        }
        let cont = clearAttemptLocked()
        lock.unlock()
        session.finishTasksAndInvalidate()
        cont?.resume(with: result)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard activeSession === session, activeTask === task else {
            lock.unlock()
            return
        }
        let cont = clearAttemptLocked()
        lock.unlock()
        session.finishTasksAndInvalidate()

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                cont?.resume(throwing: UpdateDownloadError.downloadCancelled)
            } else {
                cont?.resume(throwing: UpdateDownloadError.downloadFailed(error.localizedDescription))
            }
        } else {
            cont?.resume(throwing: UpdateDownloadError.downloadFailed("Download completed without a staged package"))
        }
    }
}
