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
        XCTAssertTrue(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://objects.githubusercontent.com/github-production-release-asset-2e65be/12345")!))

        // Untrusted / Attack URLs
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://github.com/attacker/malware/releases/download/v1/bad.dmg")!), "Must reject untrusted GitHub repository")
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "https://evil.github.com/marspater/jolly-hopper/bad.dmg")!), "Must reject untrusted subdomain")
        XCTAssertFalse(UpdateDownloader.isTrustedGitHubURL(URL(string: "http://github.com/marspater/jolly-hopper/releases/download/v1.0/Siphon.dmg")!), "Must reject insecure http")
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
}

private final class HoldingUpdateURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { /* Delegate events are delivered explicitly by the test. */ }
    override func stopLoading() {}
}
