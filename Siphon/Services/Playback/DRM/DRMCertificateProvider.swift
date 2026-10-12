import Foundation

protocol FairPlayCertificateProviding: Sendable {
    func fetchApplicationDrmCertificate() async throws -> Data
}

struct TrustedCertificateProvider: FairPlayCertificateProviding {
    let endpoint: URL
    let httpClient: PlaybackHTTPClient

    func fetchApplicationDrmCertificate() async throws -> Data {
        let (data, _) = try await httpClient.fetch(URLRequest(url: endpoint), limit: 1024 * 1024, sameOriginOnly: true)
        guard !data.isEmpty else { throw PlaybackError.invalidCertificate }
        return data
    }
}
