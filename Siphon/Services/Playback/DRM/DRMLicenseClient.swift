import Foundation
import Network

protocol FairPlayLicenseProviding: Sendable {
    func requestCKC(spcData: Data, contentID: String) async throws -> Data
}

/// Only for providers that explicitly accept raw SPC and return raw CKC.
/// The content ID is embedded in the SPC; other provider formats need their own adapter.
struct LicenseClient: FairPlayLicenseProviding {
    let endpoint: URL
    let authorization: String?
    let httpClient: PlaybackHTTPClient

    func requestCKC(spcData: Data, contentID: String) async throws -> Data {
        guard !spcData.isEmpty, spcData.count <= 1024 * 1024, !contentID.isEmpty else {
            throw PlaybackError.keyRequestFailed
        }
        if let authorization, authorization.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) || authorization.utf8.count > 8192 {
            throw PlaybackError.invalidConfiguration
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = spcData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpClient.fetch(request, limit: 1024 * 1024, sameOriginOnly: true)
        guard !data.isEmpty, response.mimeType?.lowercased() == "application/octet-stream" else {
            throw PlaybackError.invalidLicenseResponse
        }
        return data
    }
}

/// Production connections use the public-network proxy; session injection is for URLProtocol tests.
final class PlaybackHTTPClient: Sendable {
    private let session: URLSession

    init(session: URLSession) { self.session = session }

    static func make() async throws -> PlaybackHTTPClient {
        let port = try await EgressProxyServer.shared.start()
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return PlaybackHTTPClient(session: URLSession(configuration: configuration))
    }

    static func validateEndpoint(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              !url.absoluteString.contains("\r"), !url.absoluteString.contains("\n") else {
            throw PlaybackError.invalidConfiguration
        }
    }

    func fetch(_ request: URLRequest, limit: Int, sameOriginOnly: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw PlaybackError.invalidSource }
        try Self.validateEndpoint(url)
        try Task.checkCancellation()
        let redirects = PlaybackRedirectPolicy(origin: sameOriginOnly ? url : nil)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw PlaybackError.networkFailed }
            guard (200...299).contains(response.statusCode) else { throw PlaybackError.httpStatus(response.statusCode) }
            guard response.expectedContentLength <= Int64(limit) else { throw PlaybackError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw PlaybackError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? PlaybackError { throw error }
            throw PlaybackError.networkFailed
        }
    }

    func invalidate() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }
}

final class PlaybackRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL?
    init(origin: URL?) { self.origin = origin }

    static func allows(_ url: URL, from origin: URL?) -> Bool {
        guard (try? PlaybackHTTPClient.validateEndpoint(url)) != nil else { return false }
        guard let origin else { return true } // Proxy checks every connection's public address.
        return url.host?.lowercased() == origin.host?.lowercased() && (url.port ?? 443) == (origin.port ?? 443)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { Self.allows($0, from: origin) ? request : nil })
    }
}
