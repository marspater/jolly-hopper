//
//  UpdateDownloader.swift
//  Siphon
//

import Foundation

public enum UpdateDownloadError: LocalizedError, Sendable {
    case invalidURL
    case downloadCancelled
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid update download URL"
        case .downloadCancelled:
            return "Update download was cancelled"
        case .downloadFailed(let msg):
            return "Update download failed: \(msg)"
        }
    }
}

public final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
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
        return host == "github.com" || host.hasSuffix(".github.com") ||
               host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Fetches and parses a SHA-256 checksum from a GitHub release checksum file.
    public static func fetchExpectedChecksum(from checksumURL: URL, targetAssetName: String) async -> String? {
        guard isTrustedGitHubURL(checksumURL) else { return nil }
        guard let (cData, _) = try? await URLSession.shared.data(from: checksumURL),
              let text = String(data: cData, encoding: .utf8) else {
            return nil
        }

        let lines = text.split(whereSeparator: \.isNewline)
        let lowerTarget = targetAssetName.lowercased()
        let cURLName = checksumURL.lastPathComponent.lowercased()
        let isAssetSpecificChecksumFile = !lowerTarget.isEmpty && cURLName.hasPrefix(lowerTarget)

        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first, first.count == 64 else { continue }
            let hash = String(first).lowercased()

            // Single-hash file specifically named for this asset (e.g. Siphon-arm64.dmg.sha256)
            if isAssetSpecificChecksumFile && parts.count <= 2 {
                return hash
            }

            // Multi-entry manifest (e.g. SHA256SUMS.txt): must strictly match targeted asset name
            if parts.count >= 2 {
                let manifestFilename = parts.dropFirst().joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^\\*", with: "", options: .regularExpression)
                    .lowercased()
                if manifestFilename == lowerTarget || URL(fileURLWithPath: manifestFilename).lastPathComponent.lowercased() == lowerTarget {
                    return hash
                }
            }
        }
        return nil
    }

    /// Downloads a release asset to a temporary staged location with progress streaming.
    public func download(
        from url: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard Self.isTrustedGitHubURL(url) else {
            throw UpdateDownloadError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.progressHandler = onProgress
            self.continuation = continuation

            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.activeSession = session
            let task = session.downloadTask(with: url)
            self.activeTask = task
            lock.unlock()

            task.resume()
        }
    }

    /// Cancels any in-flight download task and cleans up sessions.
    public func cancel() {
        lock.lock()
        activeTask?.cancel()
        activeTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
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

        let stagedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("Siphon_Update_\(UUID().uuidString).pkg_tmp")
        do {
            if FileManager.default.fileExists(atPath: stagedFile.path) {
                try FileManager.default.removeItem(at: stagedFile)
            }
            try FileManager.default.moveItem(at: location, to: stagedFile)

            lock.lock()
            activeTask = nil
            activeSession = nil
            let cont = continuation
            continuation = nil
            lock.unlock()

            cont?.resume(returning: stagedFile)
        } catch {
            lock.lock()
            activeTask = nil
            activeSession = nil
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
        let cont = continuation
        continuation = nil
        lock.unlock()

        if let error = error {
            cont?.resume(throwing: UpdateDownloadError.downloadFailed(error.localizedDescription))
        }
    }
}
