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
    public static let productionBundleIdentifier = "com.marspater.siphon"

    public init() {}

    /// Computes the SHA-256 hexadecimal hash of a file using streaming chunks to bound memory.
    public static func computeSHA256(for fileURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UpdateVerificationError.fileNotFound(fileURL)
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 64 * 1024
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies that a downloaded file matches the expected SHA-256 checksum.
    public static func verifySHA256(fileURL: URL, expectedChecksum: String) throws {
        let cleanExpected = expectedChecksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanExpected.isEmpty else { return }

        let calculated = try computeSHA256(for: fileURL).lowercased()
        guard calculated == cleanExpected else {
            throw UpdateVerificationError.checksumMismatch(expected: cleanExpected, actual: calculated)
        }
    }

    /// Returns the Developer Team identifier for a valid signed bundle.
    /// Ad-hoc/unsigned bundles intentionally return nil so legacy installations can
    /// migrate once through the checksum-pinned update path.
    public static func teamIdentifier(for bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode,
              SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else {
            return nil
        }

        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        ) == errSecSuccess,
        let info = infoCF as? [String: Any] else {
            return nil
        }

        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return teamID?.isEmpty == false ? teamID : nil
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
        expectedBundleID: String = UpdateVerifier.productionBundleIdentifier,
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
        guard actualBundleID == expectedBundleID else {
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
