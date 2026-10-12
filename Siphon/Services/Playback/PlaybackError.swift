import Foundation

enum PlaybackError: Error, LocalizedError, Equatable {
    case invalidSource
    case invalidConfiguration
    case invalidDescriptor
    case offlineUnsupported
    case unsupportedProtection
    case invalidCertificate
    case invalidLicenseResponse
    case keyRequestFailed
    case networkFailed
    case responseTooLarge
    case httpStatus(Int)
    case playerFailed

    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidSource: key = "playback_invalid_source"
        case .invalidConfiguration: key = "playback_invalid_configuration"
        case .invalidDescriptor: key = "playback_invalid_descriptor"
        case .offlineUnsupported: key = "playback_offline_unsupported"
        case .unsupportedProtection: key = "playback_unsupported_protection"
        case .invalidCertificate: key = "playback_invalid_certificate"
        case .invalidLicenseResponse: key = "playback_invalid_license"
        case .keyRequestFailed: key = "playback_key_failed"
        case .networkFailed: key = "playback_network_failed"
        case .responseTooLarge: key = "playback_response_too_large"
        case .httpStatus(401), .httpStatus(403): key = "playback_license_denied"
        case .httpStatus: key = "playback_http_failed"
        case .playerFailed: key = "playback_player_failed"
        }
        return LanguageService.s(key)
    }
}
