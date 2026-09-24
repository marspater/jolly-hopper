import Foundation
import Security
import CommonCrypto
import CryptoKit
import SQLite3

/// Chromium-based browser cookie reader.
/// Supports universal Chromium browsers (Helium, Chromium, Chrome, Brave, Edge, Arc, Vivaldi, Opera)
/// on macOS using each browser's respective Keychain storage key and standard on-disk SQLite cookie database.
enum ChromiumCookieReader {
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
            return host == String(domain.dropFirst()) || host.hasSuffix(domain)
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
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003, keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        guard status == kCCSuccess else { throw failure("Could not derive the cookie key.") }
        return key
    }

    // Helper extracting the inner buffer call to avoid nesting more than 2 closure expressions (swift:S3087)
    private static func decryptBlock(
        keyBytes: UnsafeRawBufferPointer,
        keyCount: Int,
        iv: [UInt8],
        ciphertext: Data,
        output: UnsafeMutableRawBufferPointer,
        capacity: Int,
        count: inout Int
    ) -> CCCryptorStatus {
        var localCount = 0
        let status = ciphertext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, keyCount, iv, input.baseAddress, ciphertext.count,
                    output.baseAddress, capacity, &localCount)
        }
        count = localCount
        return status
    }

    static func decrypt(_ encrypted: Data, key: Data, domain: String, version: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else {
            throw failure("Unsupported encrypted cookie format. Use the browser extension for this browser version.")
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = plaintext.count
        var count = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                decryptBlock(
                    keyBytes: keyBytes,
                    keyCount: key.count,
                    iv: iv,
                    ciphertext: ciphertext,
                    output: output,
                    capacity: capacity,
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

    /// Returns nil when the first readable profile has no cookies for the target host.
    /// Other browsers' profiles are not probed in that case.
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

        var lastError: Error?
        for candidate in candidateRoots {
            do {
                let candidatePassword: () throws -> Data = {
                    if let password {
                        return try password()
                    }
                    if let target = candidate.target {
                        return try keychainPassword(service: target.keychainService, account: target.keychainAccount)
                    }
                    return try keychainPassword()
                }
                return try exportFromProfile(targetHost: host, root: candidate.root, password: candidatePassword)
            } catch {
                lastError = error
            }
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
        func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: text)
        }
        var key: Data?
        var lines = ["# Netscape HTTP Cookie File"]
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure("Could not read the browser cookie database.") }
            let domain = string(0)
            guard matches(host: host, domain: domain) else { continue }
            let expiry = sqlite3_column_int(statement, 8) == 0 ? 0 :
                sqlite3_column_int64(statement, 5) / 1_000_000 - 11_644_473_600
            guard expiry == 0 || expiry > Int64(Date().timeIntervalSince1970) else { continue }
            var value = string(2)
            let encryptedCount = Int(sqlite3_column_bytes(statement, 3))
            if encryptedCount > 0, let bytes = sqlite3_column_blob(statement, 3) {
                if key == nil { key = try deriveKey(password: password()) }
                value = try decrypt(Data(bytes: bytes, count: encryptedCount), key: key!, domain: domain, version: version)
            }
            let name = string(1)
            let path = string(4)
            guard [domain, name, path, value].allSatisfy({ $0.rangeOfCharacter(from: CharacterSet(charactersIn: "\t\r\n\0")) == nil }) else {
                throw failure("Cookie contains invalid control characters.")
            }
            let httpOnly = sqlite3_column_int(statement, 7) != 0 ? "#HttpOnly_" : ""
            let subdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = sqlite3_column_int(statement, 6) != 0 ? "TRUE" : "FALSE"
            lines.append("\(httpOnly)\(domain)\t\(subdomains)\t\(path)\t\(secure)\t\(expiry)\t\(name)\t\(value)")
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

    static func prepare(_ args: [String], rootOverride: URL? = nil) throws -> (args: [String], cookieFile: SecureCookieFile?) {
        guard let index = args.firstIndex(of: "--cookies-from-browser"), index + 1 < args.count else {
            return (args, nil)
        }
        let browserArg = args[index + 1].lowercased()
        guard browserArg == "helium" || browserArg == "chromium-based" || browserArg == "arc" else {
            return (args, nil)
        }
        guard let target = args.last.flatMap(URL.init(string:)), ["http", "https"].contains(target.scheme) else {
            throw failure("Missing HTTP target for cookie extraction.")
        }
        let root: URL
        if let rootOverride {
            root = rootOverride
        } else if browserArg == "arc", let arcBrowser = knownChromiumBrowsers.first(where: { $0.name == "Arc" }) {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(arcBrowser.relativePath)
        } else {
            root = defaultHeliumRoot
        }
        var prepared = args
        guard let file = try export(for: target, root: root) else {
            let host = target.host ?? "target"
            Task { @MainActor in
                LoggerService.shared.log("No \(browserArg) cookies for \(host); continuing without browser cookies.", level: .info)
            }
            prepared.removeSubrange(index...index + 1)
            return (prepared, nil)
        }
        prepared.replaceSubrange(index...index + 1, with: ["--cookies", file.path])
        return (prepared, file)
    }
}

/// Backward compatibility alias for HeliumCookieReader
typealias HeliumCookieReader = ChromiumCookieReader
