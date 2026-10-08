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
        let raw = "Sending request with Cookie: SID=super_secret_cookie; HSID=top_secret_auth\nResponse: Set-Cookie: SESSION=response_secret_cookie; Path=/\nEnd"
        let sanitized = LoggerService.sanitizeLogContentForExport(raw)
        XCTAssertFalse(sanitized.contains("super_secret_cookie"))
        XCTAssertFalse(sanitized.contains("response_secret_cookie"))
        XCTAssertTrue(sanitized.contains("<REDACTED_COOKIES>"))
    }

    func testSanitizeApiKeyHeaders() {
        let raw = "Sending request with X-API-Key: secret_key_12345 and X-Auth-Token: secret_token_67890\nEnd"
        let sanitized = LoggerService.sanitizeLogContentForExport(raw)
        XCTAssertFalse(sanitized.contains("secret_key_12345"))
        XCTAssertFalse(sanitized.contains("secret_token_67890"))
        XCTAssertTrue(sanitized.contains("X-API-Key: <REDACTED_KEY>"))
        XCTAssertTrue(sanitized.contains("X-Auth-Token: <REDACTED_KEY>"))
    }

    func testSanitizeQuerySecrets() {
        let raw = "Fetching https://api.service.com/stream?token=secret_stream_token_123&quality=1080p&key=api_key_456&access_token=secret_jwt_789&session=sess_abc_123"
        let sanitized = LoggerService.sanitizeLogContentForExport(raw)
        XCTAssertFalse(sanitized.contains("secret_stream_token_123"))
        XCTAssertFalse(sanitized.contains("api_key_456"))
        XCTAssertFalse(sanitized.contains("secret_jwt_789"))
        XCTAssertFalse(sanitized.contains("sess_abc_123"))
        XCTAssertTrue(sanitized.contains("token=<REDACTED>"))
        XCTAssertTrue(sanitized.contains("key=<REDACTED>"))
        XCTAssertTrue(sanitized.contains("access_token=<REDACTED>"))
        XCTAssertTrue(sanitized.contains("session=<REDACTED>"))
        XCTAssertTrue(sanitized.contains("quality=1080p"))
    }

    func testSanitizeLoginWithTokenCommandFlag() {
        let args = ["yt-dlp", "--login-with-token", "secret_user_login_token_12345", "https://example.com/video"]
        let sanitized = LoggerService.sanitizeCommandForLog(args)
        XCTAssertFalse(sanitized.contains("secret_user_login_token_12345"))
        XCTAssertTrue(sanitized.contains("--login-with-token \"<TOKEN>\""))
    }

    func testSanitizeProxyAuthAndConfigFileCommandFlags() {
        let args = [
            "yt-dlp",
            "--proxy-user", "proxy_user_123",
            "--proxy-password", "proxy_pass_456",
            "--user", "user_789",
            "--netrc-location", "/Users/secret/netrc",
            "--config-location", "/Users/secret/config",
            "--client-certificate-key-password", "cert_key_pass_321",
            "https://example.com/video"
        ]
        let sanitized = LoggerService.sanitizeCommandForLog(args)
        XCTAssertFalse(sanitized.contains("proxy_user_123"))
        XCTAssertFalse(sanitized.contains("proxy_pass_456"))
        XCTAssertFalse(sanitized.contains("user_789"))
        XCTAssertFalse(sanitized.contains("cert_key_pass_321"))
        XCTAssertFalse(sanitized.contains("/Users/secret/netrc"))
        XCTAssertFalse(sanitized.contains("/Users/secret/config"))
        XCTAssertTrue(sanitized.contains("--proxy-user \"<USERNAME>\""))
        XCTAssertTrue(sanitized.contains("--proxy-password \"<PASSWORD>\""))
        XCTAssertTrue(sanitized.contains("--user \"<USERNAME>\""))
        XCTAssertTrue(sanitized.contains("--netrc-location \"<LOCATION_REDACTED>\""))
        XCTAssertTrue(sanitized.contains("--config-location \"<LOCATION_REDACTED>\""))
        XCTAssertTrue(sanitized.contains("--client-certificate-key-password \"<PASSWORD>\""))
    }

    func testSanitizeAttachedShortCommandFlags() {
        let args = ["yt-dlp", "-pMySecretPass", "-uAdminUser", "-2Token123456", "-bHelium", "-HCookie: secret=123", "https://example.com/video"]
        let sanitized = LoggerService.sanitizeCommandForLog(args)
        XCTAssertFalse(sanitized.contains("MySecretPass"))
        XCTAssertFalse(sanitized.contains("AdminUser"))
        XCTAssertFalse(sanitized.contains("Token123456"))
        XCTAssertFalse(sanitized.contains("Helium"))
        XCTAssertFalse(sanitized.contains("secret=123"))
        XCTAssertTrue(sanitized.contains("-p\"<PASSWORD>\""))
        XCTAssertTrue(sanitized.contains("-u\"<USERNAME>\""))
        XCTAssertTrue(sanitized.contains("-2\"<2FACTOR>\""))
        XCTAssertTrue(sanitized.contains("-b\"<BROWSER>\""))
        XCTAssertTrue(sanitized.contains("-H\"<REDACTED_HEADER>\""))
    }

    func testSanitizeQuotedAndFlagPrefixedURLsInCommand() {
        let args = [
            "yt-dlp",
            "\"https://example.com/video?token=secret_query_param_123\"",
            "--url=https://example.com/stream?secret_key=abc456"
        ]
        let sanitized = LoggerService.sanitizeCommandForLog(args)
        XCTAssertFalse(sanitized.contains("secret_query_param_123"))
        XCTAssertFalse(sanitized.contains("secret_key=abc456"))
        XCTAssertTrue(sanitized.contains("\"https://example.com/video\""))
        XCTAssertTrue(sanitized.contains("--url=https://example.com/stream"))
    }

    func testSanitizeLocalUserHomePaths() {
        let raw = "File saved to /Users/secret_developer_name/Library/Application Support/Siphon/download.mp4"
        let sanitized = LoggerService.sanitizeLogContentForExport(raw)
        XCTAssertFalse(sanitized.contains("/Users/secret_developer_name/"))
        XCTAssertTrue(sanitized.contains("/Users/<USER>/"))
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
