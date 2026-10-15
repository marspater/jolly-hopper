//
//  DependencyUpdateCoordinatorTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

@MainActor
final class DependencyUpdateCoordinatorTests: XCTestCase {

    func testUpdateMessageEquality() {
        let msg = YtdlpUpdateMessage(title: "Updated", message: "Success")
        XCTAssertEqual(msg.title, "Updated")
        XCTAssertEqual(msg.message, "Success")
    }

    func testBindTracksUpdatingAndProgress() {
        let coordinator = DependencyUpdateCoordinator()
        let service = YtdlpService()
        coordinator.bind(to: service)

        service.isUpdating = true
        service.updateProgress = 0.75

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(coordinator.isUpdating)
        XCTAssertEqual(coordinator.updateProgress, 0.75)
    }

    func testInitializeWithNonDefaultRunner() async {
        let coordinator = DependencyUpdateCoordinator()
        let service = YtdlpService()

        struct MockRunner: YtdlpProcessRunning {
            func runCommand(_ args: [String]) async throws -> String {
                return "2026.09.17\n"
            }
            func runDownloadProcess(
                args: [String],
                saveFolder: URL,
                processController: DownloadProcessController?,
                onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
                onOutput: @escaping @Sendable (String) -> Void
            ) async throws -> DownloadProcessResult {
                return DownloadProcessResult(primaryPath: "/tmp/fake.mp4")
            }
        }

        service.processRunner = MockRunner()
        service.ytdlpPath = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        await coordinator.initialize(service: service, skipBinarySetup: true)
        XCTAssertEqual(coordinator.version, "2026.09.17")
    }

    func testPreparingPinnedExecutablePreservesSignedAndUnsignedBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for removeSignature in [false, true] {
            let file = directory.appendingPathComponent(removeSignature ? "unsigned" : "signed")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: file)
            if removeSignature {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["--remove-signature", "--", file.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            }
            let before = try Data(contentsOf: file)
            let checksum = try UpdateVerifier.computeSHA256(for: file)
            try DependencyInstaller.prepareVerifiedExecutable(at: file, expectedSHA256: checksum, name: "Fixture")
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertTrue(YtdlpService.verifySHA256(fileURL: file, expectedHash: checksum))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: file.path))
        }
    }

    func testPreparingPinnedExecutableRejectsMismatchedBytes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("tampered".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try DependencyInstaller.prepareVerifiedExecutable(at: file, expectedSHA256: String(repeating: "0", count: 64), name: "FFmpeg executable")) { error in
            guard case DependencyInstaller.InstallError.sha256Mismatch(let name, let expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(name, "FFmpeg executable")
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("tampered".utf8))
    }

    func testRebindCancelsPreviousSubscriptions() {
        let coordinator = DependencyUpdateCoordinator()
        let service1 = YtdlpService()
        let service2 = YtdlpService()

        coordinator.bind(to: service1)
        coordinator.bind(to: service2)

        service1.isUpdating = true
        service1.updateProgress = 0.5
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // coordinator was rebound to service2, so service1 updates must be ignored
        XCTAssertFalse(coordinator.isUpdating)
        XCTAssertEqual(coordinator.updateProgress, 0.0)

        service2.isUpdating = true
        service2.updateProgress = 0.9
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(coordinator.isUpdating)
        XCTAssertEqual(coordinator.updateProgress, 0.9)
    }

    func testUpdateYtdlpReportsUpToDateWithoutClaimingAnUpdate() async {
        let coordinator = DependencyUpdateCoordinator()
        let service = YtdlpService()
        let lang = LanguageService()
        service.version = "2026.08.19"
        service.updateYtdlpHandler = { "2026.08.19" }

        await coordinator.updateYtdlp(service: service, languageService: lang)

        XCTAssertEqual(coordinator.updateMessage?.title, lang.s("ytdlp_up_to_date_title"))
        XCTAssertEqual(coordinator.updateMessage?.message, String(format: lang.s("ytdlp_up_to_date_message"), "2026.08.19"))
    }

    func testUpdateYtdlpLocalizedMessages() async {
        let coordinator = DependencyUpdateCoordinator()
        let service = YtdlpService()
        let lang = LanguageService()

        service.updateYtdlpHandler = {
            return "2026.09.24"
        }

        await coordinator.updateYtdlp(service: service, languageService: lang)
        XCTAssertEqual(coordinator.version, "2026.09.24")
        XCTAssertEqual(coordinator.updateMessage?.title, lang.s("ytdlp_update_success_title"))
        XCTAssertEqual(coordinator.updateMessage?.message, String(format: lang.s("ytdlp_update_success_message"), "2026.09.24"))

        service.updateYtdlpHandler = {
            throw YtdlpError.downloadFailed("Network failure")
        }

        await coordinator.updateYtdlp(service: service, languageService: lang)
        XCTAssertEqual(coordinator.updateMessage?.title, lang.s("ytdlp_update_failed_title"))
        XCTAssertTrue(coordinator.updateMessage?.message.contains("Network failure") == true)
    }
}
