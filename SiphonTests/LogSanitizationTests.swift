//
//  LogSanitizationTests.swift
//  SiphonTests
//

import XCTest
import Testing
@testable import Siphon

final class LogSanitizationTests: XCTestCase {
    @MainActor
    func testClearingLogsDoesNotResurrectTheStartupSnapshot() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("old startup entry\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = InitialLogReadGate()
        let logger = LoggerService(logFileURL: file, initialLogReader: {
            await gate.wait()
            return ["old startup entry"]
        })
        logger.clearLogs()
        await gate.release()
        await logger.initialLogLoadTask?.value
        XCTAssertFalse(logger.logs.contains { $0.contains("old startup entry") })
        XCTAssertTrue(logger.logs.contains { $0.contains("Logs cleared") })
        let exported = try await logger.exportLogs()
        defer { try? FileManager.default.removeItem(at: exported) }
        XCTAssertFalse(try String(contentsOf: exported, encoding: .utf8).contains("old startup entry"))
    }

    func testDiagnosticExportRedactsURLsCredentialsAndHomePathsTogether() {
        let raw = "https://user:password@example.com/video?token=secret#private\nAuthorization: Bearer credential\nCookie: session=private-cookie\n/Users/fixture/Downloads/video.mp4"
        let safe = LoggerService.sanitizedDiagnosticExport(raw)
        for secret in ["password", "token=secret", "#private", "credential", "private-cookie", "/Users/fixture/"] {
            XCTAssertFalse(safe.contains(secret), secret)
        }
        XCTAssertTrue(safe.contains("example.com/video"))
        XCTAssertTrue(safe.contains("/Users/<USER>/Downloads/video.mp4"))
    }


    @MainActor
    func testLoggerWritesOutsideRealAppSupportUnderXCTest() throws {
        // Tests run inside Siphon.app; writing here would append fixture lines
        // to the user's real debug log.
        let appSupport = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let logPath = LoggerService.shared.logFileURL.resolvingSymlinksInPath().path
        XCTAssertFalse(logPath.hasPrefix(appSupport.resolvingSymlinksInPath().path), "Test runs must not write to \(logPath)")
    }

    @MainActor
    func testExportLogsProducesSanitizedTemporaryFileWithSecurePermissions() async throws {
        let logger = LoggerService.shared
        logger.log("Testing export with /Users/developer_test/file.txt and token=abc12345secret", level: .info)

        let exportURL = try await logger.exportLogs()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        // Check permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: exportURL.path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perm, 0o600, "Exported log file must have 0o600 permissions")

        // Check content redaction
        let content = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertFalse(content.contains("/Users/developer_test/"))
        XCTAssertFalse(content.contains("abc12345secret"))
        XCTAssertTrue(content.contains("/Users/<USER>/"))
    }
}

@MainActor
struct LoggerLifecycleTests {
    @Test func startupReaderDoesNotKeepLoggerAlive() async {
        let gate = InitialLogReadGate()
        weak var weakLogger: LoggerService?
        var logger: LoggerService? = LoggerService(
            logFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("SiphonLoggerLifetime-\(UUID().uuidString)"),
            initialLogReader: {
                await gate.wait()
                return ["fixture"]
            }
        )
        let loadTask = logger?.initialLogLoadTask
        weakLogger = logger
        logger = nil
        #expect(weakLogger === nil, "A suspended startup reader must not retain its logger")
        await gate.release()
        await loadTask?.value
    }

    @Test func exportReportsUnreadableExistingLog() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonUnreadableLog-\(UUID().uuidString)")
        let logger = LoggerService(logFileURL: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }

        let didThrow: Bool
        do {
            _ = try await logger.exportLogs()
            didThrow = false
        } catch {
            didThrow = true
        }
        #expect(didThrow, "An existing directory is not a readable log file")
    }

    @Test func exportOfMissingLogIsEmptyHistory() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonMissingLog-\(UUID().uuidString)")
        let logger = LoggerService(logFileURL: path)

        let exported = try await logger.exportLogs()
        defer { try? FileManager.default.removeItem(at: exported) }
        #expect(FileManager.default.fileExists(atPath: exported.path))
    }

    @Test func exportReportsLogInInaccessibleDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiphonLockedLogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logger = LoggerService(logFileURL: directory.appendingPathComponent("siphon_debug.log"))
        try "existing history".write(to: logger.logFileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        await #expect(throws: (any Error).self) { try await logger.exportLogs() }
    }
}

private actor InitialLogReadGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
