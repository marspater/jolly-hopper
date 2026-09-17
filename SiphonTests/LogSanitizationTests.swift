//
//  LogSanitizationTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

final class LogSanitizationTests: XCTestCase {

    func testSanitizeAuthorizationHeaders() {
        let raw = "Request outgoing: Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.xyz.123\nDone"
        let sanitized = LoggerService.sanitizeLogContentForExport(raw)
        XCTAssertFalse(sanitized.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        XCTAssertTrue(sanitized.contains("<REDACTED_AUTH>"))
    }

    func testSanitizeCookieHeaders() {
        let raw = "Sending request with Cookie: SID=super_secret_cookie; HSID=top_secret_auth\nEnd"
        let sanitized = LoggerService.sanitizeLogContentForExport(raw)
        XCTAssertFalse(sanitized.contains("super_secret_cookie"))
        XCTAssertTrue(sanitized.contains("<REDACTED_COOKIES>"))
    }

    func testSanitizeQuerySecrets() {
        let raw = "Fetching https://api.service.com/stream?token=secret_stream_token_123&quality=1080p&key=api_key_456"
        let sanitized = LoggerService.sanitizeLogContentForExport(raw)
        XCTAssertFalse(sanitized.contains("secret_stream_token_123"))
        XCTAssertFalse(sanitized.contains("api_key_456"))
        XCTAssertTrue(sanitized.contains("token=<REDACTED>"))
        XCTAssertTrue(sanitized.contains("key=<REDACTED>"))
        XCTAssertTrue(sanitized.contains("quality=1080p"))
    }

    func testSanitizeLocalUserHomePaths() {
        let raw = "File saved to /Users/secret_developer_name/Library/Application Support/Siphon/download.mp4"
        let sanitized = LoggerService.sanitizeLogContentForExport(raw)
        XCTAssertFalse(sanitized.contains("/Users/secret_developer_name/"))
        XCTAssertTrue(sanitized.contains("/Users/<USER>/"))
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
