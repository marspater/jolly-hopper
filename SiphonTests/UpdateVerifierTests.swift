//
//  UpdateVerifierTests.swift
//  SiphonTests
//

import XCTest
import CryptoKit
import os
@testable import Siphon

final class UpdateVerifierTests: XCTestCase {

    func testStaleUpdateCallbacksCannotFinishOrReportProgressForNewAttempt() async throws {
        let sessions = OSAllocatedUnfairLock(initialState: [URLSession]())
        let progress = OSAllocatedUnfairLock(initialState: [Double]())
        let firstCreated = expectation(description: "First session")
        let secondCreated = expectation(description: "Second session")
        let downloader = UpdateDownloader(sessionFactory: { delegate in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HoldingUpdateURLProtocol.self]
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let count = sessions.withLock { $0.append(session); return $0.count }
            if count == 1 { firstCreated.fulfill() } else { secondCreated.fulfill() }
            return session
        })
        defer {
            downloader.cancel()
            sessions.withLock { $0 }.forEach { $0.invalidateAndCancel() }
        }
        let url = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/test/Siphon.dmg")!
        let first = Task { try await downloader.download(from: url) }
        await fulfillment(of: [firstCreated], timeout: 2)
        let oldSession = try XCTUnwrap(sessions.withLock { $0.first })
        let oldTask = try await activeDownloadTask(in: oldSession)
        downloader.cancel()
        _ = try? await first.value

        let second = Task {
            try await downloader.download(from: url) { value in progress.withLock { $0.append(value) } }
        }
        await fulfillment(of: [secondCreated], timeout: 2)
        let newSession = try XCTUnwrap(sessions.withLock { $0.last })
        let newTask = try await activeDownloadTask(in: newSession)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = root.appendingPathComponent("old.dmg")
        let newFile = root.appendingPathComponent("new.dmg")
        try Data("old".utf8).write(to: oldFile)
        try Data("new".utf8).write(to: newFile)

        downloader.urlSession(oldSession, task: oldTask, didCompleteWithError: URLError(.cancelled))
        downloader.urlSession(oldSession, downloadTask: oldTask, didFinishDownloadingTo: oldFile)
        downloader.urlSession(oldSession, downloadTask: oldTask, didWriteData: 50, totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
        downloader.urlSession(newSession, task: oldTask, didCompleteWithError: URLError(.cancelled))
        XCTAssertTrue(progress.withLock { $0.isEmpty })
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        downloader.urlSession(newSession, downloadTask: newTask, didWriteData: 25, totalBytesWritten: 25, totalBytesExpectedToWrite: 100)
        XCTAssertEqual(progress.withLock { $0 }, [0.25])
        downloader.urlSession(newSession, downloadTask: newTask, didFinishDownloadingTo: newFile)
        downloader.urlSession(newSession, task: newTask, didCompleteWithError: nil)
        let staged = try await second.value
        defer { try? FileManager.default.removeItem(at: staged) }
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "new")
    }

    private func activeDownloadTask(in session: URLSession) async throws -> URLSessionDownloadTask {
        for _ in 0..<200 {
            if let task = await session.allTasks.first as? URLSessionDownloadTask { return task }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "UpdateTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download task did not start"])
    }

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
        for checksum in [wrongChecksum, "", "   ", "not-a-digest"] {
            XCTAssertThrowsError(try UpdateVerifier.verifySHA256(fileURL: sampleFile, expectedChecksum: checksum)) { error in
                guard case UpdateVerificationError.checksumMismatch = error else {
                    XCTFail("Expected checksumMismatch error, got \(error)")
                    return
                }
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
            let bundleID = Bundle.main.bundleIdentifier ?? "com.marspater.siphon"
            // The default expectation must accept the shipped app itself.
            XCTAssertNoThrow(
                try UpdateVerifier.verifyAppBundle(bundleURL: currentBundle, expectedTeamID: nil, allowAdHoc: true)
            )
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

    func testAtomicSwapRollsBackWhenStagedAppCorrupt() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_updater_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Setup mock current app
        let currentApp = tempDir.appendingPathComponent("Current.app")
        try FileManager.default.createDirectory(at: currentApp, withIntermediateDirectories: true)
        let markerURL = currentApp.appendingPathComponent("version.txt")
        try "v1.0.0".write(to: markerURL, atomically: true, encoding: .utf8)

        // Setup mock corrupt staged app (missing required Info.plist / executable)
        let stagedApp = tempDir.appendingPathComponent("CorruptStaged.app")
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        try "bad".write(to: stagedApp.appendingPathComponent("bad.txt"), atomically: true, encoding: .utf8)

        // Attempt replaceAppBundle
        XCTAssertThrowsError(
            try UpdateInstaller.replaceAppBundle(
                currentAppURL: currentApp,
                stagedAppURL: stagedApp,
                fileManager: .default
            )
        )

        // Verify that currentApp was completely restored by rollback
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentApp.path), "Current app must still exist after rollback")
        let restoredContent = try? String(contentsOf: markerURL, encoding: .utf8)
        XCTAssertEqual(restoredContent, "v1.0.0", "Current app content must be restored exactly")

        // Verify no leftover backup bundles in the directory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let backups = files.filter { $0.contains("Backup") }
        XCTAssertTrue(backups.isEmpty, "Temporary backup must be cleaned up after rollback")
    }

    func testIsTrustedGitHubURLStrictValidation() {
        // Valid URLs
        XCTAssertTrue(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v1.0.0/Siphon.dmg")!))
        XCTAssertTrue(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://api.github.com/repos/marspater/jolly-hopper/releases/latest")!))
        XCTAssertTrue(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://raw.githubusercontent.com/marspater/jolly-hopper/main/README.md")!))
        // The asset CDN is trusted only as a redirect target, never as a starting URL.
        let cdnAsset = URL(string: "https://objects.githubusercontent.com/github-production-release-asset-2e65be/12345")!
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(cdnAsset))
        XCTAssertTrue(UpdateDownloader.isTrustedRedirectURL(cdnAsset))
        XCTAssertTrue(UpdateDownloader.isTrustedRedirectURL(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1")!))
        XCTAssertFalse(UpdateDownloader.isTrustedRedirectURL(URL(string: "http://objects.githubusercontent.com/x")!))
        XCTAssertFalse(UpdateDownloader.isTrustedRedirectURL(URL(string: "https://evil.example/Siphon.dmg")!))
        XCTAssertNil(UpdateDownloader.redirectRequestIfTrusted(URLRequest(url: URL(string: "https://evil.example/Siphon.dmg")!)))

        // Untrusted / Attack URLs
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://github.com/attacker/malware/releases/download/v1/bad.dmg")!), "Must reject untrusted GitHub repository")
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://evil.github.com/marspater/jolly-hopper/bad.dmg")!), "Must reject untrusted subdomain")
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "http://github.com/marspater/jolly-hopper/releases/download/v1.0/Siphon.dmg")!), "Must reject insecure http")
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://github.com/marspater/jolly-hopper/../../attacker/repo/releases/download/v1/bad.dmg")!), "Must reject path traversal escaping repository")
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://api.github.com/repos/marspater/jolly-hopper/../../attacker/repo")!), "Must reject path traversal in API URLs")
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://raw.githubusercontent.com/marspater/jolly-hopper/../../attacker/repo/main/bad.txt")!), "Must reject path traversal in raw URLs")
    }

    func testUpdateStagingPreservesPackageExtension() {
        let tempDir = FileManager.default.temporaryDirectory

        let dmg = UpdateDownloader.stagedFileURL(
            for: URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v1/Siphon-arm64.dmg")!,
            temporaryDirectory: tempDir
        )
        let zip = UpdateDownloader.stagedFileURL(
            for: URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v1/Siphon.app.zip")!,
            temporaryDirectory: tempDir
        )

        XCTAssertEqual(dmg.pathExtension.lowercased(), "dmg")
        XCTAssertEqual(zip.pathExtension.lowercased(), "zip")
    }

    func testInstallerAssetFollowsReleaseNameContract() {
        func asset(_ name: String) -> [String: Any] { ["name": name, "browser_download_url": "https://github.com/\(name)"] }
        let release = [asset("Siphon-v5.5.0.dSYM.zip"), asset("helper.zip"), asset("Siphon-v5.5.0.zip"), asset("Siphon-v5.5.0.dmg")]

        XCTAssertEqual(UpdateChecker.installerAsset(in: release, tag: "v5.5.0")?["name"] as? String, "Siphon-v5.5.0.dmg")
        XCTAssertEqual(UpdateChecker.installerAsset(in: Array(release.prefix(3)), tag: "v5.5.0")?["name"] as? String, "Siphon-v5.5.0.zip")
        XCTAssertNil(UpdateChecker.installerAsset(in: Array(release.prefix(2)), tag: "v5.5.0"))
        XCTAssertNil(UpdateChecker.installerAsset(in: release, tag: "v5.6.0"), "An archive from another release is never picked")
    }

    func testChecksumParserRequiresMatchingAssetAndValidSHA256() {
        let hash = String(repeating: "a", count: 64)
        let manifest = """
        \(hash)  Siphon-arm64.dmg
        \(String(repeating: "b", count: 64))  Siphon-x86_64.dmg
        """

        XCTAssertEqual(
            UpdateDownloader.parseExpectedChecksum(
                from: manifest,
                targetAssetName: "Siphon-arm64.dmg",
                checksumFileName: "SHA256SUMS.txt"
            ),
            hash
        )

        XCTAssertNil(
            UpdateDownloader.parseExpectedChecksum(
                from: manifest,
                targetAssetName: "Missing.dmg",
                checksumFileName: "SHA256SUMS.txt"
            )
        )

        XCTAssertNil(
            UpdateDownloader.parseExpectedChecksum(
                from: "not-a-hash  Siphon-arm64.dmg",
                targetAssetName: "Siphon-arm64.dmg",
                checksumFileName: "SHA256SUMS.txt"
            )
        )
    }

    func testLocateAppBundleIgnoresSymlinkedApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update_locate_\(UUID().uuidString)")
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("external_app_\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        let symlink = root.appendingPathComponent("Siphon.app")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)

        let installer = UpdateInstaller()
        XCTAssertNil(installer.locateAppBundle(in: root), "Updater must not follow symlinked app bundles out of staging")
    }

    func testLocateAppBundleSelectsSiphonByBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update_locate_id_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func makeApp(_ name: String, bundleID: String) throws -> URL {
            let app = root.appendingPathComponent(name)
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": bundleID],
                format: .xml,
                options: 0
            )
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            return app
        }
        // Can be enumerated before Siphon.app, so a first-.app search may pick it.
        _ = try makeApp("Aaa Uninstaller.app", bundleID: "com.example.Uninstaller")
        // The identifier Siphon actually ships with (PRODUCT_BUNDLE_IDENTIFIER).
        let siphon = try makeApp("Siphon.app", bundleID: "com.marspater.siphon")

        let installer = UpdateInstaller()
        XCTAssertEqual(installer.locateAppBundle(in: root)?.lastPathComponent, siphon.lastPathComponent)
        XCTAssertNil(installer.locateAppBundle(in: root, bundleID: "com.example.Missing"))
    }

    func testUpdateDownloaderReportsHTTPErrorInsteadOfStagingTheBody() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil))
            return (response, Data("Not Found".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let downloader = UpdateDownloader(sessionFactory: { delegate in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        })
        let url = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v1.0.0/Siphon.dmg")!

        do {
            _ = try await downloader.download(from: url)
            XCTFail("An HTTP error body must not be staged as the update package")
        } catch UpdateDownloadError.downloadFailed(let message) {
            XCTAssertTrue(message.contains("HTTP 404"), message)
        }
    }

    func testUpdateDownloaderRejectsConcurrentCalls() async throws {
        let started = expectation(description: "First update started")
        let downloader = UpdateDownloader(sessionFactory: { delegate in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HoldingUpdateURLProtocol.self]
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            started.fulfill()
            return session
        })
        defer { downloader.cancel() }
        let url = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v1.0.0/Siphon.dmg")!

        let task1 = Task {
            try await downloader.download(from: url)
        }

        await fulfillment(of: [started], timeout: 2)

        do {
            _ = try await downloader.download(from: url)
            XCTFail("Concurrent download call must throw error")
        } catch let error as UpdateDownloadError {
            if case .downloadFailed(let msg) = error {
                XCTAssertTrue(msg.contains("already in progress") || msg.contains("already active"))
            } else {
                XCTFail("Expected downloadFailed for concurrent download, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        downloader.cancel()
        _ = try? await task1.value
    }

    // MARK: - Signed Release Manifest Tests (Finding 9 / Issue #354)

    func testEmbeddedReleasePublicKeyIsValid() {
        XCTAssertEqual(UpdateManifestVerifier.defaultPublicKey.rawRepresentation.count, 32)
    }

    func testUpdateManifestVerifierValidSignature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: privateKey.publicKey)
        let hash = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        let manifest = """
        {
            "version": "5.5.0",
            "assets": {
                "Siphon-arm64.dmg": "\(hash)",
                "Siphon-x86_64.dmg": "\(String(repeating: "b", count: 64))"
            }
        }
        """
        let manifestData = Data(manifest.utf8)
        let signatureData = try privateKey.signature(for: manifestData)

        let verifiedChecksum = try verifier.verify(
            manifestData: manifestData,
            signatureData: signatureData,
            expectedVersion: "5.5.0",
            targetAssetName: "Siphon-arm64.dmg"
        )
        XCTAssertEqual(verifiedChecksum, hash)

        let verifiedLower = try verifier.verify(
            manifestData: manifestData,
            signatureData: signatureData,
            expectedVersion: "v5.5.0",
            targetAssetName: "siphon-arm64.dmg"
        )
        XCTAssertEqual(verifiedLower, hash)
    }

    func testUpdateManifestVerifierRejectsTamperedManifest() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: privateKey.publicKey)
        let manifest = """
        {
            "version": "5.5.0",
            "assets": {
                "Siphon-arm64.dmg": "\(String(repeating: "a", count: 64))"
            }
        }
        """
        let manifestData = Data(manifest.utf8)
        let signatureData = try privateKey.signature(for: manifestData)

        var tamperedData = manifestData
        tamperedData[tamperedData.count - 5] ^= 0xFF

        XCTAssertThrowsError(
            try verifier.verify(
                manifestData: tamperedData,
                signatureData: signatureData,
                expectedVersion: "5.5.0",
                targetAssetName: "Siphon-arm64.dmg"
            )
        ) { error in
            guard case ManifestVerificationError.invalidSignature = error else {
                XCTFail("Expected invalidSignature, got \(error)")
                return
            }
        }
    }

    func testUpdateManifestVerifierRejectsForgedSignature() throws {
        let validKey = Curve25519.Signing.PrivateKey()
        let attackerKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: validKey.publicKey)

        let manifestData = Data("{\"version\": \"5.5.0\", \"assets\": {\"Siphon.dmg\": \"\(String(repeating: "a", count: 64))\"}}".utf8)
        let forgedSignature = try attackerKey.signature(for: manifestData)

        XCTAssertThrowsError(
            try verifier.verify(
                manifestData: manifestData,
                signatureData: forgedSignature,
                expectedVersion: "5.5.0",
                targetAssetName: "Siphon.dmg"
            )
        ) { error in
            guard case ManifestVerificationError.invalidSignature = error else {
                XCTFail("Expected invalidSignature, got \(error)")
                return
            }
        }
    }

    func testUpdateManifestVerifierRejectsVersionMismatch() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: privateKey.publicKey)
        let manifestData = Data("{\"version\": \"5.5.0\", \"assets\": {\"Siphon.dmg\": \"\(String(repeating: "a", count: 64))\"}}".utf8)
        let signatureData = try privateKey.signature(for: manifestData)

        XCTAssertThrowsError(
            try verifier.verify(
                manifestData: manifestData,
                signatureData: signatureData,
                expectedVersion: "5.5.1",
                targetAssetName: "Siphon.dmg"
            )
        ) { error in
            guard case ManifestVerificationError.versionMismatch(let expected, let actual) = error else {
                XCTFail("Expected versionMismatch, got \(error)")
                return
            }
            XCTAssertEqual(expected, "5.5.1")
            XCTAssertEqual(actual, "5.5.0")
        }
    }

    func testUpdateManifestVerifierRejectsMissingAsset() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: privateKey.publicKey)
        let manifestData = Data("{\"version\": \"5.5.0\", \"assets\": {\"Siphon-x86_64.dmg\": \"\(String(repeating: "a", count: 64))\"}}".utf8)
        let signatureData = try privateKey.signature(for: manifestData)

        XCTAssertThrowsError(
            try verifier.verify(
                manifestData: manifestData,
                signatureData: signatureData,
                expectedVersion: "5.5.0",
                targetAssetName: "Siphon-arm64.dmg"
            )
        ) { error in
            guard case ManifestVerificationError.assetNotFound = error else {
                XCTFail("Expected assetNotFound, got \(error)")
                return
            }
        }
    }

    func testUpdateManifestVerifierRejectsMalformedChecksum() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: privateKey.publicKey)
        let manifestData = Data("{\"version\": \"5.5.0\", \"assets\": {\"Siphon.dmg\": \"not-a-valid-sha256\"}}".utf8)
        let signatureData = try privateKey.signature(for: manifestData)

        XCTAssertThrowsError(
            try verifier.verify(
                manifestData: manifestData,
                signatureData: signatureData,
                expectedVersion: "5.5.0",
                targetAssetName: "Siphon.dmg"
            )
        ) { error in
            guard case ManifestVerificationError.invalidChecksum = error else {
                XCTFail("Expected invalidChecksum, got \(error)")
                return
            }
        }
    }

    func testUpdateManifestVerifierSupportsArrayAssetFormat() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: privateKey.publicKey)
        let hash = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        let manifest = """
        {
            "version": "5.5.0",
            "assets": [
                {
                    "name": "Siphon-arm64.dmg",
                    "sha256": "\(hash)"
                }
            ]
        }
        """
        let manifestData = Data(manifest.utf8)
        let signatureData = try privateKey.signature(for: manifestData)

        let verifiedChecksum = try verifier.verify(
            manifestData: manifestData,
            signatureData: signatureData,
            expectedVersion: "5.5.0",
            targetAssetName: "Siphon-arm64.dmg"
        )
        XCTAssertEqual(verifiedChecksum, hash)
    }

    func testUpdateManifestVerifierParsesBase64AndHexSignatures() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: privateKey.publicKey)
        let hash = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        let manifestData = Data("{\"version\": \"5.5.0\", \"assets\": {\"Siphon.dmg\": \"\(hash)\"}}".utf8)
        let rawSignature = try privateKey.signature(for: manifestData)

        // 1. Base64 signature
        let base64Sig = Data(rawSignature.base64EncodedString().utf8)
        let result1 = try verifier.verify(
            manifestData: manifestData,
            signatureData: base64Sig,
            expectedVersion: "5.5.0",
            targetAssetName: "Siphon.dmg"
        )
        XCTAssertEqual(result1, hash)

        // 2. Hex signature
        let hexString = rawSignature.map { String(format: "%02x", $0) }.joined()
        let hexSig = Data(hexString.utf8)
        let result2 = try verifier.verify(
            manifestData: manifestData,
            signatureData: hexSig,
            expectedVersion: "5.5.0",
            targetAssetName: "Siphon.dmg"
        )
        XCTAssertEqual(result2, hash)
    }

    @MainActor
    func testUpdateCheckerRequiresSignedManifestWhenConfigured() async {
        let checker = UpdateChecker(requireSignedManifest: true)
        let downloadURL = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v5.5.0/Siphon.dmg")!
        checker.configureUpdateSources(
            downloadURL: downloadURL,
            downloadAssetName: "Siphon.dmg",
            expectedChecksum: nil,
            checksumURL: nil,
            manifestURL: nil,
            manifestSigURL: nil,
            latestVersion: "5.5.0"
        )
        await checker.downloadAndInstallUpdate()
        XCTAssertNotNil(checker.updateError)
        XCTAssertTrue(checker.updateError?.contains("signed release manifest") == true)
    }

    @MainActor
    func testReleasesAfterCutoverRequireSignedManifestEvenWhenItIsMissing() async {
        XCTAssertFalse(UpdateChecker.releaseRequiresSignedManifest(UpdateChecker.lastUnsignedRelease))
        XCTAssertFalse(UpdateChecker.releaseRequiresSignedManifest("5.4.0"))
        XCTAssertTrue(UpdateChecker.releaseRequiresSignedManifest("5.4.6"))
        XCTAssertTrue(UpdateChecker.releaseRequiresSignedManifest("5.10.0"))

        // A newer release that simply leaves the manifest out must not fall back
        // to the unsigned checksum path.
        let checker = UpdateChecker()
        checker.configureUpdateSources(
            downloadURL: URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v5.5.0/Siphon.dmg")!,
            downloadAssetName: "Siphon.dmg",
            expectedChecksum: "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
            checksumURL: nil,
            manifestURL: nil,
            manifestSigURL: nil,
            latestVersion: "5.5.0"
        )
        await checker.downloadAndInstallUpdate()
        XCTAssertTrue(checker.updateError?.contains("signed release manifest") == true)
    }

    @MainActor
    func testUpdateCheckerRejectsUntrustedManifestURL() async {
        let checker = UpdateChecker()
        let downloadURL = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v5.5.0/Siphon.dmg")!
        let untrustedManifest = URL(string: "http://malicious.com/manifest.json")!
        let untrustedSig = URL(string: "http://malicious.com/manifest.sig")!
        checker.configureUpdateSources(
            downloadURL: downloadURL,
            downloadAssetName: "Siphon.dmg",
            expectedChecksum: nil,
            checksumURL: nil,
            manifestURL: untrustedManifest,
            manifestSigURL: untrustedSig,
            latestVersion: "5.5.0"
        )
        await checker.downloadAndInstallUpdate()
        XCTAssertEqual(checker.updateError, UpdateDownloadError.invalidURL.localizedDescription)
    }

    @MainActor
    func testUpdateCheckerRejectsMismatchedManifestSignature() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let verifier = UpdateManifestVerifier(publicKey: privateKey.publicKey)
        let checker = UpdateChecker(manifestVerifier: verifier)

        let downloadURL = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v5.5.0/Siphon.dmg")!
        let manifestURL = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v5.5.0/release-manifest.json")!
        let sigURL = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/v5.5.0/release-manifest.json.sig")!

        let hash = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        let manifestData = Data("{\"version\": \"5.5.0\", \"assets\": {\"Siphon.dmg\": \"\(hash)\"}}".utf8)
        let badSignatureData = try otherKey.signature(for: manifestData)

        URLProtocol.registerClass(MockURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MockURLProtocol.self)
            MockURLProtocol.requestHandler = nil
        }

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url == manifestURL {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, manifestData)
            } else if url == sigURL {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, badSignatureData)
            }
            throw URLError(.fileDoesNotExist)
        }

        checker.configureUpdateSources(
            downloadURL: downloadURL,
            downloadAssetName: "Siphon.dmg",
            expectedChecksum: nil,
            checksumURL: nil,
            manifestURL: manifestURL,
            manifestSigURL: sigURL,
            latestVersion: "5.5.0"
        )

        await checker.downloadAndInstallUpdate()
        XCTAssertNotNil(checker.updateError)
        XCTAssertTrue(checker.updateError?.contains("Signature verification failed") == true || checker.updateError?.contains("signature") == true)
    }
}

private final class HoldingUpdateURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { /* Delegate events are delivered explicitly by the test. */ }
    override func stopLoading() {}
}
