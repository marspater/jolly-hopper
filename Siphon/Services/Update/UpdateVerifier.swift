//
//  UpdateVerifier.swift
//  Siphon
//

import Foundation
import Security
import CryptoKit

public enum UpdateVerificationError: LocalizedError, Sendable {
    case fileNotFound(URL)
    case checksumMismatch(expected: String, actual: String)
    case bundleNotFound(URL)
    case invalidBundleIdentifier(expected: String, actual: String?)
    case codeSignatureInvalid(OSStatus, String)
    case teamIDMismatch(expected: String, actual: String?)
    case architectureMismatch(expected: String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File for verification does not exist at: \(url.path)"
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 checksum mismatch. Expected: \(expected), calculated: \(actual)"
        case .bundleNotFound(let url):
            return "Application bundle not found at: \(url.path)"
        case .invalidBundleIdentifier(let expected, let actual):
            return "Invalid bundle identifier. Expected: \(expected), got: \(actual ?? "nil")"
        case .codeSignatureInvalid(let status, let msg):
            return "Code signature check failed (OSStatus \(status)): \(msg)"
        case .teamIDMismatch(let expected, let actual):
            return "Developer Team ID mismatch. Expected: \(expected), found: \(actual ?? "nil")"
        case .architectureMismatch(let expected):
            return "App bundle does not support required architecture: \(expected)"
        case .verificationFailed(let msg):
            return "Verification failed: \(msg)"
        }
    }
}

public struct UpdateVerifier: Sendable {
    /// The running app's identifier (`com.marspater.siphon`); an update must carry the same one.
    public static let siphonBundleID = Bundle.main.bundleIdentifier ?? "com.marspater.siphon"

    /// Bundle identifiers are case-insensitive to Launch Services.
    public static func bundleIDsMatch(_ actual: String?, _ expected: String) -> Bool {
        actual?.caseInsensitiveCompare(expected) == .orderedSame
    }

    public init() {
        // Intentionally empty initializer for struct instantiation (swift:S1186)
    }

    /// Computes the SHA-256 hexadecimal hash of a file using streaming chunks to bound memory.
    public static func computeSHA256(for fileURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UpdateVerificationError.fileNotFound(fileURL)
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 64 * 1024
        var hasMoreData = true
        while hasMoreData {
            hasMoreData = try autoreleasepool {
                guard let data = try handle.read(upToCount: bufferSize), !data.isEmpty else { return false }
                hasher.update(data: data)
                return true
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies that a downloaded file matches the expected SHA-256 checksum.
    /// An empty or malformed checksum never matches, so it fails verification.
    public static func verifySHA256(fileURL: URL, expectedChecksum: String) throws {
        let cleanExpected = expectedChecksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let calculated = try computeSHA256(for: fileURL).lowercased()
        guard calculated == cleanExpected else {
            throw UpdateVerificationError.checksumMismatch(expected: cleanExpected, actual: calculated)
        }
    }

    /// Validates an extracted .app bundle.
    /// Supports two modes:
    /// 1. Developer ID signed release (`expectedTeamID` != nil):
    ///    - SHA-256 (pre-checked)
    ///    - Bundle ID match
    ///    - Valid code signature via Security.framework
    ///    - Matching Team ID
    /// 2. Open-source / ad-hoc release (`expectedTeamID` == nil):
    ///    - SHA-256 (pre-checked)
    ///    - Bundle ID match
    ///    - Architecture compatibility
    ///    - Code signature checked if present, but ad-hoc or unsigned builds are permitted if `allowAdHoc` is true.
    public static func verifyAppBundle(
        bundleURL: URL,
        expectedBundleID: String = siphonBundleID,
        expectedTeamID: String? = nil,
        allowAdHoc: Bool = true
    ) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw UpdateVerificationError.bundleNotFound(bundleURL)
        }

        // 1. Verify bundle identifier
        guard let bundle = Bundle(url: bundleURL) else {
            throw UpdateVerificationError.bundleNotFound(bundleURL)
        }
        let actualBundleID = bundle.bundleIdentifier
        guard bundleIDsMatch(actualBundleID, expectedBundleID) else {
            throw UpdateVerificationError.invalidBundleIdentifier(expected: expectedBundleID, actual: actualBundleID)
        }

        // 2. Verify architecture compatibility
        if let archs = bundle.executableArchitectures {
            let arm64Arch = NSNumber(value: NSBundleExecutableArchitectureARM64)
            let x8664Arch = NSNumber(value: NSBundleExecutableArchitectureX86_64)
            #if arch(arm64)
            guard archs.contains(arm64Arch) else {
                throw UpdateVerificationError.architectureMismatch(expected: "arm64")
            }
            #else
            guard archs.contains(x8664Arch) else {
                throw UpdateVerificationError.architectureMismatch(expected: "x86_64")
            }
            #endif
        }

        // 3. Security.framework code signing verification
        let appCFURL = bundleURL as CFURL
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appCFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            if allowAdHoc && expectedTeamID == nil {
                Task { @MainActor in
                    LoggerService.shared.log("SecStaticCodeCreateWithPath status \(createStatus); proceeding under ad-hoc open-source mode", level: .warning)
                }
                return
            }
            throw UpdateVerificationError.codeSignatureInvalid(createStatus, "Failed to create SecStaticCode")
        }

        let validityStatus = SecStaticCodeCheckValidity(code, SecCSFlags(), nil)

        // Check Team ID if expected
        if let expectedTeamID = expectedTeamID {
            guard validityStatus == errSecSuccess else {
                throw UpdateVerificationError.codeSignatureInvalid(validityStatus, "SecStaticCodeCheckValidity failed for signed release")
            }

            var infoCF: CFDictionary?
            let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
            guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
                throw UpdateVerificationError.verificationFailed("Could not read code signing information")
            }

            let actualTeamID = info[kSecCodeInfoTeamIdentifier as String] as? String
            guard actualTeamID == expectedTeamID else {
                throw UpdateVerificationError.teamIDMismatch(expected: expectedTeamID, actual: actualTeamID)
            }
        } else {
            // Open-source / ad-hoc mode
            if validityStatus != errSecSuccess {
                if allowAdHoc {
                    Task { @MainActor in
                        LoggerService.shared.log("App code signature validation returned \(validityStatus); accepted under ad-hoc open-source mode.", level: .info)
                    }
                } else {
                    throw UpdateVerificationError.codeSignatureInvalid(validityStatus, "Code signature invalid and ad-hoc builds not allowed")
                }
            }
        }
    }
}

public enum ManifestVerificationError: LocalizedError, Sendable {
    case invalidSignature
    case invalidPublicKey
    case versionMismatch(expected: String, actual: String)
    case assetNotFound(String)
    case invalidChecksum(String)
    case manifestNotFound
    case signatureNotFound
    case malformedManifest(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSignature:
            return "Release manifest signature verification failed"
        case .invalidPublicKey:
            return "Invalid Ed25519 public key"
        case .versionMismatch(let expected, let actual):
            return "Manifest version '\(actual)' does not match release version '\(expected)'"
        case .assetNotFound(let asset):
            return "Asset '\(asset)' not found in signed release manifest"
        case .invalidChecksum(let checksum):
            return "Checksum '\(checksum)' in manifest is not a valid 64-character SHA-256 hex string"
        case .manifestNotFound:
            return "Release manifest was not found"
        case .signatureNotFound:
            return "Release manifest signature was not found"
        case .malformedManifest(let reason):
            return "Release manifest is malformed: \(reason)"
        }
    }
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let version: String
    public let assets: [String: String]

    public init(version: String, assets: [String: String]) {
        self.version = version
        self.assets = assets
    }

    private struct ManifestAssetItem: Codable {
        let name: String
        let sha256: String
    }

    enum CodingKeys: String, CodingKey {
        case version
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(String.self, forKey: .version)

        if let dict = try? container.decode([String: String].self, forKey: .assets) {
            self.assets = dict
        } else if let array = try? container.decode([ManifestAssetItem].self, forKey: .assets) {
            var map: [String: String] = [:]
            for item in array {
                map[item.name] = item.sha256
            }
            self.assets = map
        } else {
            throw DecodingError.dataCorruptedError(forKey: .assets, in: container, debugDescription: "Expected dictionary or array for assets")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(assets, forKey: .assets)
    }
}

public struct UpdateManifestVerifier: Sendable {
    /// Pinned Ed25519 public key for Siphon release manifest verification.
    /// The corresponding private key is held offline outside GitHub Actions.
    public static let defaultPublicKeyBase64 = "Lmu0+3Kurb7TKWcwNNgDDKmXP/7F4rPRXqR10Q3k8/w="

    public static let defaultPublicKey: Curve25519.Signing.PublicKey = {
        guard let data = Data(base64Encoded: defaultPublicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
            fatalError("Invalid hardcoded Ed25519 release public key")
        }
        return key
    }()

    public let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey = defaultPublicKey) {
        self.publicKey = publicKey
    }

    public init(publicKeyBase64: String) throws {
        guard let data = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ManifestVerificationError.invalidPublicKey
        }
        do {
            self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: data)
        } catch {
            throw ManifestVerificationError.invalidPublicKey
        }
    }

    public static func parseSignatureData(_ signatureData: Data) throws -> Data {
        if signatureData.count == 64 {
            return signatureData
        }

        if let string = String(data: signatureData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let decoded = Data(base64Encoded: string), decoded.count == 64 {
                return decoded
            }
            if string.count == 128 && string.allSatisfy(\.isHexDigit) {
                var data = Data(capacity: 64)
                var index = string.startIndex
                while index < string.endIndex {
                    let next = string.index(index, offsetBy: 2)
                    if let byte = UInt8(string[index..<next], radix: 16) {
                        data.append(byte)
                    } else {
                        break
                    }
                    index = next
                }
                if data.count == 64 {
                    return data
                }
            }
        }

        throw ManifestVerificationError.invalidSignature
    }

    public static func decodeManifest(_ data: Data) throws -> ReleaseManifest {
        do {
            return try JSONDecoder().decode(ReleaseManifest.self, from: data)
        } catch {
            throw ManifestVerificationError.malformedManifest(error.localizedDescription)
        }
    }

    public func verify(
        manifestData: Data,
        signatureData: Data,
        expectedVersion: String,
        targetAssetName: String
    ) throws -> String {
        let rawSig = try Self.parseSignatureData(signatureData)

        guard publicKey.isValidSignature(rawSig, for: manifestData) else {
            throw ManifestVerificationError.invalidSignature
        }

        let manifest = try Self.decodeManifest(manifestData)

        let cleanExpected = (expectedVersion.hasPrefix("v") || expectedVersion.hasPrefix("V"))
            ? String(expectedVersion.dropFirst())
            : expectedVersion
        let cleanManifest = (manifest.version.hasPrefix("v") || manifest.version.hasPrefix("V"))
            ? String(manifest.version.dropFirst())
            : manifest.version

        guard cleanExpected == cleanManifest else {
            throw ManifestVerificationError.versionMismatch(expected: cleanExpected, actual: cleanManifest)
        }

        let lowerTarget = targetAssetName.lowercased()
        guard let checksum = manifest.assets.first(where: { $0.key.lowercased() == lowerTarget })?.value else {
            throw ManifestVerificationError.assetNotFound(targetAssetName)
        }

        let cleanChecksum = checksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanChecksum.count == 64,
              cleanChecksum.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ManifestVerificationError.invalidChecksum(cleanChecksum)
        }

        return cleanChecksum
    }
}
