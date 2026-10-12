import Foundation

/// Explicit provider contract: DER certificate, raw binary SPC POST / CKC response,
/// UTF-8 content IDs, and optional license-only Authorization. Never persisted.
struct DRMConfiguration: Sendable {
    let certificateURL: URL
    let licenseServerURL: URL
    let contentIDsByKeyURI: [String: String]
    var authorization: String? = nil

    func validate() throws {
        try PlaybackHTTPClient.validateEndpoint(certificateURL)
        try PlaybackHTTPClient.validateEndpoint(licenseServerURL)
        guard !contentIDsByKeyURI.isEmpty,
              contentIDsByKeyURI.allSatisfy({ key, value in
                  URL(string: key)?.scheme?.lowercased() == "skd" && !value.isEmpty && value.utf8.count <= 4096
              }),
              authorization.map({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && $0.utf8.count <= 8192 }) ?? true else {
            throw PlaybackError.invalidConfiguration
        }
    }

    func contentID(for identifier: (any Sendable)?) throws -> String {
        let keyURI: String?
        if let url = identifier as? URL { keyURI = url.absoluteString }
        else { keyURI = identifier as? String }
        guard let keyURI, let contentID = contentIDsByKeyURI[keyURI] else {
            throw PlaybackError.unsupportedProtection
        }
        return contentID
    }
}
