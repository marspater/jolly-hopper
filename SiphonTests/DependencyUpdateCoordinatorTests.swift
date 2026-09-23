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

    func testAdHocSignBinaryHandlesNonExecutableGracefully() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("non_exec_\(UUID().uuidString)")
        try "text".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Should return cleanly without throwing because it's not executable
        XCTAssertNoThrow(try DependencyInstaller.adHocSignBinary(at: tempFile))
    }

    func testIsBinarySignedDetection() throws {
        let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")
        XCTAssertTrue(DependencyInstaller.isBinarySigned(at: codesignURL), "System binary /usr/bin/codesign must be recognized as validly signed")

        let unsignedScript = FileManager.default.temporaryDirectory.appendingPathComponent("script_\(UUID().uuidString).sh")
        try "#!/bin/sh\necho hi\n".write(to: unsignedScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unsignedScript.path)
        defer { try? FileManager.default.removeItem(at: unsignedScript) }

        XCTAssertFalse(DependencyInstaller.isBinarySigned(at: unsignedScript), "Unsigned script should not report as signed")
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
