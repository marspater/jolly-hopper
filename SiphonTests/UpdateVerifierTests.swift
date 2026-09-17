//
//  UpdateVerifierTests.swift
//  SiphonTests
//

import XCTest
import CryptoKit
@testable import Siphon

final class UpdateVerifierTests: XCTestCase {

    func testComputeSHA256MatchesExpected() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sampleFile = tempDir.appendingPathComponent("test_hash_\(UUID().uuidString).txt")
        let content = "The quick brown fox jumps over the lazy dog"
        try content.write(to: sampleFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sampleFile) }

        let calculated = try UpdateVerifier.computeSHA256(for: sampleFile)
        // Known SHA-256 for "The quick brown fox jumps over the lazy dog"
        let expected = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        XCTAssertEqual(calculated, expected)

        // verifySHA256 should pass
        XCTAssertNoThrow(try UpdateVerifier.verifySHA256(fileURL: sampleFile, expectedChecksum: expected))
        XCTAssertNoThrow(try UpdateVerifier.verifySHA256(fileURL: sampleFile, expectedChecksum: expected.uppercased()))
    }

    func testVerifySHA256ThrowsOnMismatch() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sampleFile = tempDir.appendingPathComponent("test_hash_mismatch_\(UUID().uuidString).txt")
        try "sample data".write(to: sampleFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sampleFile) }

        let wrongChecksum = "0000000000000000000000000000000000000000000000000000000000000000"
        XCTAssertThrowsError(try UpdateVerifier.verifySHA256(fileURL: sampleFile, expectedChecksum: wrongChecksum)) { error in
            guard case UpdateVerificationError.checksumMismatch = error else {
                XCTFail("Expected checksumMismatch error, got \(error)")
                return
            }
        }
    }

    func testVerifyAppBundleRejectsMissingBundle() {
        let nonExistentURL = URL(fileURLWithPath: "/tmp/non_existent_app_\(UUID().uuidString).app")
        XCTAssertThrowsError(try UpdateVerifier.verifyAppBundle(bundleURL: nonExistentURL)) { error in
            guard case UpdateVerificationError.bundleNotFound = error else {
                XCTFail("Expected bundleNotFound, got \(error)")
                return
            }
        }
    }

    func testVerifyCurrentAppBundleSucceeds() throws {
        let currentBundle = Bundle.main.bundleURL
        // The current test host or app bundle exists
        if FileManager.default.fileExists(atPath: currentBundle.path) {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.marspater.Siphon"
            XCTAssertNoThrow(
                try UpdateVerifier.verifyAppBundle(
                    bundleURL: currentBundle,
                    expectedBundleID: bundleID,
                    expectedTeamID: nil,
                    allowAdHoc: true
                )
            )
        }
    }
}
