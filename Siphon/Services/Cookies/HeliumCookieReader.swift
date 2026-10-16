import Foundation
import Security
import CommonCrypto
import CryptoKit
import SQLite3

/// Chromium-based browser cookie reader.
/// Supports universal Chromium browsers (Helium, Chromium, Chrome, Brave, Edge, Arc, Vivaldi, Opera)
/// on macOS using each browser's respective Keychain storage key and standard on-disk SQLite cookie database.
enum ChromiumCookieReader {
    // Bolt Performance Optimization: Pre-compile static cryptographic constants and salt buffers to eliminate heap allocations during PBKDF key derivation and AES decryption.
    nonisolated private static let pbkdfSalt = Array("saltysalt".utf8)
    nonisolated private static let v10Header = Data("v10".utf8)
    nonisolated private static let aesIV = [UInt8](repeating: 32, count: kCCBlockSizeAES128)

    // Bolt Performance Optimization: Check control scalar values directly in CPU registers on native UnicodeScalarView to eliminate Foundation CharacterSet allocations and NSString bridging per cookie row.
    nonisolated private static func containsInvalidControlChar(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x00
        }
    }

    struct ChromiumBrowserTarget: Sendable {
        let name: String
        let relativePath: String
        let keychainService: String
        let keychainAccount: String
    }

    static let defaultHeliumRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/net.imput.helium")

    static let knownChromiumBrowsers: [ChromiumBrowserTarget] = [
        ChromiumBrowserTarget(
            name: "Helium",
            relativePath: "Library/Application Support/net.imput.helium",
            keychainService: "Helium Storage Key",
            keychainAccount: "Helium"
        ),
        ChromiumBrowserTarget(
            name: "Chromium",
            relativePath: "Library/Application Support/Chromium",
            keychainService: "Chromium Safe Storage",
            keychainAccount: "Chromium"
        ),
        ChromiumBrowserTarget(
            name: "Google Chrome",
            relativePath: "Library/Application Support/Google/Chrome",
            keychainService: "Chrome Safe Storage",
            keychainAccount: "Chrome"
        ),
        ChromiumBrowserTarget(
            name: "Brave",
            relativePath: "Library/Application Support/BraveSoftware/Brave-Browser",
            keychainService: "Brave Safe Storage",
            keychainAccount: "Brave"
        ),
        ChromiumBrowserTarget(
            name: "Microsoft Edge",
            relativePath: "Library/Application Support/Microsoft Edge",
            keychainService: "Microsoft Edge Safe Storage",
            keychainAccount: "Microsoft Edge"
        ),
        ChromiumBrowserTarget(
            name: "Arc",
            relativePath: "Library/Application Support/Arc/User Data",
            keychainService: "Arc Safe Storage",
            keychainAccount: "Arc"
        ),
        ChromiumBrowserTarget(
            name: "Vivaldi",
            relativePath: "Library/Application Support/Vivaldi",
            keychainService: "Vivaldi Safe Storage",
            keychainAccount: "Vivaldi"
        ),
        ChromiumBrowserTarget(
            name: "Thorium",
            relativePath: "Library/Application Support/Thorium",
            keychainService: "Thorium Safe Storage",
            keychainAccount: "Thorium"
        ),
        ChromiumBrowserTarget(
            name: "Opera",
            relativePath: "Library/Application Support/com.operasoftware.Opera",
            keychainService: "Opera Safe Storage",
            keychainAccount: "Opera"
        )
    ]

    static func failure(_ message: String) -> YtdlpError {
        .downloadFailed("Chromium cookies: \(message)")
    }

    static func profileDirectory(root: URL) throws -> URL {
        let stateURL = root.appendingPathComponent("Local State")
        var profile = "Default"
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let settings = state?["profile"] as? [String: Any],
               let lastUsed = settings["last_used"] as? String, !lastUsed.isEmpty {
                guard lastUsed != ".", lastUsed != "..", !lastUsed.contains("/"), !lastUsed.contains("\\") else {
                    throw failure("Invalid active profile in Local State.")
                }
                profile = lastUsed
            }
        }
        return root.appendingPathComponent(profile, isDirectory: true)
    }

    static func matches(host: String, domain: String) -> Bool {
        let domain = domain.lowercased()
        let host = host.lowercased()
        if domain.hasPrefix(".") {
            // Bolt Performance Optimization: Compare host directly with Substring (domain.dropFirst()) to avoid intermediate String heap allocation.
            return host == domain.dropFirst() || host.hasSuffix(domain)
        }
        return host == domain
    }

    static func keychainPassword(service: String = "Helium Storage Key", account: String = "Helium") throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            throw failure("Could not read \(service) from Keychain (\(status)). Allow Siphon access when macOS asks, or send this page using the browser extension.")
        }
        return password
    }

    static func deriveKey(password: Data) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                    pbkdfSalt, pbkdfSalt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003, keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        guard status == kCCSuccess else { throw failure("Could not derive the cookie key.") }
        return key
    }

    // Helper extracting the inner buffer call to avoid nesting more than 2 closure expressions (swift:S3087)
    private static func decryptBlock(
        keyBytes: UnsafeRawBufferPointer,
        iv: [UInt8],
        ciphertext: Data,
        output: UnsafeMutableRawBufferPointer,
        count: inout Int
    ) -> CCCryptorStatus {
        var localCount = 0
        let status = ciphertext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, keyBytes.count, iv, input.baseAddress, ciphertext.count,
                    output.baseAddress, output.count, &localCount)
        }
        count = localCount
        return status
    }

    static func decrypt(_ encrypted: Data, key: Data, domain: String, version: Int) throws -> String {
        guard encrypted.starts(with: v10Header) else {
            throw failure("Unsupported encrypted cookie format. Use the browser extension for this browser version.")
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var count = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                decryptBlock(
                    keyBytes: keyBytes,
                    iv: aesIV,
                    ciphertext: ciphertext,
                    output: output,
                    count: &count
                )
            }
        }
        guard status == kCCSuccess else { throw failure("Cookie decryption failed. The browser key may have changed.") }
        plaintext.count = count
        if version >= 24 {
            let digest = Data(SHA256.hash(data: Data(domain.utf8)))
            guard plaintext.starts(with: digest) else { throw failure("Cookie domain verification failed.") }
            plaintext = Data(plaintext.dropFirst(digest.count))
        }
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw failure("Decrypted cookie is not valid UTF-8.")
        }
        return value
    }

    /// Returns nil when no readable profile has cookies for the target host.
    /// A browser with no matching cookies falls through to the next one, so an
    /// installed but signed-out Chrome does not hide a signed-in Arc. Keychain
    /// access failures remain errors; malformed individual rows are skipped.
    static func export(
        for target: URL,
        root: URL = defaultHeliumRoot,
        password: (() throws -> Data)? = nil
    ) throws -> SecureCookieFile? {
        guard let host = target.host else { throw failure("Missing target host.") }

        // If default root does not exist, look across known Chromium browser installations
        var candidateRoots: [(root: URL, target: ChromiumBrowserTarget?)] = []
        if root == defaultHeliumRoot {
            candidateRoots.append((defaultHeliumRoot, knownChromiumBrowsers.first))
            let home = FileManager.default.homeDirectoryForCurrentUser
            for browser in knownChromiumBrowsers {
                let candidateURL = home.appendingPathComponent(browser.relativePath)
                if candidateURL != root && FileManager.default.fileExists(atPath: candidateURL.path) {
                    candidateRoots.append((candidateURL, browser))
                }
            }
        } else {
            let matched = knownChromiumBrowsers.first {
                root.path.hasSuffix($0.relativePath)
            }
            candidateRoots.append((root, matched))
        }

        return try export(host: host, from: candidateRoots, password: password)
    }

    static func export(
        host: String,
        from candidateRoots: [(root: URL, target: ChromiumBrowserTarget?)],
        password: (() throws -> Data)?
    ) throws -> SecureCookieFile? {
        var lastError: Error?
        var cookieError: Error?
        var foundReadableProfile = false
        for candidate in candidateRoots {
            // The key is read only for a cookie that matches the host, so a failure after
            // that is a Keychain/derivation error, not a missing or locked profile.
            var readKey = false
            do {
                let candidatePassword: () throws -> Data = {
                    readKey = true
                    if let password {
                        return try password()
                    }
                    if let target = candidate.target {
                        return try keychainPassword(service: target.keychainService, account: target.keychainAccount)
                    }
                    return try keychainPassword()
                }
                if let file = try exportFromProfile(targetHost: host, root: candidate.root, password: candidatePassword) {
                    return file
                }
                foundReadableProfile = true
            } catch {
                if readKey {
                    cookieError = cookieError ?? error
                } else {
                    lastError = error
                }
            }
        }

        // A Keychain/derivation failure must not be masked by a signed-out browser.
        if let cookieError {
            throw cookieError
        }
        if foundReadableProfile {
            return nil
        }
        if let lastError {
            throw lastError
        }
        throw failure("No cookie database found in any active Chromium profile. Open the page in your Chromium browser and sign in first.")
    }

    private static func exportFromProfile(
        targetHost host: String,
        root: URL,
        password: () throws -> Data
    ) throws -> SecureCookieFile? {
        let profile = try profileDirectory(root: root)
        let candidates = [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
        guard let database = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw failure("No cookie database in the active profile. Open the page in your Chromium-based browser and sign in first.")
        }
        // Read the live SQLite snapshot, including WAL, without copying or modifying browser files.
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw failure("Could not open the browser cookie database.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var metadata: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &metadata, nil) == SQLITE_OK else {
            throw failure("Could not read the cookie database version.")
        }
        defer { sqlite3_finalize(metadata) }
        guard sqlite3_step(metadata) == SQLITE_ROW else { throw failure("Missing cookie database version.") }
        let version = Int(sqlite3_column_int(metadata, 0))
        var statement: OpaquePointer?
        let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, has_expires FROM cookies"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw failure("Unsupported cookie database schema.")
        }
        defer { sqlite3_finalize(statement) }
        func string(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(data: Data(bytes: text, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
        }
        var key: Data?
        var undecryptableRows = 0
        var lines = ["# Netscape HTTP Cookie File"]
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure("Could not read the browser cookie database.") }
            guard let domain = string(0), let name = string(1), let path = string(4),
                  matches(host: host, domain: domain) else { continue }
            let expiry = sqlite3_column_int(statement, 8) == 0 ? 0 :
                sqlite3_column_int64(statement, 5) / 1_000_000 - 11_644_473_600
            guard expiry == 0 || expiry > Int64(Date().timeIntervalSince1970) else { continue }
            var value = string(2) ?? ""
            let encryptedCount = Int(sqlite3_column_bytes(statement, 3))
            if encryptedCount > 0, let bytes = sqlite3_column_blob(statement, 3) {
                if key == nil { key = try deriveKey(password: password()) }
                do {
                    value = try decrypt(Data(bytes: bytes, count: encryptedCount), key: key!, domain: domain, version: version)
                } catch {
                    // Keychain/derivation failures above remain fatal; one invalid row
                    // must not discard the remaining verified cookies.
                    Task { @MainActor in
                        LoggerService.shared.log("Skipping an unverifiable Chromium cookie row.", level: .warning)
                    }
                    undecryptableRows += 1
                    continue
                }
            } else if string(2) == nil {
                continue
            }
            guard !name.isEmpty, !containsInvalidControlChar(domain),
                  !containsInvalidControlChar(name),
                  !containsInvalidControlChar(path),
                  !containsInvalidControlChar(value) else {
                continue
            }
            let httpOnly = sqlite3_column_int(statement, 7) != 0 ? "#HttpOnly_" : ""
            let subdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = sqlite3_column_int(statement, 6) != 0 ? "TRUE" : "FALSE"
            lines.append("\(httpOnly)\(domain)\t\(subdomains)\t\(path)\t\(secure)\t\(expiry)\t\(name)\t\(value)")
        }
        // Every matching row failing points at a stale or wrong Keychain key, not a
        // signed-out browser; continuing anonymously would hide that.
        if lines.count == 1 && undecryptableRows > 0 {
            throw failure("Could not decrypt any cookie for this site with the browser's Keychain key.")
        }
        // No cookies for this host is not an error: yt-dlp's own browser readers
        // also continue anonymously, and CDN hosts never carry site cookies.
        guard lines.count > 1 else { return nil }
        guard let directory = CookieManager.getSecureTempCookiesDirectory() else {
            throw failure("Could not prepare temporary cookie storage.")
        }
        let url = directory.appendingPathComponent("siphon_cookies_\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: url.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw failure("Could not write temporary cookies.")
        }
        let file = SecureCookieFile(fileURL: url)
        try file.validate()
        return file
    }
}

/// Backward compatibility alias for HeliumCookieReader
typealias HeliumCookieReader = ChromiumCookieReader
