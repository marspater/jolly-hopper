import Foundation

enum PlaybackSource: Sendable {
    case localFile(URL)
    case hls(manifestURL: URL, drm: DRMConfiguration?)
    // Reserved for the separate, licensed offline-download workflow.
    case offlineHLS(packageURL: URL, licenseReference: String)
}

enum PlaybackSourceResolver {
    static func validate(_ source: PlaybackSource) throws {
        switch source {
        case .localFile(let url):
            var isDirectory: ObjCBool = false
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path),
                  !["m3u8", "m3u", "movpkg"].contains(url.pathExtension.lowercased()) else {
                throw PlaybackError.invalidSource
            }
        case .hls(let url, let drm):
            try PlaybackHTTPClient.validateEndpoint(url)
            if let drm { try drm.validate() }
        case .offlineHLS:
            throw PlaybackError.offlineUnsupported
        }
    }

    static func prefersNativePlayer(_ url: URL) -> Bool {
        // Preserve external-app playback for containers AVFoundation may not support.
        url.isFileURL && ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf"].contains(url.pathExtension.lowercased())
    }
}

/// Local, explicitly selected stream descriptors. Authentication never belongs in the file.
enum PlaybackSourceDescriptor {
    private struct Fields: Decodable {
        let version: Int
        let manifestURL: URL
        let protection: String
        let certificateURL: URL?
        let licenseServerURL: URL?
        let licenseFormat: String?
        let contentIDsByKeyURI: [String: String]?
    }

    static func read(from url: URL) throws -> PlaybackSource {
        guard url.isFileURL else { throw PlaybackError.invalidConfiguration }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            return try decode(file.read(upToCount: 65537) ?? Data())
        } catch {
            throw (error as? PlaybackError) ?? .invalidDescriptor
        }
    }

    static func decode(_ data: Data) throws -> PlaybackSource {
        guard data.count <= 65536 else { throw PlaybackError.responseTooLarge }
        do {
            let allowedKeys: Set<String> = ["version", "manifestURL", "protection", "certificateURL", "licenseServerURL", "licenseFormat", "contentIDsByKeyURI"]
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: allowedKeys) else {
                throw PlaybackError.invalidConfiguration
            }
            let fields = try JSONDecoder().decode(Fields.self, from: data)
            guard fields.version == 1 else { throw PlaybackError.invalidConfiguration }
            let drm: DRMConfiguration?
            switch fields.protection {
            case "clear":
                guard fields.certificateURL == nil, fields.licenseServerURL == nil,
                      fields.licenseFormat == nil, fields.contentIDsByKeyURI == nil else {
                    throw PlaybackError.invalidConfiguration
                }
                drm = nil
            case "fairplay":
                guard fields.licenseFormat == "raw-spc-ckc",
                      let certificateURL = fields.certificateURL,
                      let licenseServerURL = fields.licenseServerURL,
                      let contentIDs = fields.contentIDsByKeyURI else {
                    throw PlaybackError.invalidConfiguration
                }
                drm = DRMConfiguration(certificateURL: certificateURL, licenseServerURL: licenseServerURL, contentIDsByKeyURI: contentIDs)
            default:
                throw PlaybackError.unsupportedProtection
            }
            let source = PlaybackSource.hls(manifestURL: fields.manifestURL, drm: drm)
            try PlaybackSourceResolver.validate(source)
            return source
        } catch {
            if let error = error as? PlaybackError, error == .unsupportedProtection || error == .responseTooLarge {
                throw error
            }
            throw PlaybackError.invalidDescriptor
        }
    }
}
