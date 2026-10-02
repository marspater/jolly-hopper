//
//  SecureCookieFileTests.swift
//  SiphonTests
//

import XCTest
import SQLite3
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

    func testSanitizesHostWithControlCharacters() throws {
        // Crafted host with tab and newline characters
        let malformedURL = "https://example.com\t\r\ninjected.org/video"
        let cookie = try SecureCookieFile.create(
            url: malformedURL,
            rawCookies: "session=valid_token"
        )
        defer { cookie.cleanup() }

        XCTAssertNoThrow(try cookie.validate())
        let content = try String(contentsOf: cookie.fileURL, encoding: .utf8)
        XCTAssertFalse(content.contains("\r"), "Netscape file must not contain raw carriage returns")
        let lines = content.components(separatedBy: .newlines)
        // Ensure host control characters were stripped and didn't create extra lines
        XCTAssertTrue(content.contains("example.cominjected.org"))
        XCTAssertEqual(lines.filter { !$0.isEmpty }.count, 2, "Must contain header line and single cookie entry")
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
            additionalNetscapeLines: [".youtube.com\tTRUE\t/\tFALSE\t2000000000\tEXTRA\tval"]
        )
        defer { cookie.cleanup() }

        XCTAssertNoThrow(try cookie.validate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookie.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: cookie.path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perm, 0o600, "Permissions must be strictly 0o600")

        let fileContent = try String(contentsOf: cookie.fileURL, encoding: .utf8)
        XCTAssertTrue(fileContent.contains("SID\ttest123"))
        XCTAssertTrue(fileContent.contains("PREF\tf1=50000"))
        XCTAssertTrue(fileContent.contains("EXTRA\tval"))
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
        XCTAssertEqual(dir.lastPathComponent, "session-\(getpid())", "Each process must write into its own session directory")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path),
           let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue {
            XCTAssertEqual(perm, 0o700, "Directory permissions must be 0o700")
        }
    }

    func testPurgeKeepsLiveSessionsOfOtherProcesses() throws {
        let fileManager = FileManager.default
        let own = try XCTUnwrap(CookieManager.getSecureTempCookiesDirectory())
        let root = own.deletingLastPathComponent()
        // PID 1 (launchd) is always alive; 999999 is above the macOS PID limit, so never alive.
        let live = root.appendingPathComponent("session-1")
        let dead = root.appendingPathComponent("session-999999")
        defer {
            try? fileManager.removeItem(at: live)
            try? fileManager.removeItem(at: dead)
        }
        for dir in [live, dead] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "dummy".write(to: dir.appendingPathComponent("siphon_cookies_x.txt"), atomically: true, encoding: .utf8)
        }
        let ownFile = own.appendingPathComponent("siphon_cookies_own.txt")
        try "dummy".write(to: ownFile, atomically: true, encoding: .utf8)

        CookieManager.purgeOrphanedTempCookieFiles()

        XCTAssertTrue(fileManager.fileExists(atPath: live.appendingPathComponent("siphon_cookies_x.txt").path),
                      "Another running Siphon's cookie file must survive this process's purge")
        XCTAssertFalse(fileManager.fileExists(atPath: dead.path), "A session whose process is gone must be removed")
        XCTAssertFalse(fileManager.fileExists(atPath: ownFile.path))
    }

    func testChromiumExportKeepsKeychainFailureOverBrowserWithoutMatches() throws {
        struct KeychainDenied: Error {}
        func makeRoot(_ row: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let profile = root.appendingPathComponent("Default")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(profile.appendingPathComponent("Cookies").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let sql = """
            CREATE TABLE meta(key TEXT, value TEXT);
            INSERT INTO meta VALUES ('version','24');
            CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, has_expires INTEGER);
            \(row)
            """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            return root
        }
        // An encrypted cookie for the host forces the Keychain read, which is denied.
        let locked = try makeRoot("INSERT INTO cookies VALUES('.example.com','session','',X'7631300102','/',0,1,1,0);")
        let signedOut = try makeRoot("INSERT INTO cookies VALUES('other.test','session','x',X'','/',0,1,1,0);")
        let signedIn = try makeRoot("INSERT INTO cookies VALUES('.example.com','session','fixture',X'','/',0,1,1,0);")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            for root in [locked, signedOut, signedIn] { try? FileManager.default.removeItem(at: root) }
        }
        let denied: () throws -> Data = { throw KeychainDenied() }

        let orders: [[(root: URL, target: ChromiumCookieReader.ChromiumBrowserTarget?)]] = [
            [(locked, nil), (signedOut, nil), (missing, nil)],
            [(missing, nil), (signedOut, nil), (locked, nil)]
        ]
        for order in orders {
            XCTAssertThrowsError(try ChromiumCookieReader.export(
                host: "example.com", from: order, password: denied
            ), "A browser without matches must not mask one whose cookies cannot be decrypted") {
                XCTAssertTrue($0 is KeychainDenied, "Unexpected error: \($0)")
            }
        }

        let file = try XCTUnwrap(ChromiumCookieReader.export(
            host: "example.com", from: [(locked, nil), (signedIn, nil)], password: denied
        ), "A later browser with readable cookies still wins")
        file.cleanup()
    }
}
