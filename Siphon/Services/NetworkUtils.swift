import Foundation

enum NetworkUtils {
    static func download(url: URL) async throws -> (URL, URLResponse) {
        if #available(macOS 12.0, *) {
            return try await URLSession.shared.download(from: url)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let localURL = localURL, let response = response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    // URLSession deletes the file when this completion handler returns!
                    // We must move it to a temporary location that persists.
                    let persistentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do {
                        if FileManager.default.fileExists(atPath: persistentURL.path) {
                            try FileManager.default.removeItem(at: persistentURL)
                        }
                        try FileManager.default.moveItem(at: localURL, to: persistentURL)
                        continuation.resume(returning: (persistentURL, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                task.resume()
            }
        }
    }
}
