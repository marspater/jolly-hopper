//
//  SecureCookieFileTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

final class SecureCookieFileTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CookieManager.purgeOrphanedTempCookieFiles()
    }

    override func tearDown() {
        CookieManager.purgeOrphanedTempCookieFiles()
        super.tearDown()
    }

    func testCreateAndValidateSecureCookieFile() throws {
        let cookie = try SecureCookieFile.create(
            url: "https://www.youtube.com/watch?v=12345",
            rawCookies: "SID=abc123xyz; HSID=def456uvw",
            additionalCookies: [("LOGIN_INFO", "token789")]
        )
        defer { cookie.cleanup() }

        // Must validate cleanly
        XCTAssertNoThrow(try cookie.validate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookie.path))

        // Check POSIX permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: cookie.path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perm, 0o600, "Permissions must be strictly 0o600")

        // Check Netscape content
        let content = try String(contentsOf: cookie.fileURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Netscape HTTP Cookie File"))
        XCTAssertTrue(content.contains("SID\tabc123xyz"))
        XCTAssertTrue(content.contains("LOGIN_INFO\ttoken789"))
    }

    func testValidationRejectsEmptyOrInvalidFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let emptyURL = tempDir.appendingPathComponent("test_empty_\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: emptyURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: emptyURL) }

        let emptyCookie = SecureCookieFile(fileURL: emptyURL)
        XCTAssertThrowsError(try emptyCookie.validate())

        // File with bad header
        let badHeaderURL = tempDir.appendingPathComponent("test_bad_header_\(UUID().uuidString).txt")
        try "Not a netscape cookie file".write(to: badHeaderURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: badHeaderURL) }

        let badCookie = SecureCookieFile(fileURL: badHeaderURL)
        XCTAssertThrowsError(try badCookie.validate())
    }

    func testValidationRejectsInsecurePermissions() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let insecureURL = tempDir.appendingPathComponent("test_insecure_\(UUID().uuidString).txt")
        let content = "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tFALSE\t2000000000\tA\tB\n"
        FileManager.default.createFile(atPath: insecureURL.path, contents: content.data(using: .utf8)!, attributes: [.posixPermissions: 0o666])
        defer { try? FileManager.default.removeItem(at: insecureURL) }

        let insecureCookie = SecureCookieFile(fileURL: insecureURL)
        XCTAssertThrowsError(try insecureCookie.validate())
    }

    func testCleanupIsIdempotent() throws {
        let cookie = try SecureCookieFile.create(
            url: "https://example.com",
            rawCookies: "foo=bar"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookie.path))

        cookie.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cookie.path))

        // Second cleanup should be a harmless no-op
        XCTAssertNoThrow(cookie.cleanup())
    }

    func testScopedExecutionCleansUpOnSuccess() async throws {
        var filePath: String?

        let result = try await SecureCookieFile.scoped(
            url: "https://example.com/video",
            rawCookies: "auth=12345"
        ) { cookie -> String in
            filePath = cookie.path
            XCTAssertTrue(FileManager.default.fileExists(atPath: cookie.path))
            return "success_result"
        }

        XCTAssertEqual(result, "success_result")
        if let path = filePath {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Scoped cookie file must be cleaned up on completion")
        }
    }

    func testScopedExecutionCleansUpOnError() async {
        struct TestError: Error {}
        var filePath: String?

        do {
            _ = try await SecureCookieFile.scoped(
                url: "https://example.com/video",
                rawCookies: "auth=12345"
            ) { cookie -> String in
                filePath = cookie.path
                throw TestError()
            }
            XCTFail("Should have thrown")
        } catch {
            if let path = filePath {
                XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Scoped cookie file must be cleaned up even if error was thrown")
            }
        }
    }

    func testPurgeOrphanedTempCookieFiles() {
        guard let dir = CookieManager.getSecureTempCookiesDirectory() else { return }
        let orphan1 = dir.appendingPathComponent("siphon_consolidated_cookies_orphan1.txt")
        let orphan2 = dir.appendingPathComponent("siphon_cookies_orphan2.txt")
        try? "dummy".write(to: orphan1, atomically: true, encoding: .utf8)
        try? "dummy".write(to: orphan2, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan2.path))

        CookieManager.purgeOrphanedTempCookieFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan2.path))
    }

    func testCookieManagerCreateSecureCookieFile() async throws {
        let manager = CookieManager()
        let cookie = try await manager.createSecureCookieFile(
            url: "https://www.youtube.com/watch?v=98765",
            rawCookies: "SID=test123; HSID=test456",
            additionalCookies: [("PREF", "f1=50000")],
            additionalNetscapeLines: [".youtube.com	TRUE	/	FALSE	2000000000	EXTRA	val"]
        )
        defer { cookie.cleanup() }

        XCTAssertNoThrow(try cookie.validate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookie.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: cookie.path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perm, 0o600, "Permissions must be strictly 0o600")

        let fileContent = try String(contentsOf: cookie.fileURL, encoding: .utf8)
        XCTAssertTrue(fileContent.contains("SID	test123"))
        XCTAssertTrue(fileContent.contains("PREF	f1=50000"))
        XCTAssertTrue(fileContent.contains("EXTRA	val"))
    }

    func testCookieManagerPurgeOrphanedFilesInstanceMethod() async {
        guard let dir = CookieManager.getSecureTempCookiesDirectory() else { return }
        let orphan = dir.appendingPathComponent("siphon_cookies_instance_orphan.txt")
        try? "dummy".write(to: orphan, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        let manager = CookieManager()
        await manager.purgeOrphanedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testCookieManagerGetSecureTempCookiesDirectory() {
        guard let dir = CookieManager.getSecureTempCookiesDirectory() else {
            XCTFail("Directory should not be nil")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        if let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path),
           let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue {
            XCTAssertEqual(perm, 0o700, "Directory permissions must be 0o700")
        }
    }
}
