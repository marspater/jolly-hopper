import Foundation
import CryptoKit

struct DependencyChecksums {
    static let ytdlpVersion = "2026.08.19"
    static let ytdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos")!
    static let ytdlpExecutableSHA256 = "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"

    #if arch(arm64)
    static let ffmpegURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64.gz")!
    static let ffmpegArchiveSHA256 = "8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa"
    static let ffmpegExecutableSHA256 = "a90e3db6a3fd35f6074b013f948b1aa45b31c6375489d39e572bea3f18336584"

    static let ffprobeURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-arm64.gz")!
    static let ffprobeArchiveSHA256 = "d986a8ec7b030899fe66a8a288ed809a3543338705a3ce178cfb85869c5d80be"
    static let ffprobeExecutableSHA256 = "bb2db6f5d8cef919da12fbf592119a987202a8c060a886f3cab091f9cab90b64"
    #else
    static let ffmpegURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-x64.gz")!
    static let ffmpegArchiveSHA256 = "929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106"
    static let ffmpegExecutableSHA256 = "ebdddc936f61e14049a2d4b549a412b8a40deeff6540e58a9f2a2da9e6b18894"

    static let ffprobeURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-x64.gz")!
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

        var errorDescription: String? {
            switch self {
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

    func installYtdlp(
        downloadURL: URL,
        expectedSHA256: String,
        appSupportDir: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let destination = appSupportDir.appendingPathComponent("yt-dlp")
        let tempStaging = appSupportDir.appendingPathComponent("yt-dlp.tmp_\(UUID().uuidString)")

        let (downloadedTempURL, _) = try await URLSession.shared.download(from: downloadURL)
        onProgress?(0.65)

        if FileManager.default.fileExists(atPath: tempStaging.path) {
            try FileManager.default.removeItem(at: tempStaging)
        }
        try FileManager.default.moveItem(at: downloadedTempURL, to: tempStaging)

        // 1. Verify SHA-256
        guard YtdlpService.verifySHA256(fileURL: tempStaging, expectedHash: expectedSHA256) else {
            try? FileManager.default.removeItem(at: tempStaging)
            throw InstallError.sha256Mismatch(file: "yt-dlp", expected: expectedSHA256)
        }

        // 2. Set executable permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempStaging.path)

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
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        let ffmpegFinal = appSupportDir.appendingPathComponent("ffmpeg")
        let ffprobeFinal = appSupportDir.appendingPathComponent("ffprobe")

        let ffmpegGz = appSupportDir.appendingPathComponent("ffmpeg_\(UUID().uuidString).gz")
        let ffprobeGz = appSupportDir.appendingPathComponent("ffprobe_\(UUID().uuidString).gz")

        // 1. Download both archives
        let (tempFfmpegURL, _) = try await URLSession.shared.download(from: ffmpegURL)
        let (tempFfprobeURL, _) = try await URLSession.shared.download(from: ffprobeURL)

        try FileManager.default.moveItem(at: tempFfmpegURL, to: ffmpegGz)
        try FileManager.default.moveItem(at: tempFfprobeURL, to: ffprobeGz)

        defer {
            try? FileManager.default.removeItem(at: ffmpegGz)
            try? FileManager.default.removeItem(at: ffprobeGz)
        }

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
            proc.arguments = ["-d", "-f", path]
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

        // 5. Set executable permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedFfmpeg.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedFfprobe.path)

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
    private let localVersion = DependencyChecksums.ytdlpVersion
    private let bundledYtdlpName = "yt-dlp_macos"
    private var activeSetupTask: Task<Void, Never>?

    var processRunner: YtdlpProcessRunning

    init(processRunner: YtdlpProcessRunning = DefaultYtdlpProcessRunner()) {
        self.processRunner = processRunner
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

    nonisolated static func isPathContained(targetURL: URL, inside parentDirectoryURL: URL) -> Bool {
        let root = parentDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = targetURL.standardizedFileURL.resolvingSymlinksInPath()
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
        if !isExecutableBinary(at: ffmpeg) || !isExecutableBinary(at: ffprobe) ||
           !Self.verifySHA256(fileURL: ffmpeg, expectedHash: DependencyChecksums.ffmpegExecutableSHA256) ||
           !Self.verifySHA256(fileURL: ffprobe, expectedHash: DependencyChecksums.ffprobeExecutableSHA256) {
            LoggerService.shared.log("Downloading atomic FFmpeg and FFprobe bundle in \(ffmpeg.deletingLastPathComponent().path)", level: .info)
            await downloadFfmpegAndFfprobeBundle()
        }
    }

    nonisolated static func createSanitizedEnvironment() -> [String: String] {
        let appSupport = Self.getAppSupportDirectory()
        let isolatedHome = appSupport.appendingPathComponent("SandboxHome")
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)

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
        env["HOME"] = isolatedHome.path
        env["TMPDIR"] = FileManager.default.temporaryDirectory.path
        env["XDG_CONFIG_HOME"] = isolatedHome.appendingPathComponent(".config").path
        env["XDG_CACHE_HOME"] = isolatedHome.appendingPathComponent(".cache").path
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }

    func setupBinaries() async {
        if let existing = activeSetupTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await findYtdlp()
            await findFfmpeg()
            await getVersion()
        }
        activeSetupTask = task
        await task.value
        activeSetupTask = nil
    }

    func findYtdlp() async {
        let appSupport = Self.getAppSupportDirectory()
        let invalidBackup = appSupport.appendingPathComponent("yt-dlp.invalid-backup")

        if let bundledPath = Bundle.main.url(forResource: "yt-dlp", withExtension: nil) {
            if Self.verifySHA256(fileURL: bundledPath, expectedHash: DependencyChecksums.ytdlpExecutableSHA256) {
                ytdlpPath = bundledPath
                isAvailable = true
                try? FileManager.default.removeItem(at: invalidBackup)
                return
            }
        }

        let ytdlpInSupport = appSupport.appendingPathComponent("yt-dlp")

        if FileManager.default.fileExists(atPath: ytdlpInSupport.path) {
            if Self.verifySHA256(fileURL: ytdlpInSupport, expectedHash: DependencyChecksums.ytdlpExecutableSHA256) {
                ytdlpPath = ytdlpInSupport
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

        guard Self.verifySHA256(fileURL: url, expectedHash: expectedSHA256) else {
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
        LoggerService.shared.log("Selected \(source) FFmpeg path: \(ffmpeg.path)", level: .info)
        LoggerService.shared.log("Selected \(source) FFprobe path: \(ffprobe.path)", level: .info)
    }

    private func validatedFfmpegLocationForYtdlp() async throws -> URL {
        if let ffmpeg = ffmpegPath,
           let ffprobe = ffprobePath,
           await validateFfmpegPair(ffmpeg: ffmpeg, ffprobe: ffprobe, context: "yt-dlp") {
            setFfmpegPaths(ffmpeg: ffmpeg, ffprobe: ffprobe, source: "yt-dlp")
            return ffmpeg
        }

        await findFfmpeg()

        guard let ffmpeg = ffmpegPath,
              let ffprobe = ffprobePath,
              await validateFfmpegPair(ffmpeg: ffmpeg, ffprobe: ffprobe, context: "yt-dlp") else {
            let attemptedPath = Self.getAppSupportDirectory().path
            throw YtdlpError.ffmpegInstallationFailed(attemptedPath)
        }

        setFfmpegPaths(ffmpeg: ffmpeg, ffprobe: ffprobe, source: "yt-dlp")
        return ffmpeg
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

    func downloadFfmpeg() async {
        await downloadFfmpegAndFfprobeBundle()
    }

    func downloadFfprobe() async {
        await downloadFfmpegAndFfprobeBundle()
    }

    func updateAllDependencies() async {
        await downloadYtdlp()
        await downloadFfmpegAndFfprobeBundle()
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

    func fetchInfo(url: String, rawCookies: String? = nil) async throws -> MediaInfo {
        guard let path = ytdlpPath else {
            throw YtdlpError.notFound
        }
        
        let normalizedURL = normalizeURLForYtdlp(url)
        do {
             return try await fetchSingleVideoInfo(path: path.path, url: normalizedURL, rawCookies: rawCookies)
        } catch {
            if isPlaylistURL(normalizedURL) {
                do {
                    return try await fetchPlaylistSummaryInfo(path: path.path, url: normalizedURL, rawCookies: rawCookies)
                } catch {
                    throw mapSiteSpecificError(error, url: normalizedURL)
                }
            }
            throw mapSiteSpecificError(error, url: normalizedURL)
        }
    }

    private func fetchSingleVideoInfo(path: String, url: String, forceBrowserCookies: Bool = false, rawCookies: String? = nil) async throws -> MediaInfo {
        if isBoyfriendTVURL(url) {
            if let btvMedia = await resolveBoyfriendTVMediaInfo(url: url, rawCookies: rawCookies) {
                var btvArgs = [
                    path,
                    "--ignore-config",
                    "--dump-json",
                    "--no-playlist",
                    "--no-warnings"
                ]
                appendSiteSpecificArgs(for: btvMedia.embedURL, to: &btvArgs)
                btvArgs.append("--")
                btvArgs.append(btvMedia.streamURL)
                
                var parsedInfo: MediaInfo? = nil
                do {
                    let output = try await runCommand(btvArgs)
                    if let data = output.data(using: .utf8) {
                        parsedInfo = try? JSONDecoder().decode(MediaInfo.self, from: data)
                    }
                } catch {
                    // If yt-dlp dump-json fails on the stream template, synthesize MediaInfo directly
                }

                let synthesizedFormats = parseBoyfriendTVFormats(from: btvMedia.streamURL)
                let resolvedFormats = (parsedInfo?.formats?.isEmpty == false) ? parsedInfo?.formats : synthesizedFormats

                return MediaInfo(
                    id: url,
                    title: btvMedia.title,
                    description: parsedInfo?.description,
                    thumbnail: parsedInfo?.thumbnail ?? btvMedia.thumbnailURL,
                    duration: parsedInfo?.duration,
                    uploader: parsedInfo?.uploader ?? "BoyfriendTV",
                    uploadDate: parsedInfo?.uploadDate,
                    viewCount: parsedInfo?.viewCount,
                    likeCount: parsedInfo?.likeCount,
                    formats: resolvedFormats,
                    subtitles: parsedInfo?.subtitles,
                    automaticCaptions: parsedInfo?.automaticCaptions,
                    chapters: parsedInfo?.chapters,
                    playlist: nil,
                    playlistIndex: nil,
                    playlistCount: nil
                )
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
        
        var tempRawCookieFile: URL? = nil
        if let raw = rawCookies, !raw.isEmpty {
            if let tempFile = createTempCookiesFileFromHeader(url: url, cookieHeader: raw) {
                tempRawCookieFile = tempFile
                args.append(contentsOf: ["--cookies", tempFile.path])
            }
        } else {
            let usingBrowserCookies = appendCookieArgs(for: url, to: &args, force: forceBrowserCookies)
            logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)
        }

        // Handle Sucuri bypass
        var tempCookieFile: URL? = nil
        if let sucuriCookie = await resolveSucuriCookie(for: url) {
            if let tempFile = createTempCookiesFile(url: url, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFile = tempFile
                LoggerService.shared.log("Using temporary Sucuri cookie file for \(hostForLog(url)) (cookie values not logged)", level: .info)
                args.append(contentsOf: ["--cookies", tempFile.path])
                args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
            }
        }

        appendSiteSpecificArgs(for: url, to: &args)
        args.append("--")
        args.append(url)

        defer {
            if let fileURL = tempCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let fileURL = tempRawCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        do {
            let output = try await runCommand(args)
            guard let data = output.data(using: .utf8) else { throw YtdlpError.parseError }
            do {
                return try JSONDecoder().decode(MediaInfo.self, from: data)
            } catch {
                LoggerService.shared.log("Failed to decode MediaInfo JSON: \(error)", level: .error)
                throw YtdlpError.parseError
            }
        } catch let err as YtdlpError {
            throw err
        } catch {
            let usingBrowserCookies = args.contains("--cookies-from-browser")
            if shouldRetryWithBrowserCookies(error: error, url: url, usingBrowserCookies: usingBrowserCookies, forceBrowserCookies: forceBrowserCookies) {
                LoggerService.shared.log("Retrying metadata extraction with configured browser cookies", level: .info)
                return try await fetchSingleVideoInfo(path: path, url: url, forceBrowserCookies: true, rawCookies: rawCookies)
            }
            throw mapSiteSpecificError(error, url: url)
        }
    }

    private func fetchPlaylistSummaryInfo(path: String, url: String, rawCookies: String? = nil) async throws -> MediaInfo {
        var args = [
            path,
            "--ignore-config",
            "--dump-single-json",
            "--flat-playlist",
            "--no-warnings"
        ]
        appendJsRuntimeArgs(to: &args)
        
        var tempRawCookieFile: URL? = nil
        if let raw = rawCookies, !raw.isEmpty {
            if let tempFile = createTempCookiesFileFromHeader(url: url, cookieHeader: raw) {
                tempRawCookieFile = tempFile
                args.append(contentsOf: ["--cookies", tempFile.path])
            }
        } else {
            let usingBrowserCookies = appendCookieArgs(for: url, to: &args)
            logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)
        }

        // Handle Sucuri bypass
        var tempCookieFile: URL? = nil
        if let sucuriCookie = await resolveSucuriCookie(for: url) {
            if let tempFile = createTempCookiesFile(url: url, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFile = tempFile
                LoggerService.shared.log("Using temporary Sucuri cookie file for \(hostForLog(url)) (cookie values not logged)", level: .info)
                args.append(contentsOf: ["--cookies", tempFile.path])
                args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
            }
        }

        args.append(contentsOf: ["--extractor-args", "generic:impersonate"])
        args.append("--")
        args.append(url)

        defer {
            if let fileURL = tempCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let fileURL = tempRawCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        let output = try await runCommand(args)
        guard let data = output.data(using: .utf8) else { throw YtdlpError.parseError }

        let decoder = JSONDecoder()

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


    func fetchPlaylistInfo(url: String, rawCookies: String? = nil) async throws -> [MediaInfo] {
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
        
        var tempRawCookieFile: URL? = nil
        if let raw = rawCookies, !raw.isEmpty {
            if let tempFile = createTempCookiesFileFromHeader(url: url, cookieHeader: raw) {
                tempRawCookieFile = tempFile
                args.append(contentsOf: ["--cookies", tempFile.path])
            }
        } else {
            let usingBrowserCookies = appendCookieArgs(for: url, to: &args)
            logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)
        }

        // Handle Sucuri bypass
        var tempCookieFile: URL? = nil
        if let sucuriCookie = await resolveSucuriCookie(for: url) {
            if let tempFile = createTempCookiesFile(url: url, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFile = tempFile
                LoggerService.shared.log("Using temporary Sucuri cookie file for \(hostForLog(url)) (cookie values not logged)", level: .info)
                args.append(contentsOf: ["--cookies", tempFile.path])
                args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
            }
        }

        let parsedHost = (URL(string: url)?.host ?? url).lowercased()
        let isYouTube = parsedHost == "youtube.com" || parsedHost.hasSuffix(".youtube.com") || parsedHost == "youtu.be" || parsedHost.hasSuffix(".youtu.be")
        if !isYouTube {
            args.append(contentsOf: ["--extractor-args", "generic:impersonate"])
        }
        args.append("--")
        args.append(url)

        defer {
            if let fileURL = tempCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let fileURL = tempRawCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

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




    func download(
        url: String,
        options: DownloadOptions,
        mediaInfo: MediaInfo? = nil,
        processController: DownloadProcessController? = nil,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        guard let path = ytdlpPath else {
            throw YtdlpError.notFound
        }
        let normalizedURL = normalizeURLForYtdlp(url)
        var targetURL = normalizedURL
        var customResolvedTitle: String? = nil
        var customEmbedURL: String? = nil
        var customThumbnailURL: String? = nil
        if isBoyfriendTVURL(url) {
            if let btvMedia = await resolveBoyfriendTVMediaInfo(url: url, rawCookies: options.rawCookies) {
                targetURL = resolveBoyfriendTVStreamURLForDownload(streamURL: btvMedia.streamURL, options: options)
                customResolvedTitle = btvMedia.title
                customEmbedURL = btvMedia.embedURL
                customThumbnailURL = btvMedia.thumbnailURL
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
        let scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("siphon_scratch_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        args.append(contentsOf: ["--paths", "temp:\(scratchDirectory.path)"])
        args.append(contentsOf: ["--paths", "thumbnail:\(scratchDirectory.path)"])
        args.append("--no-playlist")

        let outputTemplate: String
        if let customFilename = options.customFilename ?? customResolvedTitle, !customFilename.isEmpty {
            let safeName = Self.sanitizeFilename(customFilename)
            outputTemplate = options.saveFolder.appendingPathComponent("\(safeName).%(ext)s").path
        } else {
            outputTemplate = options.saveFolder.appendingPathComponent("%(title)s.%(ext)s").path
        }
        args.append("--windows-filenames")
        args.append("--continue")
        args.append(contentsOf: ["-o", outputTemplate])
        args.append(contentsOf: ["--print", "after_move:SIPHON_FINAL_PATH:%(filepath)s"])

        // Metadata-first HLS detection: configure FFmpeg downloader up-front for standalone .m3u8 streams
        // (YouTube and DASH formats must ALWAYS use yt-dlp's native downloader)
        let isHlsOrStream: Bool = {
            let lower = targetURL.lowercased()
            let parsedHost = (URL(string: targetURL)?.host ?? targetURL).lowercased()
            let isYouTube = parsedHost == "youtube.com" || parsedHost.hasSuffix(".youtube.com") || parsedHost == "youtu.be" || parsedHost.hasSuffix(".youtu.be")
            if isYouTube { return false }
            return lower.contains(".m3u8")
        }()
        if isHlsOrStream && !args.contains("--downloader") {
            args.append(contentsOf: ["--downloader", "ffmpeg", "--hls-use-mpegts"])
        }

        args.append(contentsOf: buildFormatArgs(options: options, mediaInfo: mediaInfo))
        let codecFallbackWarnings = codecFallbackOutputWarnings(options: options)
        if options.downloadSubtitles && !options.subtitleLanguages.isEmpty {
            let subFormat = options.subtitleFormat?.ytdlpValue ?? "srt"
            args.append(contentsOf: ["--sub-format", "\(subFormat)/best"])
            let langList = options.subtitleLanguages.joined(separator: ",")
            args.append(contentsOf: ["--sub-langs", langList])

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
        if options.embedThumbnail {
            args.append("--embed-thumbnail")
            args.append(contentsOf: ["--convert-thumbnails", "jpg"])
        }

        if options.embedMetadata {
            args.append("--embed-metadata")
            args.append("--embed-chapters")
        }

        if options.splitChapters {
            args.append("--split-chapters")
        }

        if options.sponsorBlock {
            args.append(contentsOf: ["--sponsorblock-remove", "all"])
        }

        if let start = options.timeFrameStart, let end = options.timeFrameEnd {
            args.append(contentsOf: ["--download-sections", "*\(start)-\(end)"])
        }

        if options.forceOverwrite == true {
            args.append("--force-overwrites")
        }

        if options.hdrAction == .convertToSDR {
            args.append(contentsOf: ["--postprocessor-args", "ffmpeg:-vf tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"])
        }

        let speedLimit = UserDefaults.standard.integer(forKey: UserDefaultsKeys.downloadSpeedLimit)
        if speedLimit > 0 {
            args.append(contentsOf: ["--limit-rate", "\(speedLimit)K"])
        }

        var tempCookieFiles: [URL] = []
        if let rawCookies = options.rawCookies, !rawCookies.isEmpty {
            if let tempFile = createTempCookiesFileFromHeader(url: targetURL, cookieHeader: rawCookies) {
                tempCookieFiles.append(tempFile)
                LoggerService.shared.log("Using session cookies passed from browser extension for \(hostForLog(targetURL))", level: .info)
                args.append(contentsOf: ["--cookies", tempFile.path])
            }
        } else {
            let usingBrowserCookies = appendCookieArgs(for: normalizedURL, to: &args)
            logCookieUsage(for: normalizedURL, usingBrowserCookies: usingBrowserCookies)
        }

        // Handle Sucuri bypass
        if let sucuriCookie = await resolveSucuriCookie(for: normalizedURL) {
            if let tempFile = createTempCookiesFile(url: normalizedURL, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFiles.append(tempFile)
                LoggerService.shared.log("Using temporary Sucuri cookie file for \(hostForLog(normalizedURL)) (cookie values not logged)", level: .info)
                args.append(contentsOf: ["--cookies", tempFile.path])
                args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
            }
        }
        
        // Prepare local scratch thumbnail if available to guarantee embedding for direct stream downloads
        let thumbnailCandidateURL = customThumbnailURL ?? mediaInfo?.thumbnail
        let scratchThumbnailURL = scratchDirectory.appendingPathComponent("custom_cover.jpg")
        if (options.embedThumbnail || options.downloadThumbnail), let thumbStr = thumbnailCandidateURL, !thumbStr.isEmpty {
            _ = await downloadThumbnailLocally(from: thumbStr, to: scratchThumbnailURL)
        }

        appendSiteSpecificArgs(for: customEmbedURL ?? targetURL, options: options, mediaInfo: mediaInfo, to: &args)

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

        defer {
            for fileURL in tempCookieFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        
        // Structured bounded recovery state machine
        enum DownloadRecoveryStrategy: Hashable {
            case stripCookies
            case disableRangeChunking
            case useFfmpegHls
            case injectBrowserCookies(browser: String)
            case retryTransientNetworkError
            case disableAria2c
        }

        var triedStrategies = Set<DownloadRecoveryStrategy>()
        var currentArgs = args
        var outputPath: String? = nil

        while outputPath == nil {
            do {
                outputPath = try await runDownloadProcess(
                    args: currentArgs,
                    saveFolder: options.saveFolder,
                    processController: processController,
                    onProgress: onProgress,
                    onOutput: onOutput
                )
            } catch let error as YtdlpError {
                let errText: String
                switch error {
                case .commandFailed(let msg), .downloadFailed(let msg):
                    errText = msg
                default:
                    errText = ""
                }

                // Strategy 1: Cookie failure -> handle FDA or strip browser cookies
                if !errText.isEmpty, isCookieFailureError(errText), currentArgs.contains("--cookies-from-browser"), !triedStrategies.contains(.stripCookies) {
                    if isSafariPermissionError(errText) && !Self.hasFullDiskAccess {
                        throw YtdlpError.safariCookiesFullDiskAccessRequired
                    }
                    triedStrategies.insert(.stripCookies)
                    LoggerService.shared.log("Browser cookie access failed or database missing (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Retrying download without browser cookies...", level: .warning)
                    if let browser = configuredBrowserCookieSource() {
                        recordCookieDenial(browser: browser, url: normalizedURL)
                    }
                    onOutput("[Siphon Info] Browser cookies unavailable. Retrying download directly without browser cookies...\n")
                    currentArgs = stripCookieArgs(from: currentArgs)
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
                    ffmpegArgs.append(contentsOf: ["--downloader", "ffmpeg"])
                    if !ffmpegArgs.contains("--downloader-args") {
                        ffmpegArgs.append(contentsOf: ["--downloader-args", "ffmpeg_i:-analyzeduration 20M -probesize 20M"])
                    }
                    if !ffmpegArgs.contains("--hls-use-mpegts") {
                        ffmpegArgs.append(contentsOf: ["--hls-use-mpegts"])
                    }
                    currentArgs = ffmpegArgs
                    continue
                }

                // Strategy 4: YouTube 403 / bot challenge -> Inject browser cookies
                if !errText.isEmpty, (normalizedURL.contains("youtube.com") || normalizedURL.contains("youtu.be")),
                   (errText.contains("403") || errText.contains("Sign in") || errText.contains("bot") || errText.contains("login_required")),
                   !currentArgs.contains("--cookies-from-browser"),
                   let browser = configuredBrowserCookieSource(),
                   !triedStrategies.contains(.injectBrowserCookies(browser: browser)) {
                    triedStrategies.insert(.injectBrowserCookies(browser: browser))
                    LoggerService.shared.log("YouTube 403 / bot challenge encountered. Retrying download with browser cookies from \(browser)...", level: .warning)
                    onOutput("[Siphon Info] YouTube authentication required. Retrying download with browser cookies from \(browser)...\n")
                    var cookieArgs = currentArgs
                    _ = appendCookieArgs(for: normalizedURL, to: &cookieArgs, force: true)
                    currentArgs = cookieArgs
                    continue
                }

                // Strategy 5: Transient CDN connection refusal / reset -> Retry with fresh connection
                if !errText.isEmpty, (errText.contains("Connection refused") || errText.contains("Failed to establish a new connection") || errText.contains("Connection reset")), !triedStrategies.contains(.retryTransientNetworkError) {
                    triedStrategies.insert(.retryTransientNetworkError)
                    LoggerService.shared.log("Transient CDN connection refusal encountered (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Retrying download with fresh connection...", level: .warning)
                    onOutput("[Siphon Info] CDN edge server refused connection. Retrying with fresh stream endpoint...\n")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
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

                throw mapSiteSpecificError(error, url: normalizedURL)
            }
        }

        guard let finalOutputPath = outputPath else {
            throw YtdlpError.downloadFailed("Download failed across all recovery strategies.")
        }
        let finalFileURL = URL(fileURLWithPath: finalOutputPath, relativeTo: options.saveFolder).absoluteURL

        // Post-download cover art fallback: if the output file lacks an embedded thumbnail and we have a local cover image, embed it via FFmpeg
        if options.embedThumbnail && FileManager.default.fileExists(atPath: scratchThumbnailURL.path) {
            let hasThumb = await hasAttachedThumbnail(mediaFile: finalFileURL, ffmpegDir: ffmpegDir)
            if !hasThumb {
                _ = await embedThumbnailWithFfmpeg(imageFile: scratchThumbnailURL, mediaFile: finalFileURL, ffmpegDir: ffmpegDir)
            }
        }

        // If user requested downloading thumbnail as a standalone file, save to folder
        if options.downloadThumbnail && FileManager.default.fileExists(atPath: scratchThumbnailURL.path) {
            let standaloneThumbURL = finalFileURL.deletingPathExtension().appendingPathExtension("jpg")
            if !FileManager.default.fileExists(atPath: standaloneThumbURL.path) {
                try? FileManager.default.copyItem(at: scratchThumbnailURL, to: standaloneThumbURL)
            }
        }

        return finalFileURL
    }

    private func downloadThumbnailLocally(from urlString: String, to destinationURL: URL) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.boyfriend.tv/", forHTTPHeaderField: "Referer")
        
        do {
            let (tempLocal, response) = try await URLSession.shared.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return false
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempLocal, to: destinationURL)
            return true
        } catch {
            return false
        }
    }

    private func embedThumbnailWithFfmpeg(imageFile: URL, mediaFile: URL, ffmpegDir: String) async -> Bool {
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

        let proc = Process()
        proc.executableURL = ffmpegBin
        proc.arguments = procArgs
        proc.environment = Self.createSanitizedEnvironment()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 && fm.fileExists(atPath: tempOutput.path), ((try? tempOutput.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 {
                let backupURL = mediaFile.deletingLastPathComponent().appendingPathComponent("thumb_orig_\(UUID().uuidString).\(ext)")
                try fm.moveItem(at: mediaFile, to: backupURL)
                do {
                    try fm.moveItem(at: tempOutput, to: mediaFile)
                    try? fm.removeItem(at: backupURL)
                    return true
                } catch {
                    try? fm.moveItem(at: backupURL, to: mediaFile)
                    try? fm.removeItem(at: tempOutput)
                    return false
                }
            } else {
                try? fm.removeItem(at: tempOutput)
                return false
            }
        } catch {
            try? fm.removeItem(at: tempOutput)
            return false
        }
    }

    private func hasAttachedThumbnail(mediaFile: URL, ffmpegDir: String) async -> Bool {
        let ffprobeBin = URL(fileURLWithPath: ffmpegDir).appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobeBin.path) else { return false }

        let proc = Process()
        proc.executableURL = ffprobeBin
        proc.arguments = [
            "-v", "error",
            "-select_streams", "v",
            "-show_entries", "stream_disposition=attached_pic",
            "-of", "csv=p=0",
            mediaFile.path
        ]
        proc.environment = Self.createSanitizedEnvironment()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.components(separatedBy: .newlines).contains("1")
        } catch {
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



    private func buildFormatArgs(options: DownloadOptions, mediaInfo: MediaInfo? = nil) -> [String] {
        var args: [String] = []

        // 1. Explicit user-specified format ID
        if let customFormatId = options.selectedFormatId, !customFormatId.isEmpty {
            args.append(contentsOf: ["-f", customFormatId])
            if options.fileType.isVideo {
                if let mergeFormat = compatibleMergeOutputFormat(for: options) {
                    args.append(contentsOf: ["--merge-output-format", mergeFormat])
                }
            } else {
                args.append(contentsOf: ["-x", "--audio-format", options.fileType.fileExtension])
                if let quality = options.audioQuality {
                    args.append(contentsOf: ["--audio-quality", quality.ytdlpValue])
                }
            }
            return args
        }

        // 2. Metadata-driven concrete format selection (eliminates silent fallback downgrades)
        if let info = mediaInfo {
            let resolved = info.resolveSelectedFormats(options: options)
            if !resolved.isEmpty {
                let isSynthesizedBtv = (info.uploader == "BoyfriendTV" || isBoyfriendTVURL(info.id)) && resolved.allSatisfy { $0.formatId == "1080" || $0.formatId == "720" || $0.formatId == "480" || $0.formatId == "240" || $0.formatId == "best" }
                let formatId: String
                if isSynthesizedBtv {
                    formatId = "best"
                } else if resolved.count == 2 {
                    formatId = "\(resolved[0].formatId)+\(resolved[1].formatId)"
                } else {
                    formatId = resolved[0].formatId
                }
                args.append(contentsOf: ["-f", formatId])
                if options.fileType.isVideo {
                    if let mergeFormat = compatibleMergeOutputFormat(for: options) {
                        args.append(contentsOf: ["--merge-output-format", mergeFormat])
                    }
                } else {
                    args.append(contentsOf: ["-x", "--audio-format", options.fileType.fileExtension])
                    if let quality = options.audioQuality {
                        args.append(contentsOf: ["--audio-quality", quality.ytdlpValue])
                    }
                }
                return args
            }
        }

        // 3. Fallback when mediaInfo metadata is absent
        if options.fileType.isAudio {
            args.append(contentsOf: ["-x", "--audio-format", options.fileType.fileExtension, "-f", "bestaudio/best"])
            if let quality = options.audioQuality {
                args.append(contentsOf: ["--audio-quality", quality.ytdlpValue])
            }
            return args
        }

        let maxH = options.videoResolution?.maxHeight
        let selector: String
        if let h = maxH {
            selector = "bestvideo[height<=\(h)]+bestaudio/best[height<=\(h)]/bestvideo+bestaudio/best"
        } else {
            selector = "bestvideo+bestaudio/best"
        }

        args.append(contentsOf: ["-f", selector])
        args.append(contentsOf: ["-S", "lang,quality,res,height,fps,hdr:12,vbr,abr,filesize"])

        var finalMergeFormat = compatibleMergeOutputFormat(for: options)

        if let conversionCodec = options.conversionCodec, conversionCodec != .none {
            var targetExt = options.fileType.fileExtension
            if conversionCodec == .av1 || conversionCodec == .vp9 {
                targetExt = "mkv"
            }
            finalMergeFormat = targetExt
        }

        if let mergeOutputFormat = finalMergeFormat {
            args.append(contentsOf: ["--merge-output-format", mergeOutputFormat])
        }

        if let conversionCodec = options.conversionCodec, conversionCodec != .none {
            var targetExt = options.fileType.fileExtension
            if conversionCodec == .av1 || conversionCodec == .vp9 {
                targetExt = "mkv"
            }
            
            switch conversionCodec {
            case .av1:
                args.append(contentsOf: ["--recode-video", targetExt, "--postprocessor-args", "VideoConvertor:-y -c:v libsvtav1 -preset 8 -crf 28 -strict experimental"])
            case .h265:
                #if arch(arm64)
                args.append(contentsOf: ["--recode-video", targetExt, "--postprocessor-args", "VideoConvertor:-y -c:v hevc_videotoolbox -strict experimental"])
                #else
                args.append(contentsOf: ["--recode-video", targetExt, "--postprocessor-args", "VideoConvertor:-y -c:v libx265 -strict experimental"])
                #endif
            case .vp9:
                args.append(contentsOf: ["--recode-video", targetExt, "--postprocessor-args", "VideoConvertor:-y -c:v libvpx-vp9 -strict experimental"])
            case .h264:
                #if arch(arm64)
                args.append(contentsOf: ["--recode-video", targetExt, "--postprocessor-args", "VideoConvertor:-y -c:v h264_videotoolbox -strict experimental"])
                #else
                args.append(contentsOf: ["--recode-video", targetExt, "--postprocessor-args", "VideoConvertor:-y -c:v libx264 -strict experimental"])
                #endif
            case .none:
                break
            }
        }

        return args
    }

    private func buildVideoSelector(for resolution: VideoResolution?, ignoreWorst: Bool = false) -> String {
        guard let resolution else { return "bestvideo" }

        switch resolution {
        case .best:
            return "bestvideo"
        case .r2160p, .r1440p, .r1080p, .r720p, .r480p, .r360p, .r240p:
            return resolution.ytdlpValue
        case .worst:
            return ignoreWorst ? "bestvideo" : "worstvideo"
        }
    }

    private func buildCombinedSelector(for resolution: VideoResolution?) -> String {
        guard let resolution else { return "best*" }
        return resolution.ytdlpCombinedValue
    }

    private func compatibleMergeOutputFormat(for options: DownloadOptions) -> String? {
        guard options.fileType.isVideo else { return nil }

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

    private func recordCookieDenial(browser: String, url: String) {
        let key = cookieScopeKey(browser: browser, url: url)
        deniedCookieSources.insert(key)
    }

    private func appendCookieArgs(for url: String, to args: inout [String], force: Bool = false) -> Bool {
        guard let browser = configuredBrowserCookieSource() else { return false }
        if isCookieDenied(browser: browser, url: url) { return false }
        if force || !args.contains("--cookies-from-browser") {
            args.append(contentsOf: ["--cookies-from-browser", browser])
        }
        return true
    }

    private func configuredBrowserCookieSource() -> String? {
        let browser = UserDefaults.standard.string(forKey: UserDefaultsKeys.browserForCookies) ?? "safari"
        return browser == "none" ? nil : browser
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
    
    private func isBoyfriendTVURL(_ urlOrHost: String) -> Bool {
        let host = (URL(string: urlOrHost)?.host ?? urlOrHost).lowercased()
        return host == "boyfriend.tv" || host.hasSuffix(".boyfriend.tv") ||
               host == "boyfriendtv.com" || host.hasSuffix(".boyfriendtv.com")
    }

    struct BoyfriendTVExtractedMedia {
        let streamURL: String
        let embedURL: String
        let title: String
        let thumbnailURL: String?
    }

    private func resolveBoyfriendTVMediaInfo(url: String, rawCookies: String? = nil) async -> BoyfriendTVExtractedMedia? {
        let targetUrl = normalizeURLForYtdlp(url)
        guard let pageURL = URL(string: targetUrl) else { return nil }
        
        var html = ""
        
        let appSupportYtdlp = Self.getAppSupportDirectory().appendingPathComponent("yt-dlp")
        let ytdlpBinary = ytdlpPath ?? Bundle.main.url(forResource: "yt-dlp", withExtension: nil) ?? (FileManager.default.fileExists(atPath: appSupportYtdlp.path) ? appSupportYtdlp : nil)

        // Try raw session cookies if provided (e.g. from browser extension)
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
            } catch {}
            
            if let output = dumpOutput, !output.isEmpty {
                var rawChunks: [String] = []
                for line in output.split(whereSeparator: \.isNewline) {
                    let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                    if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR") {
                        if let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                            let decodedString = String(decoding: decodedData, as: UTF8.self)
                            if !decodedString.isEmpty {
                                rawChunks.append(decodedString)
                            }
                        }
                    }
                }
                if !rawChunks.isEmpty {
                    let rawHtml = rawChunks.joined()
                    let hasMediaData = rawHtml.contains("hlsAuto") ||
                                       rawHtml.contains("videoPlayerData") ||
                                       rawHtml.contains("sources") ||
                                       rawHtml.contains("cdn.boyfriend") ||
                                       rawHtml.contains("boyfriend") ||
                                       rawHtml.contains("embedUrl") ||
                                       rawHtml.contains("/embed/") ||
                                       rawHtml.contains("<title>") ||
                                       rawHtml.contains("playerConfig")
                    if hasMediaData {
                        html = rawHtml
                        LoggerService.shared.log("Successfully extracted BoyfriendTV page dump using session cookies", level: .info)
                    }
                }
            }
        }

        var browsersToTry: [String?] = []
        if let configured = configuredBrowserCookieSource() {
            if configured != "safari" || Self.hasFullDiskAccess {
                browsersToTry.append(configured)
            }
        }
        for candidate in ["safari", "chrome", "brave", "firefox", "edge"] {
            if candidate == "safari" && !Self.hasFullDiskAccess {
                continue
            }
            if !browsersToTry.contains(where: { $0 == candidate }) {
                browsersToTry.append(candidate)
            }
        }
        browsersToTry.append(nil)

        if html.isEmpty, let ytdlp = ytdlpBinary {
            for browser in browsersToTry {
                var args = [ytdlp.path, "--ignore-config", "--dump-pages"]
                if let browserName = browser {
                    args.append(contentsOf: ["--cookies-from-browser", browserName])
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
                        if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR") {
                            if let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                                let decodedString = String(decoding: decodedData, as: UTF8.self)
                                if !decodedString.isEmpty {
                                    browserChunks.append(decodedString)
                                }
                            }
                        }
                    }
                    if !browserChunks.isEmpty {
                        let browserHtml = browserChunks.joined()
                        let hasMediaData = browserHtml.contains("hlsAuto") ||
                                           browserHtml.contains("videoPlayerData") ||
                                           browserHtml.contains("sources") ||
                                           browserHtml.contains("cdn.boyfriend") ||
                                           browserHtml.contains("boyfriend") ||
                                           browserHtml.contains("embedUrl") ||
                                           browserHtml.contains("/embed/") ||
                                           browserHtml.contains("<title>") ||
                                           browserHtml.contains("playerConfig")
                        if hasMediaData {
                            html = browserHtml
                            let sourceLog = browser == nil ? "impersonated HTTP request" : "browser cookies from '\(browser!)'"
                            LoggerService.shared.log("Successfully extracted BoyfriendTV page dump using \(sourceLog)", level: .info)
                            break
                        }
                    }
                }
            }
        }
        
        // Fallback to URLSession if browser dump output was empty or didn't contain stream
        if html.isEmpty && (processRunner is DefaultYtdlpProcessRunner) {
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 3.0
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.boyfriend.tv/", forHTTPHeaderField: "Referer")
            request.setValue("https://www.boyfriend.tv", forHTTPHeaderField: "Origin")
            
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let fetched = String(data: data, encoding: .utf8) {
                html = fetched
            } else {
                return nil
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
        
        // Extract Embed URL
        var embedUrl: String? = nil
        let embedPatterns = [
            "\"embedUrl\"\\s*:\\s*\"([^\"]+)\"",
            "<iframe[^>]+src=[\"'](https?://(?:www\\.)?boyfriend(?:tv)?\\.(?:tv|com)/embed/[^\"']+)[\"']",
            "<iframe[^>]+src=[\"'](/embed/[^\"']+)[\"']"
        ]
        for pattern in embedPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let val = (html as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\/", with: "/")
                if val.hasPrefix("http") {
                    embedUrl = val
                    break
                } else if val.hasPrefix("/embed/") {
                    let baseDomain = targetUrl.contains("boyfriendtv.com") ? "https://www.boyfriendtv.com" : "https://www.boyfriend.tv"
                    embedUrl = baseDomain + val
                    break
                }
            }
        }

        // Generate candidate embed URLs for both domain variations (.com and .tv)
        var candidateEmbeds: [String] = []
        if let embed = embedUrl {
            candidateEmbeds.append(embed)
            if embed.contains("boyfriend.tv") {
                candidateEmbeds.append(embed.replacingOccurrences(of: "boyfriend.tv", with: "boyfriendtv.com"))
            } else if embed.contains("boyfriendtv.com") {
                candidateEmbeds.append(embed.replacingOccurrences(of: "boyfriendtv.com", with: "boyfriend.tv"))
            }
        }
        let videoIdPattern = "/videos/(\\d+)"
        if let regex = try? NSRegularExpression(pattern: videoIdPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: targetUrl, options: [], range: NSRange(location: 0, length: (targetUrl as NSString).length)),
           match.numberOfRanges > 1 {
            let videoId = (targetUrl as NSString).substring(with: match.range(at: 1))
            let defaultCom = "https://www.boyfriendtv.com/embed/\(videoId)/"
            let defaultTv = "https://www.boyfriend.tv/embed/\(videoId)/"
            if !candidateEmbeds.contains(defaultCom) { candidateEmbeds.append(defaultCom) }
            if !candidateEmbeds.contains(defaultTv) { candidateEmbeds.append(defaultTv) }
        }

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
                    for browser in browsersToTry {
                        var embedArgs = [ytdlp.path, "--ignore-config", "--dump-pages"]
                        if let browserName = browser {
                            embedArgs.append(contentsOf: ["--cookies-from-browser", browserName])
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
                        } catch {}
                        
                        if let output = embedDump, !output.isEmpty {
                            var embedChunks: [String] = []
                            for line in output.split(whereSeparator: \.isNewline) {
                                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                                if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR") {
                                    if let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                                        let decodedString = String(decoding: decodedData, as: UTF8.self)
                                        if !decodedString.isEmpty {
                                            embedChunks.append(decodedString)
                                        }
                                    }
                                }
                            }
                            if !embedChunks.isEmpty {
                                let embedHtml = embedChunks.joined()
                                if let extracted = extractStreamURLFromHTML(embedHtml) {
                                    streamUrl = extracted
                                    embedUrl = embed
                                    break
                                }
                            }
                        }
                    }
                }

                // HTTP fallback for embed URL if yt-dlp did not extract stream
                if streamUrl == nil, let embedPageURL = URL(string: embed), (processRunner is DefaultYtdlpProcessRunner) {
                    var embedRequest = URLRequest(url: embedPageURL)
                    embedRequest.timeoutInterval = 3.0
                    embedRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                    embedRequest.setValue("https://www.boyfriend.tv/", forHTTPHeaderField: "Referer")
                    embedRequest.setValue("https://www.boyfriend.tv", forHTTPHeaderField: "Origin")

                    if let (data, response) = try? await URLSession.shared.data(for: embedRequest),
                       let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200,
                       let fetchedEmbed = String(data: data, encoding: .utf8) {
                        if let extracted = extractStreamURLFromHTML(fetchedEmbed) {
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
        
        return nil
    }

    private func extractStreamURLFromHTML(_ html: String) -> String? {
        let streamPatterns = [
            "\"(?:hlsAuto|hls|videoUrl|media|src|file|video_url)\"\\s*:\\s*\"(https?:[^\"]+)\"",
            "(https?:\\\\?/\\\\?/cdn\\.boyfriend(?:tv)?\\.(?:tv|com)[^\\s\"'<>]+?\\.mp4)",
            "(https?:\\\\?/\\\\?/cdn\\.boyfriend(?:tv)?\\.(?:tv|com)[^\\s\"'<>]+?\\.m3u8)",
            "(https?:\\\\?/\\\\?/[^\\s\"'<>]+\\.boyfriend(?:tv)?\\.(?:tv|com)[^\\s\"'<>]+?\\.m3u8)",
            "(https?:\\\\?/\\\\?/[^\\s\"'<>]+\\.boyfriend(?:tv)?\\.(?:tv|com)[^\\s\"'<>]+?\\.mp4)"
        ]
        for pattern in streamPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length))
                for match in matches where match.numberOfRanges > 1 {
                    let rawVal = (html as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: "\\/", with: "/")
                    if rawVal.hasPrefix("http") {
                        let lowerVal = rawVal.lowercased()
                        // Ignore teaser / preview / rollover clips
                        if lowerVal.contains("/pv/") ||
                           lowerVal.contains("pv_") ||
                           lowerVal.contains("/preview/") ||
                           lowerVal.contains("preview_") ||
                           lowerVal.contains("trailer") ||
                           lowerVal.contains("teaser") {
                            continue
                        }
                        return rawVal
                    }
                }
            }
        }
        return nil
    }

    private func parseBoyfriendTVFormats(from streamURL: String) -> [MediaFormat]? {
        guard let range = streamURL.range(of: "multi=([^/]+)", options: .regularExpression) else {
            return [MediaFormat(formatId: "best", ext: "mp4", resolution: "1920x1080", formatNote: "HD")]
        }
        let multiChunk = String(streamURL[range]).replacingOccurrences(of: "multi=", with: "")
        let entries = multiChunk.components(separatedBy: ",")
        var formats: [MediaFormat] = []
        for entry in entries {
            let parts = entry.components(separatedBy: ":")
            guard let res = parts.first, res.contains("x") else { continue }
            let dims = res.components(separatedBy: "x")
            if dims.count == 2, let _ = Int(dims[0]), let h = Int(dims[1]) {
                formats.append(MediaFormat(
                    formatId: "\(h)",
                    ext: "mp4",
                    resolution: res,
                    fps: 30,
                    vcodec: "h264",
                    acodec: "aac",
                    formatNote: "\(h)p"
                ))
            }
        }
        return formats.isEmpty ? nil : formats.sorted(by: {
            let h0 = Int($0.resolution?.components(separatedBy: "x").last ?? "0") ?? 0
            let h1 = Int($1.resolution?.components(separatedBy: "x").last ?? "0") ?? 0
            return h0 > h1
        })
    }

    func resolveBoyfriendTVStreamURLForDownload(streamURL: String, options: DownloadOptions) -> String {
        guard streamURL.contains("_TPL_") || streamURL.contains("_TPL") else {
            return streamURL
        }
        
        var targetTag = "1080p"
        if let range = streamURL.range(of: "multi=([^/&]+)", options: .regularExpression) {
            let multiChunk = String(streamURL[range]).replacingOccurrences(of: "multi=", with: "")
            let entries = multiChunk.components(separatedBy: ",")
            var tagMap: [(height: Int, tag: String)] = []
            for entry in entries {
                let parts = entry.components(separatedBy: ":")
                let res = parts.first ?? ""
                let tag = parts.count > 1 ? parts[1] : res
                let h: Int? = {
                    if res.contains("x") {
                        let dims = res.components(separatedBy: "x")
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

    private func normalizeURLForYtdlp(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        if let nested = components.queryItems?.first(where: { ["url", "u", "redirect", "target"].contains($0.name.lowercased()) })?.value,
           isBoyfriendTVURL(nested) {
            return normalizeURLForYtdlp(nested)
        }

        guard let host = components.host?.lowercased() else { return urlString }

        // 1. BoyfriendTV normalization
        if isBoyfriendTVURL(host) {
            components.scheme = "https"
            let trackingPrefixes = ["utm_"]
            let trackingNames = Set(["fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_cid", "mc_eid", "ref", "source"])
            components.queryItems = components.queryItems?.filter { item in
                let name = item.name.lowercased()
                return !trackingNames.contains(name) && !trackingPrefixes.contains { name.hasPrefix($0) }
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            
            let path = components.path
            // Extract video ID from path or query across all language/subdomain variations
            let videoId: String? = {
                if let regex = try? NSRegularExpression(pattern: "(?:^|/)(?:videos|embed|v)/(\\d+)", options: .caseInsensitive),
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

            let targetHost = host.contains("boyfriendtv.com") ? "www.boyfriendtv.com" : (host.contains("boyfriend.tv") ? "www.boyfriend.tv" : host)
            if let id = videoId {
                return "https://\(targetHost)/videos/\(id)/"
            }

            components.host = targetHost
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        // 2. Generic Tube / Gallery / Playlist URL normalization (e.g. /playlist/123/video/slug or /album/123/video/slug)
        let path = components.path
        let galleryVideoPattern = "^/(?:playlist|album|galleries)/\\d+/video/([^/]+)"
        let singleVideoPattern = "^/video/([^/]+)"
        if let regex = try? NSRegularExpression(pattern: galleryVideoPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: path, options: [], range: NSRange(location: 0, length: (path as NSString).length)),
           match.numberOfRanges > 1 {
            let videoSlug = (path as NSString).substring(with: match.range(at: 1))
            components.path = "/videos/\(videoSlug)/"
            return components.url?.absoluteString ?? components.string ?? urlString
        } else if host.contains("thisvid") {
            if let regex = try? NSRegularExpression(pattern: singleVideoPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: path, options: [], range: NSRange(location: 0, length: (path as NSString).length)),
               match.numberOfRanges > 1 {
                let videoSlug = (path as NSString).substring(with: match.range(at: 1))
                components.path = "/videos/\(videoSlug)/"
                return components.url?.absoluteString ?? components.string ?? urlString
            }
        }

        // 3. xHamster normalization
        if isXHamsterURL(host) {
            components.scheme = "https"
            let trackingPrefixes = ["utm_"]
            let trackingNames = Set(["from", "promo", "ref", "source", "reftag"])
            components.queryItems = components.queryItems?.filter { item in
                let name = item.name.lowercased()
                return !trackingNames.contains(name) && !trackingPrefixes.contains { name.hasPrefix($0) }
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }

            if host.hasSuffix("xhamster.com") {
                components.host = "xhamster.com"
            }
            return components.url?.absoluteString ?? components.string ?? urlString
        }

        return components.string ?? urlString
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

    private func shouldRetryWithBrowserCookies(error _: Error, url: String, usingBrowserCookies: Bool, forceBrowserCookies: Bool) -> Bool {
        isBoyfriendTVURL(url) && !usingBrowserCookies && !forceBrowserCookies && configuredBrowserCookieSource() != nil
    }

    private func mapSiteSpecificError(_ error: Error, url: String) -> Error {
        let errString = "\(error)"
        let lowerErr = errString.lowercased()
        let configuredBrowser = configuredBrowserCookieSource()

        if configuredBrowser == "safari" && isSafariPermissionError(errString) && !Self.hasFullDiskAccess {
            return YtdlpError.safariCookiesFullDiskAccessRequired
        }

        if isBoyfriendTVURL(url) {
            if lowerErr.contains("cloudflare") || lowerErr.contains("403") || lowerErr.contains("anti-bot") || lowerErr.contains("captcha") || lowerErr.contains("challenge") {
                return YtdlpError.cloudflareBlocked
            }
            if (lowerErr.contains("video is unavailable") || lowerErr.contains("video unavailable") || lowerErr.contains("video has been removed") || lowerErr.contains("video removed") || lowerErr.contains("404 not found") || lowerErr.contains("page not found") || lowerErr.contains("http error 404")) && !lowerErr.contains("cookie") {
                return YtdlpError.downloadFailed("This video is unavailable, private, or has been removed.")
            }
            if lowerErr.contains("sign in") || lowerErr.contains("private video") || lowerErr.contains("login") || lowerErr.contains("members-only") || lowerErr.contains("unsupported url") {
                if configuredBrowser == "safari" && !Self.hasFullDiskAccess {
                    return YtdlpError.safariCookiesFullDiskAccessRequired
                }
                if configuredBrowser == nil {
                    return YtdlpError.boyfriendTVNeedsBrowserCookies
                } else {
                    return YtdlpError.boyfriendTVLoginRequired
                }
            }
            return error
        }

        let parsedHost = (URL(string: url)?.host ?? url).lowercased()
        let isYouTube = parsedHost == "youtube.com" || parsedHost.hasSuffix(".youtube.com") || parsedHost == "youtu.be" || parsedHost.hasSuffix(".youtu.be")
        if isYouTube {
            if lowerErr.contains("403") || lowerErr.contains("sign in") || lowerErr.contains("bot") || lowerErr.contains("login_required") {
                if configuredBrowser == "safari" && !Self.hasFullDiskAccess {
                    return YtdlpError.safariCookiesFullDiskAccessRequired
                }
                if configuredBrowser == nil {
                    return YtdlpError.downloadFailed("YouTube requires authentication or browser cookies. Go to Settings > Advanced > Browser Cookies to select your browser.")
                }
            }
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
        if lower.contains("range header not supported") || lower.contains("range request not supported") || lower.contains("does not support range") || lower.contains("server does not support ranges") {
            return true
        }
        return false
    }

    private func appendSiteSpecificArgs(for url: String, options: DownloadOptions? = nil, mediaInfo: MediaInfo? = nil, to args: inout [String]) {
        let lowerUrl = url.lowercased()
        let parsedHost = (URL(string: url)?.host ?? url).lowercased()
        let isYouTube = parsedHost == "youtube.com" || parsedHost.hasSuffix(".youtube.com") || parsedHost == "youtu.be" || parsedHost.hasSuffix(".youtu.be")
        let isThisVid = isThisVidURL(parsedHost)
        let isXHamster = isXHamsterURL(parsedHost)
        let isBoyfriendTV = isBoyfriendTVURL(parsedHost) ||
                            parsedHost == "cdn.boyfriend.tv" || parsedHost.hasSuffix(".boyfriend.tv") ||
                            parsedHost == "cdn.boyfriendtv.com" || parsedHost.hasSuffix(".boyfriendtv.com")

        // Retries, socket timeouts & performance optimization flags
        args.append(contentsOf: ["--retries", "10"])
        args.append(contentsOf: ["--fragment-retries", "10"])
        args.append(contentsOf: ["--socket-timeout", "15"])
        args.append("--no-mtime")

        if !isYouTube {
            // Common modern browser headers & Cloudflare extraction options
            let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
            let secChUa = "\"Chromium\";v=\"124\", \"Google Chrome\";v=\"124\", \"Not-A.Brand\";v=\"99\""

            // Anti-bot flags for Cloudflare & rate limits
            args.append(contentsOf: ["--user-agent", defaultUA])
            args.append(contentsOf: ["--add-header", "Sec-Ch-Ua:\(secChUa)"])
            args.append(contentsOf: ["--add-header", "Sec-Ch-Ua-Mobile:?0"])
            args.append(contentsOf: ["--add-header", "Sec-Ch-Ua-Platform:\"macOS\""])
            args.append(contentsOf: ["--add-header", "Accept-Language:en-US,en;q=0.9"])
            args.append(contentsOf: ["--extractor-args", "generic:impersonate"])
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
                isXHamster
        }

        // Universal baseline transport optimization:
        // 1. 10M HTTP chunking: enables multi-megabyte Range chunks across CDNs/hosts to bypass single-stream connection throttling.
        //    Safe because runDownloadProcess automatically catches Range-incompatible servers and retries as continuous stream.
        // 2. 16K buffer size: reduces read/write syscall overhead compared to default small buffers.
        args.append(contentsOf: ["--http-chunk-size", "10M"])
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
            if let uaIdx = args.firstIndex(of: "--user-agent") {
                args[uaIdx + 1] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            } else {
                args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
            }
            let baseDomain = (parsedHost.contains("boyfriendtv.com") || lowerUrl.contains("boyfriendtv.com")) ? "https://www.boyfriendtv.com" : "https://www.boyfriend.tv"
            args.append(contentsOf: ["--add-header", "Origin:\(baseDomain)"])
            args.append(contentsOf: ["--add-header", "Accept:*/*"])
            let referer = lowerUrl.contains("/embed/") ? url : "\(baseDomain)/"
            args.append(contentsOf: ["--add-header", "Referer:\(referer)"])
            args.append(contentsOf: ["--downloader", "ffmpeg"])
            args.append(contentsOf: ["--hls-use-mpegts"])
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
        } else if parsedHost == "single-stream video site.com" || parsedHost.hasSuffix(".single-stream video site.com") {
            args.append(contentsOf: ["--add-header", "Referer:https://single-stream video site.com/"])
        } else if lowerUrl.contains(".m3u8") || lowerUrl.contains(".mpd") {
            args.append(contentsOf: ["--hls-use-mpegts"])
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
    }

    static var hasFullDiskAccess: Bool {
        let candidatePaths = [
            NSHomeDirectory() + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            NSHomeDirectory() + "/Library/Cookies/Cookies.binarycookies",
            NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
            NSHomeDirectory() + "/Library/Safari/History.db"
        ]
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                if let fileHandle = FileHandle(forReadingAtPath: path) {
                    try? fileHandle.close()
                    return true
                }
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

    private func runCommand(_ args: [String]) async throws -> String {
        do {
            return try await processRunner.runCommand(args)
        } catch let error as YtdlpError {
            if case .commandFailed(let output) = error, isCookieFailureError(output), let idx = args.firstIndex(of: "--cookies-from-browser"), idx + 1 < args.count {
                let browser = args[idx + 1]
                if browser == "safari" && isSafariPermissionError(output) && !Self.hasFullDiskAccess {
                    throw YtdlpError.safariCookiesFullDiskAccessRequired
                }
                LoggerService.shared.log("Browser cookie access failed for '\(browser)' or database missing. Automatically retrying command without browser cookies...", level: .info)
                if let urlArg = args.last {
                    recordCookieDenial(browser: browser, url: urlArg)
                }
                let cleanArgs = stripCookieArgs(from: args)
                return try await processRunner.runCommand(cleanArgs)
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
    ) async throws -> String {
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
            }
        }

        return siphonDir
    }

    private func extractBrowserCookiesToTempFile(url: String, browser: String) async -> URL? {
        // Not used explicitly here but kept for architecture
        return nil
    }

    private func fetchHTMLWithBrowserCookies(url: String, browser: String) async -> String? {
        guard let path = ytdlpPath?.path else { return nil }
        let cookieURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_cookies.txt")
        let cookiePath = cookieURL.path
        FileManager.default.createFile(atPath: cookiePath, contents: nil, attributes: [.posixPermissions: 0o600])
        defer {
            try? FileManager.default.removeItem(atPath: cookiePath)
        }

        let ytdlpArgs = [path, "--ignore-config", "--cookies-from-browser", browser, "--cookies", cookiePath, "--skip-download", "--", url]
        
        // This will create the cookies file, even if it eventually fails with "Unsupported URL"
        _ = try? await runCommand(ytdlpArgs)
        
        guard FileManager.default.fileExists(atPath: cookiePath) else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cookiePath)
        
        let curlArgs = [
            "/usr/bin/curl",
            "-sL",
            "--cookie", cookiePath,
            "-A", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            "--",
            url
        ]
        
        do {
            let output = try await runCommand(curlArgs)
            return output
        } catch {
            return nil
        }
    }

    private func resolveSucuriCookie(for url: String) async -> (name: String, value: String)? {
        guard let parsedURL = URL(string: url), let host = parsedURL.host?.lowercased() else { return nil }
        let sucuriDomains = ["thisvid.com"]
        guard sucuriDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }

        var request = URLRequest(url: parsedURL)
        request.timeoutInterval = 3.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let htmlText = String(data: data, encoding: .utf8) else { return nil }

            if htmlText.contains("sucuri_cloudproxy_js") {
                let pattern = "S\\s*=\\s*'([^']+)'"
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                let nsRange = NSRange(htmlText.startIndex..<htmlText.endIndex, in: htmlText)
                if let match = regex.firstMatch(in: htmlText, options: [], range: nsRange),
                   let range = Range(match.range(at: 1), in: htmlText) {
                    let b64Str = String(htmlText[range])
                    if let decodedData = Data(base64Encoded: b64Str),
                       let jsCode = String(data: decodedData, encoding: .utf8) {

                        var cookieName = ""
                        var cookieValue = ""

                        let strPattern = "\"(.*?)\"|'(.*?)'"
                        if let strRegex = try? NSRegularExpression(pattern: strPattern, options: []) {
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

    nonisolated static func sanitizeFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = filename.components(separatedBy: invalidCharacters)
        let cleaned = components.joined(separator: "_")
        let trimmed = cleaned.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : trimmed
    }

    private func createTempCookiesFile(url: String, cookieName: String, cookieValue: String) -> URL? {
        let tempCookiesURL = FileManager.default.temporaryDirectory.appendingPathComponent("siphon_cookies_\(UUID().uuidString).txt")
        let host = URL(string: url)?.host ?? ""
        let cookieContent = "# Netscape HTTP Cookie File\n\(host)\tFALSE\t/\tFALSE\t2783382923\t\(cookieName)\t\(cookieValue)\n"
        do {
            try cookieContent.write(to: tempCookiesURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempCookiesURL.path)
            return tempCookiesURL
        } catch {
            LoggerService.shared.log("Error writing cookies file: \(error)", level: .error)
            return nil
        }
    }

    private func createTempCookiesFileFromHeader(url: String, cookieHeader: String) -> URL? {
        guard let urlObj = URL(string: url), let host = urlObj.host, !host.isEmpty else { return nil }
        let domain = host.hasPrefix(".") ? host : ".\(host)"
        let tempCookiesURL = FileManager.default.temporaryDirectory.appendingPathComponent("siphon_header_cookies_\(UUID().uuidString).txt")
        
        var lines = ["# Netscape HTTP Cookie File"]
        let pairs = cookieHeader.components(separatedBy: ";")
        let expiry = Int(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970)
        
        for pair in pairs {
            let parts = pair.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "=")
            if parts.count >= 2 {
                let key = sanitizeCookieToken(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
                let value = sanitizeCookieToken(parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespacesAndNewlines))
                if !key.isEmpty && !value.isEmpty {
                    lines.append("\(domain)\tTRUE\t/\tFALSE\t\(expiry)\t\(key)\t\(value)")
                }
            }
        }
        
        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: tempCookiesURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempCookiesURL.path)
            return tempCookiesURL
        } catch {
            return nil
        }
    }

    private func sanitizeCookieToken(_ token: String) -> String {
        return token.replacingOccurrences(of: "\t", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
    }

    static func purgeOrphanedTempCookieFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.lastPathComponent
            if (name.hasPrefix("siphon_cookies_") || name.hasPrefix("siphon_header_cookies_")) && name.hasSuffix(".txt") {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}



enum YtdlpError: LocalizedError {
    case notFound
    case parseError
    case commandFailed(String)
    case downloadFailed(String)
    case tooManyRequests
    case subtitleError(String)
    case cloudflareBlocked
    case ffmpegInstallationFailed(String)
    case boyfriendTVNeedsBrowserCookies
    case boyfriendTVLoginRequired
    case safariCookiesFullDiskAccessRequired
    case securityViolation(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "yt-dlp not found"
        case .parseError:
            return "Failed to parse data"
        case .commandFailed(let output):
            return "Command failed: \(output)"
        case .downloadFailed(let output):
            return output.isEmpty ? "Download failed" : output
        case .tooManyRequests:
            return "429: Too Many Requests"
        case .subtitleError(let output):
            return "Subtitle error: \(output)"
        case .cloudflareBlocked:
            return "Blocked by Cloudflare anti-bot protection. Please select your browser as cookie source in Settings > Advanced and try again."
        case .ffmpegInstallationFailed(let path):
            return "FFmpeg installation failed. Please try updating dependencies again. Attempted path: \(path)"
        case .boyfriendTVNeedsBrowserCookies:
            return "This video site requires signed-in browser cookies. Open Settings > Advanced > Browser Cookies, choose your browser, then try again."
        case .boyfriendTVLoginRequired:
            return "Could not extract video stream. This specific video may require a login (premium/private). Siphon cannot automatically access logged-in videos."
        case .safariCookiesFullDiskAccessRequired:
            return "Safari cookies require Full Disk Access on macOS. Please grant Full Disk Access to Siphon in System Settings > Privacy & Security > Full Disk Access, or choose another browser in Settings > Advanced."
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

    func append(_ newBytes: Data) {
        lock.lock()
        data.append(newBytes)
        lock.unlock()
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

    func appendAndExtractLines(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []

        var searchStartIndex = buffer.startIndex
        while let newlineIndex = buffer[searchStartIndex...].firstIndex(of: 0x0A) { // 0x0A is '\n'
            let lineData = buffer.subdata(in: searchStartIndex..<newlineIndex)
            searchStartIndex = newlineIndex + 1

            if let line = String(data: lineData, encoding: .utf8) {
                var trimmed = line[...]
                while trimmed.hasSuffix("\r") { trimmed = trimmed.dropLast() }
                while trimmed.hasPrefix("\r") { trimmed = trimmed.dropFirst() }
                if !trimmed.isEmpty {
                    lines.append(String(trimmed))
                }
            }
        }

        if searchStartIndex > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<searchStartIndex)
        }

        // Safety bound: If continuous stream chunk exceeds 512KB without newline, extract and clear to prevent memory growth
        if buffer.count > 512 * 1024 {
            if let line = String(data: buffer, encoding: .utf8) {
                lines.append(line)
            }
            buffer.removeAll()
        }

        return lines
    }

    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        if !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8) {
                var trimmed = line[...]
                while trimmed.hasSuffix("\r") || trimmed.hasSuffix("\n") { trimmed = trimmed.dropLast() }
                while trimmed.hasPrefix("\r") || trimmed.hasPrefix("\n") { trimmed = trimmed.dropFirst() }
                if !trimmed.isEmpty {
                    lines.append(String(trimmed))
                }
            }
            buffer.removeAll()
        }
        return lines
    }
}

final class ThreadSafeOutputState: @unchecked Sendable {
    private var finalPath: String?
    private var candidatePaths: [String] = []
    private var errorText: String = ""
    private let lock = NSLock()

    func setFinalPath(_ path: String) {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
        guard !cleaned.isEmpty else { return }
        lock.lock()
        finalPath = cleaned
        lock.unlock()
    }

    func getFinalPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return finalPath
    }

    func addCandidatePath(_ newPath: String) {
        let cleaned = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
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
        // Bound error buffer to prevent unbounded memory growth during long-running error outputs
        if errorText.count > 100_000 {
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
