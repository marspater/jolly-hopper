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
}
