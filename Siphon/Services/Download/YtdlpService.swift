import Foundation
import CryptoKit
import CommonCrypto
import AppKit
import WebKit

struct DependencyChecksums {
    /// Siphon downloads and pins the Siphon build of yt-dlp (marspater/yt-dlp,
    /// VARIANT "siphon"). Turn off to use a user-provided yt-dlp instead (see
    /// `findYtdlp`), which Siphon does not checksum-verify.
    static let managedYtdlpEnabled = true

    /// The fork repository is private, so its `yt-dlp_macos` is mirrored to a
    /// public `ytdlp-<version>` prerelease of this repository. To bump, mirror
    /// the new fork asset there and change version, URL and SHA-256 together.
    static let ytdlpVersion = "2026.10.06.1"
    static let ytdlpURL = URL(string: "https://github.com/marspater/jolly-hopper/releases/download/ytdlp-2026.10.06.1/yt-dlp_macos") ?? URL(fileURLWithPath: "/")
    static let ytdlpExecutableSHA256 = "d7e3950941f980895b2b8e5280303373e4b23baacdca51878539fbb19bf9b48a"

    #if arch(arm64)
    static let ffmpegURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64.gz") ?? URL(fileURLWithPath: "/")
    static let ffmpegArchiveSHA256 = "8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa"
    static let ffmpegExecutableSHA256 = "a90e3db6a3fd35f6074b013f948b1aa45b31c6375489d39e572bea3f18336584"

    static let ffprobeURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-arm64.gz") ?? URL(fileURLWithPath: "/")
    static let ffprobeArchiveSHA256 = "d986a8ec7b030899fe66a8a288ed809a3543338705a3ce178cfb85869c5d80be"
    static let ffprobeExecutableSHA256 = "bb2db6f5d8cef919da12fbf592119a987202a8c060a886f3cab091f9cab90b64"
    #else
    static let ffmpegURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-x64.gz") ?? URL(fileURLWithPath: "/")
    static let ffmpegArchiveSHA256 = "929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106"
    static let ffmpegExecutableSHA256 = "ebdddc936f61e14049a2d4b549a412b8a40deeff6540e58a9f2a2da9e6b18894"

    static let ffprobeURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-x64.gz") ?? URL(fileURLWithPath: "/")
    static let ffprobeArchiveSHA256 = "d4da574d6e2e197bd259b47d69cf262df9e312af24ad960444f6d806d3d4c186"
    static let ffprobeExecutableSHA256 = "fa3add0ce901f7241abe0dfc0155d958fc834aca3f8ce61f87cc712ae669c1e0"
    #endif
}

actor DependencyInstaller {
    static let shared = DependencyInstaller()

    enum InstallError: LocalizedError {
        case sha256Mismatch(file: String, expected: String)
        case executionFailed(binary: String, message: String)
        case rollbackFailed(destination: String, underlyingError: Error)
        case installationFailed(destination: String, underlyingError: Error)
        case downloadFailed(file: String, statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let file, let statusCode):
                return "\(file) download failed: the server returned HTTP \(statusCode)."
            case .sha256Mismatch(let file, let exp):
                return "\(file) failed SHA-256 verification. Expected: \(exp)"
            case .executionFailed(let bin, let msg):
                return "\(bin) execution validation failed: \(msg)"
            case .rollbackFailed(let dest, let err):
                return "CRITICAL: Rollback failed for \(dest): \(err.localizedDescription)"
            case .installationFailed(let dest, let err):
                return "Installation failed for \(dest): \(err.localizedDescription)"
            }
        }
    }

    /// URLSession treats an HTTP error page as a successful download, which
    /// would otherwise surface as a misleading SHA-256 mismatch.
    static func download(_ url: URL, named file: String, to destination: URL) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        if let statusCode = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw InstallError.downloadFailed(file: file, statusCode: statusCode)
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func isBinarySigned(at url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // Use '--' to delimit arguments from option flags to prevent CLI option injection if a file path starts with '-'
        proc.arguments = ["--verify", "--deep", "--strict", "--", url.path]
        proc.environment = YtdlpService.createSanitizedEnvironment()
        let nullPipe = Pipe()
        proc.standardOutput = nullPipe
        proc.standardError = nullPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func adHocSignBinary(at url: URL) throws {
        guard !NotificationService.isRunningTests else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
        
        // If the binary already has a valid code signature, skip re-signing to avoid mutating
        // Mach-O binaries and invalidating upstream SHA-256 hashes.
        if isBinarySigned(at: url) {
            return
        }

        let binaryPath = url.path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--force", "--sign", "-", "--", binaryPath]
        proc.environment = YtdlpService.createSanitizedEnvironment()
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw InstallError.executionFailed(binary: url.lastPathComponent, message: "Ad-hoc codesign failed with exit code \(proc.terminationStatus): \(errMsg)")
        }
    }

    func installYtdlp(
        downloadURL: URL,
        expectedSHA256: String,
        appSupportDir: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = appSupportDir.appendingPathComponent("yt-dlp")
        let tempStaging = appSupportDir.appendingPathComponent("yt-dlp.tmp_\(UUID().uuidString)")

        var installedSuccessfully = false
        defer {
            if !installedSuccessfully {
                try? FileManager.default.removeItem(at: tempStaging)
            }
        }

        try await Self.download(downloadURL, named: "yt-dlp", to: tempStaging)
        onProgress?(0.65)

        // 1. Verify SHA-256
        guard YtdlpService.verifySHA256(fileURL: tempStaging, expectedHash: expectedSHA256) else {
            try? FileManager.default.removeItem(at: tempStaging)
            throw InstallError.sha256Mismatch(file: "yt-dlp", expected: expectedSHA256)
        }

        // 2. Set executable permissions and ad-hoc sign
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempStaging.path)
        try Self.adHocSignBinary(at: tempStaging)

        // 3. Dry-run execution test
        let process = Process()
        process.executableURL = tempStaging
        process.arguments = ["--ignore-config", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = YtdlpService.createSanitizedEnvironment()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: tempStaging)
                throw InstallError.executionFailed(binary: "yt-dlp", message: "Exited with code \(process.terminationStatus)")
            }
        } catch {
            try? FileManager.default.removeItem(at: tempStaging)
            throw InstallError.executionFailed(binary: "yt-dlp", message: error.localizedDescription)
        }

        // 4. Atomic Replace
        let backupDest = destination.deletingLastPathComponent().appendingPathComponent("yt-dlp.backup_\(UUID().uuidString)")
        let hadOld = FileManager.default.fileExists(atPath: destination.path)
        if hadOld {
            try FileManager.default.moveItem(at: destination, to: backupDest)
        }

        do {
            try FileManager.default.moveItem(at: tempStaging, to: destination)
            try Self.adHocSignBinary(at: destination)
            installedSuccessfully = true
            if hadOld {
                try? FileManager.default.removeItem(at: backupDest)
            }
            onProgress?(0.9)
            return destination
        } catch {
            if hadOld && !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.moveItem(at: backupDest, to: destination)
            }
            throw InstallError.installationFailed(destination: destination.path, underlyingError: error)
        }
    }

    func installFfmpegBundle(
        ffmpegURL: URL,
        ffmpegArchiveSHA256: String,
        ffmpegExecutableSHA256: String,
        ffprobeURL: URL,
        ffprobeArchiveSHA256: String,
        ffprobeExecutableSHA256: String,
        appSupportDir: URL
    ) async throws -> (ffmpeg: URL, ffprobe: URL) {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let ffmpegFinal = appSupportDir.appendingPathComponent("ffmpeg")
        let ffprobeFinal = appSupportDir.appendingPathComponent("ffprobe")

        let ffmpegGz = appSupportDir.appendingPathComponent("ffmpeg_\(UUID().uuidString).gz")
        let ffprobeGz = appSupportDir.appendingPathComponent("ffprobe_\(UUID().uuidString).gz")

        // 1. Download both archives. The cleanup is registered first, so a
        // failed second download does not leave the first archive behind.
        defer {
            try? FileManager.default.removeItem(at: ffmpegGz)
            try? FileManager.default.removeItem(at: ffprobeGz)
        }
        try await Self.download(ffmpegURL, named: "FFmpeg", to: ffmpegGz)
        try await Self.download(ffprobeURL, named: "FFprobe", to: ffprobeGz)

        // 2. Verify both .gz archive SHA-256
        guard YtdlpService.verifySHA256(fileURL: ffmpegGz, expectedHash: ffmpegArchiveSHA256) else {
            throw InstallError.sha256Mismatch(file: "FFmpeg archive", expected: ffmpegArchiveSHA256)
        }
        guard YtdlpService.verifySHA256(fileURL: ffprobeGz, expectedHash: ffprobeArchiveSHA256) else {
            throw InstallError.sha256Mismatch(file: "FFprobe archive", expected: ffprobeArchiveSHA256)
        }

        // 3. Decompress both
        let runGzip: (String) async throws -> Void = { path in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            proc.arguments = ["-d", "-f", "--", path]
            proc.environment = YtdlpService.createSanitizedEnvironment()
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw InstallError.executionFailed(binary: "gzip", message: "Failed to decompress \(path)")
            }
        }
        try await runGzip(ffmpegGz.path)
        try await runGzip(ffprobeGz.path)

        let extractedFfmpeg = ffmpegGz.deletingPathExtension()
        let extractedFfprobe = ffprobeGz.deletingPathExtension()

        defer {
            try? FileManager.default.removeItem(at: extractedFfmpeg)
            try? FileManager.default.removeItem(at: extractedFfprobe)
        }

        // 4. Verify extracted binary SHA-256
        guard YtdlpService.verifySHA256(fileURL: extractedFfmpeg, expectedHash: ffmpegExecutableSHA256) else {
            throw InstallError.sha256Mismatch(file: "FFmpeg executable", expected: ffmpegExecutableSHA256)
        }
        guard YtdlpService.verifySHA256(fileURL: extractedFfprobe, expectedHash: ffprobeExecutableSHA256) else {
            throw InstallError.sha256Mismatch(file: "FFprobe executable", expected: ffprobeExecutableSHA256)
        }

        // 5. Set executable permissions and ad-hoc sign
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: extractedFfmpeg.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: extractedFfprobe.path)
        try Self.adHocSignBinary(at: extractedFfmpeg)
        try Self.adHocSignBinary(at: extractedFfprobe)

        // 6. Test both binaries
        let testVersion: (URL) async throws -> Void = { binURL in
            let proc = Process()
            proc.executableURL = binURL
            proc.arguments = ["-version"]
            proc.environment = YtdlpService.createSanitizedEnvironment()
            let p = Pipe()
            proc.standardOutput = p
            proc.standardError = p
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw InstallError.executionFailed(binary: binURL.lastPathComponent, message: "Exited with code \(proc.terminationStatus)")
            }
        }
        try await testVersion(extractedFfmpeg)
        try await testVersion(extractedFfprobe)

        // 7. Atomic Pair Transaction: move both into place
        let ffmpegBackup = appSupportDir.appendingPathComponent("ffmpeg.backup_\(UUID().uuidString)")
        let ffprobeBackup = appSupportDir.appendingPathComponent("ffprobe.backup_\(UUID().uuidString)")
        let hadOldFfmpeg = FileManager.default.fileExists(atPath: ffmpegFinal.path)
        let hadOldFfprobe = FileManager.default.fileExists(atPath: ffprobeFinal.path)

        var ffmpegMovedToBackup = false
        var ffprobeMovedToBackup = false

        do {
            if hadOldFfmpeg {
                try FileManager.default.moveItem(at: ffmpegFinal, to: ffmpegBackup)
                ffmpegMovedToBackup = true
            }
            if hadOldFfprobe {
                try FileManager.default.moveItem(at: ffprobeFinal, to: ffprobeBackup)
                ffprobeMovedToBackup = true
            }

            try FileManager.default.moveItem(at: extractedFfmpeg, to: ffmpegFinal)
            try FileManager.default.moveItem(at: extractedFfprobe, to: ffprobeFinal)
            try Self.adHocSignBinary(at: ffmpegFinal)
            try Self.adHocSignBinary(at: ffprobeFinal)

            if ffmpegMovedToBackup { try? FileManager.default.removeItem(at: ffmpegBackup) }
            if ffprobeMovedToBackup { try? FileManager.default.removeItem(at: ffprobeBackup) }

            return (ffmpeg: ffmpegFinal, ffprobe: ffprobeFinal)
        } catch {
            // Atomic rollback of both binaries
            try? FileManager.default.removeItem(at: ffmpegFinal)
            try? FileManager.default.removeItem(at: ffprobeFinal)

            var rollbackErrors: [Error] = []
            if ffmpegMovedToBackup {
                do {
                    try FileManager.default.moveItem(at: ffmpegBackup, to: ffmpegFinal)
                } catch {
                    rollbackErrors.append(error)
                }
            }
            if ffprobeMovedToBackup {
                do {
                    try FileManager.default.moveItem(at: ffprobeBackup, to: ffprobeFinal)
                } catch {
                    rollbackErrors.append(error)
                }
            }

            if !rollbackErrors.isEmpty {
                await MainActor.run {
                    LoggerService.shared.log("Critical: Rollback error during FFmpeg installation: \(rollbackErrors)", level: .error)
                }
            }
            throw InstallError.installationFailed(destination: "\(ffmpegFinal.path) + \(ffprobeFinal.path)", underlyingError: error)
        }
    }
}

@MainActor
class YtdlpService: ObservableObject {
    @Published var isAvailable: Bool = false
    @Published var version: String?
    @Published var isUpdating: Bool = false
    @Published var updateProgress: Double = 0

    var ytdlpPath: URL?
    var ffmpegPath: URL?
    var ffprobePath: URL?
    private var deniedCookieSources: Set<String> = []
    private var activeSetupTask: Task<Void, Never>?

    var processRunner: YtdlpProcessRunning
    var updateYtdlpHandler: (() async throws -> String)?
    // Persistent, so a BoyfriendTV sign-in survives relaunches. Safari keeps the
    // site's login in a session cookie it never writes to disk, so browser-cookie
    // import cannot see it; the user signs in once in Siphon's window instead.
    // Boundary-enforced jobs keep theirs in a second store, signed in separately.
    private var boyfriendTVWebDataStores: [String: WKWebsiteDataStore] = [:]
    var boyfriendTVWebDataStore: WKWebsiteDataStore {
        webDataStore(in: &boyfriendTVWebDataStores) {
            let identifier = EgressBoundary.proxyURL == nil
                ? "F2F923A6-E203-4927-88BB-CCB9DF9DF651"
                : "550F3EA0-3E13-4475-B62F-146DC44E6700"
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: identifier)!)
        }
    }
    // Test seam for the browser-engine fallback. Production uses WKWebView.
    var boyfriendTVRenderedPageLoader: ((URL) async throws -> String?)?
    // Test seam for media URLs that only exist in the live browser runtime.
    var boyfriendTVRenderedStreamLoader: ((URL) async throws -> String?)?
    // Test seam for installed browser candidate discovery.
    var installedBrowsersProvider: (() async -> [String])?
    // Persistent, so the user's recu.me clearance and sign-in survive relaunches.
    // Boundary-enforced jobs keep theirs in a second store, signed in separately.
    private var recuWebDataStores: [String: WKWebsiteDataStore] = [:]
    private var recuWebDataStore: WKWebsiteDataStore {
        webDataStore(in: &recuWebDataStores) {
            let identifier = EgressBoundary.proxyURL == nil
                ? "6F1E2B7C-3A4D-4E5F-9A8B-7C6D5E4F3A2B"
                : "0C494988-0FFE-497D-904A-DCC4E85842B7"
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: identifier)!)
        }
    }
    // Test seam for the recu.me WebKit session. Production uses WKWebView.
    var recuBrowserSessionLoader: ((URL, String) async throws -> RecuBrowserSession)?
    // Persistent, so Gayteam's Cloudflare clearance survives relaunches.
    private var gayteamWebDataStores: [String: WKWebsiteDataStore] = [:]
    private var gayteamWebDataStore: WKWebsiteDataStore {
        webDataStore(in: &gayteamWebDataStores) {
            let identifier = EgressBoundary.proxyURL == nil
                ? "3B8E6C1D-7F2A-4E95-B0C4-9D1A6E5F2C83"
                : "A4D2F7E9-1C6B-4A38-8E5D-2F9B7C3A6D14"
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: identifier)!)
        }
    }
    // Test seam for Safari's saved cookies. Production reads Safari's cookie store.
    var safariCookiesProvider: () -> [HTTPCookie] = { SafariCookieReader.cookies() }
    // Test seam for the player capture session. Production uses WKWebView.
    var browserCaptureLoader: ((URL) async throws -> BrowserCapture)?
    // One WebKit page session at a time. Parallel jobs would each open their own
    // sign-in or verification window; queued, they reuse the first one's result.
    private var webKitSessionBusy = false
    private var webKitSessionWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    // When the user closes a site's window, jobs already queued for that site stop
    // without opening one each. A later retry opens it again.
    private var sessionWindowClosedAt: [String: Date] = [:]

    init(processRunner: YtdlpProcessRunning = DefaultYtdlpProcessRunner()) {
        self.processRunner = processRunner
    }

    /// The store for the current job's egress route. A store's proxy is store-wide,
    /// so jobs on different routes never share a store, and each store's proxy is
    /// set once, at creation: a concurrent job can never change another's route.
    private func webDataStore(
        in stores: inout [String: WKWebsiteDataStore],
        make: () -> WKWebsiteDataStore
    ) -> WKWebsiteDataStore {
        let route = EgressBoundary.proxyURL ?? ""
        if let store = stores[route] { return store }
        let store = make()
        store.proxyConfigurations = EgressBoundary.webKitProxyConfigurations
        stores[route] = store
        return store
    }

    func withExclusiveWebKitSession<T>(_ body: () async throws -> T) async throws -> T {
        if webKitSessionBusy {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    webKitSessionWaiters.append((id, continuation))
                }
            } onCancel: {
                Task { @MainActor in self.cancelWebKitSessionWait(id) }
            }
        } else {
            webKitSessionBusy = true
        }
        // The session passes straight to the next waiter, so it is never free in between.
        defer {
            if webKitSessionWaiters.isEmpty {
                webKitSessionBusy = false
            } else {
                webKitSessionWaiters.removeFirst().continuation.resume()
            }
        }
        return try await body()
    }

    private func cancelWebKitSessionWait(_ id: UUID) {
        guard let index = webKitSessionWaiters.firstIndex(where: { $0.id == id }) else { return }
        webKitSessionWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func mayOpenSessionWindow(for site: String, requestedAt: Date) -> Bool {
        (sessionWindowClosedAt[site] ?? .distantPast) < requestedAt
    }

    nonisolated static func verifySHA256(fileURL: URL, expectedHash: String) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1 MB buffer for streaming hash calculation
        while true {
            guard let data = try? fileHandle.read(upToCount: bufferSize), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        let hashString = digest.map { String(format: "%02x", $0) }.joined()
        return hashString.caseInsensitiveCompare(expectedHash) == .orderedSame
    }

    /// Hashes off the main actor: the three pinned binaries are ~130 MB, which
    /// stalled the UI for ~0.3 s at launch when verified inline.
    nonisolated static func verifySHA256Detached(fileURL: URL, expectedHash: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            verifySHA256(fileURL: fileURL, expectedHash: expectedHash)
        }.value
    }

    /// Signed stream URLs in reused metadata must still be valid when the
    /// download starts; YouTube's last hours, other CDNs much less.
    static let reusableInfoMaxAge: TimeInterval = 10 * 60

    nonisolated static func isPathContained(targetURL: URL, inside parentDirectoryURL: URL) -> Bool {
        let root = parentDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = targetURL.standardizedFileURL.resolvingSymlinksInPath()
        if root.path == "/" {
            return candidate.path.hasPrefix("/")
        }
        return candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    nonisolated static let supportedMediaExtensions: Set<String> = [
        "mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "wmv", "ts",
        "mp3", "m4a", "aac", "flac", "wav", "opus", "ogg", "alac", "aiff"
    ]

    nonisolated static func isMediaFilePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedMediaExtensions.contains(ext)
    }

    nonisolated static func findAria2cPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c",
            "/usr/bin/aria2c"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isExecutableBinary(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && FileManager.default.isExecutableFile(atPath: url.path)
    }

    enum TransactionalInstallError: LocalizedError {
        case validationFailed(String)
        case rollbackFailed(destination: String, underlyingError: Error)
        case installationFailed(destination: String, underlyingError: Error)

        var errorDescription: String? {
            switch self {
            case .validationFailed(let msg):
                return "Validation failed: \(msg)"
            case .rollbackFailed(let dest, let err):
                return "CRITICAL: Rollback failed for \(dest): \(err.localizedDescription)"
            case .installationFailed(let dest, let err):
                return "Installation failed for \(dest): \(err.localizedDescription)"
            }
        }
    }

    func transactionalInstall(from source: URL, to destination: URL, validate: (URL) async -> Bool) async throws -> Bool {
        let fm = FileManager.default
        let backupDestination = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".backup_\(UUID().uuidString)")
        try? fm.removeItem(at: backupDestination)

        let hadOldBinary = fm.fileExists(atPath: destination.path)
        if hadOldBinary {
            try fm.moveItem(at: destination, to: backupDestination)
        }

        do {
            try fm.moveItem(at: source, to: destination)
            let isValid = await validate(destination)
            if isValid {
                if hadOldBinary {
                    try? fm.removeItem(at: backupDestination)
                }
                return true
            } else {
                // Post-validation failed: remove new binary and restore backup
                try? fm.removeItem(at: destination)
                if hadOldBinary {
                    do {
                        try fm.moveItem(at: backupDestination, to: destination)
                    } catch {
                        LoggerService.shared.log("CRITICAL: Failed to restore backup from \(backupDestination.path) to \(destination.path): \(error.localizedDescription)", level: .error)
                        throw TransactionalInstallError.rollbackFailed(destination: destination.path, underlyingError: error)
                    }
                }
                return false
            }
        } catch let error as TransactionalInstallError {
            throw error
        } catch {
            if hadOldBinary && !fm.fileExists(atPath: destination.path) {
                do {
                    try fm.moveItem(at: backupDestination, to: destination)
                } catch {
                    LoggerService.shared.log("CRITICAL: Failed to restore backup from \(backupDestination.path) to \(destination.path): \(error.localizedDescription)", level: .error)
                    throw TransactionalInstallError.rollbackFailed(destination: destination.path, underlyingError: error)
                }
            }
            throw TransactionalInstallError.installationFailed(destination: destination.path, underlyingError: error)
        }
    }

    private func repairAppSupportFfmpegPair(ffmpeg: URL, ffprobe: URL) async {
        let ffmpegValid = await Self.verifySHA256Detached(fileURL: ffmpeg, expectedHash: DependencyChecksums.ffmpegExecutableSHA256)
        let ffprobeValid = await Self.verifySHA256Detached(fileURL: ffprobe, expectedHash: DependencyChecksums.ffprobeExecutableSHA256)
        if !isExecutableBinary(at: ffmpeg) || !isExecutableBinary(at: ffprobe) || !ffmpegValid || !ffprobeValid {
            LoggerService.shared.log("Downloading atomic FFmpeg and FFprobe bundle in \(ffmpeg.deletingLastPathComponent().path)", level: .info)
            await downloadFfmpegAndFfprobeBundle()
        }
    }

    nonisolated static func createSanitizedEnvironment() -> [String: String] {
        let appSupport = Self.getAppSupportDirectory()
        let isolatedHome = appSupport.appendingPathComponent("SandboxHome")
        if !FileManager.default.fileExists(atPath: isolatedHome.path) {
            try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: isolatedHome.path)
        }

        let homeDir = NSHomeDirectory()
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDir)/.bun/bin",
            "\(homeDir)/.deno/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var env: [String: String] = [:]
        env["PATH"] = searchPaths.joined(separator: ":")
        env["HOME"] = homeDir
        env["TMPDIR"] = FileManager.default.temporaryDirectory.path
        env["XDG_CONFIG_HOME"] = isolatedHome.appendingPathComponent(".config").path
        env["XDG_CACHE_HOME"] = isolatedHome.appendingPathComponent(".cache").path
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }

    private func cleanStaleArtifacts() {
        let appSupport = Self.getAppSupportDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("yt-dlp.tmp_") || name.hasPrefix("ffmpeg_") || name.hasPrefix("ffprobe_") || name.contains(".backup_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func setupBinaries() async {
        if let existing = activeSetupTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            cleanStaleArtifacts()
            await findYtdlp()
            await findFfmpeg()
            await getVersion()
        }
        activeSetupTask = task
        await task.value
        activeSetupTask = nil
    }

    /// Locations checked for a user-installed yt-dlp when no explicit path is
    /// set: Homebrew, pipx/`pip install --user`, and the system prefix.
    nonisolated static let ytdlpSearchPaths: [String] = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        NSHomeDirectory() + "/.local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
    ]

    /// The user's yt-dlp: the path chosen in Settings, else the first
    /// executable in `ytdlpSearchPaths`. Not checksum-verified by design.
    nonisolated static func userYtdlpPath(
        customPath: String? = UserDefaults.standard.string(forKey: UserDefaultsKeys.customYtdlpPath),
        searchPaths: [String] = ytdlpSearchPaths,
        fileManager: FileManager = .default
    ) -> URL? {
        let custom = (customPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = custom.isEmpty ? searchPaths : [(custom as NSString).expandingTildeInPath]
        return candidates.first { isRegularExecutable($0, fileManager: fileManager) }.map { URL(fileURLWithPath: $0) }
    }

    nonisolated static func isRegularExecutable(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: path)
    }

    /// yt-dlp prints a date version such as `2026.09.30` or `2026.09.30.232921`.
    nonisolated static func isYtdlpVersion(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^\d{4}\.\d{2}\.\d{2}(\.\d+)?$"#, options: .regularExpression) != nil
    }

    /// The yt-dlp every code path must run. With user-provided yt-dlp only the
    /// validated `ytdlpPath` counts; a stale bundled or App Support copy never does.
    var resolvedYtdlpBinary: URL? {
        if !DependencyChecksums.managedYtdlpEnabled { return ytdlpPath }
        let installed = Self.getAppSupportDirectory().appendingPathComponent("yt-dlp")
        return ytdlpPath ?? Bundle.main.url(forResource: "yt-dlp", withExtension: nil)
            ?? (FileManager.default.fileExists(atPath: installed.path) ? installed : nil)
    }

    func findYtdlp() async {
        if ytdlpPath != nil && !(processRunner is DefaultYtdlpProcessRunner) {
            return
        }
        if !DependencyChecksums.managedYtdlpEnabled {
            ytdlpPath = nil
            isAvailable = false
            version = nil
            guard let candidate = Self.userYtdlpPath() else {
                LoggerService.shared.log("No yt-dlp found. Set its path in Settings > Advanced.", level: .warning)
                return
            }
            // Commit only a binary that identifies itself as yt-dlp.
            do {
                let output = try await processRunner.runCommand([candidate.path, "--ignore-config", "--version"])
                guard Self.isYtdlpVersion(output) else {
                    LoggerService.shared.log("\(candidate.path) is not yt-dlp (unexpected --version output).", level: .warning)
                    return
                }
                version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                LoggerService.shared.log("\(candidate.path) failed its yt-dlp version check: \(error.localizedDescription)", level: .warning)
                return
            }
            ytdlpPath = candidate
            isAvailable = true
            LoggerService.shared.log("Using user-provided yt-dlp at \(candidate.path)", level: .info)
            return
        }
        let appSupport = Self.getAppSupportDirectory()
        let invalidBackup = appSupport.appendingPathComponent("yt-dlp.invalid-backup")

        if let bundledPath = Bundle.main.url(forResource: "yt-dlp", withExtension: nil),
           await Self.verifySHA256Detached(fileURL: bundledPath, expectedHash: DependencyChecksums.ytdlpExecutableSHA256) {
            ytdlpPath = bundledPath
            isAvailable = true
            try? FileManager.default.removeItem(at: invalidBackup)
            return
        }

        let ytdlpInSupport = appSupport.appendingPathComponent("yt-dlp")

        if FileManager.default.fileExists(atPath: ytdlpInSupport.path) {
            if await Self.verifySHA256Detached(fileURL: ytdlpInSupport, expectedHash: DependencyChecksums.ytdlpExecutableSHA256) {
                ytdlpPath = ytdlpInSupport
                try? DependencyInstaller.adHocSignBinary(at: ytdlpInSupport)
                isAvailable = true
                try? FileManager.default.removeItem(at: invalidBackup)
                return
            } else {
                LoggerService.shared.log("yt-dlp binary in App Support failed SHA-256 verification. Preserving invalid backup and downloading pinned version.", level: .warning)
                try? FileManager.default.removeItem(at: invalidBackup)
                try? FileManager.default.moveItem(at: ytdlpInSupport, to: invalidBackup)
            }
        }

        await downloadYtdlp()
    }




    func downloadYtdlp() async {
        do {
            _ = try await updateYtdlp()
        } catch {
            LoggerService.shared.log("Failed to update yt-dlp: \(error.localizedDescription)", level: .error)
        }
    }

    func findFfmpeg() async {
        if ffmpegPath != nil || !(processRunner is DefaultYtdlpProcessRunner) {
            return
        }
        let appSupport = Self.getAppSupportDirectory()
        let ffmpegInSupport = appSupport.appendingPathComponent("ffmpeg")
        let ffprobeInSupport = appSupport.appendingPathComponent("ffprobe")

        ffmpegPath = nil
        ffprobePath = nil

        let bundledFfmpeg = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)
        let bundledFfprobe = Bundle.main.url(forResource: "ffprobe", withExtension: nil)
        if let bundledFfmpeg,
           let bundledFfprobe,
           await validateFfmpegPair(ffmpeg: bundledFfmpeg, ffprobe: bundledFfprobe, context: "bundled") {
            setFfmpegPaths(ffmpeg: bundledFfmpeg, ffprobe: bundledFfprobe, source: "bundled")
            return
        } else if bundledFfmpeg != nil || bundledFfprobe != nil {
            LoggerService.shared.log("Bundled FFmpeg/FFprobe pair is incomplete or invalid; repairing app-support binaries.", level: .warning)
            await repairAppSupportFfmpegPair(ffmpeg: ffmpegInSupport, ffprobe: ffprobeInSupport)
        }

        if await validateFfmpegPair(ffmpeg: ffmpegInSupport, ffprobe: ffprobeInSupport, context: "app-support") {
            setFfmpegPaths(ffmpeg: ffmpegInSupport, ffprobe: ffprobeInSupport, source: "app-support")
            return
        }

        await repairAppSupportFfmpegPair(ffmpeg: ffmpegInSupport, ffprobe: ffprobeInSupport)
        if await validateFfmpegPair(ffmpeg: ffmpegInSupport, ffprobe: ffprobeInSupport, context: "app-support repaired") {
            setFfmpegPaths(ffmpeg: ffmpegInSupport, ffprobe: ffprobeInSupport, source: "app-support repaired")
            return
        }

        LoggerService.shared.log("FFmpeg installation failed. Attempted path: \(appSupport.path)", level: .error)
    }

    private func validateBinary(_ url: URL, name: String, expectedSHA256: String, context: String) async -> Bool {
        guard isExecutableBinary(at: url) else {
            LoggerService.shared.log("\(name) at \(url.path) is missing or not executable for \(context).", level: .warning)
            return false
        }

        guard await Self.verifySHA256Detached(fileURL: url, expectedHash: expectedSHA256) else {
            LoggerService.shared.log("\(name) at \(url.path) failed SHA-256 checksum verification for \(context). Expected: \(expectedSHA256)", level: .error)
            return false
        }

        do {
            _ = try await runCommand([url.path, "-version"])
            LoggerService.shared.log("Cryptographically validated \(name) at \(url.path) for \(context).", level: .info)
            return true
        } catch {
            LoggerService.shared.log("Failed to validate \(name) at \(url.path) for \(context): \(error.localizedDescription)", level: .error)
            return false
        }
    }

    private func validateFfmpegPair(ffmpeg: URL, ffprobe: URL, context: String) async -> Bool {
        let ffmpegValid = await validateBinary(ffmpeg, name: "FFmpeg", expectedSHA256: DependencyChecksums.ffmpegExecutableSHA256, context: context)
        let ffprobeValid = await validateBinary(ffprobe, name: "FFprobe", expectedSHA256: DependencyChecksums.ffprobeExecutableSHA256, context: context)
        return ffmpegValid && ffprobeValid
    }

    private func setFfmpegPaths(ffmpeg: URL, ffprobe: URL, source: String) {
        ffmpegPath = ffmpeg
        ffprobePath = ffprobe
        try? DependencyInstaller.adHocSignBinary(at: ffmpeg)
        try? DependencyInstaller.adHocSignBinary(at: ffprobe)
        LoggerService.shared.log("Selected \(source) FFmpeg path: \(ffmpeg.path)", level: .info)
        LoggerService.shared.log("Selected \(source) FFprobe path: \(ffprobe.path)", level: .info)
    }

    func downloadFfmpegAndFfprobeBundle() async {
        let appSupport = Self.getAppSupportDirectory()
        LoggerService.shared.log("Safely downloading atomic FFmpeg + FFprobe bundle from \(DependencyChecksums.ffmpegURL) and \(DependencyChecksums.ffprobeURL)", level: .info)
        do {
            let (ffmpegURL, ffprobeURL) = try await DependencyInstaller.shared.installFfmpegBundle(
                ffmpegURL: DependencyChecksums.ffmpegURL,
                ffmpegArchiveSHA256: DependencyChecksums.ffmpegArchiveSHA256,
                ffmpegExecutableSHA256: DependencyChecksums.ffmpegExecutableSHA256,
                ffprobeURL: DependencyChecksums.ffprobeURL,
                ffprobeArchiveSHA256: DependencyChecksums.ffprobeArchiveSHA256,
                ffprobeExecutableSHA256: DependencyChecksums.ffprobeExecutableSHA256,
                appSupportDir: appSupport
            )
            setFfmpegPaths(ffmpeg: ffmpegURL, ffprobe: ffprobeURL, source: "downloaded bundle")
        } catch {
            LoggerService.shared.log("Failed to download atomic FFmpeg/FFprobe bundle: \(error.localizedDescription)", level: .error)
        }
    }

    func updateYtdlp() async throws -> String {
        guard !isUpdating else {
            throw YtdlpUpdateError.alreadyInProgress
        }
        isUpdating = true
        updateProgress = 0.1
        defer {
            updateProgress = 1.0
            isUpdating = false
        }

        if let handler = updateYtdlpHandler {
            let installedVersion = try await handler()
            version = installedVersion
            return installedVersion
        }

        // The pin is the newest yt-dlp Siphon has verified. When that build is
        // already installed, downloading it again cannot produce a newer one.
        if let currentPath = ytdlpPath,
           await Self.verifySHA256Detached(fileURL: currentPath, expectedHash: DependencyChecksums.ytdlpExecutableSHA256) {
            if version == nil {
                await getVersion()
            }
            return version ?? DependencyChecksums.ytdlpVersion
        }

        let downloadURL = DependencyChecksums.ytdlpURL
        let appSupport = Self.getAppSupportDirectory()
        let destination = appSupport.appendingPathComponent("yt-dlp")

        LoggerService.shared.log("Safely downloading yt-dlp binary from \(downloadURL)", level: .info)

        do {
            let installedURL = try await DependencyInstaller.shared.installYtdlp(
                downloadURL: downloadURL,
                expectedSHA256: DependencyChecksums.ytdlpExecutableSHA256,
                appSupportDir: appSupport,
                onProgress: { [weak self] p in
                    Task { @MainActor in
                        self?.updateProgress = p
                    }
                }
            )
            ytdlpPath = installedURL
            isAvailable = true
            updateProgress = 0.9
            await getVersion()
            let installedVersion = version ?? "unknown"
            LoggerService.shared.log("yt-dlp verified and updated successfully to version \(installedVersion)", level: .info)
            return installedVersion
        } catch {
            isAvailable = FileManager.default.fileExists(atPath: destination.path)
            LoggerService.shared.log("Failed to update yt-dlp: \(error.localizedDescription)", level: .error)
            throw error
        }
    }



    func getVersion() async {
        guard let path = ytdlpPath else { return }

        do {
            let output = try await runCommand([path.path, "--ignore-config", "--version"])
            version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            LoggerService.shared.log("Failed to get yt-dlp version: \(error)", level: .warning)
        }
    }




    private func isPlaylistURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else {
            return (urlString.contains("list=") || urlString.contains("/playlist/")) && !urlString.contains("/videos/")
        }
        let path = components.path.lowercased()
        if path.contains("/playlist") || path.contains("/sets/") || path.contains("/album/") {
            return !path.contains("/videos/")
        }
        if let queryItems = components.queryItems {
            let hasListQuery = queryItems.contains(where: { $0.name.lowercased() == "list" || $0.name.lowercased() == "p" })
            let isSingleVideoPath = path.contains("/watch") || path.contains("/videos/") || path.contains("/video/")
            return hasListQuery && !isSingleVideoPath
        }
        return false
    }

    func fetchInfo(
        url: String,
        rawCookies: String? = nil,
        rawUserAgent: String? = nil,
        browserCookieSource: String? = nil,
        proxy: String? = nil
    ) async throws -> MediaInfo {
        // Site resolvers make their own requests; the binding routes those too.
        try await EgressBoundary.$proxyURL.withValue(proxy ?? EgressBoundary.proxyURL) {
            try await fetchInfoWithinBoundary(
                url: url,
                rawCookies: rawCookies,
                rawUserAgent: rawUserAgent,
                browserCookieSource: browserCookieSource,
                proxy: proxy
            )
        }
    }

    private func fetchInfoWithinBoundary(
        url: String,
        rawCookies: String?,
        rawUserAgent: String?,
        browserCookieSource: String?,
        proxy: String?
    ) async throws -> MediaInfo {
        guard let path = ytdlpPath else {
            throw YtdlpError.notFound
        }
        
        let normalizedURL = normalizeURLForYtdlp(url)
        // Try the flat summary first: --dump-json on a playlist URL fully extracts
        // every entry (about 1.4 s per YouTube video) before failing to decode.
        if isPlaylistURL(normalizedURL) {
            do {
                return try await fetchPlaylistSummaryInfo(
                    path: path.path,
                    url: normalizedURL,
                    rawCookies: rawCookies,
                    rawUserAgent: rawUserAgent,
                    browserCookieSource: browserCookieSource,
                    proxy: proxy
                )
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                LoggerService.shared.log("Playlist summary unavailable for \(hostForLog(normalizedURL)) (\(error.localizedDescription)); trying single-video metadata", level: .info)
            }
        }
        let info: MediaInfo
        do {
            info = try await fetchSingleVideoInfo(
                path: path.path,
                url: normalizedURL,
                rawCookies: rawCookies,
                rawUserAgent: rawUserAgent,
                browserCookieSource: browserCookieSource,
                proxy: proxy
            )
        } catch {
            throw mapSiteSpecificError(
                error,
                url: normalizedURL,
                browserCookieSource: browserCookieSource
            )
        }
        if let json = info.rawJSON, Self.isTwinkabooPromo(pageURL: normalizedURL, infoJSON: json) {
            LoggerService.shared.log("[ProtectedSite] twinkaboo returned only its sponsored promo; not saving it as the video", level: .warning)
            throw YtdlpError.downloadFailed("Twinkaboo plays this video through an encrypted player that Siphon doesn't support. The only other video on the page is the site's sponsored promo, so Siphon didn't download anything.")
        }
        return info
    }

    /// Twinkaboo's player loads the scene from an encrypted playlist. yt-dlp's
    /// generic extractor then falls through to the only plain <video> on the
    /// page: a sponsored promo served from the site's asset host.
    nonisolated static func isTwinkabooPromo(pageURL: String, infoJSON: Data) -> Bool {
        guard let host = URL(string: pageURL)?.host?.lowercased(),
              host == "twinkaboo.com" || host.hasSuffix(".twinkaboo.com"),
              let json = try? JSONSerialization.jsonObject(with: infoJSON) as? [String: Any] else {
            return false
        }
        let formats = (json["formats"] as? [[String: Any]]) ?? [json]
        let mediaHosts = formats.compactMap { ($0["url"] as? String).flatMap { URL(string: $0)?.host?.lowercased() } }
        return !mediaHosts.isEmpty && mediaHosts.allSatisfy { $0 == "assets.twinkaboo.com" }
    }

    private func fetchSingleVideoInfo(
        path: String,
        url: String,
        forceBrowserCookies: Bool = false,
        rawCookies: String? = nil,
        rawUserAgent: String? = nil,
        browserCookieSource: String? = nil,
        proxy: String? = nil
    ) async throws -> MediaInfo {
        if isRecuURL(url) {
            let recuMedia = try await resolveRecuMediaInfo(url: url)
            var parsedInfo: MediaInfo?
            var probeArgs = [
                path,
                "--ignore-config",
                "--dump-json",
                "--no-playlist",
                "--no-warnings"
            ]
            if let userAgent = recuMedia.userAgent, !userAgent.isEmpty {
                probeArgs.append(contentsOf: ["--user-agent", userAgent])
            }
            probeArgs.append(contentsOf: ["--add-header", "Origin:https://recu.me"])
            probeArgs.append(contentsOf: ["--add-header", "Referer:\(recuMedia.pageURL)"])
            if let proxy = proxy, !proxy.isEmpty {
                probeArgs.append(contentsOf: ["--proxy", proxy])
            }
            probeArgs.append("--")
            probeArgs.append(recuMedia.playlistURL)

            do {
                let output = try await runCommand(probeArgs)
                if let data = output.data(using: .utf8) {
                    parsedInfo = try? JSONDecoder().decode(MediaInfo.self, from: data)
                }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                LoggerService.shared.log("[ProtectedSite] playlist metadata probe failed; using synthesized HLS metadata", level: .debug)
            }

            let fallbackFormat = MediaFormat(
                formatId: "hls",
                ext: "mp4",
                resolution: nil,
                fps: nil,
                vcodec: nil,
                acodec: nil,
                tbr: nil
            )
            return MediaInfo(
                id: recuMedia.videoID,
                title: recuMedia.title,
                description: parsedInfo?.description,
                thumbnail: parsedInfo?.thumbnail ?? recuMedia.thumbnailURL,
                duration: parsedInfo?.duration,
                uploader: parsedInfo?.uploader ?? recuMedia.model,
                uploadDate: parsedInfo?.uploadDate,
                viewCount: parsedInfo?.viewCount,
                likeCount: parsedInfo?.likeCount,
                formats: parsedInfo?.formats?.isEmpty == false ? parsedInfo?.formats : [fallbackFormat],
                subtitles: parsedInfo?.subtitles,
                automaticCaptions: parsedInfo?.automaticCaptions,
                chapters: parsedInfo?.chapters,
                playlist: nil,
                playlistIndex: nil,
                playlistCount: nil,
                webpageUrl: recuMedia.pageURL,
                originalUrl: recuMedia.playlistURL,
                formatProtocol: "m3u8_native",
                manifestUrl: recuMedia.playlistURL
            )
        }

        if isGayteamURL(url) {
            return try await resolveGayteamMediaInfo(url: url, path: path, proxy: proxy)
        }

        if isBoyfriendTVURL(url),
           let btvMedia = try await resolveBoyfriendTVMediaInfo(
               url: url,
               rawCookies: rawCookies,
               rawUserAgent: rawUserAgent,
               browserCookieSource: browserCookieSource
           ) {
                var btvArgs = [
                    path,
                    "--ignore-config",
                    "--dump-json",
                    "--no-playlist",
                    "--no-warnings"
                ]
                appendSiteSpecificArgs(for: btvMedia.embedURL, to: &btvArgs)
                if let proxy = proxy, !proxy.isEmpty {
                    btvArgs.append(contentsOf: ["--proxy", proxy])
                }
                btvArgs.append("--")
                btvArgs.append(btvMedia.streamURL)
                
                var parsedInfo: MediaInfo? = nil
                do {
                    let output = try await runCommand(btvArgs)
                    if let data = output.data(using: .utf8) {
                        parsedInfo = try? JSONDecoder().decode(MediaInfo.self, from: data)
                    }
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    // If yt-dlp dump-json fails on the stream template, synthesize MediaInfo directly
                }
                try Task.checkCancellation()

                let synthesizedFormats = parseBoyfriendTVFormats(from: btvMedia.streamURL)
                let resolvedFormats = (parsedInfo?.formats?.isEmpty == false) ? parsedInfo?.formats : synthesizedFormats

                return MediaInfo(
                    id: url,
                    title: btvMedia.title,
                    description: parsedInfo?.description,
                    thumbnail: parsedInfo?.thumbnail ?? btvMedia.thumbnailURL,
                    duration: parsedInfo?.duration,
                    uploader: parsedInfo?.uploader ?? "Protected Site",
                    uploadDate: parsedInfo?.uploadDate,
                    viewCount: parsedInfo?.viewCount,
                    likeCount: parsedInfo?.likeCount,
                    formats: resolvedFormats,
                    subtitles: parsedInfo?.subtitles,
                    automaticCaptions: parsedInfo?.automaticCaptions,
                    chapters: parsedInfo?.chapters,
                    playlist: nil,
                    playlistIndex: nil,
                    playlistCount: nil,
                    webpageUrl: btvMedia.embedURL,
                    originalUrl: btvMedia.streamURL,
                    formatProtocol: "m3u8_native",
                    manifestUrl: btvMedia.streamURL
                )
        }

        if isGuywhURL(url),
           let guywhMedia = await resolveGuywhMediaInfo(url: url, rawCookies: rawCookies) {
                let quality = guywhMedia.quality ?? "720p"
                let height = Int(quality.replacingOccurrences(of: "p", with: "")) ?? 720
                let format = MediaFormat(
                    formatId: quality,
                    ext: "mp4",
                    resolution: "\(Int(Double(height) * 16.0 / 9.0))x\(height)",
                    fps: 30.0,
                    vcodec: "h264",
                    acodec: "aac",
                    tbr: 2500,
                    manifestUrl: guywhMedia.streamURL
                )
                return MediaInfo(
                    id: url,
                    title: guywhMedia.title,
                    thumbnail: guywhMedia.thumbnailURL,
                    duration: guywhMedia.duration,
                    uploader: "Protected Site",
                    formats: [format],
                    webpageUrl: guywhMedia.embedURL,
                    originalUrl: guywhMedia.streamURL,
                    formatProtocol: guywhMedia.streamURL.contains(".m3u8") ? "m3u8_native" : "https",
                    manifestUrl: guywhMedia.streamURL
                )
        }

        if isGFFURL(url) {
            LoggerService.shared.log("Initiating protected-site media info resolution for: \(LoggerService.sanitizeURLForLog(url))", level: .info)
            if let gffMedia = await resolveGFFMediaInfo(url: url, rawCookies: rawCookies) {
                LoggerService.shared.log("Protected-site media successfully extracted: '\(gffMedia.title)' with stream: \(LoggerService.sanitizeURLForLog(gffMedia.streamURL))", level: .info)
                let quality = gffMedia.quality ?? "720p"
                let height = Int(quality.replacingOccurrences(of: "p", with: "")) ?? 720
                let format = MediaFormat(
                    formatId: quality,
                    ext: "mp4",
                    resolution: "\(Int(Double(height) * 16.0 / 9.0))x\(height)",
                    fps: 30.0,
                    vcodec: "h264",
                    acodec: "aac",
                    tbr: 2500,
                    manifestUrl: gffMedia.streamURL
                )
                return MediaInfo(
                    id: url,
                    title: gffMedia.title,
                    thumbnail: gffMedia.thumbnailURL,
                    duration: gffMedia.duration,
                    uploader: "Protected Site",
                    formats: [format],
                    webpageUrl: gffMedia.embedURL,
                    originalUrl: gffMedia.streamURL,
                    formatProtocol: gffMedia.streamURL.contains(".m3u8") ? "m3u8_native" : "https",
                    manifestUrl: gffMedia.streamURL
                )
            } else {
                LoggerService.shared.log("Protected-site resolver could not resolve media directly. Falling back to yt-dlp native extraction...", level: .warning)
            }
        }

        if isBestCamURL(url) {
            LoggerService.shared.log("Initiating protected-site media info resolution for: \(LoggerService.sanitizeURLForLog(url))", level: .info)
            if let bestCamMedia = await resolveBestCamMediaInfo(url: url, rawCookies: rawCookies) {
                LoggerService.shared.log("Protected-site media successfully extracted: '\(bestCamMedia.title)' with \(bestCamMedia.allSources.count) format(s)", level: .info)
                let formats: [MediaFormat] = bestCamMedia.allSources.map { src in
                    let quality = src.label
                    let height = Int(quality.replacingOccurrences(of: "p", with: "")) ?? 720
                    return MediaFormat(
                        formatId: quality,
                        ext: "mp4",
                        resolution: "\(Int(Double(height) * 16.0 / 9.0))x\(height)",
                        fps: 30.0,
                        vcodec: src.codec.isEmpty ? "h264" : src.codec,
                        acodec: "aac",
                        tbr: nil,
                        filesize: src.size > 0 ? src.size : nil,
                        formatNote: src.path.components(separatedBy: "/").last,
                        manifestUrl: "\(src.url)/\(src.path)"
                    )
                }
                return MediaInfo(
                    id: url,
                    title: bestCamMedia.title,
                    thumbnail: bestCamMedia.thumbnailURL,
                    duration: bestCamMedia.duration,
                    uploader: "Protected Site",
                    formats: formats.isEmpty ? nil : formats,
                    webpageUrl: bestCamMedia.embedURL,
                    originalUrl: bestCamMedia.streamURL,
                    formatProtocol: bestCamMedia.streamURL.contains(".m3u8") ? "m3u8_native" : "https",
                    manifestUrl: bestCamMedia.streamURL
                )
            } else {
                LoggerService.shared.log("Protected-site resolver could not resolve media directly. Falling back to yt-dlp native extraction...", level: .warning)
            }
        }

        if isStarwankURL(url) {
            LoggerService.shared.log("Initiating protected-site media info resolution for: \(LoggerService.sanitizeURLForLog(url))", level: .info)
            if let starwankMedia = await resolveStarwankMediaInfo(url: url, rawCookies: rawCookies) {
                LoggerService.shared.log("Protected-site media successfully extracted: '\(starwankMedia.title)' with \(starwankMedia.allSources.count) format(s)", level: .info)
                let formats = Self.protectedSiteFormats(
                    from: starwankMedia.allSources.map { ($0.label, $0.url, $0.height) }
                )
                return MediaInfo(
                    id: url,
                    title: starwankMedia.title,
                    thumbnail: starwankMedia.thumbnailURL,
                    duration: starwankMedia.duration,
                    uploader: "StarWank",
                    formats: formats.isEmpty ? nil : formats,
                    webpageUrl: starwankMedia.embedURL,
                    originalUrl: starwankMedia.streamURL,
                    formatProtocol: starwankMedia.streamURL.contains(".m3u8") ? "m3u8_native" : "https",
                    manifestUrl: starwankMedia.streamURL
                )
            } else {
                LoggerService.shared.log("Starwank resolver could not resolve media directly. Falling back to yt-dlp native extraction...", level: .warning)
            }
        }

        if isPussyspaceURL(url) {
            LoggerService.shared.log("Initiating PussySpace media info resolution for: \(LoggerService.sanitizeURLForLog(url))", level: .info)
            if let pussyMedia = await resolvePussyspaceMediaInfo(url: url, rawCookies: rawCookies) {
                LoggerService.shared.log("PussySpace media successfully extracted: '\(pussyMedia.title)' with \(pussyMedia.allSources.count) format(s)", level: .info)
                let formats = Self.protectedSiteFormats(
                    from: pussyMedia.allSources.map { ($0.label, $0.url, $0.height) }
                )
                return MediaInfo(
                    id: url,
                    title: pussyMedia.title,
                    thumbnail: pussyMedia.thumbnailURL,
                    duration: pussyMedia.duration,
                    uploader: "PussySpace",
                    formats: formats.isEmpty ? nil : formats,
                    webpageUrl: pussyMedia.embedURL,
                    originalUrl: pussyMedia.streamURL,
                    formatProtocol: pussyMedia.streamURL.contains(".m3u8") ? "m3u8_native" : "https",
                    manifestUrl: pussyMedia.streamURL
                )
            } else {
                LoggerService.shared.log("PussySpace resolver could not resolve media directly. Falling back to yt-dlp native extraction...", level: .warning)
            }
        }

        var args = [
            path,
            "--ignore-config",
            "--dump-json",
            "--no-playlist",
            "--no-warnings"
        ]
        appendJsRuntimeArgs(to: &args)
        if let proxy = proxy, !proxy.isEmpty {
            args.append(contentsOf: ["--proxy", proxy])
        }
        
        var secureCookieFile: SecureCookieFile? = nil
        defer {
            secureCookieFile?.cleanup()
        }

        let sucuriCookie = await resolveSucuriCookie(for: url)
        var additionalCookies: [(name: String, value: String)] = []
        if let sc = sucuriCookie {
            additionalCookies.append((name: sc.name, value: sc.value))
        }

        if (rawCookies?.isEmpty == false) || !additionalCookies.isEmpty {
            if let cookieFile = try? SecureCookieFile.create(url: url, rawCookies: rawCookies, additionalCookies: additionalCookies) {
                secureCookieFile = cookieFile
                args.append(contentsOf: ["--cookies", cookieFile.path])
                if sucuriCookie != nil {
                    LoggerService.shared.log("Using temporary Sucuri cookie in consolidated file for \(hostForLog(url)) (cookie values not logged)", level: .info)
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
                }
                if let raw = rawCookies, !raw.isEmpty {
                    LoggerService.shared.log("Using session cookies passed from browser extension for \(hostForLog(url))", level: .info)
                }
            }
        } else {
            let usingBrowserCookies = appendCookieArgs(
                for: url,
                to: &args,
                force: forceBrowserCookies,
                browserOverride: browserCookieSource
            )
            logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)
        }

        appendSiteSpecificArgs(for: url, rawUserAgent: rawUserAgent, to: &args)
        args.append("--")
        args.append(url)
        
        do {
            let output = try await runCommand(args)
            guard let data = output.data(using: .utf8) else { throw YtdlpError.parseError }
            do {
                var info = try JSONDecoder().decode(MediaInfo.self, from: data)
                info.rawJSON = data
                info.fetchedAt = Date()
                return info
            } catch {
                LoggerService.shared.log("Failed to decode MediaInfo JSON: \(error)", level: .error)
                throw YtdlpError.parseError
            }
        } catch {
            let usingBrowserCookies = args.contains("--cookies-from-browser")
            if shouldRetryWithBrowserCookies(
                error: error,
                url: url,
                usingBrowserCookies: usingBrowserCookies,
                forceBrowserCookies: forceBrowserCookies,
                browserCookieSource: browserCookieSource
            ) {
                LoggerService.shared.log("Retrying metadata extraction with configured browser cookies", level: .info)
                return try await fetchSingleVideoInfo(
                    path: path,
                    url: url,
                    forceBrowserCookies: true,
                    rawCookies: rawCookies,
                    rawUserAgent: rawUserAgent,
                    browserCookieSource: browserCookieSource
                )
            }
            throw mapSiteSpecificError(
                error,
                url: url,
                browserCookieSource: browserCookieSource
            )
        }
    }

    private func fetchPlaylistSummaryInfo(
        path: String,
        url: String,
        rawCookies: String? = nil,
        rawUserAgent: String? = nil,
        browserCookieSource: String? = nil,
        proxy: String? = nil
    ) async throws -> MediaInfo {
        var args = [
            path,
            "--ignore-config",
            "--dump-single-json",
            "--flat-playlist",
            "--no-warnings"
        ]
        appendJsRuntimeArgs(to: &args)
        if let proxy = proxy, !proxy.isEmpty {
            args.append(contentsOf: ["--proxy", proxy])
        }
        
        var secureCookieFile: SecureCookieFile? = nil
        defer {
            secureCookieFile?.cleanup()
        }

        let sucuriCookie = await resolveSucuriCookie(for: url)
        var additionalCookies: [(name: String, value: String)] = []
        if let sc = sucuriCookie {
            additionalCookies.append((name: sc.name, value: sc.value))
        }

        if (rawCookies?.isEmpty == false) || !additionalCookies.isEmpty {
            if let cookieFile = try? SecureCookieFile.create(url: url, rawCookies: rawCookies, additionalCookies: additionalCookies) {
                secureCookieFile = cookieFile
                args.append(contentsOf: ["--cookies", cookieFile.path])
                if sucuriCookie != nil {
                    LoggerService.shared.log("Using temporary Sucuri cookie in consolidated file for \(hostForLog(url)) (cookie values not logged)", level: .info)
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
                }
                if let raw = rawCookies, !raw.isEmpty {
                    LoggerService.shared.log("Using session cookies passed from browser extension for \(hostForLog(url))", level: .info)
                }
            }
        } else {
            let usingBrowserCookies = appendCookieArgs(for: url, to: &args, browserOverride: browserCookieSource)
            logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)
        }

        if let exactUA = rawUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !exactUA.isEmpty {
            args.append(contentsOf: ["--user-agent", exactUA])
            args.append(contentsOf: [
                "--extractor-args",
                "generic:impersonate=\(recuImpersonationTarget(rawUserAgent: exactUA, browserCookieSource: browserCookieSource))"
            ])
        } else {
            args.append(contentsOf: [
                "--extractor-args",
                "generic:impersonate=\(recuImpersonationTarget(rawUserAgent: nil, browserCookieSource: browserCookieSource))"
            ])
        }
        args.append("--")
        args.append(url)

        let output = try await runCommand(args)
        guard let data = output.data(using: .utf8) else { throw YtdlpError.parseError }

        let decoder = JSONDecoder()
        // A playlist-looking URL (for example a "?p=" post link) can resolve to a
        // single video; only a real playlist may be summarized without formats.
        struct ResultKind: Decodable { let _type: String? }
        guard (try? decoder.decode(ResultKind.self, from: data))?._type == "playlist" else {
            throw YtdlpError.parseError
        }
        let info = try decoder.decode(MediaInfo.self, from: data)

        return MediaInfo(
            id: info.id,
            title: info.title,
            description: info.description,
            thumbnail: info.thumbnail, // Bazen playlist thumbnail gelir
            duration: nil,
            uploader: info.uploader,
            uploadDate: nil,
            viewCount: info.viewCount,
            likeCount: nil,
            formats: nil,
            subtitles: nil,
            automaticCaptions: nil,
            chapters: nil,
            playlist: info.id, // Playlist olduğunu belirtmek için ID'yi buraya da koyuyoruz
            playlistIndex: nil,
            playlistCount: info.playlistCount ?? info.viewCount // Bazen viewCount yerine entry count gelebilir
        )
    }


    func fetchPlaylistInfo(
        url: String,
        rawCookies: String? = nil,
        rawUserAgent: String? = nil,
        browserCookieSource: String? = nil,
        proxy: String? = nil
    ) async throws -> [MediaInfo] {
        guard let path = ytdlpPath else {
            throw YtdlpError.notFound
        }

        var args = [
            path.path,
            "--ignore-config",
            "--dump-json",
            "--flat-playlist",
            "--no-warnings"
        ]
        appendJsRuntimeArgs(to: &args)
        if let proxy = proxy, !proxy.isEmpty {
            args.append(contentsOf: ["--proxy", proxy])
        }
        
        var secureCookieFile: SecureCookieFile? = nil
        defer {
            secureCookieFile?.cleanup()
        }

        let sucuriCookie = await resolveSucuriCookie(for: url)
        var additionalCookies: [(name: String, value: String)] = []
        if let sc = sucuriCookie {
            additionalCookies.append((name: sc.name, value: sc.value))
        }

        if (rawCookies?.isEmpty == false) || !additionalCookies.isEmpty {
            if let cookieFile = try? SecureCookieFile.create(url: url, rawCookies: rawCookies, additionalCookies: additionalCookies) {
                secureCookieFile = cookieFile
                args.append(contentsOf: ["--cookies", cookieFile.path])
                if sucuriCookie != nil {
                    LoggerService.shared.log("Using temporary Sucuri cookie in consolidated file for \(hostForLog(url)) (cookie values not logged)", level: .info)
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
                }
                if let raw = rawCookies, !raw.isEmpty {
                    LoggerService.shared.log("Using session cookies passed from browser extension for \(hostForLog(url))", level: .info)
                }
            }
        } else {
            let usingBrowserCookies = appendCookieArgs(for: url, to: &args, browserOverride: browserCookieSource)
            logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)
        }

        let parsedHost = (URL(string: url)?.host ?? url).lowercased()
        let isYouTube = parsedHost == "youtube.com" || parsedHost.hasSuffix(".youtube.com") || parsedHost == "youtu.be" || parsedHost.hasSuffix(".youtu.be")
        if let exactUA = rawUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !exactUA.isEmpty {
            args.append(contentsOf: ["--user-agent", exactUA])
            args.append(contentsOf: ["--add-header", "Accept-Language:en-US,en;q=0.9"])
            if !isYouTube {
                args.append(contentsOf: [
                    "--extractor-args",
                    "generic:impersonate=\(recuImpersonationTarget(rawUserAgent: exactUA, browserCookieSource: browserCookieSource))"
                ])
            }
        } else if !isYouTube {
            args.append(contentsOf: [
                "--extractor-args",
                "generic:impersonate=\(recuImpersonationTarget(rawUserAgent: nil, browserCookieSource: browserCookieSource))"
            ])
        }
        args.append("--")
        args.append(url)

        let output = try await runCommand(args)

        var results: [MediaInfo] = []
        let decoder = JSONDecoder()

        // Bolt Performance Optimization: Avoid intermediate String allocations when splitting
        if let data = output.data(using: .utf8) {
            let newline = UInt8(ascii: "\n")
            data.split(separator: newline).forEach { lineData in
                if !lineData.isEmpty,
                   let info = try? decoder.decode(MediaInfo.self, from: Data(lineData)) {
                    results.append(info)
                }
            }
        }

        return results
    }




public struct DownloadResult: Sendable {
    public let files: [URL]
    public let primaryFile: URL?

    public init(files: [URL], primaryFile: URL? = nil) {
        self.files = files
        self.primaryFile = primaryFile ?? files.first
    }

    public var path: String {
        (primaryFile ?? files.first)?.path ?? ""
    }

    public var lastPathComponent: String {
        (primaryFile ?? files.first)?.lastPathComponent ?? ""
    }
}

    private struct ReusedDirectMedia {
        let streamURL: String
        let title: String?
        let embedURL: String?
        let thumbnailURL: String?
        let formatNote: String?
    }

    private func reusedDirectMedia(
        mediaInfo: MediaInfo?,
        selectedFormatId: String?,
        normalizedURL: String,
        fallbackEmbedURL: String,
        fallbackIsAllowed: (String) -> Bool = { _ in true }
    ) -> ReusedDirectMedia? {
        if let selectedId = selectedFormatId,
           let matched = mediaInfo?.formats?.first(where: {
               $0.formatId.lowercased() == selectedId.lowercased() ||
               $0.formatId.replacingOccurrences(of: "p", with: "").lowercased() ==
                   selectedId.replacingOccurrences(of: "p", with: "").lowercased()
           }),
           let streamURL = matched.manifestUrl,
           !streamURL.isEmpty {
            return ReusedDirectMedia(
                streamURL: streamURL,
                title: mediaInfo?.title,
                embedURL: mediaInfo?.webpageUrl ?? fallbackEmbedURL,
                thumbnailURL: mediaInfo?.thumbnail,
                formatNote: matched.formatNote
            )
        }

        if let streamURL = mediaInfo?.manifestUrl ?? mediaInfo?.originalUrl,
           !streamURL.isEmpty,
           streamURL != normalizedURL,
           fallbackIsAllowed(streamURL) {
            return ReusedDirectMedia(
                streamURL: streamURL,
                title: mediaInfo?.title,
                embedURL: mediaInfo?.webpageUrl ?? fallbackEmbedURL,
                thumbnailURL: mediaInfo?.thumbnail,
                formatNote: nil
            )
        }

        return nil
    }

    private static func protectedSiteFormats(
        from sources: [(label: String, url: String, height: Int)]
    ) -> [MediaFormat] {
        sources.map { source in
            MediaFormat(
                formatId: source.label,
                ext: "mp4",
                resolution: "\(Int(Double(source.height) * 16.0 / 9.0))x\(source.height)",
                fps: 30.0,
                vcodec: "h264",
                acodec: "aac",
                tbr: nil,
                filesize: nil,
                manifestUrl: source.url
            )
        }
    }

    func download(
        url: String,
        options: DownloadOptions,
        mediaInfo: MediaInfo? = nil,
        processController: DownloadProcessController? = nil,
        temporaryDirectory: URL? = nil,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DownloadResult {
        // Only DRM is final. A failed format check may be a transient CDN error,
        // and signed streams are extracted and checked again by the download.
        if let formats = mediaInfo?.formats, !formats.isEmpty {
            if formats.allSatisfy(\.isKnownDRM) { throw YtdlpError.noDownloadableFormats }
            if let selection = options.selectedFormatId {
                let ids = selection.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
                if formats.contains(where: { $0.isKnownDRM && ids.contains($0.formatId) }) {
                    throw YtdlpError.downloadFailed(LanguageService.s("drm_protected"))
                }
            }
        }
        let boundaryProxy = options.enforcePublicNetworkBoundary ? try await egressProxyURL() : nil
        return try await EgressBoundary.$proxyURL.withValue(boundaryProxy) {
            try await downloadWithinBoundary(
                url: url,
                options: options,
                mediaInfo: mediaInfo,
                processController: processController,
                temporaryDirectory: temporaryDirectory,
                onProgress: onProgress,
                onOutput: onOutput
            )
        }
    }

    private func downloadWithinBoundary(
        url: String,
        options: DownloadOptions,
        mediaInfo: MediaInfo?,
        processController: DownloadProcessController?,
        temporaryDirectory: URL?,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DownloadResult {
        guard let path = ytdlpPath else {
            throw YtdlpError.notFound
        }
        let normalizedURL = normalizeURLForYtdlp(url)
        var targetURL = normalizedURL
        var customResolvedTitle: String? = nil
        var customEmbedURL: String? = nil
        var customThumbnailURL: String? = nil
        var bestCamDecryptionKey: String? = nil
        // Protected-site resolvers default to their first source. Without an
        // explicit pick, reuse the source the selection logic chose so the
        // resolution ceiling applies to the stream actually downloaded.
        let protectedFormatId = options.selectedFormatId
            ?? mediaInfo?.resolveSelectedFormats(options: options).first(where: { !$0.isAudioOnly })?.formatId

        var recuUserAgent: String?
        if isRecuURL(url) {
            // Time ranges download through ffmpeg, which cannot add the segment `check`
            // parameter below, so every segment would fail with 422.
            if let start = options.timeFrameStart, let end = options.timeFrameEnd,
               Self.isValidTimeFrame(start), Self.isValidTimeFrame(end) {
                throw YtdlpError.downloadFailed("Recu.me recordings can't be trimmed yet. Clear the time range to download the full recording.")
            }
            // Recu signs the playlist for the user-agent of the session that resolved
            // it (any other agent gets 404), so resolve fresh and download with it.
            let recuMedia = try await resolveRecuMediaInfo(url: normalizedURL)
            targetURL = recuMedia.playlistURL
            customResolvedTitle = recuMedia.title
            customEmbedURL = recuMedia.pageURL
            customThumbnailURL = recuMedia.thumbnailURL
            recuUserAgent = recuMedia.userAgent
        } else if isBoyfriendTVURL(url) {
            if let streamURL = mediaInfo?.manifestUrl ?? mediaInfo?.originalUrl, !streamURL.isEmpty, streamURL.contains("boyfriend") {
                targetURL = resolveBoyfriendTVStreamURLForDownload(streamURL: streamURL, options: options)
                customResolvedTitle = mediaInfo?.title
                customEmbedURL = mediaInfo?.webpageUrl
                customThumbnailURL = mediaInfo?.thumbnail
            } else if let btvMedia = try await resolveBoyfriendTVMediaInfo(
                url: url,
                rawCookies: options.rawCookies,
                rawUserAgent: options.rawUserAgent,
                browserCookieSource: options.browserCookieSource
            ) {
                targetURL = resolveBoyfriendTVStreamURLForDownload(streamURL: btvMedia.streamURL, options: options)
                customResolvedTitle = btvMedia.title
                customEmbedURL = btvMedia.embedURL
                customThumbnailURL = btvMedia.thumbnailURL
            }
        } else if isGayteamURL(url) {
            // The captured stream while its player token is surely valid; else (also
            // for a recovered queue item, which has no capture time) capture again.
            let media: MediaInfo
            if let mediaInfo, let stream = mediaInfo.manifestUrl, !stream.isEmpty, !isGayteamURL(stream),
               let fetchedAt = mediaInfo.fetchedAt, Date().timeIntervalSince(fetchedAt) < 60 * 60 {
                media = mediaInfo
            } else {
                media = try await resolveGayteamMediaInfo(url: normalizedURL, path: path.path, proxy: EgressBoundary.proxyURL)
            }
            targetURL = media.manifestUrl ?? targetURL
            customResolvedTitle = media.title
            customEmbedURL = media.webpageUrl
            customThumbnailURL = media.thumbnail
        } else if isGuywhURL(url) {
            if let reused = reusedDirectMedia(
                mediaInfo: mediaInfo,
                selectedFormatId: protectedFormatId,
                normalizedURL: normalizedURL,
                fallbackEmbedURL: url
            ) {
                (targetURL, customResolvedTitle, customEmbedURL, customThumbnailURL) =
                    (reused.streamURL, reused.title, reused.embedURL, reused.thumbnailURL)
            } else if let guywhMedia = await resolveGuywhMediaInfo(url: url, rawCookies: options.rawCookies) {
                targetURL = guywhMedia.streamURL
                customResolvedTitle = guywhMedia.title
                customEmbedURL = guywhMedia.embedURL
                customThumbnailURL = guywhMedia.thumbnailURL
            }
        } else if isGFFURL(url) {
            if let reused = reusedDirectMedia(
                mediaInfo: mediaInfo,
                selectedFormatId: protectedFormatId,
                normalizedURL: normalizedURL,
                fallbackEmbedURL: url
            ) {
                (targetURL, customResolvedTitle, customEmbedURL, customThumbnailURL) =
                    (reused.streamURL, reused.title, reused.embedURL, reused.thumbnailURL)
            } else if let gffMedia = await resolveGFFMediaInfo(url: url, rawCookies: options.rawCookies) {
                targetURL = gffMedia.streamURL
                customResolvedTitle = gffMedia.title
                customEmbedURL = gffMedia.embedURL
                customThumbnailURL = gffMedia.thumbnailURL
            }
        } else if isBestCamURL(url) {
            if let reused = reusedDirectMedia(
                mediaInfo: mediaInfo,
                selectedFormatId: protectedFormatId,
                normalizedURL: normalizedURL,
                fallbackEmbedURL: url
            ) {
                (targetURL, customResolvedTitle, customEmbedURL, customThumbnailURL) =
                    (reused.streamURL, reused.title, reused.embedURL, reused.thumbnailURL)
                bestCamDecryptionKey = reused.formatNote ?? URL(string: reused.streamURL)?.lastPathComponent
            } else if let bestCamMedia = await resolveBestCamMediaInfo(
                url: url,
                rawCookies: options.rawCookies,
                requestedFormat: protectedFormatId
            ) {
                targetURL = bestCamMedia.streamURL
                customResolvedTitle = bestCamMedia.title
                customEmbedURL = bestCamMedia.embedURL
                customThumbnailURL = bestCamMedia.thumbnailURL
                bestCamDecryptionKey = bestCamMedia.encryptedFilename
            }
        } else if isStarwankURL(url) {
            if let reused = reusedDirectMedia(
                mediaInfo: mediaInfo,
                selectedFormatId: protectedFormatId,
                normalizedURL: normalizedURL,
                fallbackEmbedURL: url,
                fallbackIsAllowed: { stream in
                    stream.contains(".m3u8") || stream.contains(".mp4") || stream.contains("get_file")
                }
            ) {
                (targetURL, customResolvedTitle, customEmbedURL, customThumbnailURL) =
                    (reused.streamURL, reused.title, reused.embedURL, reused.thumbnailURL)
            } else if let starwankMedia = await resolveStarwankMediaInfo(
                url: url,
                rawCookies: options.rawCookies,
                requestedFormat: protectedFormatId
            ) {
                targetURL = starwankMedia.streamURL
                customResolvedTitle = starwankMedia.title
                customEmbedURL = starwankMedia.embedURL
                customThumbnailURL = starwankMedia.thumbnailURL
            }
        } else if isPussyspaceURL(url) {
            if let reused = reusedDirectMedia(
                mediaInfo: mediaInfo,
                selectedFormatId: protectedFormatId,
                normalizedURL: normalizedURL,
                fallbackEmbedURL: url,
                fallbackIsAllowed: { stream in
                    stream.contains(".m3u8") || stream.contains(".mp4") || stream.contains("reversebuffer")
                }
            ) {
                (targetURL, customResolvedTitle, customEmbedURL, customThumbnailURL) =
                    (reused.streamURL, reused.title, reused.embedURL, reused.thumbnailURL)
            } else if let pussyMedia = await resolvePussyspaceMediaInfo(
                url: url,
                rawCookies: options.rawCookies,
                requestedFormat: protectedFormatId
            ) {
                targetURL = pussyMedia.streamURL
                customResolvedTitle = pussyMedia.title
                customEmbedURL = pussyMedia.embedURL
                customThumbnailURL = pussyMedia.thumbnailURL
            }
        }

        var args = [path.path, "--ignore-config"]
        appendJsRuntimeArgs(to: &args)
        if ffmpegPath == nil || !FileManager.default.fileExists(atPath: ffmpegPath?.path ?? "") {
            await findFfmpeg()
        }
        
        let appSupport = Self.getAppSupportDirectory()
        let ffmpegDir: String
        if let loc = ffmpegPath?.deletingLastPathComponent().path, FileManager.default.fileExists(atPath: loc + "/ffmpeg") {
            ffmpegDir = loc
        } else {
            ffmpegDir = appSupport.path
        }
        args.append(contentsOf: ["--ffmpeg-location", ffmpegDir])

        // Safe per-download isolated scratch directory for temporary chunks and thumbnail conversions
        let scratchDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("siphon_scratch_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            LoggerService.shared.log("Failed to create temporary scratch directory at \(scratchDirectory.path): \(error.localizedDescription)", level: .error)
            throw YtdlpError.downloadFailed("Failed to initialize temporary scratch directory: \(error.localizedDescription)")
        }
        args.append(contentsOf: ["--paths", "home:\(options.saveFolder.path)"])
        args.append(contentsOf: ["--paths", "temp:\(scratchDirectory.path)"])
        let thumbnailDirectory = options.downloadThumbnail ? options.saveFolder : scratchDirectory
        args.append(contentsOf: ["--paths", "thumbnail:\(thumbnailDirectory.path)"])
        args.append("--no-playlist")

        let outputTemplate: String
        // A playlist URL expands to many entries (--no-playlist does not apply to
        // it). One fixed name would make yt-dlp skip every entry after the first
        // as "already downloaded". The queue reserves one path per job, so it
        // cannot protect the entries: the video id keeps distinct entries from
        // colliding with each other or with another job's output.
        let isPlaylist = mediaInfo?.playlist != nil
        if isPlaylist {
            outputTemplate = "%(title)s [%(id)s].%(ext)s"
        } else if let customFilename = options.customFilename ?? customResolvedTitle, !customFilename.isEmpty {
            let safeName = Self.sanitizeFilename(customFilename)
            outputTemplate = "\(safeName).%(ext)s"
        } else {
            outputTemplate = "%(title)s.%(ext)s"
        }
        args.append("--windows-filenames")
        args.append("--continue")
        args.append(contentsOf: ["-o", outputTemplate])
        args.append(contentsOf: ["--print", "after_move:SIPHON_FINAL_PATH:%(filepath)s"])
        // --print implies --quiet, which silences progress and every log line
        // the runner parses. --no-quiet keeps the normal output alongside it.
        args.append("--no-quiet")

        // Let yt-dlp inspect HLS encryption before choosing a downloader.
        // Forcing FFmpeg skips its FairPlay/DRM rejection and can copy encrypted samples.

        args.append(contentsOf: buildFormatArgs(url: url, options: options, mediaInfo: mediaInfo))
        let codecFallbackWarnings = codecFallbackOutputWarnings(options: options)
        if options.downloadSubtitles && !options.subtitleLanguages.isEmpty {
            let subFormat = options.subtitleFormat?.ytdlpValue ?? "srt"
            args.append(contentsOf: ["--sub-format", "\(subFormat)/best"])
            let safeLangs = options.subtitleLanguages.filter { Self.isSafeSubtitleLanguage($0) }
            if !safeLangs.isEmpty {
                let langList = safeLangs.joined(separator: ",")
                args.append(contentsOf: ["--sub-langs", langList])
            }

            args.append("--write-subs")
            args.append("--write-auto-subs")

            if options.embedSubtitles && options.fileType.isVideo {
                args.append("--embed-subs")
                args.append(contentsOf: ["--convert-subs", subFormat])
            }
        }

        if options.downloadThumbnail {
            args.append("--write-thumbnail")
        }
        // An encrypted stream stays unreadable until Siphon decrypts it after
        // yt-dlp exits, so FFmpeg postprocessors would fail on it. The cover is
        // embedded by the post-decryption fallback below instead.
        let isEncryptedStream = bestCamDecryptionKey != nil
        if options.embedThumbnail && !isEncryptedStream {
            args.append("--embed-thumbnail")
            args.append(contentsOf: ["--convert-thumbnails", "jpg"])
        }

        if options.embedMetadata && !isEncryptedStream {
            args.append("--embed-metadata")
            args.append("--embed-chapters")
        }

        if options.splitChapters && !isEncryptedStream {
            args.append("--split-chapters")
        }

        if options.sponsorBlock && !isEncryptedStream {
            args.append(contentsOf: ["--sponsorblock-remove", "all"])
        }

        if let start = options.timeFrameStart, let end = options.timeFrameEnd,
           Self.isValidTimeFrame(start), Self.isValidTimeFrame(end) {
            args.append(contentsOf: ["--download-sections", "*\(start)-\(end)"])
        }

        if options.forceOverwrite == true {
            args.append("--force-overwrites")
        }

        let speedLimit = UserDefaults.standard.integer(forKey: UserDefaultsKeys.downloadSpeedLimit)
        if speedLimit > 0 {
            args.append(contentsOf: ["--limit-rate", "\(speedLimit)K"])
        }

        if let extra = options.additionalArguments?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            var extraArgs = Self.removingOutputLocationArguments(Self.parseArgumentString(extra))
            if options.enforcePublicNetworkBoundary {
                extraArgs = Self.removingProxyArguments(extraArgs)
            }
            args.append(contentsOf: extraArgs)
        }

        if options.enforcePublicNetworkBoundary, let boundaryProxy = EgressBoundary.proxyURL {
            args.append(contentsOf: ["--proxy", boundaryProxy])
        }

        // Reuse the metadata fetched moments ago instead of extracting again
        // (saves a round of site requests and ~1-2 s). Only for the URL it was
        // fetched from, only while its signed stream URLs are surely fresh.
        var infoJSONFile: URL?
        if targetURL == normalizedURL,
           !Self.requiresHlsVariantQuery(targetURL),
           mediaInfo?.playlist == nil,
           let raw = mediaInfo?.rawJSON,
           let fetchedAt = mediaInfo?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.reusableInfoMaxAge {
            let file = scratchDirectory.appendingPathComponent("siphon_info.json")
            if FileManager.default.createFile(atPath: file.path, contents: raw, attributes: [.posixPermissions: 0o600]) {
                infoJSONFile = file
                args.append(contentsOf: ["--load-info-json", file.path])
            }
        }

        var secureCookieFiles: [SecureCookieFile] = []
        defer {
            for file in secureCookieFiles {
                file.cleanup()
            }
            if let infoJSONFile {
                try? FileManager.default.removeItem(at: infoJSONFile)
            }
            // Executor-owned directories survive a pause and are cleaned at job teardown.
            if temporaryDirectory == nil {
                do { try FileManager.default.removeItem(at: scratchDirectory) }
                catch { LoggerService.shared.log("Could not remove download scratch directory: \(error.localizedDescription)", level: .warning) }
            }
        }

        let sucuriCookie = await resolveSucuriCookie(for: normalizedURL)
        var additionalCookies: [(name: String, value: String)] = []
        if let sc = sucuriCookie {
            additionalCookies.append((name: sc.name, value: sc.value))
        }

        if isRecuURL(normalizedURL) {
            // Recu session cookies are only for resolving the signed playlist URL.
            // The CDN playlist/segments are intentionally fetched without account cookies.
            LoggerService.shared.log("Protected-site stream download uses the resolved CDN URL without forwarding account cookies", level: .debug)
        } else if (options.rawCookies?.isEmpty == false) || !additionalCookies.isEmpty {
            if let cookieFile = try? SecureCookieFile.create(
                url: targetURL,
                rawCookies: options.rawCookies,
                additionalCookies: additionalCookies
            ) {
                secureCookieFiles.append(cookieFile)
                args.append(contentsOf: ["--cookies", cookieFile.path])
                if sucuriCookie != nil {
                    LoggerService.shared.log("Using temporary Sucuri cookie in consolidated file for \(hostForLog(normalizedURL)) (cookie values not logged)", level: .info)
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
                }
                if let raw = options.rawCookies, !raw.isEmpty {
                    LoggerService.shared.log("Using session cookies passed from browser extension for \(hostForLog(targetURL))", level: .info)
                }
            }
        } else {
            let usingBrowserCookies = appendCookieArgs(
                for: normalizedURL,
                to: &args,
                browserOverride: options.browserCookieSource
            )
            logCookieUsage(for: normalizedURL, usingBrowserCookies: usingBrowserCookies)
        }
        
        // Prepare local scratch thumbnail if available to guarantee embedding for direct stream downloads
        let thumbnailCandidateURL = customThumbnailURL ?? mediaInfo?.thumbnail
        let scratchThumbnailURL = scratchDirectory.appendingPathComponent("custom_cover.jpg")
        if (options.embedThumbnail || options.downloadThumbnail), let thumbStr = thumbnailCandidateURL, !thumbStr.isEmpty {
            // Recu signs its poster for the session's user-agent, like its playlist.
            _ = await downloadThumbnailLocally(from: thumbStr, to: scratchThumbnailURL,
                                               userAgent: recuUserAgent, referer: recuUserAgent == nil ? nil : customEmbedURL)
        }

        appendSiteSpecificArgs(for: customEmbedURL ?? targetURL, options: options, mediaInfo: mediaInfo, rawUserAgent: recuUserAgent, to: &args)
        // Recu recordings are signed VOD streams; a skipped segment would leave
        // a corrupt recording. Live streams elsewhere may legitimately rotate
        // unavailable fragments, so keep yt-dlp's default behavior there.
        if isRecuURL(url) {
            args.append("--abort-on-unavailable-fragments")
        }
        if isRecuURL(url), let check = Self.recuSegmentCheck(for: targetURL) {
            args.append(contentsOf: ["--extractor-args", "generic:fragment_query=check=\(check)"])
        }

        args.append("--no-color")
        args.append("--newline")
        args.append(contentsOf: ["--progress-template", "download:SIPHON_PROG:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"])
        args.append("--")
        args.append(targetURL)
        
        let sanitizedCommand = LoggerService.sanitizeCommandForLog(args)
        for warning in codecFallbackWarnings {
            onOutput("\(warning)\n")
        }
        onOutput("[COMMAND] \(sanitizedCommand)\n")
        LoggerService.shared.log(sanitizedCommand, level: .command)
        
        // Structured bounded recovery state machine
        enum DownloadRecoveryStrategy: Hashable {
            case freshExtraction
            case stripCookies
            case disableRangeChunking
            case useFfmpegHls
            case injectBrowserCookies(browser: String)
            case retryTransientNetworkError
            case disableAria2c
        }

        var triedStrategies = Set<DownloadRecoveryStrategy>()
        var currentArgs = args
        // The URL stays in the arguments (cookie export and the fresh-extraction
        // fallback need it), so yt-dlp's expected notice about it is not job output.
        let reusesInfo = infoJSONFile != nil
        let processOutput: @Sendable (String) -> Void = { line in
            if reusesInfo, line.contains("URLs are ignored due to --load-info-json") { return }
            onOutput(line)
        }
        var processResult: DownloadProcessResult? = nil

        while processResult == nil {
            try Task.checkCancellation()
            if processController?.isCancelled == true { throw CancellationError() }
            do {
                processResult = try await runDownloadProcess(
                    args: currentArgs,
                    saveFolder: options.saveFolder,
                    processController: processController,
                    onProgress: onProgress,
                    onOutput: processOutput
                )
            } catch let error as YtdlpError {
                let errText: String
                switch error {
                case .commandFailed(let msg), .downloadFailed(let msg):
                    errText = msg
                default:
                    errText = ""
                }

                // Strategy 0: Reused metadata failed (for example an expired stream URL)
                // -> extract again. yt-dlp ignores the trailing URL while --load-info-json is set.
                if let index = currentArgs.firstIndex(of: "--load-info-json"), index + 1 < currentArgs.count,
                   !triedStrategies.contains(.freshExtraction) {
                    triedStrategies.insert(.freshExtraction)
                    LoggerService.shared.log("Download with reused metadata failed; retrying with fresh extraction", level: .info)
                    onOutput("[Siphon Info] Refreshing video information and retrying...\n")
                    currentArgs.removeSubrange(index...index + 1)
                    continue
                }

                // Strategy 1: Cookie failure -> try alternate browser or strip browser cookies
                if !errText.isEmpty, isCookieFailureError(errText), currentArgs.contains("--cookies-from-browser"), !triedStrategies.contains(.stripCookies) {
                    if let idx = currentArgs.firstIndex(of: "--cookies-from-browser"), idx + 1 < currentArgs.count {
                        let failedBrowser = currentArgs[idx + 1]
                        LoggerService.shared.log(
                            "Browser cookie access failed for '\(failedBrowser)'. Unrelated browser profiles will not be probed.",
                            level: .info
                        )
                    }
                    triedStrategies.insert(.stripCookies)
                    LoggerService.shared.log("Browser cookie access failed or database missing (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Retrying download without browser cookies...", level: .warning)
                    if let browser = Self.validatedBrowserCookieSource(options.browserCookieSource) ?? configuredBrowserCookieSource() {
                        recordCookieDenial(browser: browser, url: normalizedURL, errorOutput: errText)
                    }
                    onOutput("[Siphon Info] Browser cookies unavailable. Retrying download directly without browser cookies...\n")
                    currentArgs = stripCookieArgs(from: currentArgs)
                    refreshBrowserTransportIdentity(for: normalizedURL, args: &currentArgs)
                    continue
                }

                // Strategy 2: HTTP Range chunk failure -> disable chunking
                if !errText.isEmpty, isRangeError(errText), currentArgs.contains("--http-chunk-size"), !triedStrategies.contains(.disableRangeChunking) {
                    triedStrategies.insert(.disableRangeChunking)
                    LoggerService.shared.log("Server range request error encountered (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Retrying download without HTTP chunking...", level: .warning)
                    onOutput("[Siphon Info] Server does not support HTTP Range chunks. Retrying download directly as continuous stream...\n")
                    var unchunkedArgs = currentArgs
                    if let idx = unchunkedArgs.firstIndex(of: "--http-chunk-size") {
                        unchunkedArgs.remove(at: idx)
                        if idx < unchunkedArgs.count {
                            unchunkedArgs.remove(at: idx)
                        }
                    }
                    currentArgs = unchunkedArgs
                    continue
                }

                // Strategy 3: HLS / stream error -> FFmpeg downloader
                if !errText.isEmpty, isLiveHlsError(errText), !currentArgs.contains("--downloader"), !triedStrategies.contains(.useFfmpegHls) {
                    triedStrategies.insert(.useFfmpegHls)
                    LoggerService.shared.log("Live HLS / stream format detected (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Retrying download with FFmpeg downloader...", level: .warning)
                    onOutput("[Siphon Info] HLS stream requires FFmpeg downloader. Retrying with FFmpeg downloader...\n")
                    var ffmpegArgs = currentArgs
                    var recoveryArgs = ["--downloader", "ffmpeg"]
                    if !ffmpegArgs.contains("--downloader-args") {
                        recoveryArgs.append(contentsOf: ["--downloader-args", "ffmpeg_i:-analyzeduration 20M -probesize 20M"])
                    }
                    if !ffmpegArgs.contains("--hls-use-mpegts") {
                        recoveryArgs.append("--hls-use-mpegts")
                    }
                    ffmpegArgs.insert(contentsOf: recoveryArgs, at: ffmpegArgs.firstIndex(of: "--") ?? ffmpegArgs.endIndex)
                    currentArgs = ffmpegArgs
                    continue
                }

                // Strategy 4: YouTube 403 / bot challenge -> Inject browser cookies
                if !errText.isEmpty, (normalizedURL.contains("youtube.com") || normalizedURL.contains("youtu.be")),
                   (errText.contains("403") || errText.contains("Sign in") || errText.contains("bot") || errText.contains("login_required")),
                   !currentArgs.contains("--cookies-from-browser"),
                   let browser = Self.validatedBrowserCookieSource(options.browserCookieSource) ?? configuredBrowserCookieSource(),
                   !triedStrategies.contains(.injectBrowserCookies(browser: browser)) {
                    triedStrategies.insert(.injectBrowserCookies(browser: browser))
                    LoggerService.shared.log("YouTube 403 / bot challenge encountered. Retrying download with browser cookies from \(browser)...", level: .warning)
                    onOutput("[Siphon Info] YouTube authentication required. Retrying download with browser cookies from \(browser)...\n")
                    var cookieArgs = currentArgs
                    _ = appendCookieArgs(
                        for: normalizedURL,
                        to: &cookieArgs,
                        force: true,
                        browserOverride: options.browserCookieSource
                    )
                    currentArgs = cookieArgs
                    continue
                }

                // Strategy 5: Transient CDN connection refusal / server error -> Retry with fresh connection
                if !errText.isEmpty, isTransientServerError(errText), !triedStrategies.contains(.retryTransientNetworkError) {
                    triedStrategies.insert(.retryTransientNetworkError)
                    LoggerService.shared.log("Transient server or network error encountered (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Retrying download with fresh connection...", level: .warning)
                    onOutput("[Siphon Info] Server or network error encountered. Retrying stream download...\n")
                    if processRunner is DefaultYtdlpProcessRunner {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    continue
                }

                // Strategy 6: aria2c download error -> Fallback to native downloader
                if !errText.isEmpty, (errText.contains("aria2c") || errText.contains("aria2")), currentArgs.contains("aria2c"), !triedStrategies.contains(.disableAria2c) {
                    triedStrategies.insert(.disableAria2c)
                    LoggerService.shared.log("Aria2c multi-connection download error encountered (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Falling back to native downloader...", level: .warning)
                    onOutput("[Siphon Info] Aria2c multi-connection unavailable. Retrying with native downloader...\n")
                    var cleanArgs = currentArgs
                    if let idx = cleanArgs.firstIndex(of: "--downloader"), idx + 1 < cleanArgs.count, cleanArgs[idx + 1] == "aria2c" {
                        cleanArgs.remove(at: idx + 1)
                        cleanArgs.remove(at: idx)
                    }
                    if let idx = cleanArgs.firstIndex(of: "--downloader-args") {
                        cleanArgs.remove(at: idx + 1)
                        cleanArgs.remove(at: idx)
                    }
                    currentArgs = cleanArgs
                    continue
                }

                throw mapSiteSpecificError(
                    error,
                    url: normalizedURL,
                    browserCookieSource: options.browserCookieSource
                )
            }
        }

        guard let finalResult = processResult else {
            throw YtdlpError.downloadFailed("Download failed across all recovery strategies.")
        }
        if let partialFailure = finalResult.partialFailure {
            onOutput("[WARNING] \(finalResult.allPaths.count) item(s) finished; others failed: \(partialFailure)\n")
            LoggerService.shared.log("Download finished with failed items (\(hostForLog(normalizedURL))): \(partialFailure)", level: .warning)
        }
        var finalFileURL = URL(fileURLWithPath: finalResult.primaryPath, relativeTo: options.saveFolder).absoluteURL
        var allFileURLs = finalResult.allPaths.map { URL(fileURLWithPath: $0, relativeTo: options.saveFolder).absoluteURL }

        if let key = bestCamDecryptionKey {
            onOutput("[Siphon Info] Decrypting downloaded stream...\n")
            let encryptedFile = finalFileURL
            try await Task.detached(priority: .utility) {
                try Self.decryptBestCamFile(at: encryptedFile, filename: key)
            }.value
        }

        // yt-dlp saves GIF links and GIF pages as .gif; a video download must end as video.
        if options.fileType.isVideo, allFileURLs.contains(where: Self.isGIF) {
            onOutput("[Siphon Info] \(LanguageService.s("converting_gif_to_video"))\n")
            let primary = finalFileURL
            for index in allFileURLs.indices where Self.isGIF(allFileURLs[index]) {
                let gif = allFileURLs[index]
                let video = try await convertGIFToVideo(gif: gif, ffmpegDir: ffmpegDir,
                                                        processController: processController)
                allFileURLs[index] = video
                if gif == primary { finalFileURL = video }
            }
        }

        // A successful remux does not prove that fragmented media can be decoded.
        // Custom downloaders can return success after copying encrypted samples.
        let selectedFormats = mediaInfo?.resolveSelectedFormats(options: options) ?? []
        if URL(string: targetURL)?.pathExtension.lowercased() == "m3u8" ||
           URL(string: targetURL)?.pathExtension.lowercased() == "mpd" ||
           mediaInfo?.isFragmented == true || selectedFormats.contains(where: \.isFragmented) {
            onOutput("[Siphon Info] \(LanguageService.s("checking_media_integrity"))\n")
            for file in allFileURLs {
                try await validateDownloadedMedia(mediaFile: file, ffmpegDir: ffmpegDir,
                                                  processController: processController)
            }
        }

        // Direct streams often have no poster. Use a decoded frame for their cover.
        if (options.embedThumbnail || options.downloadThumbnail), options.fileType.isVideo,
           !FileManager.default.fileExists(atPath: scratchThumbnailURL.path) {
            try await generateVideoThumbnail(mediaFile: finalFileURL, destination: scratchThumbnailURL,
                                             ffmpegDir: ffmpegDir, processController: processController)
        }

        // Post-download cover art fallback: embed a local cover if it is missing.
        if options.embedThumbnail && FileManager.default.fileExists(atPath: scratchThumbnailURL.path) {
            let hasThumb = try await hasAttachedThumbnail(mediaFile: finalFileURL, ffmpegDir: ffmpegDir, processController: processController)
            if !hasThumb {
                let embedded = try await embedThumbnailWithFfmpeg(imageFile: scratchThumbnailURL, mediaFile: finalFileURL, ffmpegDir: ffmpegDir, processController: processController)
                if !embedded {
                    onOutput("[WARNING] Thumbnail embedding was requested, but FFmpeg could not embed the cover art into \(finalFileURL.lastPathComponent).\n")
                    LoggerService.shared.log("Thumbnail embedding failed for \(finalFileURL.lastPathComponent)", level: .warning)
                }
            }
        }

        // Attach Finder custom file icon for native macOS Finder / Downloads thumbnail display
        if options.embedThumbnail {
            var possibleThumbnailURLs: [URL] = []
            if FileManager.default.fileExists(atPath: scratchThumbnailURL.path) {
                possibleThumbnailURLs.append(scratchThumbnailURL)
            }
            let scratchFiles = (try? FileManager.default.contentsOfDirectory(at: scratchDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in scratchFiles {
                let ext = file.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "webp"].contains(ext) {
                    possibleThumbnailURLs.append(file)
                }
            }
            for thumbURL in possibleThumbnailURLs {
                if let img = DownloadExecutor.loadThumbnailImage(at: thumbURL) {
                    let squareIcon = Self.createAspectFitIcon(from: img)
                    let setSuccess = NSWorkspace.shared.setIcon(squareIcon, forFile: finalFileURL.path, options: [])
                    if setSuccess {
                        LoggerService.shared.log("Attached custom Finder thumbnail icon to \(finalFileURL.lastPathComponent)", level: .info)
                        break
                    }
                }
            }
        }

        // If user requested downloading thumbnail as a standalone file, save to folder
        if options.downloadThumbnail && FileManager.default.fileExists(atPath: scratchThumbnailURL.path) {
            let standaloneThumbURL = finalFileURL.deletingPathExtension().appendingPathExtension("jpg")
            if !FileManager.default.fileExists(atPath: standaloneThumbURL.path) {
                try? FileManager.default.copyItem(at: scratchThumbnailURL, to: standaloneThumbURL)
            }
        }

        return DownloadResult(files: allFileURLs, primaryFile: finalFileURL)
    }

    private func downloadThumbnailLocally(from urlString: String, to destinationURL: URL,
                                          userAgent: String? = nil, referer: String? = nil) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        if let referer = referer ?? Self.boyfriendTVThumbnailReferer(for: urlString) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        guard let data = await DownloadExecutor.fetchThumbnailData(for: request) else { return false }
        return (try? data.write(to: destinationURL, options: .atomic)) != nil
    }

    nonisolated static func isGIF(_ file: URL) -> Bool { file.pathExtension.lowercased() == "gif" }

    /// Re-encodes an animated GIF as H.264 MP4 beside it, then removes the GIF.
    /// The GIF is kept if conversion fails. Even dimensions and yuv420p keep the MP4 playable everywhere.
    func convertGIFToVideo(gif: URL, ffmpegDir: String,
                           processController: DownloadProcessController? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard processController?.isCancelled != true else { throw CancellationError() }
        let ffmpeg = URL(fileURLWithPath: ffmpegDir).appendingPathComponent("ffmpeg")
        let fm = FileManager.default
        let directory = gif.deletingLastPathComponent()
        let base = gif.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent(base + ".mp4")
        var copy = 1
        while fm.fileExists(atPath: destination.path) {
            copy += 1
            destination = directory.appendingPathComponent("\(base) (\(copy)).mp4")
        }
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).mp4.partial")
        defer { try? fm.removeItem(at: partial) }
        do {
            _ = try await processRunner.runCommand([
                ffmpeg.path, "-nostdin", "-v", "error", "-y", "-i", gif.path,
                "-an", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-preset", "medium",
                "-movflags", "+faststart", "-f", "mp4", partial.path
            ], processController: processController)
            try fm.moveItem(at: partial, to: destination)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            LoggerService.shared.log("GIF to video conversion failed: \(error.localizedDescription)", level: .error)
            throw YtdlpError.downloadFailed(LanguageService.s("gif_conversion_failed"))
        }
        try? fm.removeItem(at: gif)
        return destination
    }

    func validateDownloadedMedia(mediaFile: URL, ffmpegDir: String,
                                 processController: DownloadProcessController? = nil) async throws {
        try Task.checkCancellation()
        guard processController?.isCancelled != true else { throw CancellationError() }
        let ffmpeg = URL(fileURLWithPath: ffmpegDir).appendingPathComponent("ffmpeg")
        do {
            _ = try await processRunner.runCommand([
                ffmpeg.path, "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode",
                "-i", mediaFile.path, "-map", "0:V?", "-map", "0:a?",
                "-abort_on", "empty_output_stream", "-f", "null", "-"
            ], processController: processController)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            guard processController?.isCancelled != true else { throw CancellationError() }
            LoggerService.shared.log("Downloaded media failed its decode check: \(error.localizedDescription)", level: .error)
            throw YtdlpError.downloadFailed(LanguageService.s("media_integrity_failed"))
        }
        try Task.checkCancellation()
        guard processController?.isCancelled != true else { throw CancellationError() }
    }

    nonisolated static let videoThumbnailSeekSeconds = ["5", "0"]

    func generateVideoThumbnail(mediaFile: URL, destination: URL, ffmpegDir: String,
                                processController: DownloadProcessController? = nil) async throws {
        let ffmpeg = URL(fileURLWithPath: ffmpegDir).appendingPathComponent("ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path),
              FileManager.default.fileExists(atPath: mediaFile.path) else { return }
        // Recordings often open on black frames (Recu's start with a black one), so
        // take the cover a few seconds in. A clip shorter than that falls back to frame 0.
        for seek in Self.videoThumbnailSeekSeconds {
            do {
                _ = try await processRunner.runCommand([
                    ffmpeg.path, "-nostdin", "-y", "-v", "error", "-xerror", "-ss", seek, "-i", mediaFile.path,
                    "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=512:512:force_original_aspect_ratio=decrease",
                    destination.path
                ], processController: processController)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                guard processController?.isCancelled != true else { throw CancellationError() }
                LoggerService.shared.log("Video thumbnail generation at \(seek)s failed: \(error.localizedDescription)", level: .warning)
            }
            if FileManager.default.fileExists(atPath: destination.path) { return }
        }
    }

    func embedThumbnailWithFfmpeg(imageFile: URL, mediaFile: URL, ffmpegDir: String, processController: DownloadProcessController? = nil) async throws -> Bool {
        try Task.checkCancellation()
        let ext = mediaFile.pathExtension.lowercased()
        let fm = FileManager.default
        guard fm.fileExists(atPath: mediaFile.path), fm.fileExists(atPath: imageFile.path) else { return false }

        let ffmpegBin = URL(fileURLWithPath: ffmpegDir).appendingPathComponent("ffmpeg")
        guard fm.isExecutableFile(atPath: ffmpegBin.path) else { return false }

        let tempOutput = mediaFile.deletingLastPathComponent().appendingPathComponent("thumb_temp_\(UUID().uuidString).\(ext)")

        var procArgs = [
            "-nostdin",
            "-y",
            "-i", mediaFile.path,
            "-i", imageFile.path
        ]

        if ext == "mp4" || ext == "m4v" || ext == "mov" {
            procArgs.append(contentsOf: [
                "-map", "0",
                "-map", "1",
                "-c", "copy",
                "-c:v:1", "mjpeg",
                "-disposition:v:1", "attached_pic",
                "-movflags", "+faststart",
                tempOutput.path
            ])
        } else if ext == "mkv" || ext == "webm" {
            procArgs.append(contentsOf: [
                "-map", "0",
                "-map", "1",
                "-c", "copy",
                "-disposition:v:1", "attached_pic",
                tempOutput.path
            ])
        } else if ext == "mp3" || ext == "m4a" || ext == "flac" {
            procArgs.append(contentsOf: [
                "-map", "0:a",
                "-map", "1",
                "-c", "copy",
                "-disposition:v:0", "attached_pic",
                tempOutput.path
            ])
        } else {
            return false
        }

        defer {
            if fm.fileExists(atPath: tempOutput.path) {
                do { try fm.removeItem(at: tempOutput) }
                catch { LoggerService.shared.log("Could not remove thumbnail staging file: \(error.localizedDescription)", level: .warning) }
            }
        }
        do {
            _ = try await processRunner.runCommand([ffmpegBin.path] + procArgs, processController: processController)
            try Task.checkCancellation()
            guard processController?.isCancelled != true else { throw CancellationError() }
            if fm.fileExists(atPath: tempOutput.path), ((try? tempOutput.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 {
                let backupURL = mediaFile.deletingLastPathComponent().appendingPathComponent("thumb_orig_\(UUID().uuidString).\(ext)")
                try fm.moveItem(at: mediaFile, to: backupURL)
                do {
                    try fm.moveItem(at: tempOutput, to: mediaFile)
                } catch {
                    try fm.moveItem(at: backupURL, to: mediaFile)
                    throw error
                }
                do { try fm.removeItem(at: backupURL) }
                catch { LoggerService.shared.log("Could not remove thumbnail backup: \(error.localizedDescription)", level: .warning) }
                return true
            }
            return false
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            guard processController?.isCancelled != true else { throw CancellationError() }
            LoggerService.shared.log("Thumbnail post-processing failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    nonisolated public static func createAspectFitIcon(from image: NSImage, targetSize: CGFloat = 512) -> NSImage {
        ImageUtilities.createAspectFitIcon(from: image, targetSize: targetSize)
    }

    func hasAttachedThumbnail(mediaFile: URL, ffmpegDir: String, processController: DownloadProcessController? = nil) async throws -> Bool {
        try Task.checkCancellation()
        let ffprobeBin = URL(fileURLWithPath: ffmpegDir).appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobeBin.path) else { return false }

        let args = [
            ffprobeBin.path,
            "-v", "error",
            "-show_entries", "stream_disposition=attached_pic",
            "-of", "csv=p=0",
            mediaFile.path
        ]
        do {
            let output = try await processRunner.runCommand(args, processController: processController)
            try Task.checkCancellation()
            guard processController?.isCancelled != true else { throw CancellationError() }
            return output.split(whereSeparator: \.isNewline).contains { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            }
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            guard processController?.isCancelled != true else { throw CancellationError() }
            LoggerService.shared.log("Thumbnail inspection failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    private func isLiveHlsError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("live hls") ||
               lower.contains("livestream") ||
               lower.contains("native downloader") ||
               lower.contains("postprocessing: stream") ||
               lower.contains("could not find codec parameters") ||
               lower.contains("malformed aac bitstream") ||
               lower.contains("hlsnative")
    }



    /// Generic page extractors (og:video, <video> tags) return one format with no height.
    /// Any `[height<=N]` selector rejects it, so such a lone format is taken as-is.
    static func isSingleUnprobedFormat(_ info: MediaInfo?) -> Bool {
        guard let formats = info?.formats, formats.count == 1 else { return false }
        return formats[0].isDownloadable && (formats[0].resolution == nil || formats[0].resolution == "unknown")
    }

    private func buildFormatArgs(url: String? = nil, options: DownloadOptions, mediaInfo: MediaInfo? = nil) -> [String] {
        var args: [String] = []

        let isSynthesizedDirectStream = mediaInfo?.uploader == "Protected Site" ||
                                        mediaInfo?.uploader == "StarWank" ||
                                        mediaInfo?.uploader == "PussySpace" ||
                                        isGuywhURL(mediaInfo?.id ?? "") ||
                                        isGFFURL(mediaInfo?.id ?? "") ||
                                        isBoyfriendTVURL(mediaInfo?.id ?? "") ||
                                        isBestCamURL(mediaInfo?.id ?? "") ||
                                        isStarwankURL(mediaInfo?.id ?? "") ||
                                        isPussyspaceURL(mediaInfo?.id ?? "") ||
                                        (url.map(isGuywhURL) ?? false) ||
                                        (url.map(isGFFURL) ?? false) ||
                                        (url.map(isBoyfriendTVURL) ?? false) ||
                                        (url.map(isBestCamURL) ?? false) ||
                                        (url.map(isStarwankURL) ?? false) ||
                                        (url.map(isPussyspaceURL) ?? false) ||
                                        Self.isSingleUnprobedFormat(mediaInfo)

        // 1. Audio downloads: return early with audio extraction and quality options
        if options.fileType.isAudio {
            let formatId: String
            if isSynthesizedDirectStream {
                formatId = "b/best"
            } else if let customFormatId = options.selectedFormatId, !customFormatId.isEmpty, Self.isSafeFormatId(customFormatId) {
                formatId = customFormatId
            } else if let info = mediaInfo, let firstAudio = info.resolveSelectedFormats(options: options).first {
                formatId = firstAudio.formatId
            } else {
                formatId = "bestaudio/best"
            }
            args.append(contentsOf: ["-x", "--audio-format", options.fileType.fileExtension, "-f", formatId])
            if let quality = options.audioQuality {
                args.append(contentsOf: ["--audio-quality", quality.ytdlpValue])
            }
            return args
        }

        // 2. Video format selection
        if let customFormatId = options.selectedFormatId, !customFormatId.isEmpty, Self.isSafeFormatId(customFormatId) {
            let formatId: String
            if isSynthesizedDirectStream {
                formatId = "b/best"
            } else if !customFormatId.contains("+") {
                // If the selected format is video-only, automatically append best audio (+ba/b)
                if let info = mediaInfo,
                   let matchedFmt = info.formats?.first(where: { $0.formatId == customFormatId }),
                   matchedFmt.isVideoOnly {
                    formatId = "\(customFormatId)+ba/b"
                } else {
                    formatId = customFormatId
                }
            } else {
                formatId = customFormatId
            }
            args.append(contentsOf: ["-f", formatId])
        } else if let resolved = mediaInfo?.resolveSelectedFormats(options: options), !resolved.isEmpty {
            let formatId: String
            if isSynthesizedDirectStream {
                formatId = "b/best"
            } else if resolved.count == 2 {
                formatId = "\(resolved[0].formatId)+\(resolved[1].formatId)"
            } else {
                formatId = resolved[0].formatId
            }
            args.append(contentsOf: ["-f", formatId])
        } else {
            let maxH = options.videoResolution?.maxHeight
            let selector: String
            if isSynthesizedDirectStream {
                selector = "b/best"
            } else if let h = maxH {
                if options.resolutionFallbackPolicy == .allowHigher {
                    selector = "bestvideo[height<=\(h)]+bestaudio/best[height<=\(h)]/bestvideo[height>\(h)]+bestaudio/best[height>\(h)]/best"
                } else {
                    // Strict ceiling: Best available ≤ requested height (e.g. 720p requested -> best <= 720p)
                    selector = "bestvideo[height<=\(h)]+bestaudio/best[height<=\(h)]"
                }
            } else {
                selector = "bestvideo+bestaudio/best"
            }

            args.append(contentsOf: ["-f", selector])
            if let h = maxH {
                args.append(contentsOf: ["-S", "res:\(h),lang,quality,fps,hdr:12,vbr,abr,filesize"])
            } else {
                args.append(contentsOf: ["-S", "lang,quality,res,height,fps,hdr:12,vbr,abr,filesize"])
            }
        }

        // 3. Common video postprocessing: container selection, codec conversion, and tone mapping
        var finalMergeFormat = Self.compatibleMergeOutputFormat(for: options)
        let conversionCodec = options.conversionCodec ?? .none
        let isConvertToSDR = options.hdrAction == .convertToSDR

        var targetExt = options.fileType.fileExtension
        if conversionCodec == .av1 || conversionCodec == .vp9 {
            targetExt = "mkv"
        }
        if conversionCodec != .none {
            finalMergeFormat = targetExt
        }

        if let mergeOutputFormat = finalMergeFormat {
            args.append(contentsOf: ["--merge-output-format", mergeOutputFormat])
        }

        let needsRecode = (conversionCodec != .none) || isConvertToSDR
        if needsRecode {
            var videoConvertorArgs: [String] = ["-y"]
            if isConvertToSDR {
                videoConvertorArgs.append(contentsOf: ["-vf", "tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"])
            }

            switch conversionCodec {
            case .av1:
                videoConvertorArgs.append(contentsOf: ["-c:v", "libsvtav1", "-preset", "8", "-crf", "28", "-strict", "experimental"])
            case .h265:
                #if arch(arm64)
                videoConvertorArgs.append(contentsOf: ["-c:v", "hevc_videotoolbox", "-strict", "experimental"])
                #else
                videoConvertorArgs.append(contentsOf: ["-c:v", "libx265", "-strict", "experimental"])
                #endif
            case .vp9:
                videoConvertorArgs.append(contentsOf: ["-c:v", "libvpx-vp9", "-strict", "experimental"])
            case .h264:
                #if arch(arm64)
                videoConvertorArgs.append(contentsOf: ["-c:v", "h264_videotoolbox", "-strict", "experimental"])
                #else
                videoConvertorArgs.append(contentsOf: ["-c:v", "libx264", "-strict", "experimental"])
                #endif
            case .none:
                break
            }

            args.append(contentsOf: [
                "--recode-video", targetExt,
                "--postprocessor-args", "VideoConvertor:" + videoConvertorArgs.joined(separator: " ")
            ])
        }

        return args
    }

    nonisolated static func resolvedOutputFileExtension(for options: DownloadOptions) -> String {
        Self.compatibleMergeOutputFormat(for: options) ?? options.fileType.fileExtension
    }

    nonisolated static func compatibleMergeOutputFormat(for options: DownloadOptions) -> String? {
        guard options.fileType.isVideo else { return nil }

        if let conversionCodec = options.conversionCodec, conversionCodec != .none {
            if conversionCodec == .av1 || conversionCodec == .vp9 {
                return "mkv"
            }
            return options.fileType.fileExtension
        }

        let requestedVideoCodec = options.videoCodec ?? .auto
        let requestedAudioCodec = options.audioCodec ?? .auto

        switch options.fileType {
        case .mkv:
            return "mkv"
        case .webm:
            if requestedVideoCodec == .h264 || requestedVideoCodec == .h265 || requestedAudioCodec == .aac || requestedAudioCodec == .mp3 || requestedAudioCodec == .flac {
                return "mkv"
            }
            return "webm"
        case .mp4:
            if requestedVideoCodec == .vp9 || requestedVideoCodec == .av1 || requestedAudioCodec == .opus || requestedAudioCodec == .flac {
                return "mkv"
            }
            return "mp4"
        default:
            return nil
        }
    }

    private func codecFallbackOutputWarnings(options: DownloadOptions) -> [String] {
        var warnings: [String] = []

        if let videoCodec = options.videoCodec, videoCodec != .auto {
            warnings.append("[Siphon] WARNING: Requested video codec \(videoCodec.rawValue) will fall back to the best available video codec if no matching format is available.")
        }

        if let audioCodec = options.audioCodec, audioCodec != .auto {
            warnings.append("[Siphon] WARNING: Requested audio codec \(audioCodec.rawValue) will fall back to the best available audio codec if no matching format is available.")
        }

        return warnings
    }

    private func cookieScopeKey(browser: String, url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? "global"
        return "\(browser):\(host)"
    }

    private func isCookieDenied(browser: String, url: String) -> Bool {
        let key = cookieScopeKey(browser: browser, url: url)
        return deniedCookieSources.contains(key) || deniedCookieSources.contains(browser)
    }

    private func recordCookieDenial(browser: String, url: String, errorOutput: String) {
        // Without Full Disk Access macOS denies Safari's cookie file for every
        // site until Siphon relaunches. A per-host entry re-ran a failing yt-dlp
        // (about 4 s) for each new host, and again for its CDN host.
        if browser == "safari" && isSafariPermissionError(errorOutput) {
            deniedCookieSources.insert(browser)
        } else {
            deniedCookieSources.insert(cookieScopeKey(browser: browser, url: url))
        }
    }

    nonisolated static func cookiesFromBrowserArgument(for browser: String) -> String {
        return browser
    }

    private func appendCookieArgs(
        for url: String,
        to args: inout [String],
        force: Bool = false,
        browserOverride: String? = nil
    ) -> Bool {
        // Eporner videos are public, and its video API rejects a browser's
        // PHPSESSID with "Authorization failed. Try to reload page."
        if isEpornerURL(url) { return false }
        let browser: String?
        if browserOverride != nil {
            browser = Self.validatedBrowserCookieSource(browserOverride)
        } else {
            browser = configuredBrowserCookieSource()
        }
        guard let browser else { return false }
        if isCookieDenied(browser: browser, url: url) { return false }
        if force || !args.contains("--cookies-from-browser") {
            let cookieArg = Self.cookiesFromBrowserArgument(for: browser)
            args.append(contentsOf: ["--cookies-from-browser", cookieArg])
        }
        return true
    }

    nonisolated static func validatedBrowserCookieSource(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let browser = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if browser == "none" || browser.isEmpty { return nil }
        if browser == "helium" { return "chromium-based" }
        return SupportedBrowser.allowedRawValues.contains(browser) ? browser : nil
    }

    private func configuredBrowserCookieSource() -> String? {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.browserForCookies) ?? "safari"
        guard let browser = Self.validatedBrowserCookieSource(raw) else {
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "none" {
                LoggerService.shared.log("Invalid or unrecognized browserForCookies setting '\(raw)', falling back to none", level: .warning)
            }
            return nil
        }
        return browser
    }

    private func logCookieUsage(for url: String, usingBrowserCookies: Bool) {
        LoggerService.shared.log("yt-dlp request for \(hostForLog(url)) using browser cookies: \(usingBrowserCookies ? "yes" : "no")", level: .info)
    }

    private func hostForLog(_ url: String) -> String {
        URL(string: url)?.host ?? "unknown host"
    }

    private func appendJsRuntimeArgs(to args: inout [String]) {
        guard !args.contains("--js-runtimes") else { return }

        let fileManager = FileManager.default
        let homeDir = NSHomeDirectory()

        // Discover JS runtimes in order of preference for yt-dlp EJS challenge solving
        let candidatePaths: [(engine: String, path: String)] = [
            ("node", "/opt/homebrew/bin/node"),
            ("node", "/usr/local/bin/node"),
            ("bun", "\(homeDir)/.bun/bin/bun"),
            ("bun", "/opt/homebrew/bin/bun"),
            ("bun", "/usr/local/bin/bun"),
            ("deno", "/opt/homebrew/bin/deno"),
            ("deno", "/usr/local/bin/deno"),
            ("deno", "\(homeDir)/.deno/bin/deno"),
            ("quickjs", "/opt/homebrew/bin/qjs"),
            ("quickjs", "/usr/local/bin/qjs")
        ]

        for candidate in candidatePaths {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                args.append(contentsOf: ["--js-runtimes", "\(candidate.engine):\(candidate.path)"])
                return
            }
        }
    }
    
    private func isRecuURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "recu.me" || host.hasSuffix(".recu.me")
    }

    private struct RecuExtractedMedia {
        let videoID: String
        let model: String
        let playlistURL: String
        let pageURL: String
        let title: String
        let thumbnailURL: String?
        let userAgent: String?
    }

    nonisolated static func recuVideoIdentity(from urlString: String) -> (model: String, videoID: String)? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "recu.me" || host.hasSuffix(".recu.me") else {
            return nil
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3,
              parts[1].lowercased() == "video",
              !parts[0].isEmpty,
              !parts[2].isEmpty,
              parts[2].allSatisfy(\.isNumber) else {
            return nil
        }
        if parts.count >= 4 && parts[3].lowercased() != "play" {
            return nil
        }
        return (model: parts[0], videoID: parts[2])
    }

    nonisolated static func recuPlaylistURL(from apiResponse: String) -> String? {
        let decoded = apiResponse.decodingHTMLEntities()
            .replacingOccurrences(of: "\\/", with: "/")
        for regex in recuPlaylistRegexes {
            guard let match = regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: decoded) else {
                continue
            }
            let value = String(decoded[range]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: value),
                  url.scheme?.lowercased() == "https",
                  url.user == nil,
                  url.password == nil else {
                continue
            }
            return url.absoluteString
        }
        return nil
    }

    private func recuImpersonationTarget(
        rawUserAgent: String?,
        browserCookieSource: String? = nil
    ) -> String {
        let ua = rawUserAgent?.lowercased() ?? ""
        if ua.contains("firefox/") { return "firefox:macos" }
        if ua.contains("safari/") && !ua.contains("chrome/") && !ua.contains("chromium/") {
            return "safari:macos"
        }
        switch Self.validatedBrowserCookieSource(browserCookieSource) ?? configuredBrowserCookieSource() {
        case "firefox": return "firefox:macos"
        case "safari": return "safari:macos"
        default: return "chrome:macos"
        }
    }

    /// Recu's player appends the page token verbatim. The token carries its own
    /// `&`-separated parameters, so percent-encoding it as one value makes the API
    /// answer `wrong_token`.
    nonisolated static func recuAPIURL(videoID: String, token: String) -> String {
        "https://recu.me/api/video/\(videoID)?token=\(token)"
    }

    /// Recu's player adds `check` to every segment request (`window.__hlsCheck`);
    /// the CDN answers 422 without it. The value derives from the signed playlist query.
    nonisolated static func recuSegmentCheck(for playlistURL: String) -> String? {
        guard let items = URLComponents(string: playlistURL)?.queryItems else { return nil }
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        let check = String(value("request_id").prefix(4))
            + String(value("uid").dropFirst(2).prefix(4))
            + String(value("expires").suffix(4))
        // Keep it a single safe token inside yt-dlp's `--extractor-args` syntax.
        guard !check.isEmpty, check.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        return check
    }

    /// Mirrors Recu's own sign-in redirect, which returns to the video afterwards.
    nonisolated static func recuSignInURL(for pageURL: URL) -> URL? {
        URL(string: "https://recu.me/account/signin?url=\(Data(pageURL.path.utf8).base64EncodedString())")
    }

    enum RecuAPIOutcome: Equatable {
        case stream(String)
        case signInRequired
        case staleToken
        case denied(String)
    }

    /// Maps the exact state strings that Recu's own player handles.
    nonisolated static func recuAPIOutcome(from response: String) -> RecuAPIOutcome {
        switch response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "shall_signin":
            return .signInRequired
        case "wrong_token":
            return .staleToken
        case "shall_subscribe":
            return .denied("Recu.me refused playback for this account: its daily view limit is reached or the recording needs a membership.")
        case "shall_confirm_email":
            return .denied("Recu.me requires a confirmed email address for this account. Confirm it on recu.me, then retry.")
        case "views_restricted":
            return .denied("Recu.me has temporarily restricted playback of this recording.")
        default:
            if let playlistURL = recuPlaylistURL(from: response) {
                return .stream(playlistURL)
            }
            return .denied("Recu.me did not return a playable HLS stream for this recording.")
        }
    }

    struct RecuBrowserSession: Sendable {
        let pageHTML: String
        let playlistURL: String
        let userAgent: String?
    }

    private struct RecuPageState: Decodable {
        let challenge: Bool
        let token: String?
        let html: String?
        let userAgent: String?
    }

    final class RecuNavigationDelegate: NSObject, WKNavigationDelegate {
        func webView(
            _ _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let targetFrame = navigationAction.targetFrame else {
                decisionHandler(.cancel)
                return
            }
            // Cloudflare's check runs in a subframe; only the page itself stays on Recu.
            guard targetFrame.isMainFrame else {
                decisionHandler(.allow)
                return
            }
            let url = navigationAction.request.url
            let host = url?.host?.lowercased() ?? ""
            let isRecu = url?.scheme?.lowercased() == "https" && (host == "recu.me" || host.hasSuffix(".recu.me"))
            decisionHandler(isRecu ? .allow : .cancel)
        }
    }

    /// A real close, unlike `isVisible`, which is also false while Siphon is hidden (Cmd-H).
    @MainActor
    final class BrowserSessionWindowDelegate: NSObject, NSWindowDelegate {
        private(set) var didClose = false

        func windowWillClose(_ _: Notification) {
            didClose = true
        }
    }

    /// Shows a WebKit session so the user can complete a site's check or sign-in.
    /// A hidden, windowless WKWebView reports `document.visibilityState == "hidden"`,
    /// and Cloudflare's managed challenge never completes there.
    private func presentBrowserSessionWindow(
        _ webView: WKWebView,
        title: String,
        delegate: BrowserSessionWindowDelegate
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.title = title
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func recuPageState(_ webView: WKWebView, videoID: String) async -> RecuPageState? {
        let script = """
        const button = document.querySelector('#play_button[data-token]');
        const matches = !!button && button.getAttribute('data-video-id') === videoID;
        return JSON.stringify({
            challenge: !!document.getElementById('challenge-error-text') || /^just a moment/i.test(document.title),
            token: matches ? button.getAttribute('data-token') : null,
            html: matches ? document.documentElement.outerHTML : null,
            userAgent: navigator.userAgent
        });
        """
        let json: String? = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: ["videoID": videoID], in: nil, in: .defaultClient) { result in
                continuation.resume(returning: (try? result.get()) as? String)
            }
        }
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RecuPageState.self, from: data)
    }

    /// The page's fetch has no deadline of its own and WebKit ignores task
    /// cancellation, so a stalled request would hold the job (and its slot) after
    /// Stop. It aborts after `recuAPITimeoutMs` or as soon as the task is cancelled.
    private static let recuAPITimeoutMs = 20_000

    private func recuAPIResponse(_ webView: WKWebView, url: String) async throws -> String {
        let script = """
        const controller = new AbortController();
        window.__siphonRecuAbort = controller;
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        try {
            const response = await fetch(apiURL, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' }, signal: controller.signal });
            return await response.text();
        } finally {
            clearTimeout(timer);
        }
        """
        let response: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                webView.callAsyncJavaScript(
                    script,
                    arguments: ["apiURL": url, "timeoutMs": Self.recuAPITimeoutMs],
                    in: nil,
                    in: .defaultClient
                ) { result in
                    continuation.resume(returning: (try? result.get()) as? String)
                }
            }
        } onCancel: {
            Task { @MainActor in
                webView.evaluateJavaScript("window.__siphonRecuAbort?.abort()", in: nil, in: .defaultClient) { _ in
                    // The aborted fetch resumes the waiting request above.
                }
            }
        }
        try Task.checkCancellation()
        guard let response else {
            LoggerService.shared.log("[ProtectedSite] stage=api result=request-failed", level: .debug)
            throw YtdlpError.downloadFailed("Recu.me did not answer the video request. Check the connection, then retry.")
        }
        return response
    }

    /// Recu sits behind a Cloudflare managed challenge and plays only for signed-in
    /// accounts, which a plain HTTP client cannot satisfy. Siphon resolves it in its own
    /// WebKit session: hidden while that session's clearance and sign-in are valid, and
    /// shown in a window only when the user must complete Cloudflare's check or sign in.
    /// Siphon never completes either step itself.
    private func loadRecuBrowserSession(pageURL: URL, videoID: String) async throws -> RecuBrowserSession {
        if let loader = recuBrowserSessionLoader {
            return try await loader(pageURL, videoID)
        }
        guard processRunner is DefaultYtdlpProcessRunner else {
            throw YtdlpError.cloudflareBlocked
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = recuWebDataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: configuration)
        let navigationDelegate = RecuNavigationDelegate()
        webView.navigationDelegate = navigationDelegate
        webView.load(URLRequest(url: pageURL))

        var window: NSWindow?
        let windowDelegate = BrowserSessionWindowDelegate()
        defer {
            _ = navigationDelegate
            _ = windowDelegate
            webView.stopLoading()
            window?.close()
        }

        var deadline = Date().addingTimeInterval(15)
        var lastToken: String?
        var reloadedStaleToken = false

        func presentWindow(reason: String) {
            guard window == nil else { return }
            LoggerService.shared.log("[ProtectedSite] stage=browser-session result=\(reason); waiting for the user", level: .info)
            window = presentBrowserSessionWindow(
                webView,
                title: LanguageService.s("recu_verification_title"),
                delegate: windowDelegate
            )
            deadline = Date().addingTimeInterval(300)
        }

        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            try Task.checkCancellation()

            if windowDelegate.didClose {
                throw YtdlpError.downloadFailed("The recu.me window was closed before verification or sign-in finished.")
            }
            if Date() > deadline {
                guard window != nil else {
                    presentWindow(reason: "page-timeout")
                    continue
                }
                throw YtdlpError.downloadFailed("Recu.me verification or sign-in did not finish within 5 minutes.")
            }

            guard let state = await recuPageState(webView, videoID: videoID) else { continue }
            if state.challenge {
                presentWindow(reason: "challenge")
                continue
            }
            // A token is single-use for this loop: navigation leaves the old page
            // readable until the next one commits.
            guard let token = state.token, let html = state.html, token != lastToken else { continue }
            lastToken = token

            let response = try await recuAPIResponse(webView, url: Self.recuAPIURL(videoID: videoID, token: token))
            switch Self.recuAPIOutcome(from: response) {
            case .stream(let playlistURL):
                LoggerService.shared.log("[ProtectedSite] stage=api result=stream-found", level: .debug)
                return RecuBrowserSession(pageHTML: html, playlistURL: playlistURL, userAgent: state.userAgent)
            case .signInRequired:
                presentWindow(reason: "sign-in-required")
                if let signInURL = Self.recuSignInURL(for: pageURL) {
                    webView.load(URLRequest(url: signInURL))
                }
            case .staleToken:
                guard !reloadedStaleToken else {
                    throw YtdlpError.downloadFailed("Recu.me rejected the refreshed video token. Retry in a moment.")
                }
                reloadedStaleToken = true
                LoggerService.shared.log("[ProtectedSite] stage=api result=stale-token; reloading once", level: .info)
                webView.reload()
            case .denied(let message):
                LoggerService.shared.log("[ProtectedSite] stage=api result=denied bytes=\(response.utf8.count)", level: .debug)
                throw YtdlpError.downloadFailed(message)
            }
        }
    }

    private func resolveRecuMediaInfo(url: String) async throws -> RecuExtractedMedia {
        guard let identity = Self.recuVideoIdentity(from: url),
              let pageURL = URL(string: "https://recu.me/\(identity.model)/video/\(identity.videoID)/play") else {
            throw YtdlpError.downloadFailed("Unsupported protected-site URL. Expected /<model>/video/<id>/play.")
        }
        let session = try await loadRecuBrowserSession(pageURL: pageURL, videoID: identity.videoID)
        let lastPageHTML = session.pageHTML

        let title: String = {
            for regex in Self.ogTitleRegexes {
                guard let match = regex.firstMatch(in: lastPageHTML, range: NSRange(lastPageHTML.startIndex..., in: lastPageHTML)),
                      match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: lastPageHTML) else {
                    continue
                }
                var value = String(lastPageHTML[range])
                if let stripRegex = Self.htmlTagStripRegex {
                    value = stripRegex.stringByReplacingMatches(in: value, options: [], range: NSRange(location: 0, length: (value as NSString).length), withTemplate: "")
                }
                value = value.decodingHTMLEntities().trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return "\(identity.model) - \(identity.videoID)"
        }()

        let thumbnail: String? = {
            for regex in Self.ogImageRegexes {
                guard let match = regex.firstMatch(in: lastPageHTML, range: NSRange(lastPageHTML.startIndex..., in: lastPageHTML)),
                      match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: lastPageHTML) else {
                    continue
                }
                let value = String(lastPageHTML[range]).decodingHTMLEntities()
                if let candidate = URL(string: value),
                   ["http", "https"].contains(candidate.scheme?.lowercased() ?? "") {
                    return candidate.absoluteString
                }
            }
            return nil
        }()

        return RecuExtractedMedia(
            videoID: identity.videoID,
            model: identity.model,
            playlistURL: session.playlistURL,
            pageURL: pageURL.absoluteString,
            title: title,
            thumbnailURL: thumbnail,
            userAgent: session.userAgent
        )
    }

    // MARK: - Gayteam (player capture)

    private func isGayteamURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "gayteam.club" || host.hasSuffix(".gayteam.club")
    }

    /// A stream a player loaded, and the player page that loaded it. That page's
    /// host is the Referer the stream's CDN expects (DoodStream redirects without it).
    struct CapturedStream: Sendable, Equatable {
        let url: String
        let frameURL: String
    }

    struct BrowserCapture: Sendable {
        let pageHTML: String
        let streams: [CapturedStream]
    }

    /// Page scripts report these, so only plain http(s) URLs pass. Ads are dropped
    /// by name here and, like previews, by duration when the stream is probed.
    nonisolated static func capturedStream(url: String, frameURL: String) -> CapturedStream? {
        guard url.count < 4096,
              let stream = URL(string: url),
              let frame = URL(string: frameURL),
              ["http", "https"].contains(stream.scheme?.lowercased() ?? ""),
              ["http", "https"].contains(frame.scheme?.lowercased() ?? ""),
              stream.host?.isEmpty == false,
              stream.user == nil,
              stream.password == nil else {
            return nil
        }
        let lower = url.lowercased()
        guard !["/vast", "preroll", "/ads/", "/ad/"].contains(where: { lower.contains($0) }) else { return nil }
        return CapturedStream(url: url, frameURL: frameURL)
    }

    /// Runs in every frame. In the page it starts lazy (`data-src`) player frames;
    /// in every frame it reports what a player loads: a <video>'s source (DoodStream
    /// plays an MP4 directly) or an HLS playlist fetched by script (StreamWish-style).
    nonisolated static let browserCaptureScript = #"""
    (() => {
        if (window.__siphonCapture) return;
        window.__siphonCapture = true;
        const seen = new Set();
        const report = (url) => {
            if (typeof url !== 'string' || !/^https?:\/\//i.test(url) || seen.has(url)) return;
            seen.add(url);
            try {
                window.webkit.messageHandlers.siphonCapture.postMessage({ url, frame: location.href });
            } catch (_) {}
        };
        try {
            new PerformanceObserver((list) => list.getEntries().forEach((entry) => {
                if (/\.m3u8(?:[?#]|$)/i.test(entry.name)) report(entry.name);
            })).observe({ type: 'resource', buffered: true });
        } catch (_) {}
        setInterval(() => {
            document.querySelectorAll('video, video source').forEach((el) => report(el.currentSrc || el.src));
            if (window !== window.top) return;
            document.querySelectorAll('iframe[data-src]').forEach((frame) => {
                const source = frame.getAttribute('data-src');
                if (!frame.getAttribute('src') && /^https?:\/\//i.test(source)) frame.setAttribute('src', source);
            });
        }, 500);
    })();
    """#

    /// WebKit retains a script message handler; the session removes it when done.
    @MainActor
    final class BrowserCaptureMessageHandler: NSObject, WKScriptMessageHandler {
        private(set) var streams: [CapturedStream] = []

        func userContentController(_ _: WKUserContentController, didReceive message: WKScriptMessage) {
            guard streams.count < 32,
                  let body = message.body as? [String: Any],
                  let url = body["url"] as? String,
                  let frameURL = body["frame"] as? String,
                  let stream = YtdlpService.capturedStream(url: url, frameURL: frameURL),
                  !streams.contains(stream) else {
                return
            }
            streams.append(stream)
        }
    }

    final class BrowserCaptureNavigationDelegate: NSObject, WKNavigationDelegate {
        private let siteHost: String

        init(siteHost: String) {
            self.siteHost = siteHost
        }

        /// The page stays on its site. Frames load what a browser would (players,
        /// Cloudflare's widget, ads); popups are refused.
        nonisolated static func allowsNavigation(to url: URL?, isMainFrame: Bool?, siteHost: String) -> Bool {
            guard let isMainFrame, let scheme = url?.scheme?.lowercased() else { return false }
            guard isMainFrame else { return ["https", "http", "about", "data"].contains(scheme) }
            guard scheme == "https" || scheme == "http", let host = url?.host?.lowercased() else { return false }
            return host == siteHost || host.hasSuffix("." + siteHost)
        }

        func webView(
            _ _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard Self.allowsNavigation(
                to: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame,
                siteHost: siteHost
            ) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    /// Loads the page in Siphon's WebKit session and collects the streams its
    /// players load. Hidden while the session's clearance is valid. Cloudflare's
    /// check, or players that wait for a click, open the page in a window; Siphon
    /// never completes a check or presses play itself.
    private func captureBrowserStreams(
        pageURL: URL,
        siteHost: String,
        store: WKWebsiteDataStore,
        requestedAt: Date
    ) async throws -> BrowserCapture {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let messageHandler = BrowserCaptureMessageHandler()
        configuration.userContentController.add(messageHandler, name: "siphonCapture")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.browserCaptureScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
        let navigationDelegate = BrowserCaptureNavigationDelegate(siteHost: siteHost)
        webView.navigationDelegate = navigationDelegate
        webView.load(URLRequest(url: pageURL))

        var window: NSWindow?
        let windowDelegate = BrowserSessionWindowDelegate()
        defer {
            _ = navigationDelegate
            configuration.userContentController.removeScriptMessageHandler(forName: "siphonCapture")
            webView.stopLoading()
            window?.close()
        }

        var deadline = Date().addingTimeInterval(20)
        var firstStreamAt: Date?

        func presentWindow(reason: String) throws {
            guard window == nil else { return }
            guard mayOpenSessionWindow(for: siteHost, requestedAt: requestedAt) else {
                throw YtdlpError.downloadFailed("The \(siteHost) window was closed, so Siphon stopped the downloads waiting for it. Retry to open it again.")
            }
            LoggerService.shared.log("[ProtectedSite] stage=capture-webkit result=\(reason); waiting for the user", level: .info)
            window = presentBrowserSessionWindow(
                webView,
                title: String(format: LanguageService.s("site_play_title"), pageURL.host ?? siteHost),
                delegate: windowDelegate
            )
            deadline = Date().addingTimeInterval(300)
        }

        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            try Task.checkCancellation()

            if windowDelegate.didClose {
                sessionWindowClosedAt[siteHost] = Date()
                throw YtdlpError.downloadFailed("The \(siteHost) window was closed before a video started.")
            }
            // Players start within a moment of each other; keep the order they started in.
            if !messageHandler.streams.isEmpty {
                let first = firstStreamAt ?? Date()
                firstStreamAt = first
                if Date().timeIntervalSince(first) >= 1.5 { break }
                continue
            }
            if Date() > deadline {
                guard window == nil else {
                    throw YtdlpError.downloadFailed("No video started on \(siteHost) within 5 minutes.")
                }
                try presentWindow(reason: "no-stream")
                continue
            }
            if let html = await boyfriendTVWebViewDocumentHTML(webView), isBoyfriendTVChallengeHTML(html) {
                try presentWindow(reason: "challenge")
            }
        }
        LoggerService.shared.log("[ProtectedSite] stage=capture-webkit result=streams count=\(messageHandler.streams.count)", level: .debug)
        return BrowserCapture(
            pageHTML: await boyfriendTVWebViewDocumentHTML(webView) ?? "",
            streams: messageHandler.streams
        )
    }

    /// Gayteam lazy-loads third-party players (DoodStream, StreamWish and similar
    /// hosts that rotate domains) behind Cloudflare; yt-dlp supports neither. Siphon
    /// takes the stream a player loads in its WebKit session and probes it.
    private func resolveGayteamMediaInfo(url: String, path: String, proxy: String?) async throws -> MediaInfo {
        guard let pageURL = URL(string: url) else {
            throw YtdlpError.downloadFailed("Unsupported Gayteam URL.")
        }
        let capture: BrowserCapture
        if let loader = browserCaptureLoader {
            capture = try await loader(pageURL)
        } else {
            guard processRunner is DefaultYtdlpProcessRunner else { throw YtdlpError.cloudflareBlocked }
            let requestedAt = Date()
            capture = try await withExclusiveWebKitSession {
                try await captureBrowserStreams(
                    pageURL: pageURL,
                    siteHost: "gayteam.club",
                    store: gayteamWebDataStore,
                    requestedAt: requestedAt
                )
            }
        }

        let title = Self.firstRegexCapture(in: capture.pageHTML, regexes: Self.ogTitleRegexes) { raw in
            let value = raw.decodingHTMLEntities().trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let thumbnail = Self.protectedThumbnail(in: capture.pageHTML, regexes: Self.ogImageRegexes)

        // Direct files first (DoodStream serves the upload itself), in the order the
        // players started. HLS is the fallback: StreamWish-style hosts hide segments
        // behind a fake PNG header on an image CDN, which ffmpeg can't read.
        // ponytail: no segment unwrapping; add it if a site has only such players.
        let isHLS = { (stream: CapturedStream) in URL(string: stream.url)?.pathExtension.lowercased() == "m3u8" }
        for stream in capture.streams.filter({ !isHLS($0) }) + capture.streams.filter(isHLS) {
            var args = [path, "--ignore-config", "--dump-json", "--no-playlist", "--no-warnings"]
            appendSiteSpecificArgs(for: stream.frameURL, to: &args)
            if let proxy, !proxy.isEmpty {
                args.append(contentsOf: ["--proxy", proxy])
            }
            args.append(contentsOf: ["--", stream.url])
            let parsed: MediaInfo?
            do {
                parsed = try await runCommand(args).data(using: .utf8).flatMap {
                    try? JSONDecoder().decode(MediaInfo.self, from: $0)
                }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                parsed = nil
            }
            // An ad or a preview: the scene itself runs for many minutes.
            guard let parsed, (parsed.duration ?? .infinity) >= 60 else {
                LoggerService.shared.log("[ProtectedSite] stage=stream-probe result=rejected", level: .debug)
                continue
            }
            var info = MediaInfo(
                id: url,
                title: title ?? parsed.title,
                thumbnail: thumbnail ?? parsed.thumbnail,
                duration: parsed.duration,
                uploader: "Gayteam",
                formats: parsed.formats,
                webpageUrl: stream.frameURL,
                originalUrl: stream.url,
                formatProtocol: stream.url.contains(".m3u8") ? "m3u8_native" : "https",
                manifestUrl: stream.url
            )
            info.fetchedAt = Date()
            return info
        }
        throw YtdlpError.downloadFailed(capture.streams.isEmpty
            ? "Gayteam's players didn't load a video. It may have been removed from every player on the page."
            : "None of the videos Gayteam's players loaded could be downloaded. Retry in a moment.")
    }

    private func isGayPornTubeURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "gayporntube.com" || host.hasSuffix(".gayporntube.com")
    }

    private func usesBrowserTransport(_ url: String) -> Bool {
        isBoyfriendTVURL(url) || isGayPornTubeURL(url) || isRecuURL(url)
    }

    // Let curl-impersonate supply a consistent TLS fingerprint and HTTP headers.
    // Hard-coded Chrome headers mixed with Safari/Firefox cookies are contradictory.
    private func refreshBrowserTransportIdentity(for url: String, args: inout [String]) {
        guard usesBrowserTransport(url), !isRecuURL(url) else { return }
        let optionEnd = args.firstIndex(of: "--") ?? args.count
        let options = Array(args[..<optionEnd])
        let suffix = Array(args[optionEnd...])
        let browser = options.firstIndex(of: "--cookies-from-browser").flatMap {
            $0 + 1 < options.count ? options[$0 + 1] : nil
        }
        let target: String
        switch browser {
        case "safari": target = "safari:macos"
        case "firefox": target = "firefox:macos"
        default: target = "chrome:macos"
        }
        var clean: [String] = []
        var index = 0
        while index < options.count {
            let arg = options[index]
            if index + 1 < options.count {
                let value = options[index + 1]
                if arg == "--user-agent" ||
                    (arg == "--add-header" && (value.lowercased().hasPrefix("sec-ch-ua") || value.lowercased().hasPrefix("user-agent:"))) {
                    index += 2
                    continue
                }
                if arg == "--extractor-args" && value.hasPrefix("generic:impersonate") {
                    index += 2
                    continue
                }
            }
            clean.append(arg)
            index += 1
        }
        clean.append(contentsOf: ["--extractor-args", "generic:impersonate=\(target)"])
        args = clean + suffix
    }

    private func isBoyfriendTVURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "boyfriend.tv" || host.hasSuffix(".boyfriend.tv") ||
               host == "boyfriendtv.com" || host.hasSuffix(".boyfriendtv.com")
    }

    nonisolated static func boyfriendTVAlternateURL(for urlString: String) -> String? {
        guard var components = URLComponents(string: urlString),
              let host = components.host?.lowercased() else {
            return nil
        }

        if host == "boyfriendtv.com" || host.hasSuffix(".boyfriendtv.com") {
            components.host = "www.boyfriend.tv"
        } else if host == "boyfriend.tv" || host.hasSuffix(".boyfriend.tv") {
            components.host = "www.boyfriendtv.com"
        } else {
            return nil
        }
        components.scheme = "https"
        return components.url?.absoluteString
    }

    nonisolated static func boyfriendTVBrowserCandidates(
        configured: String?,
        installed: [String],
        hasFullDiskAccess: Bool
    ) -> [String?] {
        var result: [String?] = []
        var seen = Set<String>()

        func appendBrowser(_ browser: String) {
            let normalized = browser.lowercased()
            guard normalized != "none",
                  !normalized.isEmpty,
                  normalized != "safari" || hasFullDiskAccess || configured?.lowercased() == "safari",
                  seen.insert(normalized).inserted else {
                return
            }
            result.append(normalized)
        }

        if let configured {
            appendBrowser(configured)
        }

        // A selected browser is an explicit session choice. Do not spray a protected
        // endpoint with unrelated browser profiles after a 403; Cloudflare can treat
        // that as a new client on every request. Automatic discovery is only used
        // when no usable browser was selected.
        if result.isEmpty {
            let installedSet = Set(installed.map { $0.lowercased() })
            for browser in ["chrome", "brave", "edge", "vivaldi", "chromium", "firefox", "opera", "safari", "helium", "chromium-based"]
                where installedSet.contains(browser) {
                appendBrowser(browser)
            }
        }

        // Keep one anonymous attempt as the final transport fallback.
        result.append(nil)
        return result
    }

    nonisolated static func boyfriendTVCookieScope(for urlString: String) -> String? {
        let host = (URL(string: urlString)?.host ?? urlString).lowercased()
        if host == "boyfriend.tv" || host.hasSuffix(".boyfriend.tv") {
            return "boyfriend.tv"
        }
        if host == "boyfriendtv.com" || host.hasSuffix(".boyfriendtv.com") {
            return "boyfriendtv.com"
        }
        return nil
    }

    nonisolated static func shouldForwardBoyfriendTVRawCookies(
        from sourceURL: String,
        to destinationURL: String
    ) -> Bool {
        guard let sourceScope = boyfriendTVCookieScope(for: sourceURL),
              let destinationScope = boyfriendTVCookieScope(for: destinationURL) else {
            return false
        }
        return sourceScope == destinationScope
    }

    nonisolated static func boyfriendTVThumbnailReferer(for urlString: String) -> String? {
        switch boyfriendTVCookieScope(for: urlString) {
        case "boyfriend.tv":
            return "https://www.boyfriend.tv/"
        case "boyfriendtv.com":
            return "https://www.boyfriendtv.com/"
        default:
            return nil
        }
    }

    struct BoyfriendTVExtractedMedia {
        let streamURL: String
        let embedURL: String
        let title: String
        let thumbnailURL: String?
    }

    /// Markers of Cloudflare's challenge page itself. Not `/cdn-cgi/challenge-platform/`:
    /// Cloudflare also injects that bot-detection script into the real, playable page.
    private func isBoyfriendTVChallengeHTML(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("cf-chl-") ||
               lower.contains("_cf_chl_opt") ||
               lower.contains("challenge-error-text") ||
               lower.contains("<title>just a moment") ||
               lower.contains("cf-turnstile")
    }

    /// The members-only notice. Its element class is the same in every language; the
    /// link text is not ("Login", "Ingrese", ...).
    private func isBoyfriendTVLoginHTML(_ html: String) -> Bool {
        let lower = html.lowercased()
        return (lower.contains("to watch this video please") && lower.contains("login")) ||
               lower.range(of: #"class\s*=\s*["'][^"']*\bloginprotected\b"#, options: .regularExpression) != nil ||
               lower.contains("user has been banned")
    }

    nonisolated static func boyfriendTVCookies(from cookieHeader: String, for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased(),
              boyfriendTVCookieScope(for: url.absoluteString) != nil else {
            return []
        }

        return cookieHeader.split(separator: ";", omittingEmptySubsequences: true).compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }

            let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !name.contains("\r"),
                  !name.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\n") else {
                return nil
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: "/"
            ]
            if url.scheme?.lowercased() == "https" {
                properties[.secure] = "TRUE"
            }
            return HTTPCookie(properties: properties)
        }
    }

    private func seedBoyfriendTVWebKitCookies(_ rawCookies: String?, for url: URL) async {
        guard let rawCookies, !rawCookies.isEmpty else { return }
        let cookies = Self.boyfriendTVCookies(from: rawCookies, for: url)
        guard !cookies.isEmpty else { return }

        let store = boyfriendTVWebDataStore.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
        LoggerService.shared.log(
            "[BoyfriendTV] stage=webkit-session cookies-seeded=\(cookies.count)",
            level: .debug
        )
    }

    /// The user's BoyfriendTV cookies from Safari. A sign-in made there with "Remember
    /// me" ticked is a persistent cookie Siphon can carry over, for when the site's
    /// sign-in doesn't complete in Siphon's own window. Cloudflare's cookies stay out:
    /// they are bound to Safari's fingerprint, and WebKit gets its own.
    nonisolated static func boyfriendTVSessionCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { cookie in
            let name = cookie.name.lowercased()
            let host = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return boyfriendTVCookieScope(for: host) != nil &&
                !name.hasPrefix("cf_") && !name.hasPrefix("__cf") && name != "_cfuvid"
        }
    }

    private func seedBoyfriendTVSafariSession() async {
        let cookies = Self.boyfriendTVSessionCookies(from: safariCookiesProvider())
        guard !cookies.isEmpty else { return }
        let store = boyfriendTVWebDataStore.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
        LoggerService.shared.log("[BoyfriendTV] stage=webkit-session safari-cookies=\(cookies.count)", level: .debug)
    }

    private func boyfriendTVWebViewDocumentHTML(_ webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.outerHTML") { value, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: value as? String)
            }
        }
    }

    private func boyfriendTVWebViewRuntimeMediaURL(_ webView: WKWebView) async -> String? {
        let script = """
        (() => {
            const values = [];
            const seenValues = new Set();
            const push = (value) => {
                if (typeof value !== 'string' || value.length === 0 || seenValues.has(value)) return;
                seenValues.add(value);
                values.push(value);
            };

            document.querySelectorAll('video').forEach((video) => {
                push(video.currentSrc);
                push(video.src);
            });
            document.querySelectorAll('source').forEach((source) => {
                push(source.src);
                push(source.getAttribute('src'));
            });

            try {
                performance.getEntriesByType('resource').forEach((entry) => push(entry.name));
            } catch (_) {}

            const walk = (value, depth, visited) => {
                if (depth > 4 || value == null) return;
                if (typeof value === 'string') {
                    push(value);
                    return;
                }
                if (typeof value !== 'object' || visited.has(value)) return;
                visited.add(value);
                let keys = [];
                try { keys = Object.keys(value).slice(0, 128); } catch (_) { return; }
                for (const key of keys) {
                    try { walk(value[key], depth + 1, visited); } catch (_) {}
                    if (values.length >= 512) return;
                }
            };

            for (const key of ['playerConfig', 'videoPlayerData', 'sources', 'hlsAuto', 'hls']) {
                try { walk(window[key], 0, new Set()); } catch (_) {}
            }

            return values.slice(0, 512);
        })();
        """

        let values: [String]? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                guard error == nil, let values = value as? [String] else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: values)
            }
        }

        for value in values ?? [] {
            if let validated = validatedBoyfriendTVStreamURL(value) {
                return validated
            }
        }
        return nil
    }

    private func boyfriendTVHTML(_ html: String, appendingRuntimeStream streamURL: String?) -> String {
        guard let streamURL,
              let validated = validatedBoyfriendTVStreamURL(streamURL),
              let data = try? JSONSerialization.data(withJSONObject: ["hlsAuto": validated]),
              let json = String(data: data, encoding: .utf8) else {
            return html
        }
        return html + "\n<script type=\"application/json\" data-siphon-runtime-media>\(json)</script>"
    }

    final class BoyfriendTVNavigationDelegate: NSObject, WKNavigationDelegate {
        /// The page may only navigate within BoyfriendTV (both domains). Frames may
        /// also load Cloudflare's challenge widget, which the challenge cannot
        /// complete without, and script-built `about:` frames, which fetch nothing.
        /// Popups and every other target are refused.
        nonisolated static func allowsNavigation(to url: URL?, isMainFrame: Bool?) -> Bool {
            guard let isMainFrame, let scheme = url?.scheme?.lowercased() else { return false }
            if !isMainFrame && scheme == "about" { return true }
            guard scheme == "https" || scheme == "http", let host = url?.host?.lowercased() else {
                return false
            }
            let isBoyfriendTV = ["boyfriend.tv", "boyfriendtv.com"].contains { host == $0 || host.hasSuffix("." + $0) }
            return isBoyfriendTV || (!isMainFrame && host == "challenges.cloudflare.com")
        }

        func webView(
            _ _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard Self.allowsNavigation(
                to: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame
            ) else {
                // Host and frame only: paths and queries can carry tokens.
                let url = navigationAction.request.url
                let frame = navigationAction.targetFrame.map { $0.isMainFrame ? "main" : "sub" } ?? "popup"
                LoggerService.shared.log(
                    "[ProtectedSite] stage=webkit-navigation refused frame=\(frame) scheme=\(url?.scheme ?? "none") host=\(url?.host ?? "none")",
                    level: .debug
                )
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    /// Executes BoyfriendTV's JavaScript challenge in a real browser engine.
    /// The website data store is non-persistent but shared across main/embed loads so
    /// short-lived Cloudflare clearance cookies can be reused during one app session.
    private func loadBoyfriendTVRenderedPage(_ url: URL, stage: String, rawCookies: String? = nil) async throws -> String? {
        guard (url.scheme == "https" || url.scheme == "http"),
              url.user == nil,
              url.password == nil,
              isBoyfriendTVURL(url.absoluteString) else {
            return nil
        }

        if let loader = boyfriendTVRenderedPageLoader {
            guard let rendered = try await loader(url) else { return nil }
            let runtimeStream = try await boyfriendTVRenderedStreamLoader?(url)
            let resolved = boyfriendTVHTML(rendered, appendingRuntimeStream: runtimeStream)
            let result: String
            if extractStreamURLFromHTML(resolved) != nil {
                result = "stream-found"
            } else if isBoyfriendTVChallengeHTML(resolved) {
                result = "challenge-page"
            } else if hasBoyfriendTVMediaData(resolved) {
                result = "player-found"
            } else {
                result = "page-ready"
            }
            LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=\(result)", level: .debug)
            return resolved
        }

        guard processRunner is DefaultYtdlpProcessRunner else {
            return nil
        }
        let requestedAt = Date()
        return try await withExclusiveWebKitSession {
            try await renderBoyfriendTVPage(url, stage: stage, rawCookies: rawCookies, requestedAt: requestedAt)
        }
    }

    private func renderBoyfriendTVPage(_ url: URL, stage: String, rawCookies: String?, requestedAt: Date) async throws -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = boyfriendTVWebDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        await seedBoyfriendTVWebKitCookies(rawCookies, for: url)
        if configuredBrowserCookieSource() == "safari" {
            await seedBoyfriendTVSafariSession()
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: configuration)
        let navigationDelegate = BoyfriendTVNavigationDelegate()
        webView.navigationDelegate = navigationDelegate
        // Keep WKWebView's native user-agent. Pretending to be Safari while running
        // inside WKWebView creates a contradictory JS/browser fingerprint and can
        // cause managed Cloudflare challenges to loop forever.
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        webView.load(request)
        var window: NSWindow?
        let windowDelegate = BrowserSessionWindowDelegate()
        defer {
            _ = navigationDelegate
            _ = windowDelegate
            webView.stopLoading()
            window?.close()
        }

        var lastHTML: String?
        var settledPolls = 0
        // Hidden while no check is shown (the session's clearance is valid). A check
        // opens the page in a window: Cloudflare's managed challenge completes only in
        // a visible page, and any interactive step is the user's. Siphon never completes it.
        var deadline = Date().addingTimeInterval(20)

        // False when the user closed a BoyfriendTV window after this job asked.
        func presentWindow() -> Bool {
            guard window == nil else { return true }
            guard mayOpenSessionWindow(for: "boyfriendtv", requestedAt: requestedAt) else { return false }
            LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=challenge; waiting for the user", level: .info)
            window = presentBrowserSessionWindow(
                webView,
                title: String(format: LanguageService.s("site_verification_title"), url.host ?? ""),
                delegate: windowDelegate
            )
            deadline = Date().addingTimeInterval(300)
            return true
        }

        while Date() < deadline, !windowDelegate.didClose {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            try Task.checkCancellation()

            guard let rendered = await boyfriendTVWebViewDocumentHTML(webView),
                  !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let runtimeStream = await boyfriendTVWebViewRuntimeMediaURL(webView)
            let resolved = boyfriendTVHTML(rendered, appendingRuntimeStream: runtimeStream)
            lastHTML = resolved

            if extractStreamURLFromHTML(resolved) != nil {
                LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=stream-found", level: .debug)
                return resolved
            }

            if isBoyfriendTVChallengeHTML(resolved) {
                settledPolls = 0
                guard presentWindow() else { return resolved }
                continue
            }

            // Members-only, and this session isn't signed in. The site's sign-in does not
            // complete in Siphon's window, so the caller asks for the Safari sign-in.
            if isBoyfriendTVLoginHTML(resolved) {
                guard !webView.isLoading else { continue }
                LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=login-page", level: .debug)
                return resolved
            }

            if !webView.isLoading {
                settledPolls += 1
                if settledPolls >= 3 {
                    let result = hasBoyfriendTVMediaData(resolved) ? "player-ready" : "page-ready"
                    LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=\(result)", level: .debug)
                    return resolved
                }
            }
        }

        let finalResult: String
        if windowDelegate.didClose {
            finalResult = "window-closed"
            sessionWindowClosedAt["boyfriendtv"] = Date()
        } else if let lastHTML {
            finalResult = isBoyfriendTVChallengeHTML(lastHTML) ? "challenge-timeout" : "page-timeout"
        } else {
            finalResult = "no-html"
        }
        LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=\(finalResult)", level: .debug)
        return lastHTML
    }

    private func resolveBoyfriendTVMediaInfo(
        url: String,
        rawCookies: String? = nil,
        rawUserAgent: String? = nil,
        browserCookieSource: String? = nil
    ) async throws -> BoyfriendTVExtractedMedia? {
        let targetUrl = normalizeURLForYtdlp(url)
        guard let pageURL = URL(string: targetUrl) else { return nil }
        let effectiveBrowserSource =
            Self.validatedBrowserCookieSource(browserCookieSource) ?? configuredBrowserCookieSource()

        var pageCandidates: [URL] = [pageURL]
        if let alternateString = Self.boyfriendTVAlternateURL(for: targetUrl),
           let alternateURL = URL(string: alternateString),
           alternateURL != pageURL {
            pageCandidates.append(alternateURL)
        }
        var resolvedPageURL = pageURL
        var html = ""
        var safariCookieAccessDenied = deniedCookieSources.contains("safari")
        var sawChallenge = false
        var sawLoginPage = false
        var sawForbidden = false
        var sawUnauthorized = false
        var webKitChallengeTimedOut = false

        // Keep diagnostics categorical: page dumps and signed URLs contain secrets.
        func inspectPage(_ output: String, stage: String) -> String {
            let decoded = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let data = Data(base64Encoded: trimmed),
                      let text = String(data: data, encoding: .utf8) else { return nil }
                return text
            }.joined(separator: "\n")
            let lower = decoded.lowercased()
            let hasStream = extractStreamURLFromHTML(decoded) != nil
            let challenge = !hasStream && isBoyfriendTVChallengeHTML(decoded)
            let login = !hasStream && isBoyfriendTVLoginHTML(decoded)
            sawChallenge = sawChallenge || challenge
            sawLoginPage = sawLoginPage || login
            let result: String
            if hasStream {
                result = "stream-found"
            } else if challenge {
                result = "challenge-page"
            } else if login {
                result = "login-page"
            } else if decoded.isEmpty {
                result = "no-html"
            } else {
                result = "no-stream"
            }
            LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=\(result)", level: .debug)
            return decoded
        }

        func dumpPage(_ args: [String], stage: String) async throws -> String {
            var didRetry = false
            while true {
                try Task.checkCancellation()
                let output: String
                do {
                    output = try await processRunner.runCommand(args)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    guard case YtdlpError.commandFailed(let failure) = error else {
                        LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=process-failure", level: .debug)
                        throw error
                    }
                    output = failure
                }
                try Task.checkCancellation()
                // Classify only diagnostic lines, never URLs or base64 page content.
                let diagnostic = output.split(whereSeparator: \.isNewline)
                    .filter { $0.hasPrefix("ERROR:") || $0.hasPrefix("WARNING:") }
                    .joined(separator: "\n")
                    .replacingOccurrences(of: #"https?://\S+"#, with: "[URL]", options: .regularExpression)
                let lower = diagnostic.lowercased()
                let challenge = lower.contains("cloudflare") || lower.contains("captcha") || lower.contains("challenge") || lower.contains("turnstile")
                sawChallenge = sawChallenge || challenge
                sawForbidden = sawForbidden || lower.contains("403") || lower.contains("forbidden")
                sawUnauthorized = sawUnauthorized || lower.contains("http error 401")
                if args.contains("safari"), isSafariPermissionError(output) {
                    safariCookieAccessDenied = true
                    recordCookieDenial(browser: "safari", url: args.last ?? targetUrl, errorOutput: output)
                }
                let html = inspectPage(output, stage: stage)
                let transient = isTransientServerError(lower) || lower.contains("timed out")
                let classification: String
                if challenge {
                    classification = "challenge"
                } else if transient {
                    classification = "transient"
                } else if lower.contains("401") {
                    classification = "http-401"
                } else if lower.contains("403") {
                    classification = "http-403"
                } else if lower.contains("unsupported url") {
                    classification = "unsupported-url"
                } else if diagnostic.isEmpty {
                    classification = "none"
                } else {
                    classification = "other"
                }
                LoggerService.shared.log("[ProtectedSite] stage=\(stage) yt-dlp=\(classification)", level: .debug)
                let challengePage = isBoyfriendTVChallengeHTML(html)
                if !didRetry && (challenge || challengePage || transient) && !hasBoyfriendTVMediaData(html) {
                    didRetry = true
                    LoggerService.shared.log("[ProtectedSite] Retrying transient page resolution once", level: .info)
                    continue
                }
                return html
            }
        }
        
        func fetchPage(_ request: URLRequest, stage: String) async throws -> String? {
            try Task.checkCancellation()
            do {
                let (data, response) = try await EgressBoundary.session.boundedData(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { return nil }
                sawForbidden = sawForbidden || http.statusCode == 403
                sawUnauthorized = sawUnauthorized || http.statusCode == 401
                LoggerService.shared.log("[ProtectedSite] stage=\(stage) http=\(http.statusCode)", level: .debug)
                let page = inspectPage(data.base64EncodedString(), stage: stage)
                return http.statusCode == 200 ? page : nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                LoggerService.shared.log("[ProtectedSite] stage=\(stage) result=transport-failure", level: .debug)
                return nil
            }
        }

        let ytdlpBinary = resolvedYtdlpBinary

        // Try raw session cookies if provided (e.g. from browser extension)
        if let raw = rawCookies, !raw.isEmpty, let ytdlp = ytdlpBinary,
           let tempFile = createTempCookiesFileFromHeader(url: targetUrl, cookieHeader: raw) {
            defer { try? FileManager.default.removeItem(at: tempFile) }
            var rawArgs = [ytdlp.path, "--ignore-config", "--dump-pages", "--skip-download", "--no-playlist", "--cookies", tempFile.path]
            appendSiteSpecificArgs(for: targetUrl, to: &rawArgs)
            rawArgs.append("--")
            rawArgs.append(targetUrl)
            
            let rawHtml = try await dumpPage(rawArgs, stage: "main-session")
            if hasBoyfriendTVMediaData(rawHtml) { html = rawHtml }
        }

        // The user's own sign-in from Safari ("Remember me" makes it a saved cookie),
        // without Safari's Cloudflare cookies: those are bound to Safari's fingerprint,
        // and with them Cloudflare refuses yt-dlp (403). Without them this is the
        // anonymous request, plus the user's session.
        var safariSessionSignedOut = false
        if html.isEmpty, rawCookies?.isEmpty != false, effectiveBrowserSource == "safari",
           let ytdlp = ytdlpBinary, let scope = Self.boyfriendTVCookieScope(for: targetUrl) {
            let header = Self.boyfriendTVSessionCookies(from: safariCookiesProvider())
                .filter { Self.boyfriendTVCookieScope(for: $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == scope }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            if !header.isEmpty, let tempFile = createTempCookiesFileFromHeader(url: targetUrl, cookieHeader: header) {
                defer { try? FileManager.default.removeItem(at: tempFile) }
                var args = [ytdlp.path, "--ignore-config", "--dump-pages", "--skip-download", "--no-playlist", "--cookies", tempFile.path]
                appendSiteSpecificArgs(for: targetUrl, rawUserAgent: rawUserAgent, to: &args)
                args.append(contentsOf: ["--", targetUrl])
                let page = try await dumpPage(args, stage: "main-safari-session")
                if hasBoyfriendTVMediaData(page) {
                    html = page
                } else {
                    // Safari isn't signed in, so its cookies via yt-dlp can't do better.
                    safariSessionSignedOut = sawLoginPage
                }
            }
        }

        let installedBrowsers: [String]
        if let provider = installedBrowsersProvider {
            installedBrowsers = await provider()
        } else {
            installedBrowsers = await BrowserUtils.shared.getInstalledBrowsers().map(\.id)
        }
        let browsersToTry = Self.boyfriendTVBrowserCandidates(
            configured: effectiveBrowserSource,
            installed: installedBrowsers,
            hasFullDiskAccess: Self.hasFullDiskAccess
        )
        let browserLabels = browsersToTry.compactMap { $0 }
        LoggerService.shared.log(
            "[BoyfriendTV] stage=session-recovery browser-candidates=\(browserLabels.count)",
            level: .debug
        )

        if html.isEmpty, !safariSessionSignedOut, let ytdlp = ytdlpBinary {
            for candidatePage in pageCandidates {
                let candidateURL = candidatePage.absoluteString
                let isAlternate = candidateURL != targetUrl
                for browser in browsersToTry {
                    if let browserName = browser, deniedCookieSources.contains(browserName) { continue }
                    var args = [ytdlp.path, "--ignore-config", "--dump-pages", "--skip-download", "--no-playlist"]
                    if let browserName = browser {
                        args.append(contentsOf: ["--cookies-from-browser", Self.cookiesFromBrowserArgument(for: browserName)])
                    }
                    appendSiteSpecificArgs(
                        for: candidateURL,
                        rawUserAgent: rawUserAgent,
                        to: &args
                    )
                    if rawUserAgent?.isEmpty != false, browser != nil {
                        refreshBrowserTransportIdentity(for: candidateURL, args: &args)
                    }
                    args.append("--")
                    args.append(candidateURL)

                    let stage = isAlternate ? "main-browser-alt" : "main-browser"
                    let browserHtml = try await dumpPage(args, stage: stage)
                    if hasBoyfriendTVMediaData(browserHtml) {
                        html = browserHtml
                        resolvedPageURL = candidatePage
                        break
                    }
                }
                // A login page means a members-only video that no browser session
                // here can play. The mirror and plain HTTP can't sign in either, so
                // go straight to Siphon's own (signed-in) WebKit session.
                if !html.isEmpty || sawLoginPage { break }
            }
        }

        // URLSession is a final transport fallback. Raw extension cookies are only
        // forwarded within the same BoyfriendTV cookie scope.
        if html.isEmpty && !sawLoginPage && (processRunner is DefaultYtdlpProcessRunner) {
            for candidatePage in pageCandidates {
                var request = URLRequest(url: candidatePage)
                request.timeoutInterval = 3.0
                let effectiveUA: String = {
                    let trimmed = rawUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !trimmed.isEmpty { return trimmed }
                    return effectiveBrowserSource == "safari"
                        ? Self.safariUserAgent
                        : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                }()
                request.setValue(effectiveUA, forHTTPHeaderField: "User-Agent")
                let pageBaseDomain = candidatePage.host?.lowercased().contains("boyfriendtv.com") == true
                    ? "https://www.boyfriendtv.com"
                    : "https://www.boyfriend.tv"
                request.setValue(pageBaseDomain + "/", forHTTPHeaderField: "Referer")
                request.setValue(pageBaseDomain, forHTTPHeaderField: "Origin")
                if let raw = rawCookies, !raw.isEmpty,
                   Self.shouldForwardBoyfriendTVRawCookies(from: targetUrl, to: candidatePage.absoluteString) {
                    request.setValue(raw, forHTTPHeaderField: "Cookie")
                }

                let stage = candidatePage == pageURL ? "main-http" : "main-http-alt"
                if let fetched = try await fetchPage(request, stage: stage),
                   hasBoyfriendTVMediaData(fetched) {
                    html = fetched
                    resolvedPageURL = candidatePage
                    break
                }
            }
        }

        // curl/yt-dlp/plain HTTP cannot execute a JavaScript challenge. WebKit is
        // the final network fallback so its post-challenge state is authoritative.
        // If the primary WebKit session itself times out on the challenge, do not
        // repeat the same fingerprint against mirror hosts and embeds.
        if html.isEmpty, (sawChallenge || sawForbidden || sawLoginPage) {
            for candidatePage in pageCandidates {
                let stage = candidatePage == pageURL ? "main-webkit" : "main-webkit-alt"
                let scopedCookies = rawCookies.flatMap { raw in
                    Self.shouldForwardBoyfriendTVRawCookies(
                        from: targetUrl,
                        to: candidatePage.absoluteString
                    ) ? raw : nil
                }
                guard let rendered = try await loadBoyfriendTVRenderedPage(
                    candidatePage,
                    stage: stage,
                    rawCookies: scopedCookies
                ) else {
                    continue
                }

                if isBoyfriendTVChallengeHTML(rendered) {
                    webKitChallengeTimedOut = true
                    break
                }
                // Still the login page: sign-in in Siphon's window didn't finish. The
                // embeds need the same sign-in, so don't open more windows for them.
                // (A playable page can carry the login text in its scripts.)
                if extractStreamURLFromHTML(rendered) == nil, isBoyfriendTVLoginHTML(rendered) {
                    throw YtdlpError.protectedSiteLoginRequired
                }

                sawChallenge = false
                sawForbidden = false
                sawUnauthorized = false
                html = rendered
                resolvedPageURL = candidatePage
                break
            }
        }
        
        // Extract Title
        var title = "BoyfriendTV Video"
        if let titleRange = html.range(of: "<title>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            let rawTitle = String(html[titleRange])
                .replacingOccurrences(of: "(?i)<title>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)</title>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)boyfriend\\.tv - ", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i) - boyfriend\\.tv", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i) \\| BoyFriendTV", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawTitle.isEmpty {
                title = rawTitle.decodingHTMLEntities()
            }
        }
        
        // Ads may precede the real player. Inspect all embeds, and only follow
        // BoyfriendTV embeds for this video rather than arbitrary iframe targets.
        var embedUrl: String? = nil
        var candidateEmbeds: [String] = []
        let videoID = Self.boyfriendPathVideoIdRegex.flatMap { regex -> String? in
            guard let match = regex.firstMatch(in: targetUrl, range: NSRange(targetUrl.startIndex..., in: targetUrl)) else { return nil }
            return (targetUrl as NSString).substring(with: match.range(at: 1))
        }
        let embedHTML = html.replacingOccurrences(of: "\\/", with: "/").decodingHTMLEntities()
        for regex in Self.boyfriendEmbedRegexes {
            for match in regex.matches(in: embedHTML, range: NSRange(embedHTML.startIndex..., in: embedHTML)) {
                let value = (embedHTML as NSString).substring(with: match.range(at: 1))
                guard let resolved = URL(string: value, relativeTo: resolvedPageURL)?.absoluteURL,
                      isBoyfriendTVURL(resolved.absoluteString), resolved.path.hasPrefix("/embed/"),
                      resolved.user == nil, resolved.password == nil,
                      resolved.scheme == "https" || resolved.scheme == "http" else { continue }
                let embedID = resolved.path.split(separator: "/").dropFirst().first.map(String.init)
                guard videoID == nil || embedID == videoID else { continue }
                let embed = resolved.absoluteString
                if !candidateEmbeds.contains(embed) { candidateEmbeds.append(embed) }
                if var alternate = URLComponents(url: resolved, resolvingAgainstBaseURL: false) {
                    alternate.host = Self.boyfriendTVCookieScope(for: embed) == "boyfriend.tv" ? "www.boyfriendtv.com" : "www.boyfriend.tv"
                    if let candidate = alternate.url?.absoluteString, !candidateEmbeds.contains(candidate) {
                        candidateEmbeds.append(candidate)
                    }
                }
            }
        }

        if let regex = Self.boyfriendVideoIdRegex,
           let match = regex.firstMatch(in: targetUrl, options: [], range: NSRange(location: 0, length: (targetUrl as NSString).length)),
           match.numberOfRanges > 1 {
            let videoId = (targetUrl as NSString).substring(with: match.range(at: 1))
            let defaultCom = "https://www.boyfriendtv.com/embed/\(videoId)/"
            let defaultTv = "https://www.boyfriend.tv/embed/\(videoId)/"
            if !candidateEmbeds.contains(defaultCom) { candidateEmbeds.append(defaultCom) }
            if !candidateEmbeds.contains(defaultTv) { candidateEmbeds.append(defaultTv) }
        }

        candidateEmbeds = candidateEmbeds.filter {
            guard let candidate = URL(string: $0), candidate.scheme == "https" || candidate.scheme == "http" else { return false }
            return isBoyfriendTVURL($0) && candidate.path.hasPrefix("/embed/") && candidate.user == nil && candidate.password == nil
        }
        LoggerService.shared.log("[ProtectedSite] stage=embed-discovery candidates=\(candidateEmbeds.count)", level: .debug)

        // Extract Thumbnail URL
        var thumbnailUrl: String? = nil
        if let posterRange = html.range(of: "property=\"og:image\"\\s+content=\"([^\"]+)\"", options: .regularExpression) ??
                              html.range(of: "\"thumbnailUrl\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) ??
                              html.range(of: "poster=\"([^\"]+)\"", options: .regularExpression) {
            let rawPoster = String(html[posterRange])
            if let firstHttp = rawPoster.range(of: "http") {
                let candidate = String(rawPoster[firstHttp.lowerBound...])
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "\\/", with: "/")
                    .components(separatedBy: " ").first ?? ""
                if candidate.hasPrefix("http") {
                    thumbnailUrl = candidate
                }
            }
        }
        
        // Stream URL extraction from main page
        var streamUrl = extractStreamURLFromHTML(html)
        
        // If stream URL is not found on main page, fetch candidate embed URL pages
        if streamUrl == nil && !candidateEmbeds.isEmpty {
            for embed in candidateEmbeds {
                if streamUrl != nil { break }
                if let ytdlp = ytdlpBinary {
                    if let raw = rawCookies, !raw.isEmpty,
                       Self.shouldForwardBoyfriendTVRawCookies(from: targetUrl, to: embed),
                       let tempFile = createTempCookiesFileFromHeader(url: embed, cookieHeader: raw) {
                        defer { try? FileManager.default.removeItem(at: tempFile) }
                        var rawEmbedArgs = [ytdlp.path, "--ignore-config", "--dump-pages", "--skip-download", "--no-playlist", "--cookies", tempFile.path]
                        appendSiteSpecificArgs(for: embed, to: &rawEmbedArgs)
                        rawEmbedArgs.append("--")
                        rawEmbedArgs.append(embed)

                        let embedHtml = try await dumpPage(rawEmbedArgs, stage: "embed-session")
                        if let extracted = extractStreamURLFromHTML(embedHtml) {
                            streamUrl = extracted
                            embedUrl = embed
                            break
                        }
                    }

                    for browser in browsersToTry {
                        if let browserName = browser, deniedCookieSources.contains(browserName) { continue }
                        var embedArgs = [ytdlp.path, "--ignore-config", "--dump-pages", "--skip-download", "--no-playlist"]
                        if let browserName = browser {
                            embedArgs.append(contentsOf: ["--cookies-from-browser", Self.cookiesFromBrowserArgument(for: browserName)])
                        }
                        appendSiteSpecificArgs(for: embed, to: &embedArgs)
                        embedArgs.append("--")
                        embedArgs.append(embed)
                        
                        let embedHtml = try await dumpPage(embedArgs, stage: "embed-browser")
                        if let extracted = extractStreamURLFromHTML(embedHtml) {
                            streamUrl = extracted
                            embedUrl = embed
                            break
                        }
                    }
                }

                // Cheap HTTP fallback before escalating this embed to WebKit.
                if streamUrl == nil, let embedPageURL = URL(string: embed), (processRunner is DefaultYtdlpProcessRunner) {
                    var embedRequest = URLRequest(url: embedPageURL)
                    embedRequest.timeoutInterval = 3.0
                    let effectiveUA: String = {
                        let trimmed = rawUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !trimmed.isEmpty { return trimmed }
                        return effectiveBrowserSource == "safari"
                            ? Self.safariUserAgent
                            : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                    }()
                    embedRequest.setValue(effectiveUA, forHTTPHeaderField: "User-Agent")
                    let embedBaseDomain = embedPageURL.host?.lowercased().contains("boyfriendtv.com") == true
                        ? "https://www.boyfriendtv.com"
                        : "https://www.boyfriend.tv"
                    embedRequest.setValue(embedBaseDomain + "/", forHTTPHeaderField: "Referer")
                    embedRequest.setValue(embedBaseDomain, forHTTPHeaderField: "Origin")
                    if let raw = rawCookies, !raw.isEmpty,
                       Self.shouldForwardBoyfriendTVRawCookies(from: targetUrl, to: embed) {
                        embedRequest.setValue(raw, forHTTPHeaderField: "Cookie")
                    }

                    if let fetched = try await fetchPage(embedRequest, stage: "embed-http"),
                       let extracted = extractStreamURLFromHTML(fetched) {
                        streamUrl = extracted
                        embedUrl = embed
                        break
                    }
                }

                if streamUrl == nil, !webKitChallengeTimedOut, (sawChallenge || sawForbidden),
                   let embedPageURL = URL(string: embed) {
                    let scopedCookies = rawCookies.flatMap { raw in
                        Self.shouldForwardBoyfriendTVRawCookies(from: targetUrl, to: embed) ? raw : nil
                    }
                    if let rendered = try await loadBoyfriendTVRenderedPage(
                        embedPageURL,
                        stage: "embed-webkit",
                        rawCookies: scopedCookies
                    ) {
                        if isBoyfriendTVChallengeHTML(rendered) {
                            webKitChallengeTimedOut = true
                            break
                        }
                        // Same as the page: one unfinished sign-in, not a window per embed.
                        if extractStreamURLFromHTML(rendered) == nil, isBoyfriendTVLoginHTML(rendered) {
                            throw YtdlpError.protectedSiteLoginRequired
                        }

                        sawChallenge = false
                        sawForbidden = false
                        sawUnauthorized = false
                        if let extracted = extractStreamURLFromHTML(rendered) {
                            streamUrl = extracted
                            embedUrl = embed
                            break
                        }
                    }
                }
            }
        }
        
        if let validStreamUrl = streamUrl {
            return BoyfriendTVExtractedMedia(streamURL: validStreamUrl, embedURL: embedUrl ?? targetUrl, title: title, thumbnailURL: thumbnailUrl)
        }
        
        if safariCookieAccessDenied && (effectiveBrowserSource == "safari" || browserLabels.allSatisfy { $0 == "safari" }) {
            throw YtdlpError.safariCookiesFullDiskAccessRequired
        }
        try Task.checkCancellation()
        if sawChallenge {
            throw YtdlpError.cloudflareBlocked
        }
        if sawLoginPage || sawUnauthorized {
            if browserLabels.isEmpty && rawCookies?.isEmpty != false {
                throw YtdlpError.protectedSiteNeedsBrowserCookies
            }
            throw YtdlpError.protectedSiteLoginRequired
        }
        if sawForbidden {
            throw YtdlpError.downloadFailed("The protected site denied access (HTTP 403). This may be an anti-bot challenge or an access restriction; it does not prove your cookies are invalid.")
        }
        LoggerService.shared.log("[ProtectedSite] stage=stream-resolution result=exhausted; falling back to yt-dlp", level: .warning)
        return nil
    }

    private func hasBoyfriendTVMediaData(_ html: String) -> Bool {
        // Shared login navigation/scripts can coexist with a playable full stream.
        // The stream parser excludes previews and thumbnails before accepting media.
        if extractStreamURLFromHTML(html) != nil { return true }
        let isLoginProtected = html.contains("loginProtected") ||
                               html.contains("To watch this video please") ||
                               html.contains("User has been banned")
        return !isLoginProtected && (
            html.contains("hlsAuto") || html.contains("videoPlayerData") ||
            html.contains("sources") || html.contains("playerConfig") ||
            html.contains("embedUrl") || html.contains("/embed/")
        )
    }

    // Bolt Performance Optimization: Pre-compile static NSRegularExpression patterns as `nonisolated private static let` constants to eliminate compilation and allocation overhead during high-frequency parsing.
    nonisolated private static let recuPlaylistRegexes: [NSRegularExpression] = [
        #"<source[^>]+src\s*=\s*["']([^"']+\.m3u8[^"']*)["']"#,
        #"(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    nonisolated private static let boyfriendEmbedRegexes: [NSRegularExpression] = [
        #""embedUrl"\s*:\s*"([^"]+)""#,
        #"<iframe[^>]+(?:data-src|src)\s*=\s*["']([^"']+)["']"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let boyfriendVideoIdRegex = try? NSRegularExpression(pattern: "/videos/(\\d+)", options: .caseInsensitive)
    nonisolated private static let boyfriendPathVideoIdRegex = try? NSRegularExpression(pattern: "(?:^|/)(?:videos|embed|v)/(\\d+)", options: .caseInsensitive)
    nonisolated private static let galleryVideoSlugRegex = try? NSRegularExpression(pattern: "^/(?:playlist|album|galleries)/\\d+/video/([^/]+)", options: .caseInsensitive)
    nonisolated private static let singleVideoSlugRegex = try? NSRegularExpression(pattern: "^/video/([^/]+)", options: .caseInsensitive)

    nonisolated private static let boyfriendStreamRegexes: [NSRegularExpression] = [
        #"["']?(?:hlsAuto|hls|videoUrl|media|src|file|video_url)["']?\s*:\s*["']((?:https?:)?//[^"']+)["']"#,
        #"((?:https?:)?//(?:[a-z0-9-]+\.)*boyfriend(?:tv\.com|\.tv)/[^\s"'<>]+?\.(?:mp4|m3u8)(?:\?[^\s"'<>]*)?)(?=["'\s<>]|$)"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let gffTitleRegexes: [NSRegularExpression] = [
        "video_title\\s*:\\s*['\"]([^'\"]+)['\"]",
        "property=[\"']og:title[\"']\\s+content=[\"']([^\"']+)[\"']",
        "<title>(.*?)</title>",
        "<h1[^>]*>([^<]+)</h1>"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let gffStreamRegexes: [NSRegularExpression] = [
        "video_url\\s*:\\s*['\"]([^'\"]+)['\"]",
        "video_alt_url\\s*:\\s*['\"]([^'\"]+)['\"]",
        "video_alt_url[1-4]?\\s*:\\s*['\"]([^'\"]+)['\"]",
        "\"file\"\\s*:\\s*\"([^\"]+)\"",
        "\"src\"\\s*:\\s*\"([^\"]+)\"",
        "\"videoUrl\"\\s*:\\s*\"([^\"]+)\"",
        "\"mediaUrl\"\\s*:\\s*\"([^\"]+)\"",
        "\"contentUrl\"\\s*:\\s*\"([^\"]+)\"",
        "\"(?:hlsAuto|hls|videoUrl|media|src|file|video_url)\"\\s*:\\s*\"([^\"]+)\"",
        "<source[^>]+src=[\"']([^\"']+)[\"']",
        "data-video-url=[\"']([^\"']+)[\"']",
        "data-src=[\"']([^\"']+\\.(?:mp4|m3u8)[^\"']*)[\"']",
        "['\"](https?://[^'\"]+\\.gayforfans\\.com[^'\"]+\\.(?:mp4|m3u8)(?:\\?[^'\"]*)?)['\"]",
        "['\"](//[^'\"]+\\.gayforfans\\.com[^'\"]+\\.(?:mp4|m3u8)(?:\\?[^'\"]*)?)['\"]",
        "['\"](/get_file/[^'\"]+)['\"]",
        "['\"](https?://[^'\"]+/get_file/[^'\"]+)['\"]"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let gffThumbRegexes: [NSRegularExpression] = [
        "preview_url\\s*:\\s*['\"](https?://[^'\"]+)['\"]",
        "preview_url1\\s*:\\s*['\"](https?://[^'\"]+)['\"]",
        "property=[\"']og:image[\"']\\s+content=[\"'](https?://[^\"']+)[\"']",
        "poster=[\"'](https?://[^\"']+)[\"']",
        "\"thumbnailUrl\"\\s*:\\s*\"(https?://[^\"]+)\""
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let gffEmbedRegexes: [NSRegularExpression] = [
        "\"embedUrl\"\\s*:\\s*\"([^\"]+)\"",
        "<iframe[^>]+src=[\"'](https?://(?:www\\.)?gayforfans\\.com/embed/[^\"']+)[\"']",
        "<iframe[^>]+src=[\"'](/embed/[^\"']+)[\"']"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let gffVideoIdRegexes: [NSRegularExpression] = [
        "/videos?/(\\d+)",
        "video_id\\s*:\\s*['\"](\\d+)['\"]",
        "/embed/(\\d+)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let guywhTitleRegexes: [NSRegularExpression] = [
        "video_title\\s*:\\s*['\"]([^'\"]+)['\"]",
        "property=[\"']og:title[\"']\\s+content=[\"']([^\"']+)[\"']",
        "<h1[^>]*>([^<]+)</h1>",
        "<title>(.*?)</title>"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    nonisolated private static let guywhThumbRegexes: [NSRegularExpression] = [
        "preview_url\\s*:\\s*['\"](https?://[^'\"]+)['\"]",
        "preview_url1\\s*:\\s*['\"](https?://[^'\"]+)['\"]",
        "property=[\"']og:image[\"']\\s+content=[\"'](https?://[^\"']+)[\"']",
        "poster=[\"'](https?://[^\"']+)[\"']"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    nonisolated private static let guywhStreamRegexes: [NSRegularExpression] = [
        "video_url\\s*:\\s*['\"](https?://[^'\"]+)['\"]",
        "\"contentUrl\"\\s*:\\s*\"(https?://[^\"]+)\"",
        "video_alt_url\\s*:\\s*['\"](https?://[^'\"]+)['\"]",
        "<source[^>]+src=[\"'](https?://[^\"']+)[\"']"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let bestCamTitleRegexes: [NSRegularExpression] = [
        "property=[\"']og:title[\"']\\s+content=[\"']([^\"']+)[\"']",
        "<h1[^>]*>([^<]+)</h1>",
        "<title>(.*?)</title>"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let bestCamThumbRegexes: [NSRegularExpression] = [
        "property=[\"']og:image[\"']\\s+content=[\"'](https?://[^\"']+)[\"']",
        "preview_url\\s*:\\s*['\"](https?://[^'\"]+)[\"']",
        "poster=[\"'](https?://[^\"']+)[\"']"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let bestCamIframeRegexes: [NSRegularExpression] = [
        "abyssplayer\\.com/([a-zA-Z0-9_-]+)",
        "abyss\\.to/([a-zA-Z0-9_-]+)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let guywhVideoIdRegexes: [NSRegularExpression] = [
        "/videos/(\\d+)",
        "video_id\\s*:\\s*['\"](\\d+)['\"]",
        "/embed/(\\d+)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    nonisolated private static let starwankTitleRegexes: [NSRegularExpression] = [
        "property=[\"']og:title[\"']\\s+content=[\"']([^\"']+)[\"']",
        "video_title\\s*:\\s*['\"]([^'\"]+)['\"]",
        "<title>(.*?)</title>",
        "<h1[^>]*>([^<]+)</h1>"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let starwankThumbRegexes: [NSRegularExpression] = [
        "property=[\"']og:image[\"']\\s+content=[\"'](https?://[^\"']+)[\"']",
        "posterImage\\s*:\\s*['\"](https?://[^\"']+)[\"']",
        "preview_url\\s*:\\s*['\"](https?://[^\"']+)[\"']",
        "poster=[\"'](https?://[^\"']+)[\"']"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let starwankDurationRegexes: [NSRegularExpression] = [
        "property=[\"']video:duration[\"']\\s+content=[\"'](\\d+)[\"']",
        "property=[\"']og:duration[\"']\\s+content=[\"'](\\d+)[\"']",
        "duration\\s*:\\s*['\"]?(\\d+)['\"]?"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let starwankVideoIdRegexes: [NSRegularExpression] = [
        "(?:^|/)videos/(\\d+)",
        "video_id\\s*:\\s*['\"](\\d+)['\"]",
        "(?:^|/)embed/(\\d+)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let starwankEmptyReferrerRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "empty_referrer_redirect\\s*:\\s*['\"](https?://[^'\"]+)['\"]", options: .caseInsensitive)
    }()

    nonisolated private static let pussyspaceTitleRegexes: [NSRegularExpression] = [
        "property=[\"']og:title[\"']\\s+content=[\"']([^\"']+)[\"']",
        "<title>([^<]+)</title>"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let pussyspaceThumbRegexes: [NSRegularExpression] = [
        "property=[\"']og:image[\"']\\s+content=[\"']([^\"']+)[\"']",
        "poster:\\s*[\"'](https?:[^\"']+)[\"']",
        "poster=[\"'](https?:[^\"']+)[\"']"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let pussyspaceDurationRegexes: [NSRegularExpression] = [
        "property=[\"']video:duration[\"']\\s+content=[\"'](\\d+)[\"']",
        "property=[\"']og:duration[\"']\\s+content=[\"'](\\d+)[\"']"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let pussyspacePlayerTokenRegexes: [NSRegularExpression] = [
        "\\|([a-zA-Z0-9_-]{2,10})\\|([a-zA-Z0-9_-]{20,80})\\|multiShowPlayer\\|",
        "multiShowPlayer\\(['\"]([^'\"]+)['\"],\\s*['\"]([^'\"]+)['\"]\\)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let pussyspaceFileRegexes: [NSRegularExpression] = [
        "file:\\s*[\"']([^\"']+)[\"']",
        "<video[^>]+src=[\"']([^\"']+)[\"']",
        "<source[^>]+src=[\"']([^\"']+)[\"']"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    // Bolt Performance Optimization: Pre-compile static NSRegularExpression patterns to eliminate dynamic regex compilation and heap allocations during HTML metadata extraction and media stream resolution.
    nonisolated private static let ogTitleRegexes: [NSRegularExpression] = [
        #"<meta[^>]+property\s*=\s*["']og:title["'][^>]+content\s*=\s*["']([^"']+)["']"#,
        #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+property\s*=\s*["']og:title["']"#,
        #"<title[^>]*>(.*?)</title>"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators]) }

    nonisolated private static let ogImageRegexes: [NSRegularExpression] = [
        #"<meta[^>]+property\s*=\s*["']og:image["'][^>]+content\s*=\s*["']([^"']+)["']"#,
        #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+property\s*=\s*["']og:image["']"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    nonisolated private static let htmlTagStripRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: [])

    nonisolated private static let starwankSourceBlockRegex = try? NSRegularExpression(
        pattern: "setAttribute\\(['\"]src['\"],\\s*['\"]([^'\"]+)['\"]\\)(?:(?!setAttribute\\(['\"]src).)*?setAttribute\\(['\"]title['\"],\\s*['\"]([^'\"]+)['\"]\\)",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    nonisolated private static let starwankStandaloneRegex = try? NSRegularExpression(
        pattern: "setAttribute\\(['\"]src['\"],\\s*['\"](https?:[^'\"]+)['\"]\\)",
        options: .caseInsensitive
    )

    nonisolated private static let starwankKvsRegexes: [(regex: NSRegularExpression, defaultHeight: Int)] = [
        ("video_url_fhd\\s*:\\s*['\"](https?:[^'\"]+)['\"]", 1080),
        ("video_url\\s*:\\s*['\"](https?:[^'\"]+)['\"]", 720),
        ("video_alt_url2\\s*:\\s*['\"](https?:[^'\"]+)['\"]", 480),
        ("video_alt_url\\s*:\\s*['\"](https?:[^'\"]+)['\"]", 360)
    ].compactMap { pattern, height in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return (regex, height)
    }

    nonisolated private static let pussyspaceQualityRegex = try? NSRegularExpression(
        pattern: "\\[(\\d+)p\\]([^,\\[\\]]+)",
        options: .caseInsensitive
    )

    nonisolated private static let pussyspaceBufferRegex = try? NSRegularExpression(
        pattern: "(https?:[^\"'\\s<>]+reversebuffer[^\"'\\s<>]+)",
        options: .caseInsensitive
    )

    private func validatedBoyfriendTVStreamURL(_ rawValue: String) -> String? {
        var rawValue = rawValue
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if rawValue.hasPrefix("//") {
            rawValue = "https:" + rawValue
        }

        guard let candidate = URL(string: rawValue),
              candidate.scheme == "https" || candidate.scheme == "http",
              isBoyfriendTVURL(rawValue),
              candidate.user == nil,
              candidate.password == nil,
              ["mp4", "m3u8"].contains(candidate.pathExtension.lowercased()) else {
            return nil
        }

        let pathParts = candidate.path.lowercased().split(separator: "/")
        if pathParts.contains(where: { ["ads", "ad", "advert", "preroll", "vast"].contains(String($0)) }) {
            return nil
        }

        let lowerValue = rawValue.lowercased()
        if lowerValue.contains("/pv/") ||
           lowerValue.contains("pv_") ||
           lowerValue.contains("/preview/") ||
           lowerValue.contains("preview_") ||
           lowerValue.contains("trailer") ||
           lowerValue.contains("teaser") ||
           lowerValue.contains("/thumbs/") ||
           lowerValue.contains("/thumb/") ||
           lowerValue.contains("cdn77-t.") ||
           lowerValue.contains("-t.boyfriend") ||
           lowerValue.hasSuffix(".jpg") ||
           lowerValue.hasSuffix(".jpeg") ||
           lowerValue.hasSuffix(".png") ||
           lowerValue.hasSuffix(".webp") {
            return nil
        }

        return rawValue
    }

    private func extractStreamURLFromHTML(_ html: String) -> String? {
        let html = html.replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .decodingHTMLEntities()
        for regex in Self.boyfriendStreamRegexes {
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length))
            for match in matches where match.numberOfRanges > 1 {
                let rawValue = (html as NSString).substring(with: match.range(at: 1))
                if let validated = validatedBoyfriendTVStreamURL(rawValue) {
                    return validated
                }
            }
        }
        return nil
    }

    private func parseBoyfriendTVFormats(from streamURL: String) -> [MediaFormat]? {
        guard let range = streamURL.range(of: "multi=([^/]+)", options: .regularExpression) else {
            return [MediaFormat(formatId: "best", ext: "mp4", resolution: "1920x1080", formatNote: "HD")]
        }
        // Bolt Performance Optimization: Use Substring `split` and pre-parsed height tuple sorting to eliminate string/array allocations.
        let multiChunk = streamURL[range].dropFirst("multi=".count)
        let entries = multiChunk.split(separator: ",")
        var formats: [(format: MediaFormat, height: Int)] = []
        for entry in entries {
            let parts = entry.split(separator: ":")
            guard let resSub = parts.first, resSub.contains("x") else { continue }
            let dims = resSub.split(separator: "x")
            if dims.count == 2, let _ = Int(dims[0]), let h = Int(dims[1]) {
                let res = String(resSub)
                let fmt = MediaFormat(
                    formatId: "\(h)",
                    ext: "mp4",
                    resolution: res,
                    fps: 30,
                    vcodec: "h264",
                    acodec: "aac",
                    formatNote: "\(h)p"
                )
                formats.append((format: fmt, height: h))
            }
        }
        if formats.isEmpty { return nil }
        formats.sort(by: { $0.height > $1.height })
        return formats.map(\.format)
    }

    func resolveBoyfriendTVStreamURLForDownload(streamURL: String, options: DownloadOptions) -> String {
        // Signed HLS streams (e.g. containing /media=hls... or /key=...) use _TPL_.mp4 as the signed master playlist endpoint.
        // The security key is cryptographically bound to the exact URI path. Modifying any part of the path (such as
        // replacing _TPL_) breaks the token signature and returns HTTP 403 Forbidden ("x-message: Wrong key").
        // Passing the master playlist URL directly to yt-dlp allows it to parse the master playlist and download
        // the selected format using each stream's individually signed valid URL.
        if streamURL.contains("media=hls") || streamURL.contains("/key=") {
            return streamURL
        }

        guard streamURL.contains("_TPL_") || streamURL.contains("_TPL") else {
            return streamURL
        }
        
        var targetTag = "1080p"
        if let range = streamURL.range(of: "multi=([^/&]+)", options: .regularExpression) {
            // Bolt Performance Optimization: Use Substring `split` to avoid allocating intermediate String arrays.
            let multiChunk = streamURL[range].dropFirst("multi=".count)
            let entries = multiChunk.split(separator: ",")
            var tagMap: [(height: Int, tag: String)] = []
            for entry in entries {
                let parts = entry.split(separator: ":")
                let resSub = parts.first ?? ""
                let res = String(resSub)
                let tag = parts.count > 1 ? String(parts[1]) : res
                let h: Int? = {
                    if res.contains("x") {
                        let dims = resSub.split(separator: "x")
                        if dims.count == 2 { return Int(dims[1]) }
                    }
                    return Int(res.replacingOccurrences(of: "p", with: ""))
                }()
                if let height = h {
                    tagMap.append((height: height, tag: tag))
                }
            }
            tagMap.sort(by: { $0.height > $1.height })
            
            // Choose tag based on options
            if let chosenFormatId = options.selectedFormatId, let chosenHeight = Int(chosenFormatId) {
                if let match = tagMap.first(where: { $0.height == chosenHeight }) {
                    targetTag = match.tag
                }
            } else if let res = options.videoResolution {
                let desiredHeight: Int
                switch res {
                case .r2160p, .r1440p, .r1080p, .best: desiredHeight = 1080
                case .r720p: desiredHeight = 720
                case .r480p: desiredHeight = 480
                case .r360p: desiredHeight = 360
                case .r240p, .worst: desiredHeight = 240
                }
                if let match = tagMap.first(where: { $0.height <= desiredHeight }) ?? tagMap.last {
                    targetTag = match.tag
                }
            } else if let best = tagMap.first {
                targetTag = best.tag
            }
        }
        
        let cleanTag = targetTag.hasPrefix("_") ? String(targetTag.dropFirst()) : targetTag
        var resolved = streamURL
        if resolved.contains("_TPL_") {
            resolved = resolved.replacingOccurrences(of: "_TPL_", with: "_\(cleanTag)")
        } else if resolved.contains("_TPL") {
            resolved = resolved.replacingOccurrences(of: "_TPL", with: "_\(cleanTag)")
        }
        return resolved
    }

    // MARK: - Guywh / KVS Extractor

    private func isGuywhURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "guywh.com" || host.hasSuffix(".guywh.com")
    }

    struct GuywhExtractedMedia {
        let streamURL: String
        let embedURL: String
        let title: String
        let thumbnailURL: String?
        let duration: Double?
        let quality: String?
    }

    private func resolveGuywhMediaInfo(url: String, rawCookies: String? = nil) async -> GuywhExtractedMedia? {
        let targetUrl = normalizeURLForYtdlp(url)
        guard let pageURL = URL(string: targetUrl) else { return nil }
        
        var html = ""
        
        // 1. Try URLSession direct fetch with standard browser headers
        if processRunner is DefaultYtdlpProcessRunner {
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 5.0
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("https://guywh.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://guywh.com", forHTTPHeaderField: "Origin")
            if let raw = rawCookies, !raw.isEmpty {
                request.setValue(raw, forHTTPHeaderField: "Cookie")
            }
            
            if let (data, response) = try? await EgressBoundary.session.boundedData(for: request),
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let fetched = String(data: data, encoding: .utf8) {
                html = fetched
            }
        }
        
        // 2. Fallback to yt-dlp dump-pages if direct fetch failed
        if html.isEmpty {
            let ytdlpBinary = resolvedYtdlpBinary
            if let ytdlp = ytdlpBinary {
                var dumpArgs = [ytdlp.path, "--ignore-config", "--dump-pages"]
                appendSiteSpecificArgs(for: targetUrl, to: &dumpArgs)
                dumpArgs.append("--")
                dumpArgs.append(targetUrl)
                if let output = try? await processRunner.runCommand(dumpArgs) {
                    var chunks: [String] = []
                    for line in output.split(whereSeparator: \.isNewline) {
                        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                        if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR"),
                           let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
                           let decodedString = String(decoding: decodedData, as: UTF8.self) as String?,
                           !decodedString.isEmpty {
                            chunks.append(decodedString)
                        }
                    }
                    if !chunks.isEmpty {
                        html = chunks.joined()
                    }
                }
            }
        }
        
        guard !html.isEmpty else { return nil }
        
        // Extract Title
        var title = "Guywh Video"
        for regex in Self.guywhTitleRegexes {
            if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let rawTitle = (html as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "(?i) - guywh\\.com", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?i)guywh\\.com - ", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .decodingHTMLEntities()
                if !rawTitle.isEmpty {
                    title = rawTitle
                    break
                }
            }
        }
        
        // Extract Thumbnail
        var thumbnailURL: String? = nil
        for regex in Self.guywhThumbRegexes {
            if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let candidate = (html as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\/", with: "/")
                if candidate.hasPrefix("http") {
                    thumbnailURL = candidate
                    break
                }
            }
        }
        
        // Extract Stream URL & Quality
        var streamURL: String? = nil
        var quality: String? = nil
        
        for regex in Self.guywhStreamRegexes {
            if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let candidate = (html as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\/", with: "/")
                if candidate.hasPrefix("http") {
                    streamURL = candidate
                    break
                }
            }
        }
        
        // Extract Quality Text if present
        if html.contains("video_url_fhd: '1'") || html.contains("video_url_fhd: 1") {
            quality = "1080p"
        } else if html.contains("video_url_hd: '1'") || html.contains("video_url_hd: 1") {
            quality = "720p"
        } else if let qMatch = html.range(of: "video_url_text\\s*:\\s*['\"]([^'\"]+)['\"]", options: .regularExpression) {
            let qStr = String(html[qMatch])
            if qStr.contains("1080") { quality = "1080p" }
            else if qStr.contains("720") { quality = "720p" }
            else if qStr.contains("480") { quality = "480p" }
            else if qStr.contains("360") { quality = "360p" }
        }
        
        // Extract Embed URL or generate standard embed URL
        var embedURL = targetUrl
        let targetAndHtml = targetUrl + "\n" + html
        let targetAndHtmlNs = targetAndHtml as NSString
        let targetAndHtmlRange = NSRange(location: 0, length: targetAndHtmlNs.length)
        for regex in Self.guywhVideoIdRegexes {
            if let match = regex.firstMatch(in: targetAndHtml, options: [], range: targetAndHtmlRange),
               match.numberOfRanges > 1 {
                let vidId = targetAndHtmlNs.substring(with: match.range(at: 1))
                embedURL = "https://guywh.com/embed/\(vidId)"
                break
            }
        }
        
        // If stream URL was not in main page, attempt embed page fetch
        if streamURL == nil, let embedPageURL = URL(string: embedURL), (processRunner is DefaultYtdlpProcessRunner) {
            var embedReq = URLRequest(url: embedPageURL)
            embedReq.timeoutInterval = 5.0
            embedReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            embedReq.setValue("https://guywh.com/", forHTTPHeaderField: "Referer")
            if let (data, response) = try? await EgressBoundary.session.boundedData(for: embedReq),
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let embedHtml = String(data: data, encoding: .utf8) {
                for regex in Self.guywhStreamRegexes {
                    if let match = regex.firstMatch(in: embedHtml, options: [], range: NSRange(location: 0, length: (embedHtml as NSString).length)),
                       match.numberOfRanges > 1 {
                        let candidate = (embedHtml as NSString).substring(with: match.range(at: 1))
                            .replacingOccurrences(of: "\\/", with: "/")
                        if candidate.hasPrefix("http") {
                            streamURL = candidate
                            break
                        }
                    }
                }
            }
        }
        
        guard let validStreamURL = streamURL else { return nil }
        
        return GuywhExtractedMedia(
            streamURL: validStreamURL,
            embedURL: embedURL,
            title: title,
            thumbnailURL: thumbnailURL,
            duration: nil,
            quality: quality
        )
    }

    // MARK: - GFF Extractor

    private func isGFFURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "gayforfans.com" || host.hasSuffix(".gayforfans.com")
    }

    struct GFFExtractedMedia {
        let streamURL: String
        let embedURL: String
        let title: String
        let thumbnailURL: String?
        let duration: Double?
        let quality: String?
    }

    private func sanitizeGFFStreamURL(_ raw: String) -> String? {
        var candidate = raw.replacingOccurrences(of: "\\/", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { return nil }
        
        // Base64 decoded check (e.g. kt_player base64 encoded strings)
        if !candidate.contains("://") && !candidate.hasPrefix("//") && !candidate.hasPrefix("/"),
           let decodedData = Data(base64Encoded: candidate, options: .ignoreUnknownCharacters),
           let decodedStr = String(data: decodedData, encoding: .utf8),
           decodedStr.hasPrefix("http") || decodedStr.hasPrefix("//") || decodedStr.hasPrefix("/") {
            candidate = decodedStr
        }
        
        if candidate.hasPrefix("//") {
            candidate = "https:" + candidate
        } else if candidate.hasPrefix("/") {
            candidate = "https://gayforfans.com" + candidate
        }
        
        guard candidate.hasPrefix("http://") || candidate.hasPrefix("https://") else {
            return nil
        }
        
        // Exclude image / preview thumbnails / short trailers if full stream exists
        let lower = candidate.lowercased()
        if lower.contains(".jpg") || lower.contains(".png") || lower.contains(".webp") || lower.contains(".gif") {
            return nil
        }
        return candidate
    }

    private func resolveGFFMediaInfo(url: String, rawCookies: String? = nil) async -> GFFExtractedMedia? {
        let targetUrl = normalizeURLForYtdlp(url)
        guard let pageURL = URL(string: targetUrl) else { return nil }
        
        LoggerService.shared.log("[GFF] Extracting media for: \(LoggerService.sanitizeURLForLog(targetUrl))", level: .info)
        var html = ""
        
        let ytdlpBinary = resolvedYtdlpBinary

        // 1. Try raw session cookies if provided (e.g. from browser extension)
        if let raw = rawCookies, !raw.isEmpty, let ytdlp = ytdlpBinary,
           let tempFile = createTempCookiesFileFromHeader(url: targetUrl, cookieHeader: raw) {
            defer { try? FileManager.default.removeItem(at: tempFile) }
            var rawArgs = [ytdlp.path, "--ignore-config", "--dump-pages", "--cookies", tempFile.path]
            appendSiteSpecificArgs(for: targetUrl, to: &rawArgs)
            rawArgs.append("--")
            rawArgs.append(targetUrl)
            
            var dumpOutput: String? = nil
            do {
                dumpOutput = try await processRunner.runCommand(rawArgs)
            } catch let error as YtdlpError {
                if case .commandFailed(let output) = error {
                    dumpOutput = output
                }
            } catch {
                LoggerService.shared.log("[GFF] Non-YtdlpError during raw cookie dump-pages: \(error.localizedDescription)", level: .debug)
            }
            
            if let output = dumpOutput, !output.isEmpty {
                var rawChunks: [String] = []
                for line in output.split(whereSeparator: \.isNewline) {
                    let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                    if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR"),
                       let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                        let decodedString = String(decoding: decodedData, as: UTF8.self)
                        if !decodedString.isEmpty {
                            rawChunks.append(decodedString)
                        }
                    }
                }
                if !rawChunks.isEmpty {
                    let rawHtml = rawChunks.joined()
                    let hasMediaData = rawHtml.contains("video_url") ||
                                       rawHtml.contains("videoPlayerData") ||
                                       rawHtml.contains("sources") ||
                                       rawHtml.contains("gayforfans") ||
                                       rawHtml.contains("contentUrl") ||
                                       rawHtml.contains("embedUrl") ||
                                       rawHtml.contains("/embed/") ||
                                       rawHtml.contains("<title>") ||
                                       rawHtml.contains("flashvars") ||
                                       rawHtml.contains("playerConfig")
                    if hasMediaData {
                        html = rawHtml
                        LoggerService.shared.log("[ProtectedSite] Successfully extracted page data using session cookies (length: \(rawHtml.count) bytes)", level: .info)
                    }
                }
            }
        }

        var browsersToTry: [String?] = []
        if let configured = configuredBrowserCookieSource() {
            browsersToTry.append(configured)
        }
        for candidate in ["safari", "chrome", "brave", "firefox", "edge", "helium", "chromium-based"] {
            if candidate == "safari" && !Self.hasFullDiskAccess {
                continue
            }
            if !browsersToTry.contains(candidate) {
                browsersToTry.append(candidate)
            }
        }
        browsersToTry.append(nil)

        // 2. Try browser cookies and impersonated HTTP page dump
        if html.isEmpty, let ytdlp = ytdlpBinary {
            for browser in browsersToTry {
                if let browserName = browser, deniedCookieSources.contains(browserName) { continue }
                var args = [ytdlp.path, "--ignore-config", "--dump-pages"]
                if let browserName = browser {
                    args.append(contentsOf: ["--cookies-from-browser", Self.cookiesFromBrowserArgument(for: browserName)])
                }
                appendSiteSpecificArgs(for: targetUrl, to: &args)
                args.append("--")
                args.append(targetUrl)
                
                var dumpOutput: String? = nil
                do {
                    dumpOutput = try await processRunner.runCommand(args)
                } catch let error as YtdlpError {
                    if case .commandFailed(let output) = error {
                        dumpOutput = output
                    }
                } catch {
                    // Ignore general process errors
                }
                
                if let output = dumpOutput, !output.isEmpty {
                    var browserChunks: [String] = []
                    for line in output.split(whereSeparator: \.isNewline) {
                        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                        if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR"),
                           let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                            let decodedString = String(decoding: decodedData, as: UTF8.self)
                            if !decodedString.isEmpty {
                                browserChunks.append(decodedString)
                            }
                        }
                    }
                    if !browserChunks.isEmpty {
                        let browserHtml = browserChunks.joined()
                        let hasMediaData = browserHtml.contains("video_url") ||
                                           browserHtml.contains("videoPlayerData") ||
                                           browserHtml.contains("sources") ||
                                           browserHtml.contains("gayforfans") ||
                                           browserHtml.contains("contentUrl") ||
                                           browserHtml.contains("embedUrl") ||
                                           browserHtml.contains("/embed/") ||
                                           browserHtml.contains("<title>") ||
                                           browserHtml.contains("flashvars") ||
                                           browserHtml.contains("playerConfig")
                        if hasMediaData {
                            html = browserHtml
                            let sourceLog = browser.map { "browser cookies from '\($0)'" } ?? "impersonated HTTP request"
                            LoggerService.shared.log("[ProtectedSite] Successfully extracted page data using \(sourceLog) (length: \(browserHtml.count) bytes)", level: .info)
                            break
                        }
                    }
                }
            }
        }

        // 3. Fallback to URLSession if browser dump output was empty or didn't contain stream
        if html.isEmpty && (processRunner is DefaultYtdlpProcessRunner) {
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 5.0
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("https://gayforfans.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://gayforfans.com", forHTTPHeaderField: "Origin")
            if let raw = rawCookies, !raw.isEmpty {
                request.setValue(raw, forHTTPHeaderField: "Cookie")
            }
            
            if let (data, response) = try? await EgressBoundary.session.boundedData(for: request),
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let fetched = String(data: data, encoding: .utf8) {
                html = fetched
                LoggerService.shared.log("[GFF] Fetched page HTML via URLSession direct request (length: \(fetched.count) bytes)", level: .info)
            }
        }
        
        guard !html.isEmpty else {
            LoggerService.shared.log("[GFF] Unable to retrieve HTML page dump for: \(LoggerService.sanitizeURLForLog(targetUrl))", level: .warning)
            return nil
        }
        
        // Extract Title
        var title = "GayForFans Video"
        for regex in Self.gffTitleRegexes {
            if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let rawTitle = (html as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "(?i)<title>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?i)</title>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?i) - gayforfans\\.com", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?i)gayforfans\\.com - ", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?i)gayforfans - ", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?i) - gayforfans", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?i) \\| GayForFans", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .decodingHTMLEntities()
                if !rawTitle.isEmpty {
                    title = rawTitle
                    break
                }
            }
        }
        
        // Extract Thumbnail
        var thumbnailURL: String? = nil
        for regex in Self.gffThumbRegexes {
            if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let candidate = (html as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\/", with: "/")
                if candidate.hasPrefix("http") {
                    thumbnailURL = candidate
                    break
                }
            }
        }
        
        // Extract Stream URL & Quality
        var streamURL: String? = nil
        var quality: String? = nil
        
        for regex in Self.gffStreamRegexes {
            if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let rawCandidate = (html as NSString).substring(with: match.range(at: 1))
                if let candidate = sanitizeGFFStreamURL(rawCandidate) {
                    streamURL = candidate
                    break
                }
            }
        }
        
        // Extract Quality Text if present
        if html.contains("video_url_fhd: '1'") || html.contains("video_url_fhd: 1") || html.contains("video_url_fhd:\"1\"") {
            quality = "1080p"
        } else if html.contains("video_url_hd: '1'") || html.contains("video_url_hd: 1") || html.contains("video_url_hd:\"1\"") {
            quality = "720p"
        } else if let qMatch = html.range(of: "video_url_text\\s*:\\s*['\"]([^'\"]+)['\"]", options: .regularExpression) {
            let qStr = String(html[qMatch])
            if qStr.contains("1080") { quality = "1080p" }
            else if qStr.contains("720") { quality = "720p" }
            else if qStr.contains("480") { quality = "480p" }
            else if qStr.contains("360") { quality = "360p" }
        }
        
        // Extract Candidate Embed URLs
        var candidateEmbeds: [String] = []
        for regex in Self.gffEmbedRegexes {
            if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let val = (html as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\/", with: "/")
                if val.hasPrefix("http") {
                    if !candidateEmbeds.contains(val) { candidateEmbeds.append(val) }
                } else if val.hasPrefix("/embed/") {
                    let full = "https://gayforfans.com" + val
                    if !candidateEmbeds.contains(full) { candidateEmbeds.append(full) }
                }
            }
        }

        for regex in Self.gffVideoIdRegexes {
            if let match = regex.firstMatch(in: targetUrl + "\n" + html, options: [], range: NSRange(location: 0, length: ((targetUrl + "\n" + html) as NSString).length)),
               match.numberOfRanges > 1 {
                let vidId = ((targetUrl + "\n" + html) as NSString).substring(with: match.range(at: 1))
                let defaultEmbed = "https://gayforfans.com/embed/\(vidId)/"
                if !candidateEmbeds.contains(defaultEmbed) && !candidateEmbeds.contains("https://gayforfans.com/embed/\(vidId)") {
                    candidateEmbeds.append(defaultEmbed)
                }
            }
        }
        
        var embedURL = candidateEmbeds.first ?? targetUrl

        // If stream URL was not in main page, attempt embed page fetch across candidate embeds
        if streamURL == nil && !candidateEmbeds.isEmpty {
            LoggerService.shared.log("[GFF] Stream URL not in main page; testing \(candidateEmbeds.count) candidate embed targets", level: .info)
            for embed in candidateEmbeds {
                if streamURL != nil { break }
                if let ytdlp = ytdlpBinary {
                    for browser in browsersToTry {
                        if let browserName = browser, deniedCookieSources.contains(browserName) { continue }
                        var embedArgs = [ytdlp.path, "--ignore-config", "--dump-pages"]
                        if let browserName = browser {
                            embedArgs.append(contentsOf: ["--cookies-from-browser", Self.cookiesFromBrowserArgument(for: browserName)])
                        }
                        appendSiteSpecificArgs(for: embed, to: &embedArgs)
                        embedArgs.append("--")
                        embedArgs.append(embed)
                        
                        var embedDump: String? = nil
                        do {
                            embedDump = try await processRunner.runCommand(embedArgs)
                        } catch let error as YtdlpError {
                            if case .commandFailed(let output) = error {
                                embedDump = output
                            }
                        } catch {
                            LoggerService.shared.log("[GFF] Non-YtdlpError during embed dump-pages: \(error.localizedDescription)", level: .debug)
                        }
                        
                        if let output = embedDump, !output.isEmpty {
                            var embedChunks: [String] = []
                            for line in output.split(whereSeparator: \.isNewline) {
                                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                                if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR"),
                                   let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                                    let decodedString = String(decoding: decodedData, as: UTF8.self)
                                    if !decodedString.isEmpty {
                                        embedChunks.append(decodedString)
                                    }
                                }
                            }
                            if !embedChunks.isEmpty {
                                let embedHtml = embedChunks.joined()
                                for regex in Self.gffStreamRegexes {
                                    if let match = regex.firstMatch(in: embedHtml, options: [], range: NSRange(location: 0, length: (embedHtml as NSString).length)),
                                       match.numberOfRanges > 1 {
                                        let rawCandidate = (embedHtml as NSString).substring(with: match.range(at: 1))
                                        if let candidate = sanitizeGFFStreamURL(rawCandidate) {
                                            streamURL = candidate
                                            embedURL = embed
                                            break
                                        }
                                    }
                                }
                                if thumbnailURL == nil {
                                    for regex in Self.gffThumbRegexes {
                                        if let match = regex.firstMatch(in: embedHtml, options: [], range: NSRange(location: 0, length: (embedHtml as NSString).length)),
                                           match.numberOfRanges > 1 {
                                            let candidate = (embedHtml as NSString).substring(with: match.range(at: 1))
                                                .replacingOccurrences(of: "\\/", with: "/")
                                            if candidate.hasPrefix("http") {
                                                thumbnailURL = candidate
                                                break
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // HTTP direct fallback for embed URL if yt-dlp did not extract stream
                if streamURL == nil, let embedPageURL = URL(string: embed), (processRunner is DefaultYtdlpProcessRunner) {
                    var embedReq = URLRequest(url: embedPageURL)
                    embedReq.timeoutInterval = 5.0
                    embedReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                    embedReq.setValue("https://gayforfans.com/", forHTTPHeaderField: "Referer")
                    if let (data, response) = try? await EgressBoundary.session.boundedData(for: embedReq),
                       let httpResponse = response as? HTTPURLResponse,
                       (200...299).contains(httpResponse.statusCode),
                       let text = String(data: data, encoding: .utf8) {
                        for regex in Self.gffStreamRegexes {
                            if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)),
                               match.numberOfRanges > 1 {
                                let rawCandidate = (text as NSString).substring(with: match.range(at: 1))
                                if let candidate = sanitizeGFFStreamURL(rawCandidate) {
                                    streamURL = candidate
                                    embedURL = embed
                                    break
                                }
                            }
                        }
                        if thumbnailURL == nil {
                            for regex in Self.gffThumbRegexes {
                                if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)),
                                   match.numberOfRanges > 1 {
                                    let candidate = (text as NSString).substring(with: match.range(at: 1))
                                        .replacingOccurrences(of: "\\/", with: "/")
                                    if candidate.hasPrefix("http") {
                                        thumbnailURL = candidate
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        guard let validStreamURL = streamURL else {
            LoggerService.shared.log("[GFF] Failed to extract valid stream URL from page or embed targets (HTML length: \(html.count))", level: .warning)
            return nil
        }
        
        LoggerService.shared.log("[GFF] Successfully extracted stream: \(LoggerService.sanitizeURLForLog(validStreamURL)) (Quality: \(quality ?? "auto"))", level: .info)
        return GFFExtractedMedia(
            streamURL: validStreamURL,
            embedURL: embedURL,
            title: title,
            thumbnailURL: thumbnailURL,
            duration: nil,
            quality: quality
        )
    }

    // MARK: - BestCam / Abyss Extractor

    func isBestCamURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "bestcam.tv" || host.hasSuffix(".bestcam.tv") ||
               host == "abyssplayer.com" || host.hasSuffix(".abyssplayer.com") ||
               host == "abyss.to" || host.hasSuffix(".abyss.to")
    }

    struct BestCamSource: Sendable {
        let label: String
        let resId: Int
        let size: Int64
        let codec: String
        let path: String
        let url: String
        let sub: String
    }

    struct BestCamExtractedMedia: Sendable {
        let streamURL: String
        let embedURL: String
        let title: String
        let thumbnailURL: String?
        let duration: Double?
        let quality: String?
        let encryptedFilename: String?
        let allSources: [BestCamSource]
    }

    private enum BestCamStreamCipher {
        // Derives AES-256-CTR key hex via RFC 1321 MD5 required by BestCam/Abyss CDN protocol
        static func deriveKeyHex(from string: String) -> String {
            let data = Data(string.utf8)
            var padded = [UInt8](data)
            let bitLen = UInt64(data.count) * 8
            padded.append(0x80)
            while padded.count % 64 != 56 {
                padded.append(0)
            }
            withUnsafeBytes(of: bitLen.littleEndian) { padded.append(contentsOf: $0) }

            var a: UInt32 = 0x67452301
            var b: UInt32 = 0xefcdab89
            var c: UInt32 = 0x98badcfe
            var d: UInt32 = 0x10325476

            let s: [UInt32] = [
                7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,
                5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,
                4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,
                6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21
            ]

            let k: [UInt32] = [
                0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
                0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
                0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
                0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
                0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
                0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
                0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
                0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
                0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
                0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
                0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
                0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
                0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
                0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
                0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
                0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
            ]

            for chunkStart in stride(from: 0, to: padded.count, by: 64) {
                var m = [UInt32](repeating: 0, count: 16)
                for i in 0..<16 {
                    let o = chunkStart + i * 4
                    m[i] = UInt32(padded[o]) | (UInt32(padded[o + 1]) << 8) | (UInt32(padded[o + 2]) << 16) | (UInt32(padded[o + 3]) << 24)
                }
                var aa = a
                var bb = b
                var cc = c
                var dd = d
                for i in 0..<64 {
                    var f: UInt32 = 0
                    var g = 0
                    if i < 16 { f = (bb & cc) | ((~bb) & dd); g = i }
                    else if i < 32 { f = (dd & bb) | ((~dd) & cc); g = (5 * i + 1) % 16 }
                    else if i < 48 { f = bb ^ cc ^ dd; g = (3 * i + 5) % 16 }
                    else { f = cc ^ (bb | (~dd)); g = (7 * i) % 16 }
                    let temp = dd; dd = cc; cc = bb
                    let sum = aa &+ f &+ k[i] &+ m[g]
                    bb = bb &+ ((sum << s[i]) | (sum >> (32 - s[i])))
                    aa = temp
                }
                a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
            }

            var res = [UInt8]()
            res.reserveCapacity(16)
            withUnsafeBytes(of: a.littleEndian) { res.append(contentsOf: $0) }
            withUnsafeBytes(of: b.littleEndian) { res.append(contentsOf: $0) }
            withUnsafeBytes(of: c.littleEndian) { res.append(contentsOf: $0) }
            withUnsafeBytes(of: d.littleEndian) { res.append(contentsOf: $0) }
            return res.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func decryptAES256CTRData(data: Data, keyStr: String) -> Data? {
        let keyHex = BestCamStreamCipher.deriveKeyHex(from: keyStr)
        guard let keyData = keyHex.data(using: .ascii), keyData.count == 32 else { return nil }
        let ivData = keyData.prefix(16)

        var cryptor: CCCryptorRef?
        let createStatus = keyData.withUnsafeBytes { keyBytes in
            ivData.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    32,
                    nil, 0, 0, 0,
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let ref = cryptor else { return nil }
        defer { CCCryptorRelease(ref) }

        let capacity = data.count
        var decryptedData = Data(count: capacity)
        var dataOutMoved = 0
        let updateStatus = data.withUnsafeBytes { inBytes in
            decryptedData.withUnsafeMutableBytes { outBytes in
                CCCryptorUpdate(
                    ref,
                    inBytes.baseAddress,
                    capacity,
                    outBytes.baseAddress,
                    capacity,
                    &dataOutMoved
                )
            }
        }
        guard updateStatus == kCCSuccess else { return nil }
        return decryptedData.prefix(dataOutMoved)
    }

    /// Runs one chunk through the cipher, growing `buffer` as needed.
    private nonisolated static func cryptorUpdate(_ cryptor: CCCryptorRef, _ input: Data, into buffer: inout Data) -> Data? {
        if buffer.count < input.count {
            buffer = Data(count: input.count)
        }
        var dataOutMoved = 0
        let status = input.withUnsafeBytes { inBytes in
            buffer.withUnsafeMutableBytes { outBytes in
                CCCryptorUpdate(cryptor, inBytes.baseAddress, input.count, outBytes.baseAddress, input.count, &dataOutMoved)
            }
        }
        return status == kCCSuccess ? buffer.prefix(dataOutMoved) : nil
    }

    /// Streams the file through the cipher off the main actor. Each chunk is
    /// released per iteration, so memory stays flat for multi-GB videos.
    nonisolated static func decryptBestCamFile(at fileURL: URL, filename: String) throws {
        let keyHex = BestCamStreamCipher.deriveKeyHex(from: filename)
        guard let keyData = keyHex.data(using: .ascii), keyData.count == 32 else {
            throw YtdlpError.downloadFailed("Invalid stream decryption key")
        }
        let ivData = keyData.prefix(16)

        var cryptor: CCCryptorRef?
        let createStatus = keyData.withUnsafeBytes { keyBytes in
            ivData.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    32,
                    nil, 0, 0, 0,
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let ref = cryptor else {
            throw YtdlpError.downloadFailed("Failed to initialize stream decryptor")
        }
        defer { CCCryptorRelease(ref) }

        let tempOutputURL = fileURL.deletingLastPathComponent().appendingPathComponent("decrypted_\(UUID().uuidString)_\(fileURL.lastPathComponent)")
        guard FileManager.default.createFile(atPath: tempOutputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw YtdlpError.downloadFailed("Failed to create temporary file for stream decryption with restricted permissions")
        }
        var replaced = false
        defer {
            if !replaced { try? FileManager.default.removeItem(at: tempOutputURL) }
        }
        guard let readHandle = try? FileHandle(forReadingFrom: fileURL),
              let writeHandle = try? FileHandle(forWritingTo: tempOutputURL) else {
            throw YtdlpError.downloadFailed("Failed to open file handles for stream decryption")
        }
        defer {
            try? readHandle.close()
            try? writeHandle.close()
        }

        let chunkSize = 1024 * 1024
        var buffer = Data(count: chunkSize)

        do {
            var hasMoreData = true
            while hasMoreData {
                hasMoreData = try autoreleasepool {
                    guard let chunk = try readHandle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                    guard let decrypted = cryptorUpdate(ref, chunk, into: &buffer) else {
                        throw YtdlpError.downloadFailed("Stream decryption update failed")
                    }
                    try writeHandle.write(contentsOf: decrypted)
                    return true
                }
            }
        } catch let error as YtdlpError {
            throw error
        } catch {
            throw YtdlpError.downloadFailed("Stream decryption could not read or write the file: \(error.localizedDescription)")
        }

        try? readHandle.close()
        try? writeHandle.close()
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempOutputURL)
        replaced = true
    }

    func parseBestCamSources(from json: [String: Any]) -> [BestCamSource] {
        let mp4 = (json["mp4"] as? [String: Any]) ?? json
        let fristDatas = (mp4["fristDatas"] as? [[String: Any]])
            ?? (mp4["firstDatas"] as? [[String: Any]])
            ?? (mp4["frist_datas"] as? [[String: Any]])
            ?? (json["fristDatas"] as? [[String: Any]])
            ?? []

        func splitURLAndPath(fullUrl: String, fallbackPath: String? = nil) -> (url: String, path: String)? {
            if let u = URL(string: fullUrl), let host = u.host {
                let scheme = u.scheme ?? "https"
                let base = "\(scheme)://\(host)"
                var p = u.path
                if p.hasPrefix("/") { p.removeFirst() }
                if !p.isEmpty {
                    return (base, p)
                } else if let fallback = fallbackPath, !fallback.isEmpty {
                    var fb = fallback
                    if fb.hasPrefix("/") { fb.removeFirst() }
                    return (base, fb)
                }
            }
            return nil
        }

        var parsedSources: [BestCamSource] = []
        if let rawSources = mp4["sources"] as? [[String: Any]] {
            for raw in rawSources {
                let label = (raw["label"] as? String) ?? "720p"
                let resId = (raw["res_id"] as? Int) ?? 0
                var size = (raw["size"] as? Int64) ?? Int64((raw["size"] as? Int) ?? 0)
                var codec = (raw["codec"] as? String) ?? "h264"
                let sub = (raw["sub"] as? String) ?? ""

                // Check direct path & url in raw source (Schema A)
                if let rawPath = raw["path"] as? String, !rawPath.isEmpty,
                   let rawUrl = raw["url"] as? String, !rawUrl.isEmpty {
                    var path = rawPath
                    if path.hasPrefix("/") { path.removeFirst() }
                    let sourceUrl: String
                    if let parsed = URL(string: rawUrl), let host = parsed.host {
                        sourceUrl = "\(parsed.scheme ?? "https")://\(host)"
                        if parsed.path.count > 1 && path.isEmpty {
                            var pp = parsed.path
                            if pp.hasPrefix("/") { pp.removeFirst() }
                            path = pp
                        }
                    } else {
                        sourceUrl = rawUrl
                    }
                    parsedSources.append(BestCamSource(
                        label: label,
                        resId: resId,
                        size: size,
                        codec: codec,
                        path: path,
                        url: sourceUrl,
                        sub: sub
                    ))
                    continue
                }

                // Fall back to matching fristDatas by res_id or size (Schema B)
                let matchedFrist = fristDatas.first(where: {
                    if resId > 0, let fResId = $0["res_id"] as? Int, fResId == resId {
                        return true
                    }
                    return false
                }) ?? fristDatas.first(where: {
                    if size > 0 {
                        let fSize = ($0["size"] as? Int64) ?? Int64(($0["size"] as? Int) ?? 0)
                        return fSize == size
                    }
                    return false
                })

                if let matched = matchedFrist {
                    let fdUrl = (matched["url"] as? String) ?? (matched["path"] as? String) ?? ""
                    if let (base, p) = splitURLAndPath(fullUrl: fdUrl, fallbackPath: raw["path"] as? String) {
                        if size == 0 {
                            size = (matched["size"] as? Int64) ?? Int64((matched["size"] as? Int) ?? 0)
                        }
                        if codec.isEmpty, let c = matched["codec"] as? String {
                            codec = c
                        }
                        parsedSources.append(BestCamSource(
                            label: label,
                            resId: resId,
                            size: size,
                            codec: codec,
                            path: p,
                            url: base,
                            sub: sub
                        ))
                    }
                }
            }
        }

        // If rawSources was empty or failed to parse, attempt direct extraction from fristDatas
        if parsedSources.isEmpty && !fristDatas.isEmpty {
            for fd in fristDatas {
                let resId = (fd["res_id"] as? Int) ?? 0
                let size = (fd["size"] as? Int64) ?? Int64((fd["size"] as? Int) ?? 0)
                let codec = (fd["codec"] as? String) ?? "h264"
                let fdUrl = (fd["url"] as? String) ?? (fd["path"] as? String) ?? ""
                guard let (base, p) = splitURLAndPath(fullUrl: fdUrl) else { continue }
                let label: String
                switch resId {
                case 1: label = "240p"
                case 2: label = "360p"
                case 3: label = "480p"
                case 4: label = "720p"
                case 5: label = "1080p"
                case 6: label = "2160p"
                default: label = resId > 0 ? "\(resId)p" : "720p"
                }
                parsedSources.append(BestCamSource(
                    label: label,
                    resId: resId,
                    size: size,
                    codec: codec,
                    path: p,
                    url: base,
                    sub: ""
                ))
            }
        }

        parsedSources.sort { s1, s2 in
            if s1.resId != s2.resId {
                return s1.resId > s2.resId
            }
            return s1.size > s2.size
        }

        return parsedSources
    }

    func resolveBestCamMediaInfo(url: String, rawCookies: String? = nil, requestedFormat: String? = nil) async -> BestCamExtractedMedia? {
        let targetUrl = normalizeURLForYtdlp(url)
        guard let pageURL = URL(string: targetUrl) else { return nil }

        var title = "BestCam Video"
        var thumbnailURL: String? = nil
        var abyssSlug: String? = nil

        let host = (pageURL.host ?? "").lowercased()
        if host.contains("abyssplayer.com") || host.contains("abyss.to") {
            abyssSlug = pageURL.lastPathComponent
        } else {
            var html = ""
            if processRunner is DefaultYtdlpProcessRunner {
                var request = URLRequest(url: pageURL)
                request.timeoutInterval = 8.0
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                request.setValue("https://bestcam.tv/", forHTTPHeaderField: "Referer")
                if let raw = rawCookies, !raw.isEmpty {
                    request.setValue(raw, forHTTPHeaderField: "Cookie")
                }
                if let (data, response) = try? await EgressBoundary.session.boundedData(for: request),
                   let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode),
                   let fetched = String(data: data, encoding: .utf8) {
                    html = fetched
                }
            }

            if html.isEmpty {
                let ytdlpBinary = resolvedYtdlpBinary
                if let ytdlp = ytdlpBinary {
                    var dumpArgs = [ytdlp.path, "--ignore-config", "--dump-pages"]
                    appendSiteSpecificArgs(for: targetUrl, to: &dumpArgs)
                    dumpArgs.append("--")
                    dumpArgs.append(targetUrl)
                    if let output = try? await processRunner.runCommand(dumpArgs) {
                        var chunks: [String] = []
                        for line in output.split(whereSeparator: \.isNewline) {
                            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                            if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR"),
                               let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
                               let decodedString = String(decoding: decodedData, as: UTF8.self) as String?,
                               !decodedString.isEmpty {
                                chunks.append(decodedString)
                            }
                        }
                        if !chunks.isEmpty {
                            html = chunks.joined()
                        }
                    }
                }
            }

            guard !html.isEmpty else { return nil }

            // Extract Title
            for regex in Self.bestCamTitleRegexes {
                if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
                   match.numberOfRanges > 1 {
                    let rawTitle = (html as NSString).substring(with: match.range(at: 1))
                        .replacingOccurrences(of: "(?i) - bestcam\\.tv", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "(?i)bestcam\\.tv - ", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .decodingHTMLEntities()
                    if !rawTitle.isEmpty {
                        title = rawTitle
                        break
                    }
                }
            }

            // Extract Thumbnail
            for regex in Self.bestCamThumbRegexes {
                if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
                   match.numberOfRanges > 1 {
                    let candidate = (html as NSString).substring(with: match.range(at: 1))
                        .replacingOccurrences(of: "\\/", with: "/")
                    if candidate.hasPrefix("http") {
                        thumbnailURL = candidate
                        break
                    }
                }
            }

            // Extract Abyss slug from iframe
            for regex in Self.bestCamIframeRegexes {
                if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
                   match.numberOfRanges > 1 {
                    abyssSlug = (html as NSString).substring(with: match.range(at: 1))
                    break
                }
            }
        }

        guard let slug = abyssSlug, !slug.isEmpty else { return nil }
        let embedURL = "https://abyssplayer.com/\(slug)"

        var datasB64: String? = nil
        var infoJSON: [String: Any]? = nil

        guard let abyssPageURL = URL(string: embedURL) else { return nil }
        var abyssReq = URLRequest(url: abyssPageURL)
        abyssReq.timeoutInterval = 8.0
        abyssReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        abyssReq.setValue("https://bestcam.tv/", forHTTPHeaderField: "Referer")

        if let (data, response) = try? await EgressBoundary.session.boundedData(for: abyssReq),
           let httpResponse = response as? HTTPURLResponse,
           (200...299).contains(httpResponse.statusCode),
           let pageHtml = String(data: data, encoding: .utf8),
           let m = pageHtml.range(of: "const datas = \"([^\"]+)\"", options: .regularExpression) {
            let matched = String(pageHtml[m])
            datasB64 = matched.replacingOccurrences(of: "const datas = \"", with: "").replacingOccurrences(of: "\"", with: "")
        }

        if datasB64 == nil,
           let infoURL = URL(string: "https://abyssplayer.com/info/\(slug)") {
            var infoReq = URLRequest(url: infoURL)
            infoReq.timeoutInterval = 8.0
            infoReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            infoReq.setValue("https://bestcam.tv/", forHTTPHeaderField: "Referer")
            infoReq.setValue("https://bestcam.tv/", forHTTPHeaderField: "x-referer")
            infoReq.setValue("1920x1080", forHTTPHeaderField: "x-client-screen")
            if let (data, response) = try? await EgressBoundary.session.boundedData(for: infoReq),
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                infoJSON = json
            }
        }

        if datasB64 == nil && infoJSON == nil {
            let ytdlpBinary = resolvedYtdlpBinary
            if let ytdlp = ytdlpBinary {
                var dumpArgs = [ytdlp.path, "--ignore-config", "--dump-pages"]
                appendSiteSpecificArgs(for: embedURL, to: &dumpArgs)
                dumpArgs.append("--")
                dumpArgs.append(embedURL)
                if let output = try? await processRunner.runCommand(dumpArgs) {
                    for line in output.split(whereSeparator: \.isNewline) {
                        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                        if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR"),
                           let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
                           let pageHtml = String(decoding: decodedData, as: UTF8.self) as String?,
                           !pageHtml.isEmpty,
                           let m = pageHtml.range(of: "const datas = \"([^\"]+)\"", options: .regularExpression) {
                            let matched = String(pageHtml[m])
                            datasB64 = matched.replacingOccurrences(of: "const datas = \"", with: "").replacingOccurrences(of: "\"", with: "")
                            break
                        }
                    }
                }
            }
        }

        var userIdVal: Any? = nil
        var md5IdVal: Any? = nil
        var mediaVal: String? = nil

        if let b64 = datasB64,
           let decodedData = Data(base64Encoded: b64),
           let latinStr = String(data: decodedData, encoding: .isoLatin1),
           let utf8Data = latinStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: utf8Data) as? [String: Any] {
            userIdVal = json["user_id"]
            md5IdVal = json["md5_id"]
            mediaVal = json["media"] as? String
        } else if let json = infoJSON {
            userIdVal = json["user_id"]
            md5IdVal = json["md5_id"]
            mediaVal = json["media"] as? String
        }

        guard let userId = userIdVal, let md5Id = md5IdVal, let mediaStr = mediaVal else {
            return nil
        }

        let keyStr = "\(userId):\(slug):\(md5Id)"
        let mediaBytes = Data(mediaStr.unicodeScalars.map { UInt8($0.value & 0xFF) })
        guard let decryptedData = decryptAES256CTRData(data: mediaBytes, keyStr: keyStr),
              let decryptedJson = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any] else {
            return nil
        }

        let parsedSources = parseBestCamSources(from: decryptedJson)
        guard !parsedSources.isEmpty else { return nil }

        guard let chosenSource = (requestedFormat.flatMap { reqFmt in parsedSources.first(where: { $0.label.lowercased() == reqFmt.lowercased() }) } ?? parsedSources.first) else {
            return nil
        }

        let streamURL = "\(chosenSource.url)/\(chosenSource.path)"
        let encryptedFilename = chosenSource.path.components(separatedBy: "/").last

        if title == "BestCam Video", let t = (infoJSON?["title"] as? String) ?? (decryptedJson["title"] as? String), !t.isEmpty {
            title = t
        }
        if thumbnailURL == nil, let poster = (infoJSON?["poster"] as? String) ?? (decryptedJson["poster"] as? String), !poster.isEmpty {
            thumbnailURL = poster
        }

        return BestCamExtractedMedia(
            streamURL: streamURL,
            embedURL: embedURL,
            title: title,
            thumbnailURL: thumbnailURL,
            duration: nil,
            quality: chosenSource.label,
            encryptedFilename: encryptedFilename,
            allSources: parsedSources
        )
    }

    private func fetchProtectedPageHTML(
        pageURL: URL,
        targetURL: String,
        rawCookies: String?,
        fallbackHost: String
    ) async -> String {
        var html = ""

        if processRunner is DefaultYtdlpProcessRunner {
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 15.0
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            let scheme = pageURL.scheme ?? "https"
            request.setValue("\(scheme)://\(pageURL.host ?? fallbackHost)/", forHTTPHeaderField: "Referer")
            if let rawCookies, !rawCookies.isEmpty {
                request.setValue(rawCookies, forHTTPHeaderField: "Cookie")
            }

            if let (data, response) = try? await EgressBoundary.session.boundedData(for: request),
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let fetched = String(data: data, encoding: .utf8) {
                html = fetched
            }
        }

        if html.isEmpty {
            if let ytdlp = resolvedYtdlpBinary {
                var dumpArgs = [ytdlp.path, "--ignore-config", "--dump-pages"]
                appendSiteSpecificArgs(for: targetURL, to: &dumpArgs)
                dumpArgs.append(contentsOf: ["--", targetURL])
                if let output = try? await processRunner.runCommand(dumpArgs) {
                    let chunks = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                        guard !trimmed.starts(with: "#"),
                              !trimmed.starts(with: "["),
                              !trimmed.starts(with: "WARNING"),
                              !trimmed.starts(with: "ERROR"),
                              let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
                            return nil
                        }
                        let decodedString = String(decoding: decodedData, as: UTF8.self)
                        return decodedString.isEmpty ? nil : decodedString
                    }
                    if !chunks.isEmpty {
                        html = chunks.joined()
                    }
                }
            }
        }

        return html
    }

    nonisolated private static func firstRegexCapture(
        in text: String,
        regexes: [NSRegularExpression],
        transform: (String) -> String?
    ) -> String? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        for regex in regexes {
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let value = transform(nsText.substring(with: match.range(at: 1))) {
                return value
            }
        }
        return nil
    }

    nonisolated private static func protectedThumbnail(
        in text: String,
        regexes: [NSRegularExpression]
    ) -> String? {
        firstRegexCapture(in: text, regexes: regexes) { raw in
            let candidate = raw.replacingOccurrences(of: "\\/", with: "/")
            return candidate.hasPrefix("http") ? candidate : nil
        }
    }

    nonisolated private static func protectedDuration(
        in text: String,
        regexes: [NSRegularExpression]
    ) -> Double? {
        firstRegexCapture(in: text, regexes: regexes) { raw in
            guard let value = Double(raw), value > 0 else { return nil }
            return raw
        }.flatMap(Double.init)
    }

    private func protectedPageContext(
        url: String,
        rawCookies: String?,
        fallbackHost: String
    ) async -> (targetURL: String, pageURL: URL, html: String)? {
        let targetURL = normalizeURLForYtdlp(url)
        guard let pageURL = URL(string: targetURL) else { return nil }
        let html = await fetchProtectedPageHTML(
            pageURL: pageURL,
            targetURL: targetURL,
            rawCookies: rawCookies,
            fallbackHost: fallbackHost
        )
        guard !html.isEmpty else { return nil }
        return (targetURL, pageURL, html)
    }

    // MARK: - Starwank Extractor

    struct ProtectedSiteSource: Equatable, Sendable {
        let label: String
        let url: String
        let height: Int
    }

    struct ProtectedSiteExtractedMedia: Equatable, Sendable {
        let streamURL: String
        let embedURL: String
        let title: String
        let thumbnailURL: String?
        let duration: Double?
        let quality: String?
        let allSources: [ProtectedSiteSource]
    }

    typealias StarwankSource = ProtectedSiteSource
    typealias StarwankExtractedMedia = ProtectedSiteExtractedMedia

    nonisolated private static func selectProtectedSiteSource(
        from sources: [ProtectedSiteSource],
        requestedFormat: String?
    ) -> ProtectedSiteSource? {
        guard let fallback = sources.first else { return nil }
        if let requested = requestedFormat?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
           let matched = sources.first(where: {
               $0.label.lowercased() == requested ||
               "\($0.height)p" == requested ||
               "\($0.height)" == requested ||
               $0.label.lowercased().contains(requested)
           }) {
            return matched
        }
        return fallback
    }

    nonisolated static func isStarwankURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "starwank.com" || host.hasSuffix(".starwank.com")
    }

    private func isStarwankURL(_ urlOrHost: String) -> Bool {
        Self.isStarwankURL(urlOrHost)
    }

    nonisolated static func parseStarwankMedia(html: String, targetUrl: String, requestedFormat: String? = nil) -> StarwankExtractedMedia? {
        let nsHtml = html as NSString
        let htmlRange = NSRange(location: 0, length: nsHtml.length)

        let title = Self.firstRegexCapture(in: html, regexes: starwankTitleRegexes) { raw in
            let cleaned = raw
                .replacingOccurrences(of: "(?i)\\s*-\\s*starwank(\\.com)?.*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)^starwank(\\.com)?\\s*-\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .decodingHTMLEntities()
            guard !cleaned.isEmpty,
                  cleaned.lowercased() != "starwank",
                  cleaned.lowercased() != "starwank.com" else {
                return nil
            }
            return cleaned
        } ?? "StarWank Video"
        let thumbnailURL = Self.protectedThumbnail(in: html, regexes: starwankThumbRegexes)
        let duration = Self.protectedDuration(in: html, regexes: starwankDurationRegexes)

        // Embed URL
        var embedURL = targetUrl
        let targetAndHtml = targetUrl + "\n" + html
        let targetAndHtmlNs = targetAndHtml as NSString
        let targetAndHtmlRange = NSRange(location: 0, length: targetAndHtmlNs.length)
        for regex in starwankVideoIdRegexes {
            if let match = regex.firstMatch(in: targetAndHtml, options: [], range: targetAndHtmlRange),
               match.numberOfRanges > 1 {
                let vidId = targetAndHtmlNs.substring(with: match.range(at: 1))
                embedURL = "https://starwank.com/embed/\(vidId)"
                break
            }
        }

        // Parse sources
        var parsedSources: [StarwankSource] = []
        var seenUrls = Set<String>()

        // Pattern 1: Script block with setAttribute('src', ...) and setAttribute('title', ...)
        if let blockRegex = Self.starwankSourceBlockRegex {
            let matches = blockRegex.matches(in: html, options: [], range: htmlRange)
            for m in matches where m.numberOfRanges > 2 {
                let rawSrc = nsHtml.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\/", with: "/")
                let rawTitle = nsHtml.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard rawSrc.hasPrefix("http"), seenUrls.insert(rawSrc).inserted else { continue }
                let height = Int(rawTitle.replacingOccurrences(of: "p", with: "", options: .caseInsensitive)) ?? 720
                let label = rawTitle.isEmpty ? "\(height)p" : rawTitle
                parsedSources.append(StarwankSource(label: label, url: rawSrc, height: height))
            }
        }

        // Pattern 2: Standalone setAttribute('src', ...) in JS if no block matched
        if parsedSources.isEmpty {
            if let standaloneRegex = Self.starwankStandaloneRegex {
                let matches = standaloneRegex.matches(in: html, options: [], range: htmlRange)
                for m in matches where m.numberOfRanges > 1 {
                    let rawSrc = nsHtml.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\/", with: "/")
                    guard seenUrls.insert(rawSrc).inserted else { continue }
                    let height: Int
                    if rawSrc.contains("1080") {
                        height = 1080
                    } else if rawSrc.contains("360") {
                        height = 360
                    } else if rawSrc.contains("480") {
                        height = 480
                    } else {
                        height = 720
                    }
                    parsedSources.append(StarwankSource(label: "\(height)p", url: rawSrc, height: height))
                }
            }

            // Pattern 3: KVS player config (video_url, video_alt_url, etc.)
            if parsedSources.isEmpty {
                for (regex, defaultHeight) in Self.starwankKvsRegexes {
                    if let match = regex.firstMatch(in: html, options: [], range: htmlRange),
                       match.numberOfRanges > 1 {
                        let rawSrc = nsHtml.substring(with: match.range(at: 1)).replacingOccurrences(of: "\\/", with: "/")
                        if seenUrls.insert(rawSrc).inserted {
                            parsedSources.append(StarwankSource(label: "\(defaultHeight)p", url: rawSrc, height: defaultHeight))
                        }
                    }
                }
            }
        }

        // Sort sources by height descending (e.g. 720p, then 360p)
        parsedSources.sort { $0.height > $1.height }

        guard let chosenSource = Self.selectProtectedSiteSource(
            from: parsedSources,
            requestedFormat: requestedFormat
        ) else {
            return nil
        }

        return StarwankExtractedMedia(
            streamURL: chosenSource.url,
            embedURL: embedURL,
            title: title,
            thumbnailURL: thumbnailURL,
            duration: duration,
            quality: chosenSource.label,
            allSources: parsedSources
        )
    }

    func resolveStarwankMediaInfo(url: String, rawCookies: String? = nil, requestedFormat: String? = nil) async -> StarwankExtractedMedia? {
        guard let (targetUrl, pageURL, html) = await protectedPageContext(
            url: url,
            rawCookies: rawCookies,
            fallbackHost: "starwank.com"
        ) else {
            return nil
        }

        // If this was an embed page and it points to empty_referrer_redirect, follow it to get multi-quality options
        if pageURL.pathComponents.contains("embed"),
           let redirectMatch = Self.starwankEmptyReferrerRegex?.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
           redirectMatch.numberOfRanges > 1 {
            let redirectURL = (html as NSString).substring(with: redirectMatch.range(at: 1))
            if Self.isStarwankURL(redirectURL),
               !redirectURL.contains("embed/"),
               let fullMedia = await resolveStarwankMediaInfo(url: redirectURL, rawCookies: rawCookies, requestedFormat: requestedFormat) {
                return fullMedia
            }
        }

        return Self.parseStarwankMedia(html: html, targetUrl: targetUrl, requestedFormat: requestedFormat)
    }

    // MARK: - Pussyspace Extractor

    typealias PussyspaceSource = ProtectedSiteSource
    typealias PussyspaceExtractedMedia = ProtectedSiteExtractedMedia

    nonisolated static func isPussyspaceURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "pussyspace.com" || host.hasSuffix(".pussyspace.com")
    }

    private func isPussyspaceURL(_ urlOrHost: String) -> Bool {
        Self.isPussyspaceURL(urlOrHost)
    }

    nonisolated static func parsePussyspaceMedia(html: String, targetUrl: String, requestedFormat: String? = nil, playerHtml: String? = nil) -> PussyspaceExtractedMedia? {
        let title = Self.firstRegexCapture(in: html, regexes: pussyspaceTitleRegexes) { raw in
            let cleaned = raw
                .replacingOccurrences(of: "(?i)\\s*(\\||&#124;)\\s*pussyspace.*$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)(\\s+\\b(hd|straight|sex|video)\\b|\\s*\\(\\d+\\s*min\\))+\\s*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .decodingHTMLEntities()
            guard !cleaned.isEmpty,
                  cleaned.lowercased() != "pussyspace",
                  cleaned.lowercased() != "pussyspace.com" else {
                return nil
            }
            return cleaned
        } ?? "PussySpace Video"
        var thumbnailURL = Self.protectedThumbnail(in: html, regexes: pussyspaceThumbRegexes)
        let duration = Self.protectedDuration(in: html, regexes: pussyspaceDurationRegexes)

        // Parse sources from playerHtml or html
        let streamContent = playerHtml ?? html
        var parsedSources: [PussyspaceSource] = []
        var seenUrls = Set<String>()

        let streamNs = streamContent as NSString
        let streamRange = NSRange(location: 0, length: streamNs.length)

        if thumbnailURL == nil {
            thumbnailURL = Self.protectedThumbnail(in: streamContent, regexes: pussyspaceThumbRegexes)
        }

        // Pattern 1: Playerjs file:"..." with [720p]url,[480p]url or url.m3u8 or url.mp4
        for regex in pussyspaceFileRegexes {
            if let match = regex.firstMatch(in: streamContent, options: [], range: streamRange),
               match.numberOfRanges > 1 {
                let fileRaw = streamNs.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\/", with: "/")

                if fileRaw.contains("[") && fileRaw.contains("p]") {
                    // Split qualities like [240p]url,[480p]url,[720p]url
                    if let qRegex = Self.pussyspaceQualityRegex {
                        let qMatches = qRegex.matches(in: fileRaw, options: [], range: NSRange(location: 0, length: (fileRaw as NSString).length))
                        for qm in qMatches where qm.numberOfRanges > 2 {
                            let hStr = (fileRaw as NSString).substring(with: qm.range(at: 1))
                            let rawUrl = (fileRaw as NSString).substring(with: qm.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                            let height = Int(hStr) ?? 720
                            if rawUrl.hasPrefix("http"), seenUrls.insert(rawUrl).inserted {
                                parsedSources.append(PussyspaceSource(label: "\(height)p", url: rawUrl, height: height))
                            }
                        }
                    }
                } else if fileRaw.contains(" or ") {
                    // Split urls like "url1.m3u8 or url2.mp4"
                    let parts = fileRaw.components(separatedBy: " or ")
                    for part in parts {
                        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("http"), seenUrls.insert(trimmed).inserted else { continue }
                        let isHls = trimmed.contains(".m3u8") || trimmed.contains("hls")
                        let height = isHls ? 1080 : 720
                        let label = isHls ? "HLS Auto" : "\(height)p"
                        parsedSources.append(PussyspaceSource(label: label, url: trimmed, height: height))
                    }
                } else if fileRaw.hasPrefix("http") && seenUrls.insert(fileRaw).inserted {
                    let isHls = fileRaw.contains(".m3u8") || fileRaw.contains("hls")
                    let height = isHls ? 1080 : 720
                    let label = isHls ? "HLS Auto" : "\(height)p"
                    parsedSources.append(PussyspaceSource(label: label, url: fileRaw, height: height))
                }
                if !parsedSources.isEmpty { break }
            }
        }

        // Pattern 2: reversebuffer URLs directly in HTML/JS
        if parsedSources.isEmpty {
            if let bufRegex = Self.pussyspaceBufferRegex {
                let matches = bufRegex.matches(in: streamContent, options: [], range: streamRange)
                for m in matches where m.numberOfRanges > 1 {
                    let rawUrl = streamNs.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\/", with: "/")
                    guard seenUrls.insert(rawUrl).inserted else { continue }
                    let isHls = rawUrl.contains(".m3u8") || rawUrl.contains("hls")
                    let height = isHls ? 1080 : 720
                    let label = isHls ? "HLS Auto" : "\(height)p"
                    parsedSources.append(PussyspaceSource(label: label, url: rawUrl, height: height))
                }
            }
        }

        parsedSources.sort { $0.height > $1.height }

        guard let chosenSource = Self.selectProtectedSiteSource(
            from: parsedSources,
            requestedFormat: requestedFormat
        ) else {
            return nil
        }

        return PussyspaceExtractedMedia(
            streamURL: chosenSource.url,
            embedURL: targetUrl,
            title: title,
            thumbnailURL: thumbnailURL,
            duration: duration,
            quality: chosenSource.label,
            allSources: parsedSources
        )
    }

    func resolvePussyspaceMediaInfo(url: String, rawCookies: String? = nil, requestedFormat: String? = nil) async -> PussyspaceExtractedMedia? {
        guard let (targetUrl, pageURL, html) = await protectedPageContext(
            url: url,
            rawCookies: rawCookies,
            fallbackHost: "www.pussyspace.com"
        ) else {
            return nil
        }

        // 3. Extract player endpoint token (type and id)
        var playerHtml: String? = nil
        let nsHtml = html as NSString
        let htmlRange = NSRange(location: 0, length: nsHtml.length)
        var playerType: String? = nil
        var playerId: String? = nil

        for regex in Self.pussyspacePlayerTokenRegexes {
            if let match = regex.firstMatch(in: html, options: [], range: htmlRange),
               match.numberOfRanges > 2 {
                playerType = nsHtml.substring(with: match.range(at: 1))
                playerId = nsHtml.substring(with: match.range(at: 2))
                break
            }
        }

        // 4. Fetch player payload via POST /get/player/{playerType}/
        if let type = playerType, let id = playerId,
           let host = pageURL.host,
           let playerURL = URL(string: "\(pageURL.scheme ?? "https")://\(host)/get/player/\(type)/") {
            var playerReq = URLRequest(url: playerURL)
            playerReq.httpMethod = "POST"
            playerReq.timeoutInterval = 15.0
            playerReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            playerReq.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            playerReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            playerReq.setValue(targetUrl, forHTTPHeaderField: "Referer")
            if let raw = rawCookies, !raw.isEmpty {
                playerReq.setValue(raw, forHTTPHeaderField: "Cookie")
            }
            playerReq.httpBody = "id=\(id)".data(using: .utf8)

            if let (data, response) = try? await EgressBoundary.session.boundedData(for: playerReq),
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let fetchedPlayer = String(data: data, encoding: .utf8) {
                playerHtml = fetchedPlayer
            }
        }

        return Self.parsePussyspaceMedia(html: html, targetUrl: targetUrl, requestedFormat: requestedFormat, playerHtml: playerHtml)
    }

    private func normalizeURLForYtdlp(_ urlString: String, depth: Int = 0) -> String {
        guard depth < 3 else { return urlString }
        guard var components = URLComponents(string: urlString) else { return urlString }
        if let nested = components.queryItems?.first(where: { ["url", "u", "redirect", "target"].contains($0.name.lowercased()) })?.value,
           isBoyfriendTVURL(nested) {
            return normalizeURLForYtdlp(nested, depth: depth + 1)
        }

        guard let host = components.host?.lowercased() else { return urlString }

        // 1. BoyfriendTV normalization
        if isBoyfriendTVURL(host) {
            components.scheme = "https"
            components.queryItems = components.queryItems?.filter { item in
                let name = item.name.lowercased()
                return !Self.trackingNamesGroupA.contains(name) && !Self.trackingPrefixes.contains { name.hasPrefix($0) }
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            
            let path = components.path
            // Extract video ID from path or query across all language/subdomain variations
            let videoId: String? = {
                if let regex = Self.boyfriendPathVideoIdRegex,
                   let match = regex.firstMatch(in: path, options: [], range: NSRange(location: 0, length: (path as NSString).length)),
                   match.numberOfRanges > 1 {
                    return (path as NSString).substring(with: match.range(at: 1))
                }
                if let queryId = components.queryItems?.first(where: { ["id", "v", "video_id"].contains($0.name.lowercased()) })?.value,
                   queryId.allSatisfy(\.isNumber), !queryId.isEmpty {
                    return queryId
                }
                return nil
            }()

            let targetHost: String
            if host.contains("boyfriendtv.com") {
                targetHost = "www.boyfriendtv.com"
            } else if host.contains("boyfriend.tv") {
                targetHost = "www.boyfriend.tv"
            } else {
                targetHost = host
            }
            if let id = videoId {
                return "https://\(targetHost)/videos/\(id)/"
            }

            components.host = targetHost
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 2. Generic Tube / Gallery / Playlist URL normalization (e.g. /playlist/123/video/slug or /album/123/video/slug)
        let path = components.path
        if let regex = Self.galleryVideoSlugRegex,
           let match = regex.firstMatch(in: path, options: [], range: NSRange(location: 0, length: (path as NSString).length)),
           match.numberOfRanges > 1 {
            let videoSlug = (path as NSString).substring(with: match.range(at: 1))
            components.path = "/videos/\(videoSlug)/"
            return components.url?.absoluteString ?? components.string ?? urlString
        } else if host.contains("thisvid"),
                  let regex = Self.singleVideoSlugRegex,
                  let match = regex.firstMatch(in: path, options: [], range: NSRange(location: 0, length: (path as NSString).length)),
                  match.numberOfRanges > 1 {
            let videoSlug = (path as NSString).substring(with: match.range(at: 1))
            components.path = "/videos/\(videoSlug)/"
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 3. xHamster normalization
        if isXHamsterURL(host) {
            components.scheme = "https"
            components.queryItems = components.queryItems?.filter { item in
                let name = item.name.lowercased()
                return !Self.trackingNamesGroupB.contains(name) && !Self.trackingPrefixes.contains { name.hasPrefix($0) }
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }

            if host.hasSuffix("xhamster.com") {
                components.host = "xhamster.com"
            }
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 4. Guywh normalization
        if isGuywhURL(host) {
            components.scheme = "https"
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 5. Eporner normalization (map localized subdomains like pl.eporner.com, de.eporner.com to www.eporner.com so yt-dlp triggers its native Eporner extractor)
        if isEpornerURL(host) {
            components.scheme = "https"
            components.host = "www.eporner.com"
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 6. GayForFans normalization
        if isGFFURL(host) {
            components.scheme = "https"
            components.queryItems = components.queryItems?.filter { item in
                let name = item.name.lowercased()
                return !Self.trackingNamesGroupA.contains(name) && !Self.trackingPrefixes.contains { name.hasPrefix($0) }
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            if components.path.hasPrefix("/video/") {
                components.path = components.path.replacingOccurrences(of: "^/video/", with: "/videos/", options: .regularExpression)
            }
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 7. BestCam normalization
        if isBestCamURL(host) {
            components.scheme = "https"
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 8. Starwank normalization
        if isStarwankURL(host) {
            components.scheme = "https"
            components.queryItems = components.queryItems?.filter { item in
                let name = item.name.lowercased()
                return !Self.trackingNamesGroupB.contains(name) && !Self.trackingPrefixes.contains { name.hasPrefix($0) }
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 9. Pussyspace normalization
        if isPussyspaceURL(host) {
            components.scheme = "https"
            components.queryItems = components.queryItems?.filter { item in
                let name = item.name.lowercased()
                return !Self.trackingNamesGroupB.contains(name) && !Self.trackingPrefixes.contains { name.hasPrefix($0) }
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        return components.string ?? urlString
    }

    func normalizeURL(_ urlString: String) -> String {
        normalizeURLForYtdlp(urlString)
    }

    private func isEpornerURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "eporner.com" || host.hasSuffix(".eporner.com")
    }

    private func isXHamsterURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        let domains = ["xhamster.com", "xhamster.desi", "xhamster.one", "xhamster2.com", "xhamster3.com", "xhcdn.com", "ahcdn.com", "xhvid.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func isThisVidURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "thisvid.com" || host.hasSuffix(".thisvid.com")
    }

    nonisolated private static let cloudflareErrorKeywords = [
        "cloudflare", "anti-bot", "captcha", "challenge", "turnstile"
    ]

    nonisolated private static let loginRequiredErrorKeywords = [
        "sign in", "private video", "login", "members-only", "http error 401"
    ]

    nonisolated private static let accessDeniedErrorKeywords = [
        "403", "forbidden"
    ]

    private func shouldRetryWithBrowserCookies(
        error: Error,
        url: String,
        usingBrowserCookies: Bool,
        forceBrowserCookies: Bool,
        browserCookieSource: String? = nil
    ) -> Bool {
        let selectedBrowser = Self.validatedBrowserCookieSource(browserCookieSource) ?? configuredBrowserCookieSource()
        guard !(error is CancellationError), !Task.isCancelled,
              usesBrowserTransport(url) || isGFFURL(url),
              !usingBrowserCookies, !forceBrowserCookies, selectedBrowser != nil else { return false }
        let message = String(describing: error)
            .replacingOccurrences(of: #"https?://[^\s\"]+"#, with: "[URL]", options: .regularExpression).lowercased()
        return message.containsAny(["403", "401", "sign in", "login", "cloudflare", "challenge"])
    }

    private func mapSiteSpecificError(
        _ error: Error,
        url: String,
        browserCookieSource: String? = nil
    ) -> Error {
        let errString = "\(error)"
        let lowerErr = (usesBrowserTransport(url)
            ? errString.replacingOccurrences(of: #"https?://[^\s\"]+"#, with: "[URL]", options: .regularExpression)
            : errString).lowercased()
        let configuredBrowser = Self.validatedBrowserCookieSource(browserCookieSource) ?? configuredBrowserCookieSource()

        if (configuredBrowser == "safari" || configuredBrowser == nil) && isSafariPermissionError(errString) {
            return YtdlpError.safariCookiesFullDiskAccessRequired
        }

        if isBoyfriendTVURL(url) {
            if let siteError = error as? YtdlpError {
                switch siteError {
                case .cloudflareBlocked, .protectedSiteLoginRequired, .protectedSiteNeedsBrowserCookies, .safariCookiesFullDiskAccessRequired, .downloadFailed:
                    return siteError
                default: break
                }
            }
            if lowerErr.containsAny(Self.cloudflareErrorKeywords) {
                return YtdlpError.cloudflareBlocked
            }
            if Self.isVideoUnavailableError(lowerErr) {
                return YtdlpError.downloadFailed("This video is unavailable, private, or has been removed.")
            }
            if lowerErr.containsAny(Self.loginRequiredErrorKeywords) {
                if configuredBrowser == nil {
                    return YtdlpError.protectedSiteNeedsBrowserCookies
                } else {
                    return YtdlpError.protectedSiteLoginRequired
                }
            }
            if lowerErr.containsAny(Self.accessDeniedErrorKeywords) {
                return YtdlpError.downloadFailed("The protected site denied access (HTTP 403). This may be an anti-bot challenge or an access restriction.")
            }
            if lowerErr.contains("unsupported url") {
                return YtdlpError.downloadFailed("Could not extract a media stream from this protected-site URL. Please verify the link and try again.")
            }
            return error
        }

        if isRecuURL(url) {
            if let siteError = error as? YtdlpError {
                switch siteError {
                case .cloudflareBlocked, .safariCookiesFullDiskAccessRequired, .downloadFailed:
                    return siteError
                default: break
                }
            }
            if lowerErr.containsAny(Self.cloudflareErrorKeywords) || lowerErr.containsAny(Self.accessDeniedErrorKeywords) {
                return YtdlpError.cloudflareBlocked
            }
            if lowerErr.contains("unsupported url") {
                return YtdlpError.downloadFailed("Could not resolve this protected-site recording. Use a /<model>/video/<id>/play URL.")
            }
        }

        if isGayPornTubeURL(url) {
            if lowerErr.containsAny(Self.cloudflareErrorKeywords) {
                return YtdlpError.cloudflareBlocked
            }
            if lowerErr.contains("unsupported url") {
                return YtdlpError.downloadFailed("Could not resolve the protected-site player. Verify the video link and retry.")
            }
            if lowerErr.containsAny(Self.accessDeniedErrorKeywords) {
                return YtdlpError.downloadFailed("The protected site denied access (HTTP 403). The page may require browser verification or have an access restriction.")
            }
        }

        if isGFFURL(url) {
            if lowerErr.containsAny(Self.cloudflareErrorKeywords) || lowerErr.containsAny(Self.accessDeniedErrorKeywords) {
                return YtdlpError.cloudflareBlocked
            }
            if Self.isVideoUnavailableError(lowerErr) {
                return YtdlpError.downloadFailed("This video is unavailable, private, or has been removed.")
            }
            return error
        }

        if isStarwankURL(url) {
            if lowerErr.containsAny(Self.cloudflareErrorKeywords) {
                return YtdlpError.cloudflareBlocked
            }
            if lowerErr.contains("unsupported url") {
                return YtdlpError.downloadFailed("Could not resolve this Starwank video. Verify the video link and retry.")
            }
            if lowerErr.containsAny(Self.accessDeniedErrorKeywords) {
                return YtdlpError.downloadFailed("Starwank denied access (HTTP 403). The video may require browser verification or an active session.")
            }
        }

        if isPussyspaceURL(url) {
            if lowerErr.containsAny(Self.cloudflareErrorKeywords) {
                return YtdlpError.cloudflareBlocked
            }
            if lowerErr.contains("unsupported url") {
                return YtdlpError.downloadFailed("Could not resolve this PussySpace video. Verify the video link and retry.")
            }
            if lowerErr.containsAny(Self.accessDeniedErrorKeywords) {
                return YtdlpError.downloadFailed("PussySpace denied access (HTTP 403). The video may require browser verification or an active session.")
            }
        }

        let parsedHost = (URL(string: url)?.host ?? url).lowercased()
        let isYouTube = parsedHost == "youtube.com" || parsedHost.hasSuffix(".youtube.com") || parsedHost == "youtu.be" || parsedHost.hasSuffix(".youtu.be")
        if isYouTube,
           lowerErr.containsAny(["403", "sign in", "bot", "login_required"]),
           configuredBrowser == nil {
            return YtdlpError.downloadFailed("YouTube requires authentication or browser cookies. Go to Settings > Advanced > Browser Cookies to select your browser.")
        }

        return error
    }

    private func isRangeError(_ text: String) -> Bool {
        let lower = text.lowercased()
        if text.contains("416") || lower.contains("requested range not satisfiable") {
            return true
        }
        if lower.contains("byte range") || lower.contains("byte ranges") {
            return true
        }
        if lower.contains("range header not supported") ||
           lower.contains("range request not supported") ||
           lower.contains("does not support range") ||
           lower.contains("server does not support ranges") {
            return true
        }
        // Certain CDNs reject HTTP byte-range slicing with HTTP 500 Internal Server Error.
        // When chunking is active, stripping chunk size resolves the server error.
        if lower.contains("http error 500") || lower.contains("internal server error") {
            return true
        }
        return false
    }

    private func isTransientServerError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("http error 500") ||
               lower.contains("http error 502") ||
               lower.contains("http error 503") ||
               lower.contains("http error 504") ||
               lower.contains("internal server error") ||
               lower.contains("bad gateway") ||
               lower.contains("service unavailable") ||
               lower.contains("gateway timeout") ||
               lower.contains("connection refused") ||
               lower.contains("failed to establish a new connection") ||
               lower.contains("connection reset")
    }

    private func appendSiteSpecificArgs(for url: String, options: DownloadOptions? = nil, mediaInfo: MediaInfo? = nil, rawUserAgent: String? = nil, to args: inout [String]) {
        let lowerUrl = url.lowercased()
        let parsedHost = (URL(string: url)?.host ?? url).lowercased()
        let isYouTube = parsedHost == "youtube.com" || parsedHost.hasSuffix(".youtube.com") || parsedHost == "youtu.be" || parsedHost.hasSuffix(".youtu.be")
        let isThisVid = isThisVidURL(parsedHost)
        let isXHamster = isXHamsterURL(parsedHost)
        let isBoyfriendTV = isBoyfriendTVURL(parsedHost) ||
                            parsedHost == "cdn.boyfriend.tv" || parsedHost.hasSuffix(".boyfriend.tv") ||
                            parsedHost == "cdn.boyfriendtv.com" || parsedHost.hasSuffix(".boyfriendtv.com")
        let isRecu = isRecuURL(parsedHost)
        let isEporner = isEpornerURL(parsedHost)

        // Retries, socket timeouts & performance optimization flags
        args.append(contentsOf: ["--retries", "10"])
        args.append(contentsOf: ["--fragment-retries", "10"])
        args.append(contentsOf: ["--socket-timeout", "15"])
        args.append("--no-mtime")

        let browserSource: String? = {
            if let idx = args.firstIndex(of: "--cookies-from-browser"), idx + 1 < args.count {
                return Self.validatedBrowserCookieSource(args[idx + 1])
            }
            return Self.validatedBrowserCookieSource(options?.browserCookieSource)
                ?? configuredBrowserCookieSource()
        }()
        let isSafari = browserSource == "safari"
        let isFirefox = browserSource == "firefox"

        if !isYouTube {
            if let exactUA = (rawUserAgent ?? options?.rawUserAgent)?.trimmingCharacters(in: .whitespacesAndNewlines), !exactUA.isEmpty {
                args.append(contentsOf: ["--user-agent", exactUA])
                args.append(contentsOf: ["--add-header", "Accept-Language:en-US,en;q=0.9"])
                args.append(contentsOf: [
                    "--extractor-args",
                    "generic:impersonate=\(recuImpersonationTarget(rawUserAgent: exactUA, browserCookieSource: browserSource))"
                ])
            } else if isFirefox {
                // When recovery intentionally drops the raw browser UA, keep the
                // request fingerprint coherent with the explicit Firefox cookie source.
                args.append(contentsOf: ["--add-header", "Accept-Language:en-US,en;q=0.9"])
                args.append(contentsOf: ["--extractor-args", "generic:impersonate=firefox:macos"])
            } else if isSafari {
                let safariUA = Self.safariUserAgent
                args.append(contentsOf: ["--user-agent", safariUA])
                args.append(contentsOf: ["--add-header", "Accept-Language:en-US,en;q=0.9"])
                args.append(contentsOf: ["--extractor-args", isBoyfriendTV ? "generic:impersonate=safari" : "generic:impersonate"])
            } else {
                // Common modern browser headers & Cloudflare extraction options
                let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                let secChUa = "\"Chromium\";v=\"126\", \"Google Chrome\";v=\"126\", \"Not-A.Brand\";v=\"99\""

                // Anti-bot flags for Cloudflare & rate limits
                args.append(contentsOf: ["--user-agent", defaultUA])
                args.append(contentsOf: ["--add-header", "Sec-Ch-Ua:\(secChUa)"])
                args.append(contentsOf: ["--add-header", "Sec-Ch-Ua-Mobile:?0"])
                args.append(contentsOf: ["--add-header", "Sec-Ch-Ua-Platform:\"macOS\""])
                args.append(contentsOf: ["--add-header", "Accept-Language:en-US,en;q=0.9"])
                args.append(contentsOf: ["--extractor-args", isBoyfriendTV ? "generic:impersonate=chrome" : "generic:impersonate"])
            }
        }

        let isFragmented: Bool
        if let info = mediaInfo, let opts = options {
            isFragmented = info.isSelectedFormatFragmented(options: opts)
        } else if let info = mediaInfo {
            isFragmented = info.isFragmented
        } else {
            isFragmented = lowerUrl.contains(".m3u8") ||
                lowerUrl.contains(".mpd") ||
                isBoyfriendTV ||
                isRecu ||
                isXHamster
        }

        // Universal baseline transport optimization:
        // 1. 10M HTTP chunking: enables multi-megabyte Range chunks across CDNs/hosts to bypass single-stream connection throttling.
        //    Safe because runDownloadProcess automatically catches Range-incompatible servers and retries as continuous stream.
        //    Excluded for Eporner CDNs which return HTTP 500 on chunk slicing.
        // 2. 16K buffer size: reduces read/write syscall overhead compared to default small buffers.
        // Signed, rate-limited segments should each use one request; splitting a
        // large segment into Range chunks consumes additional server allowance.
        if !isEporner && !isRecu {
            args.append(contentsOf: ["--http-chunk-size", "10M"])
        }
        args.append(contentsOf: ["--buffer-size", "16K"])

        // Adaptive rate-throttling recovery:
        // YouTube and ThisVid throttle video streams aggressively and require active rate monitoring & re-extraction.
        // Scoped specifically to prevent false-positive re-extractions on slow connections for other domains.
        if isYouTube || isThisVid {
            args.append(contentsOf: ["--throttled-rate", "100K"])
        }

        if isFragmented {
            args.append(contentsOf: ["--concurrent-fragments", "8"])
        }

        if isBoyfriendTV {
            if !isSafari && !isFirefox {
                if let uaIdx = args.firstIndex(of: "--user-agent") {
                    args[uaIdx + 1] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                } else {
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
                }
            }
            let baseDomain = (parsedHost.contains("boyfriendtv.com") || lowerUrl.contains("boyfriendtv.com")) ? "https://www.boyfriendtv.com" : "https://www.boyfriend.tv"
            args.append(contentsOf: ["--add-header", "Origin:\(baseDomain)"])
            args.append(contentsOf: ["--add-header", "Accept:*/*"])
            let referer = lowerUrl.contains("/embed/") ? url : "\(baseDomain)/"
            args.append(contentsOf: ["--add-header", "Referer:\(referer)"])
            args.append(contentsOf: ["--downloader", "ffmpeg"])
            args.append(contentsOf: ["--hls-use-mpegts"])
        } else if isRecu {
            args.append(contentsOf: ["--add-header", "Origin:https://recu.me"])
            args.append(contentsOf: ["--add-header", "Referer:\(url)"])
            args.append(contentsOf: ["--add-header", "Accept:*/*"])
            // Recu's CDN serves about one segment per second per client and answers
            // parallel requests with 429, so extra fragment workers only add retries.
            if let index = args.firstIndex(of: "--concurrent-fragments"), index + 1 < args.count {
                args[index + 1] = "1"
            }
        } else if isGayPornTubeURL(url) {
            args.append(contentsOf: ["--add-header", "Referer:\(url)"])
            args.append(contentsOf: ["--add-header", "Origin:https://www.gayporntube.com"])
        } else if isXHamster {
            args.append(contentsOf: ["--add-header", "Referer:https://xhamster.com/"])
            args.append(contentsOf: ["--add-header", "Origin:https://xhamster.com"])
            args.append(contentsOf: ["--hls-use-mpegts"])
        } else if parsedHost == "justthegays.com" || parsedHost.hasSuffix(".justthegays.com") || parsedHost == "justthegays.tv" || parsedHost.hasSuffix(".justthegays.tv") {
            args.append(contentsOf: ["--add-header", "Referer:https://justthegays.com/"])
            args.append(contentsOf: ["--downloader", "ffmpeg"])
            args.append(contentsOf: ["--downloader-args", "ffmpeg_i:-analyzeduration 20M -probesize 20M"])
            args.append(contentsOf: ["--hls-use-mpegts"])
        } else if isThisVid {
            args.append(contentsOf: ["--add-header", "Referer:https://thisvid.com/"])
            args.append(contentsOf: ["--add-header", "Origin:https://thisvid.com"])
            if Self.findAria2cPath() != nil {
                args.append(contentsOf: [
                    "--downloader", "aria2c",
                    "--downloader-args", "aria2c:-s 16 -x 16 -k 1M -j 16 --min-split-size=1M --summary-interval=1"
                ])
            }
        } else if isEporner {
            args.append(contentsOf: ["--add-header", "Referer:https://www.eporner.com/"])
            args.append(contentsOf: ["--add-header", "Origin:https://www.eporner.com"])
            if Self.findAria2cPath() != nil {
                args.append(contentsOf: [
                    "--downloader", "aria2c",
                    "--downloader-args", "aria2c:-s 16 -x 16 -k 1M -j 16 --min-split-size=1M --summary-interval=1"
                ])
            }
        } else if isGuywhURL(parsedHost) || isGuywhURL(url) || parsedHost.contains("guywh") {
            if !isSafari {
                if let uaIdx = args.firstIndex(of: "--user-agent") {
                    args[uaIdx + 1] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                } else {
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
                }
            }
            args.append(contentsOf: ["--add-header", "Referer: https://guywh.com/"])
            args.append(contentsOf: ["--add-header", "Origin: https://guywh.com"])
            args.append(contentsOf: ["--add-header", "Accept: */*"])
        } else if isGFFURL(parsedHost) || isGFFURL(url) || parsedHost.contains("gayforfans") {
            if !isSafari {
                if let uaIdx = args.firstIndex(of: "--user-agent") {
                    args[uaIdx + 1] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                } else {
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
                }
            }
            args.append(contentsOf: ["--add-header", "Referer: https://gayforfans.com/"])
            args.append(contentsOf: ["--add-header", "Origin: https://gayforfans.com"])
            args.append(contentsOf: ["--add-header", "Accept: */*"])
        } else if isBestCamURL(parsedHost) || isBestCamURL(url) || parsedHost.contains("sssrr.org") || parsedHost.contains("abyssplayer") || parsedHost.contains("abyss.to") {
            if !isSafari {
                if let uaIdx = args.firstIndex(of: "--user-agent") {
                    args[uaIdx + 1] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                } else {
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
                }
            }
            args.append(contentsOf: ["--add-header", "Referer: https://abyssplayer.com/"])
            args.append(contentsOf: ["--add-header", "Origin: https://abyssplayer.com"])
            args.append(contentsOf: ["--add-header", "Accept: */*"])
        } else if isStarwankURL(parsedHost) || isStarwankURL(url) || parsedHost.contains("starwank") || parsedHost.contains("fapnado") {
            if !isSafari {
                if let uaIdx = args.firstIndex(of: "--user-agent") {
                    args[uaIdx + 1] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                } else {
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
                }
            }
            args.append(contentsOf: ["--add-header", "Referer: https://starwank.com/"])
            args.append(contentsOf: ["--add-header", "Origin: https://starwank.com"])
            args.append(contentsOf: ["--add-header", "Accept: */*"])
        } else if isPussyspaceURL(parsedHost) || isPussyspaceURL(url) || parsedHost.contains("pussyspace") {
            if !isSafari {
                if let uaIdx = args.firstIndex(of: "--user-agent") {
                    args[uaIdx + 1] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                } else {
                    args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
                }
            }
            args.append(contentsOf: ["--add-header", "Referer: https://www.pussyspace.com/"])
            args.append(contentsOf: ["--add-header", "Origin: https://www.pussyspace.com"])
            args.append(contentsOf: ["--add-header", "Accept: */*"])
        } else if parsedHost == "single-stream video site.com" || parsedHost.hasSuffix(".single-stream video site.com") {
            args.append(contentsOf: ["--add-header", "Referer:https://single-stream video site.com/"])
        } else if lowerUrl.contains(".m3u8") || lowerUrl.contains(".mpd") {
            args.append(contentsOf: ["--hls-use-mpegts"])
            if Self.requiresHlsVariantQuery(url) {
                // This CDN's relative variant links omit the master signature.
                args.append(contentsOf: ["--extractor-args", "generic:variant_query"])
                // Encryption may be declared only in a child playlist, not the master.
                args.append("--check-formats")
            }
        } else if let components = URLComponents(string: url), let host = components.host, !host.isEmpty, !host.contains("\r"), !host.contains("\n") {
            // Universal Referer and Origin auto-injection for anti-hotlinking CDN protection
            let scheme = components.scheme ?? "https"
            let origin = "\(scheme)://\(host)"
            let referer = "\(origin)/"
            if !args.contains("Referer:\(referer)") && !args.contains(where: { $0.hasPrefix("Referer:") }) {
                args.append(contentsOf: ["--add-header", "Referer:\(referer)"])
            }
            if !args.contains("Origin:\(origin)") && !args.contains(where: { $0.hasPrefix("Origin:") }) {
                args.append(contentsOf: ["--add-header", "Origin:\(origin)"])
            }
        }
        if usesBrowserTransport(url) && !isRecu {
            refreshBrowserTransportIdentity(for: url, args: &args)
            // Smaller request bursts and bounded exponential backoff for sensitive hosts.
            for flag in ["--retries", "--fragment-retries", "--concurrent-fragments"] {
                if let index = args.firstIndex(of: flag), index + 1 < args.count {
                    args[index + 1] = flag == "--concurrent-fragments" ? "2" : "3"
                }
            }
            args.append(contentsOf: ["--extractor-retries", "2",
                                     "--retry-sleep", "http:exp=1:8",
                                     "--retry-sleep", "fragment:exp=1:8",
                                     "--retry-sleep", "extractor:exp=1:8"])
        } else if isRecu {
            args.append(contentsOf: ["--extractor-retries", "2",
                                     "--retry-sleep", "http:exp=1:8",
                                     "--retry-sleep", "fragment:exp=1:8",
                                     "--retry-sleep", "extractor:exp=1:8"])
        }
    }

    nonisolated static func requiresHlsVariantQuery(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host.hasSuffix(".onlyfans.com"), components.path.lowercased().hasSuffix(".m3u8") else { return false }
        let names = Set(components.queryItems?.map(\.name) ?? [])
        return names.contains("Policy") && names.contains("Signature") && names.contains("Key-Pair-Id")
    }

    static let safariUserAgent: String = {
        let safariPlist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        if let data = try? Data(contentsOf: safariPlist),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let version = plist["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
        }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }()

    static var hasFullDiskAccessOverride: Bool? = nil

    static var hasFullDiskAccess: Bool {
        if let override = hasFullDiskAccessOverride {
            return override
        }
        // This is an advisory cookie-read probe, not a query of macOS's FDA toggle.
        // Missing files and a different running app identity can both make it inconclusive.
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(homeDir)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "\(homeDir)/Library/Cookies/Cookies.binarycookies"
        ]
        for path in candidatePaths {
            let fd = Darwin.open(path, O_RDONLY)
            if fd >= 0 {
                Darwin.close(fd)
                return true
            }
        }

        return false
    }

    private func isCookieFailureError(_ errorOutput: String) -> Bool {
        let lower = errorOutput.lowercased()
        if lower.contains("extracted") && lower.contains("cookies") {
            return false
        }
        return lower.contains("operation not permitted") ||
               lower.contains("cookies.binarycookies") ||
               lower.contains("errno 1") ||
               (lower.contains("could not find") && lower.contains("cookies database")) ||
               lower.contains("failed to decrypt") ||
               (lower.contains("unable to extract") && lower.contains("cookies"))
    }

    private func isSafariPermissionError(_ errorOutput: String) -> Bool {
        let lower = errorOutput.lowercased()
        guard lower.contains("safari") || lower.contains("cookies.binarycookies") else { return false }
        return lower.contains("operation not permitted") ||
               lower.contains("errno 1") ||
               lower.contains("permission denied")
    }

    nonisolated static func isVideoUnavailableError(_ lowerErr: String) -> Bool {
        (lowerErr.contains("video is unavailable") ||
         lowerErr.contains("video unavailable") ||
         lowerErr.contains("video has been removed") ||
         lowerErr.contains("video removed") ||
         lowerErr.contains("404 not found") ||
         lowerErr.contains("page not found") ||
         lowerErr.contains("http error 404")) && !lowerErr.contains("cookie")
    }

    private func stripCookieArgs(from args: [String]) -> [String] {
        var cleanArgs = args
        if let idx = cleanArgs.firstIndex(of: "--cookies-from-browser") {
            cleanArgs.remove(at: idx)
            if idx < cleanArgs.count {
                cleanArgs.remove(at: idx)
            }
        }
        return cleanArgs
    }

    private func runTransportCommand(_ args: [String]) async throws -> String {
        do {
            return try await processRunner.runCommand(args)
        } catch {
            try Task.checkCancellation()
            guard usesBrowserTransport(args.last ?? ""),
                  case YtdlpError.commandFailed(let output) = error,
                  isTransientServerError(output) else { throw error }
            LoggerService.shared.log("Retrying transient metadata transport failure once", level: .info)
            if processRunner is DefaultYtdlpProcessRunner {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            try Task.checkCancellation()
            return try await processRunner.runCommand(args)
        }
    }

    private func runCommand(_ args: [String]) async throws -> String {
        try Task.checkCancellation()
        do {
            return try await runTransportCommand(args)
        } catch let error as YtdlpError {
            if case .commandFailed(let output) = error, isCookieFailureError(output), let idx = args.firstIndex(of: "--cookies-from-browser"), idx + 1 < args.count {
                let browser = args[idx + 1]
                LoggerService.shared.log("Browser cookie access failed for '\(browser)' or database missing. Checking alternative browsers...", level: .info)
                if let urlArg = args.last {
                    recordCookieDenial(browser: browser, url: urlArg, errorOutput: output)
                }
                
                LoggerService.shared.log(
                    "Selected browser cookie source '\(browser)' is unavailable. Retrying without browser cookies; unrelated browser profiles will not be probed.",
                    level: .info
                )
                var cleanArgs = stripCookieArgs(from: args)
                refreshBrowserTransportIdentity(for: args.last ?? "", args: &cleanArgs)
                return try await runTransportCommand(cleanArgs)
            }
            throw error
        }
    }

    private func runDownloadProcess(
        args: [String],
        saveFolder: URL,
        processController: DownloadProcessController? = nil,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DownloadProcessResult {
        try await processRunner.runDownloadProcess(
            args: args,
            saveFolder: saveFolder,
            processController: processController,
            onProgress: onProgress,
            onOutput: onOutput
        )
    }

    nonisolated static func getAppSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let siphonDir = appSupport.appendingPathComponent("Siphon")
        let lumaDir = appSupport.appendingPathComponent("Luma")
        let legacyDir = appSupport.appendingPathComponent("Macabolic")

        if !FileManager.default.fileExists(atPath: siphonDir.path) {
            if FileManager.default.fileExists(atPath: lumaDir.path) {
                try? FileManager.default.copyItem(at: lumaDir, to: siphonDir)
            } else if FileManager.default.fileExists(atPath: legacyDir.path) {
                try? FileManager.default.moveItem(at: legacyDir, to: siphonDir)
            } else {
                try? FileManager.default.createDirectory(at: siphonDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: siphonDir.path)

        return siphonDir
    }

    private func resolveSucuriCookie(for url: String) async -> (name: String, value: String)? {
        guard let parsedURL = URL(string: url), let host = parsedURL.host?.lowercased() else { return nil }
        let sucuriDomains = ["thisvid.com"]
        guard sucuriDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }

        var request = URLRequest(url: parsedURL)
        request.timeoutInterval = 3.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await EgressBoundary.session.boundedData(for: request)
            guard let htmlText = String(data: data, encoding: .utf8) else { return nil }

            if htmlText.contains("sucuri_cloudproxy_js"), let regex = Self.sucuriAssignmentRegex {
                let nsRange = NSRange(htmlText.startIndex..<htmlText.endIndex, in: htmlText)
                if let match = regex.firstMatch(in: htmlText, options: [], range: nsRange),
                   let range = Range(match.range(at: 1), in: htmlText) {
                    let b64Str = String(htmlText[range])
                    if let decodedData = Data(base64Encoded: b64Str),
                       let jsCode = String(data: decodedData, encoding: .utf8) {

                        var cookieName = ""
                        var cookieValue = ""

                        if let strRegex = Self.sucuriStringLiteralRegex {
                            let jsRange = NSRange(jsCode.startIndex..<jsCode.endIndex, in: jsCode)
                            let matches = strRegex.matches(in: jsCode, options: [], range: jsRange)

                            for match in matches {
                                var matchedStr = ""
                                if let range1 = Range(match.range(at: 1), in: jsCode) {
                                    matchedStr = String(jsCode[range1])
                                } else if let range2 = Range(match.range(at: 2), in: jsCode) {
                                    matchedStr = String(jsCode[range2])
                                }

                                if matchedStr.hasPrefix("sucuri_cloudproxy_uuid_") {
                                    cookieName = matchedStr.replacingOccurrences(of: "=", with: "")
                                } else if !matchedStr.hasPrefix(";") && !matchedStr.contains("path=") && !matchedStr.contains("max-age=") && !matchedStr.contains("domain=") && !matchedStr.isEmpty && matchedStr != "reload" && matchedStr != "location" && matchedStr != "cookie" && matchedStr != "document" && matchedStr != "href" {
                                    cookieValue += matchedStr
                                }
                            }
                        }

                        if !cookieName.isEmpty && !cookieValue.isEmpty {
                            return (cookieName, cookieValue)
                        }
                    }
                }
            }
        } catch {
            LoggerService.shared.log("Error resolving Sucuri cookie: \(error)", level: .error)
        }
        return nil
    }

    // Bolt Performance Optimization: Pre-compile tracking query parameter sets and prefixes to eliminate heap allocations on every URL normalization call.
    nonisolated private static let trackingPrefixes = ["utm_"]
    nonisolated private static let trackingNamesGroupA: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_cid", "mc_eid", "ref", "source"]
    nonisolated private static let trackingNamesGroupB: Set<String> = ["from", "promo", "ref", "source", "reftag"]

    // Bolt Performance Optimization: Pre-compile static NSRegularExpression patterns to eliminate repeated pattern compilation and heap allocations on every Sucuri Cloudproxy cookie resolution call.
    nonisolated private static let sucuriAssignmentRegex = try? NSRegularExpression(pattern: "S\\s*=\\s*'([^']+)'", options: [])
    nonisolated private static let sucuriStringLiteralRegex = try? NSRegularExpression(pattern: "\"([^\"]*)\"|'([^']*)'", options: [])

    // Bolt Performance Optimization: Pre-compile static NSRegularExpression to avoid compiling pattern and heap allocations on every validation call.
    nonisolated private static let timeFrameRegex = try? NSRegularExpression(pattern: #"^\d{1,2}(?::\d{2}){0,2}(?:\.\d+)?$|^\d+(?:\.\d+)?$"#, options: [])

    nonisolated static func isValidTimeFrame(_ time: String) -> Bool {
        guard let regex = timeFrameRegex else { return false }
        let nsRange = NSRange(time.startIndex..<time.endIndex, in: time)
        return regex.firstMatch(in: time, options: [], range: nsRange) != nil
    }

    nonisolated private static let safeFormatIdCharacters =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/[]<>=,:_-."))

    nonisolated private static let safeSubtitleLanguageCharacters =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    nonisolated private static let invalidFilenameCharacters =
        CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.controlCharacters)

    nonisolated private static let reservedFilenameNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ".DS_STORE", "DS_STORE"
    ]

    nonisolated static func isSafeFormatId(_ formatId: String) -> Bool {
        guard !formatId.isEmpty, !formatId.hasPrefix("-"), formatId.count <= 128 else { return false }
        return formatId.unicodeScalars.allSatisfy { safeFormatIdCharacters.contains($0) }
    }

    nonisolated static func isSafeSubtitleLanguage(_ lang: String) -> Bool {
        guard !lang.isEmpty, !lang.hasPrefix("-"), lang.count <= 32 else { return false }
        return lang.unicodeScalars.allSatisfy { safeSubtitleLanguageCharacters.contains($0) }
    }

    nonisolated static func sanitizeFilename(_ filename: String) -> String {
        var cleanedScalars: [UnicodeScalar] = []
        cleanedScalars.reserveCapacity(filename.unicodeScalars.count)

        for scalar in filename.unicodeScalars {
            cleanedScalars.append(
                invalidFilenameCharacters.contains(scalar) ? "_" : scalar
            )
        }

        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
        var trimmed = cleaned.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        while trimmed.hasPrefix(".") || trimmed.hasPrefix("-") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if reservedFilenameNames.contains(trimmed.uppercased()) {
            trimmed = "download_\(trimmed)"
        }

        while trimmed.hasSuffix(".") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.count > 200 {
            trimmed = String(trimmed.prefix(200))
        }

        return trimmed.isEmpty ? "download" : trimmed
    }

    /// Drops `-P/--paths` and `-o/--output` (with their values) from user
    /// arguments. Siphon sets both and only accepts output inside the save
    /// folder, so an override downloads fine but the job reports failure.
    static func removingOutputLocationArguments(_ arguments: [String]) -> [String] {
        let separateValue: Set<String> = ["-P", "--paths", "-o", "--output"]
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if separateValue.contains(argument) {
                LoggerService.shared.log("Ignoring additional argument \(argument): Siphon controls the output location.", level: .warning)
                index += 2
                continue
            }
            let attachedValue = argument.hasPrefix("--paths=") || argument.hasPrefix("--output=")
                || (argument.count > 2 && (argument.hasPrefix("-P") || argument.hasPrefix("-o")) && !argument.hasPrefix("--"))
            if attachedValue {
                LoggerService.shared.log("Ignoring additional argument \(argument.prefix(2)): Siphon controls the output location.", level: .warning)
            } else {
                kept.append(argument)
            }
            index += 1
        }
        return kept
    }

    /// Starts the shared egress proxy and returns its URL. Logs and rethrows when
    /// it cannot start, so boundary-enforced work never runs unproxied.
    func egressProxyURL() async throws -> String {
        do {
            let port = try await EgressProxyServer.shared.start()
            return "http://127.0.0.1:\(port)"
        } catch {
            LoggerService.shared.log("Egress proxy failed to start; refusing to contact external target directly: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// Drops `--proxy` (with its value) from user arguments when public-network
    /// boundary enforcement is active, so deep-link jobs cannot bypass the egress proxy.
    static func removingProxyArguments(_ arguments: [String]) -> [String] {
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--proxy" {
                LoggerService.shared.log("Ignoring additional argument --proxy: Siphon enforces egress boundary for this job.", level: .warning)
                index += 2
                continue
            }
            if argument.hasPrefix("--proxy=") {
                LoggerService.shared.log("Ignoring additional argument --proxy: Siphon enforces egress boundary for this job.", level: .warning)
            } else {
                kept.append(argument)
            }
            index += 1
        }
        return kept
    }

    nonisolated static func parseArgumentString(_ argString: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var quoteChar: Character = "\""
        
        for char in argString {
            if char == "\"" || char == "'" {
                if inQuotes && char == quoteChar {
                    inQuotes = false
                } else if !inQuotes {
                    inQuotes = true
                    quoteChar = char
                } else {
                    current.append(char)
                }
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }

    private func sanitizeCookieToken(_ token: String) -> String {
        return token.replacingOccurrences(of: "\t", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\0", with: "")
    }

    func createTempCookiesFile(url: String, cookieName: String, cookieValue: String) -> URL? {
        guard let cookiesDir = CookieManager.getSecureTempCookiesDirectory() else { return nil }
        let tempCookiesURL = cookiesDir.appendingPathComponent("siphon_cookies_\(UUID().uuidString).txt")
        let host = sanitizeCookieToken(URL(string: url)?.host ?? "")
        guard !host.isEmpty else { return nil }
        let cleanName = sanitizeCookieToken(cookieName)
        let cleanValue = sanitizeCookieToken(cookieValue)
        guard !cleanName.isEmpty, !cleanValue.isEmpty else { return nil }
        let cookieContent = "# Netscape HTTP Cookie File\n\(host)\tFALSE\t/\tFALSE\t2783382923\t\(cleanName)\t\(cleanValue)\n"
        guard let data = cookieContent.data(using: .utf8) else { return nil }

        // Create file with 0o600 permissions upfront to prevent TOCTOU permission window
        if FileManager.default.createFile(atPath: tempCookiesURL.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            return tempCookiesURL
        } else {
            LoggerService.shared.log("Error creating temporary cookies file with restricted permissions", level: .error)
            return nil
        }
    }

    func createTempCookiesFileFromHeader(url: String, cookieHeader: String) -> URL? {
        guard let urlObj = URL(string: url), let rawHost = urlObj.host, !rawHost.isEmpty else { return nil }
        let host = sanitizeCookieToken(rawHost)
        guard !host.isEmpty else { return nil }
        guard let cookiesDir = CookieManager.getSecureTempCookiesDirectory() else { return nil }
        let domain = host.hasPrefix(".") ? host : ".\(host)"
        let requireSecureTransport = urlObj.scheme?.lowercased() == "https"
        let tempCookiesURL = cookiesDir.appendingPathComponent("siphon_header_cookies_\(UUID().uuidString).txt")

        var domains: [String] = [domain]
        let lowerHost = host.lowercased()
        if lowerHost.hasPrefix("www.") {
            domains.append(".\(lowerHost.dropFirst(4))")
        }
        var seenDomains = Set<String>()
        let uniqueDomains = domains.filter { seenDomains.insert($0).inserted }
        
        var lines = ["# Netscape HTTP Cookie File"]
        let pairs = cookieHeader.split(separator: ";")
        let expiry = Int(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970)
        
        for pair in pairs {
            let trimmedPair = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmedPair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = sanitizeCookieToken(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
                let value = sanitizeCookieToken(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                if !key.isEmpty && !value.isEmpty {
                    for d in uniqueDomains {
                        lines.append("\(d)\tTRUE\t/\t\(requireSecureTransport ? "TRUE" : "FALSE")\t\(expiry)\t\(key)\t\(value)")
                    }
                }
            }
        }
        
        let content = lines.joined(separator: "\n") + "\n"
        guard let data = content.data(using: .utf8) else { return nil }

        // Create file with 0o600 permissions upfront to prevent TOCTOU permission window
        if FileManager.default.createFile(atPath: tempCookiesURL.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            return tempCookiesURL
        } else {
            return nil
        }
    }

    func createConsolidatedCookiesFile(
        url: String,
        rawCookies: String? = nil,
        additionalCookies: [(name: String, value: String)] = [],
        additionalNetscapeLines: [String] = []
    ) -> URL? {
        guard let secureFile = try? SecureCookieFile.create(
            url: url,
            rawCookies: rawCookies,
            additionalCookies: additionalCookies,
            additionalNetscapeLines: additionalNetscapeLines
        ) else { return nil }
        return secureFile.detach()
    }
}



enum YtdlpError: LocalizedError {
    case notFound
    case parseError
    case noDownloadableFormats
    case commandFailed(String)
    case downloadFailed(String)
    case tooManyRequests
    case subtitleError(String)
    case cloudflareBlocked
    case ffmpegInstallationFailed(String)
    case protectedSiteNeedsBrowserCookies
    case protectedSiteLoginRequired
    case safariCookiesFullDiskAccessRequired
    case securityViolation(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "yt-dlp not found. Set its path in Settings > Advanced."
        case .parseError:
            return "Failed to parse data"
        case .noDownloadableFormats:
            return LanguageService.s("no_downloadable_formats")
        case .commandFailed(let output):
            return "Command failed: \(output)"
        case .downloadFailed(let output):
            return output.isEmpty ? "Download failed" : output
        case .tooManyRequests:
            return "429: Too Many Requests"
        case .subtitleError(let output):
            return "Subtitle error: \(output)"
        case .cloudflareBlocked:
            return "Blocked by Cloudflare anti-bot protection. Siphon could not complete the browser challenge automatically."
        case .ffmpegInstallationFailed(let path):
            return "FFmpeg installation failed. Please try updating dependencies again. Attempted path: \(path)"
        case .protectedSiteNeedsBrowserCookies:
            return "This video site requires signed-in browser cookies. Open Settings > Advanced > Browser Cookies, choose your browser, then try again."
        case .protectedSiteLoginRequired:
            // BoyfriendTV only. Browser sessions can't carry its sign-in: Safari never
            // saves the site's login cookie to disk.
            return "BoyfriendTV shows this video only to signed-in members. Sign in at boyfriendtv.com in Safari with “Remember me” ticked, then retry: Siphon uses that sign-in (Settings > Advanced > Browser Cookies must be Safari)."
        case .safariCookiesFullDiskAccessRequired:
            return LanguageService.s("safari_fda_required")
        case .securityViolation(let message):
            return "Security violation: \(message)"
        }
    }
}

final class CancellationBox: @unchecked Sendable {
    private var cancelled = false
    private let lock = NSLock()

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class ThreadSafeDataBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let maxSize: Int
    private(set) var isOverflow = false

    init(maxSize: Int = 32 * 1024 * 1024) {
        self.maxSize = maxSize
    }

    /// Returns `true` if the data was accepted, `false` if the buffer is full.
    @discardableResult
    func append(_ newBytes: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isOverflow else { return false }
        if data.count + newBytes.count > maxSize {
            isOverflow = true
            return false
        }
        data.append(newBytes)
        return true
    }

    func getString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class StreamBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    // Bolt Performance Optimization: Process output lines using direct zero-copy Data byte slicing
    // and byte-level \r trimming without allocating intermediate Data objects.
    // Preserves Data capacity using removeAll(keepingCapacity: true) when all lines are consumed.
    func appendAndExtractLines(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []

        var searchStartIndex = buffer.startIndex
        // FFmpeg statistics end in carriage returns, without a newline.
        while let newlineIndex = buffer[searchStartIndex...].firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            var lineSlice = buffer[searchStartIndex..<newlineIndex]
            searchStartIndex = newlineIndex + 1

            while lineSlice.last == 0x0D { lineSlice = lineSlice.dropLast() }
            while lineSlice.first == 0x0D { lineSlice = lineSlice.dropFirst() }

            if !lineSlice.isEmpty, let line = String(data: lineSlice, encoding: .utf8) {
                lines.append(line)
            }
        }

        if searchStartIndex == buffer.endIndex {
            buffer.removeAll(keepingCapacity: true)
        } else if searchStartIndex > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<searchStartIndex)
        }

        // Safety bound: If continuous stream chunk exceeds 512KB without newline, extract and clear to prevent memory growth
        if buffer.count > 512 * 1024 {
            var lineSlice = buffer[...]
            while lineSlice.last == 0x0D || lineSlice.last == 0x0A { lineSlice = lineSlice.dropLast() }
            while lineSlice.first == 0x0D || lineSlice.first == 0x0A { lineSlice = lineSlice.dropFirst() }
            if !lineSlice.isEmpty, let line = String(data: lineSlice, encoding: .utf8) {
                lines.append(line)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        return lines
    }

    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        if !buffer.isEmpty {
            var lineSlice = buffer[...]
            while lineSlice.last == 0x0D || lineSlice.last == 0x0A { lineSlice = lineSlice.dropLast() }
            while lineSlice.first == 0x0D || lineSlice.first == 0x0A { lineSlice = lineSlice.dropFirst() }
            if !lineSlice.isEmpty, let line = String(data: lineSlice, encoding: .utf8) {
                lines.append(line)
            }
            buffer.removeAll(keepingCapacity: true)
        }
        return lines
    }
}

final class ThreadSafeOutputState: @unchecked Sendable {
    // Bolt Performance Optimization: Reuse static CharacterSet to avoid repeated allocations in high-frequency progress loops
    private static let quoteCharacterSet = CharacterSet(charactersIn: "\"\'")

    private var finalPath: String?
    private var finalPaths: [String] = []
    private var candidatePaths: [String] = []
    private var errorText: String = ""
    private let lock = NSLock()

    func setFinalPath(_ path: String) {
        addFinalPath(path)
    }

    func addFinalPath(_ path: String) {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: Self.quoteCharacterSet)
        guard !cleaned.isEmpty else { return }
        lock.lock()
        if !finalPaths.contains(cleaned) {
            finalPaths.append(cleaned)
        }
        finalPath = cleaned
        lock.unlock()
    }

    func getFinalPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return finalPath
    }

    func getFinalPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return finalPaths
    }

    func addCandidatePath(_ newPath: String) {
        let cleaned = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: Self.quoteCharacterSet)
        guard !cleaned.isEmpty else { return }
        lock.lock()
        candidatePaths.append(cleaned)
        lock.unlock()
    }

    func getCandidatePaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return candidatePaths
    }

    func appendError(_ text: String) {
        lock.lock()
        errorText += text
        // Bound error buffer to prevent unbounded memory growth during long-running error outputs.
        // utf8.count is O(1); count walks every character on each appended line.
        if errorText.utf8.count > 100_000 {
            errorText = String(errorText.suffix(50_000))
        }
        lock.unlock()
    }

    func getErrorText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return errorText
    }
}

/// Thread-safe continuation wrapper that prevents double-resume crashes.
/// If `process.run()` throws AND the terminationHandler fires, only the first
/// resume call will go through; subsequent calls are safely ignored.
final class SafeContinuation<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

enum YtdlpUpdateError: LocalizedError {
    case alreadyInProgress
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "A yt-dlp update is already in progress."
        case .validationFailed(let reason):
            return "yt-dlp validation failed: \(reason)"
        }
    }
}

private extension String {
    func containsAny(_ keywords: [String]) -> Bool {
        keywords.contains { self.contains($0) }
    }
}
