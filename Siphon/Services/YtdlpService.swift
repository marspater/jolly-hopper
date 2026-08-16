import Foundation
import CryptoKit

struct DependencyChecksums {
    static let ytdlpVersion = "2026.07.04"
    static let ytdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/yt-dlp_macos")!
    static let ytdlpExecutableSHA256 = "498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b"

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
            LoggerService.shared.log("Downloading or repairing FFmpeg and FFprobe in \(ffmpeg.deletingLastPathComponent().path)", level: .info)
            await downloadFfmpeg()
            await downloadFfprobe()
        }
    }

    nonisolated static func createSanitizedEnvironment() -> [String: String] {
        let appSupport = Self.getAppSupportDirectory()
        let isolatedHome = appSupport.appendingPathComponent("SandboxHome")
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)

        var env: [String: String] = [:]
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
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

    func downloadFfmpeg() async {
        let appSupport = Self.getAppSupportDirectory()
        let destinationGz = appSupport.appendingPathComponent("ffmpeg_\(UUID().uuidString).gz")
        let ffmpegDest = appSupport.appendingPathComponent("ffmpeg")

        LoggerService.shared.log("Safely downloading FFmpeg from \(DependencyChecksums.ffmpegURL)", level: .info)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (tempURL, _) = try await NetworkUtils.download(url: DependencyChecksums.ffmpegURL)
            if FileManager.default.fileExists(atPath: destinationGz.path) {
                try FileManager.default.removeItem(at: destinationGz)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationGz)

            // Step 1: Verify .gz archive SHA-256 before decompression
            guard Self.verifySHA256(fileURL: destinationGz, expectedHash: DependencyChecksums.ffmpegArchiveSHA256) else {
                try? FileManager.default.removeItem(at: destinationGz)
                LoggerService.shared.log("FFmpeg .gz archive failed SHA-256 verification. Download aborted.", level: .error)
                return
            }

            // Step 2: Decompress
            _ = try await runCommand(["/usr/bin/gzip", "-d", "-f", destinationGz.path])
            let extractedBinURL = destinationGz.deletingPathExtension()

            // Step 3: Verify extracted binary SHA-256
            guard Self.verifySHA256(fileURL: extractedBinURL, expectedHash: DependencyChecksums.ffmpegExecutableSHA256) else {
                try? FileManager.default.removeItem(at: extractedBinURL)
                LoggerService.shared.log("FFmpeg executable failed SHA-256 verification after decompression. Aborted.", level: .error)
                return
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinURL.path)

            let installed = try await transactionalInstall(from: extractedBinURL, to: ffmpegDest) { binURL in
                await self.validateBinary(binURL, name: "FFmpeg", expectedSHA256: DependencyChecksums.ffmpegExecutableSHA256, context: "download")
            }

            if installed {
                ffmpegPath = ffmpegDest
                LoggerService.shared.log("FFmpeg cryptographically verified and installed at \(ffmpegDest.path).", level: .info)
            } else {
                LoggerService.shared.log("FFmpeg post-install validation failed. Rolled back.", level: .error)
            }
        } catch {
            LoggerService.shared.log("Failed to download FFmpeg: \(error.localizedDescription)", level: .error)
        }
    }

    func downloadFfprobe() async {
        let appSupport = Self.getAppSupportDirectory()
        let destinationGz = appSupport.appendingPathComponent("ffprobe_\(UUID().uuidString).gz")
        let ffprobeDest = appSupport.appendingPathComponent("ffprobe")

        LoggerService.shared.log("Safely downloading FFprobe from \(DependencyChecksums.ffprobeURL)", level: .info)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (tempURL, _) = try await NetworkUtils.download(url: DependencyChecksums.ffprobeURL)
            if FileManager.default.fileExists(atPath: destinationGz.path) {
                try FileManager.default.removeItem(at: destinationGz)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationGz)

            // Step 1: Verify .gz archive SHA-256 before decompression
            guard Self.verifySHA256(fileURL: destinationGz, expectedHash: DependencyChecksums.ffprobeArchiveSHA256) else {
                try? FileManager.default.removeItem(at: destinationGz)
                LoggerService.shared.log("FFprobe .gz archive failed SHA-256 verification. Download aborted.", level: .error)
                return
            }

            // Step 2: Decompress
            _ = try await runCommand(["/usr/bin/gzip", "-d", "-f", destinationGz.path])
            let extractedBinURL = destinationGz.deletingPathExtension()

            // Step 3: Verify extracted binary SHA-256
            guard Self.verifySHA256(fileURL: extractedBinURL, expectedHash: DependencyChecksums.ffprobeExecutableSHA256) else {
                try? FileManager.default.removeItem(at: extractedBinURL)
                LoggerService.shared.log("FFprobe executable failed SHA-256 verification after decompression. Aborted.", level: .error)
                return
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinURL.path)

            let installed = try await transactionalInstall(from: extractedBinURL, to: ffprobeDest) { binURL in
                await self.validateBinary(binURL, name: "FFprobe", expectedSHA256: DependencyChecksums.ffprobeExecutableSHA256, context: "download")
            }

            if installed {
                ffprobePath = ffprobeDest
                LoggerService.shared.log("FFprobe cryptographically verified and installed at \(ffprobeDest.path).", level: .info)
            } else {
                LoggerService.shared.log("FFprobe post-install validation failed. Rolled back.", level: .error)
            }
        } catch {
            LoggerService.shared.log("Failed to download FFprobe: \(error.localizedDescription)", level: .error)
        }
    }

    func updateAllDependencies() async {
        await downloadYtdlp()
        await downloadFfmpeg()
        await downloadFfprobe()
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
        let tempDestination = appSupport.appendingPathComponent("yt-dlp.tmp_\(UUID().uuidString)")

        LoggerService.shared.log("Safely downloading yt-dlp binary from \(downloadURL)", level: .info)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (downloadedTempURL, _) = try await NetworkUtils.download(url: downloadURL)
            updateProgress = 0.65

            if FileManager.default.fileExists(atPath: tempDestination.path) {
                try FileManager.default.removeItem(at: tempDestination)
            }
            try FileManager.default.moveItem(at: downloadedTempURL, to: tempDestination)

            // Step 1: Cryptographic SHA-256 verification before staging or permissions
            guard Self.verifySHA256(fileURL: tempDestination, expectedHash: DependencyChecksums.ytdlpExecutableSHA256) else {
                try? FileManager.default.removeItem(at: tempDestination)
                throw YtdlpUpdateError.validationFailed("yt-dlp binary failed SHA-256 integrity verification. Expected: \(DependencyChecksums.ytdlpExecutableSHA256)")
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDestination.path)

            do {
                _ = try await runCommand([tempDestination.path, "--ignore-config", "--version"])
            } catch {
                try? FileManager.default.removeItem(at: tempDestination)
                throw YtdlpUpdateError.validationFailed("yt-dlp exited with error: \(error.localizedDescription)")
            }

            let installed = try await transactionalInstall(from: tempDestination, to: destination) { binURL in
                (try? await self.runCommand([binURL.path, "--ignore-config", "--version"])) != nil
            }
            guard installed else {
                throw YtdlpUpdateError.validationFailed("yt-dlp post-installation validation failed. Rolled back.")
            }
            ytdlpPath = destination
            isAvailable = true
            updateProgress = 0.9
            await getVersion()
            let installedVersion = version ?? "unknown"
            LoggerService.shared.log("yt-dlp verified and updated successfully to version \(installedVersion)", level: .info)
            return installedVersion
        } catch {
            try? FileManager.default.removeItem(at: tempDestination)
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




    func fetchInfo(url: String) async throws -> MediaInfo {
        guard let path = ytdlpPath else {
            throw YtdlpError.notFound
        }
        
        let normalizedURL = normalizeURLForYtdlp(url)
        do {
             return try await fetchSingleVideoInfo(path: path.path, url: normalizedURL)
        } catch {
            if (normalizedURL.contains("list=") || normalizedURL.contains("/playlist/")) && !normalizedURL.contains("/videos/") {
                do {
                    return try await fetchPlaylistSummaryInfo(path: path.path, url: normalizedURL)
                } catch {
                    throw mapSiteSpecificError(error, url: normalizedURL)
                }
            }
            throw mapSiteSpecificError(error, url: normalizedURL)
        }
    }

    private func fetchSingleVideoInfo(path: String, url: String, forceBrowserCookies: Bool = false) async throws -> MediaInfo {
        if isBoyfriendTVURL(url) {
            if let btvMedia = await resolveBoyfriendTVMediaInfo(url: url) {
                var btvArgs = [
                    path,
                    "--ignore-config",
                    "--dump-json",
                    "--no-playlist",
                    "--no-warnings"
                ]
                appendSiteSpecificArgs(for: btvMedia.embedURL, to: &btvArgs)
                btvArgs.append(btvMedia.streamURL)
                
                if let output = try? await runCommand(btvArgs),
                   let data = output.data(using: .utf8),
                   let parsedInfo = try? JSONDecoder().decode(MediaInfo.self, from: data) {
                    return MediaInfo(
                        id: url,
                        title: btvMedia.title,
                        description: parsedInfo.description,
                        thumbnail: parsedInfo.thumbnail ?? btvMedia.thumbnailURL,
                        duration: parsedInfo.duration,
                        uploader: "BoyfriendTV",
                        uploadDate: parsedInfo.uploadDate,
                        viewCount: parsedInfo.viewCount,
                        likeCount: parsedInfo.likeCount,
                        formats: parsedInfo.formats,
                        subtitles: parsedInfo.subtitles,
                        automaticCaptions: parsedInfo.automaticCaptions,
                        chapters: parsedInfo.chapters,
                        playlist: nil,
                        playlistIndex: nil,
                        playlistCount: nil
                    )
                }

                return MediaInfo(
                    id: url,
                    title: btvMedia.title,
                    description: nil,
                    thumbnail: btvMedia.thumbnailURL,
                    duration: nil,
                    uploader: "BoyfriendTV",
                    uploadDate: nil,
                    viewCount: nil,
                    likeCount: nil,
                    formats: nil,
                    subtitles: nil,
                    automaticCaptions: nil,
                    chapters: nil,
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
        
        let usingBrowserCookies = appendCookieArgs(for: url, to: &args, force: forceBrowserCookies)
        logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)

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
            if shouldRetryWithBrowserCookies(error: error, url: url, usingBrowserCookies: usingBrowserCookies, forceBrowserCookies: forceBrowserCookies) {
                LoggerService.shared.log("Retrying boyfriend.tv metadata with configured browser cookies", level: .info)
                return try await fetchSingleVideoInfo(path: path, url: url, forceBrowserCookies: true)
            }
            throw mapSiteSpecificError(error, url: url)
        }
    }

    private func fetchPlaylistSummaryInfo(path: String, url: String) async throws -> MediaInfo {
        var args = [
            path,
            "--ignore-config",
            "--dump-single-json",
            "--flat-playlist",
            "--no-warnings"
        ]
        
        let usingBrowserCookies = appendCookieArgs(for: url, to: &args)
        logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)

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


    func fetchPlaylistInfo(url: String) async throws -> [MediaInfo] {
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
        let usingBrowserCookies = appendCookieArgs(for: url, to: &args)
        logCookieUsage(for: url, usingBrowserCookies: usingBrowserCookies)

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
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProcessCreated: @escaping @Sendable (Process) -> Void,
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
        if isBoyfriendTVURL(url) {
            if let btvMedia = await resolveBoyfriendTVMediaInfo(url: url) {
                targetURL = btvMedia.streamURL
                customResolvedTitle = btvMedia.title
                customEmbedURL = btvMedia.embedURL
            }
        }

        var args = [path.path, "--ignore-config"]
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
        args.append(contentsOf: ["--paths", "temp:/tmp"])
        args.append(contentsOf: ["--paths", "thumbnail:/tmp"])
        args.append("--no-playlist")

        let outputTemplate: String
        if let customFilename = options.customFilename ?? customResolvedTitle, !customFilename.isEmpty {
            let safeName = sanitizeFilename(customFilename)
            outputTemplate = options.saveFolder.appendingPathComponent("\(safeName).%(ext)s").path
        } else {
            outputTemplate = options.saveFolder.appendingPathComponent("%(title)s.%(ext)s").path
        }
        args.append("--windows-filenames")
        args.append(contentsOf: ["-o", outputTemplate])

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
        
        appendSiteSpecificArgs(for: customEmbedURL ?? targetURL, options: options, mediaInfo: mediaInfo, to: &args)

        args.append("--no-color")
        args.append("--newline")
        args.append("--progress-template")
        args.append("%(progress._percent_str)s %(progress._speed_str)s %(progress._eta_str)s")
        
        args.append("--")
        args.append(targetURL)
        
        let sanitizedCommand = LoggerService.sanitizeCommandForLog(args)
        for warning in codecFallbackWarnings {
            onOutput("\(warning)\n")
        }
        onOutput("[COMMAND] \(sanitizedCommand)\n")
        Task { @MainActor in
            LoggerService.shared.log(sanitizedCommand, level: .command)
        }

        defer {
            for fileURL in tempCookieFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        let outputPath: String
        do {
            outputPath = try await runDownloadProcess(
                args: args,
                saveFolder: options.saveFolder,
                isCancelled: isCancelled,
                onProcessCreated: onProcessCreated,
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

            if !errText.isEmpty, isCookieFailureError(errText), args.contains("--cookies-from-browser") {
                LoggerService.shared.log("Browser cookie access failed or database missing (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Retrying download automatically without browser cookies...", level: .warning)
                if let browser = configuredBrowserCookieSource() {
                    recordCookieDenial(browser: browser, url: normalizedURL)
                }
                onOutput("[Siphon Info] Browser cookies unavailable. Retrying download directly without browser cookies...\n")
                let cleanArgs = stripCookieArgs(from: args)
                outputPath = try await runDownloadProcess(
                    args: cleanArgs,
                    saveFolder: options.saveFolder,
                    isCancelled: isCancelled,
                    onProcessCreated: onProcessCreated,
                    onProgress: onProgress,
                    onOutput: onOutput
                )
            } else if !errText.isEmpty, isRangeError(errText), args.contains("--http-chunk-size") {
                LoggerService.shared.log("Server range request error encountered (\(errText.trimmingCharacters(in: .whitespacesAndNewlines))). Retrying download without HTTP chunking...", level: .warning)
                onOutput("[Siphon Info] Server does not support HTTP Range chunks. Retrying download directly as continuous stream...\n")
                var unchunkedArgs = args
                if let idx = unchunkedArgs.firstIndex(of: "--http-chunk-size") {
                    unchunkedArgs.remove(at: idx)
                    if idx < unchunkedArgs.count {
                        unchunkedArgs.remove(at: idx)
                    }
                }
                outputPath = try await runDownloadProcess(
                    args: unchunkedArgs,
                    saveFolder: options.saveFolder,
                    isCancelled: isCancelled,
                    onProcessCreated: onProcessCreated,
                    onProgress: onProgress,
                    onOutput: onOutput
                )
            } else {
                throw mapSiteSpecificError(error, url: normalizedURL)
            }
        } catch {
            throw mapSiteSpecificError(error, url: normalizedURL)
        }

        return URL(fileURLWithPath: outputPath, relativeTo: options.saveFolder).absoluteURL
    }

    private func cleanupSubtitleFiles(for videoPath: String, in folder: URL) {
        let fileManager = FileManager.default
        let videoURL = URL(fileURLWithPath: videoPath)
        let videoNameWithoutExt = videoURL.deletingPathExtension().lastPathComponent

        // ⚡ Bolt: Converted array to Set for O(1) lookups
        let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "sub", "ssa"]

        do {
            let contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in contents {
                let fileExt = file.pathExtension.lowercased()

                // ⚡ Bolt: Defer expensive string manipulations (deletingPathExtension/lastPathComponent)
                // until after checking the file extension. This avoids overhead for the 99% of non-subtitle
                // files in a large Downloads folder. Impact: O(n) string ops -> O(k) where k is # of subtitles.
                if subtitleExtensions.contains(fileExt) {
                    let fileName = file.deletingPathExtension().lastPathComponent
                    if fileName.hasPrefix(videoNameWithoutExt) {
                        try? fileManager.removeItem(at: file)
                    }
                }
            }
        } catch {
            LoggerService.shared.log("Error cleaning up subtitle files: \(error)", level: .warning)
        }
    }

    private func cleanupThumbnailFiles(for videoPath: String, in folder: URL) {
        let fileManager = FileManager.default
        let videoURL = URL(fileURLWithPath: videoPath)
        let videoNameWithoutExt = videoURL.deletingPathExtension().lastPathComponent
        let imageExtensions: Set<String> = ["jpg", "jpeg", "webp", "png"]

        do {
            let contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in contents {
                let fileExt = file.pathExtension.lowercased()
                if imageExtensions.contains(fileExt) {
                    let fileName = file.deletingPathExtension().lastPathComponent
                    if fileName == videoNameWithoutExt || fileName.hasPrefix(videoNameWithoutExt) || videoNameWithoutExt.hasPrefix(fileName) {
                        try? fileManager.removeItem(at: file)
                    }
                }
            }
        } catch {
            LoggerService.shared.log("Error cleaning up thumbnail files: \(error)", level: .warning)
        }
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
                let formatId: String
                if resolved.count == 2 {
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
        args.append(contentsOf: ["-S", "res,height,fps,hdr:12,vbr,abr,quality,filesize"])

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
    
    private func isBoyfriendTVURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("boyfriend.tv") || lower.contains("boyfriendtv.com")
    }

    struct BoyfriendTVExtractedMedia {
        let streamURL: String
        let embedURL: String
        let title: String
        let thumbnailURL: String?
    }

    private func resolveBoyfriendTVMediaInfo(url: String) async -> BoyfriendTVExtractedMedia? {
        let targetUrl = normalizeURLForYtdlp(url)
        guard let pageURL = URL(string: targetUrl) else { return nil }
        
        var html = ""
        
        var browsersToTry: [String?] = []
        if let configured = configuredBrowserCookieSource() {
            browsersToTry.append(configured)
        }
        for candidate in ["safari", "chrome", "brave", "firefox", "edge"] {
            if !browsersToTry.contains(where: { $0 == candidate }) {
                browsersToTry.append(candidate)
            }
        }
        browsersToTry.append(nil)

        let appSupportYtdlp = Self.getAppSupportDirectory().appendingPathComponent("yt-dlp")
        let ytdlpBinary = ytdlpPath ?? Bundle.main.url(forResource: "yt-dlp", withExtension: nil) ?? (FileManager.default.fileExists(atPath: appSupportYtdlp.path) ? appSupportYtdlp : nil)

        if let ytdlp = ytdlpBinary {
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
                    var browserHtml = ""
                    for line in output.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR") {
                            if let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                                let decodedString = String(decoding: decodedData, as: UTF8.self)
                                if !decodedString.isEmpty {
                                    browserHtml += decodedString
                                }
                            }
                        }
                    }
                    if !browserHtml.isEmpty {
                        let hasMediaData = browserHtml.contains("hlsAuto") ||
                                           browserHtml.contains("videoPlayerData") ||
                                           browserHtml.contains("sources") ||
                                           browserHtml.contains("cdn.boyfriend.tv") ||
                                           browserHtml.contains("boyfriendtv") ||
                                           browserHtml.contains("embedUrl") ||
                                           browserHtml.contains("/embed/")
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
        
        // Fallback to URLSession if browser dump output was empty
        if html.isEmpty {
            var request = URLRequest(url: pageURL)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.boyfriend.tv/", forHTTPHeaderField: "Referer")
            
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
            "<iframe[^>]+src=[\"'](https?://(?:www\\.)?boyfriend\\.tv/embed/[^\"']+)[\"']",
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
                    embedUrl = "https://www.boyfriend.tv" + val
                    break
                }
            }
        }
        if embedUrl == nil {
            let videoIdPattern = "/videos/(\\d+)"
            if let regex = try? NSRegularExpression(pattern: videoIdPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: targetUrl, options: [], range: NSRange(location: 0, length: (targetUrl as NSString).length)),
               match.numberOfRanges > 1 {
                let videoId = (targetUrl as NSString).substring(with: match.range(at: 1))
                embedUrl = "https://www.boyfriend.tv/embed/\(videoId)/"
            }
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
        
        // If stream URL is not found on main page, fetch embed URL page
        if streamUrl == nil, let embed = embedUrl, let ytdlp = ytdlpBinary {
            for browser in browsersToTry {
                var embedArgs = [ytdlp.path, "--ignore-config", "--dump-pages"]
                if let browserName = browser {
                    embedArgs.append(contentsOf: ["--cookies-from-browser", browserName])
                }
                appendSiteSpecificArgs(for: embed, to: &embedArgs)
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
                    var embedHtml = ""
                    for line in output.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if !trimmed.starts(with: "#") && !trimmed.starts(with: "[") && !trimmed.starts(with: "WARNING") && !trimmed.starts(with: "ERROR") {
                            if let decodedData = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
                                let decodedString = String(decoding: decodedData, as: UTF8.self)
                                if !decodedString.isEmpty {
                                    embedHtml += decodedString
                                }
                            }
                        }
                    }
                    if !embedHtml.isEmpty {
                        if let extracted = extractStreamURLFromHTML(embedHtml) {
                            streamUrl = extracted
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
            "(https?:\\\\?/\\\\?/cdn\\.boyfriend\\.tv[^\\s\"'<>]+?\\.mp4)",
            "(https?:\\\\?/\\\\?/cdn\\.boyfriend\\.tv[^\\s\"'<>]+?\\.m3u8)"
        ]
        for pattern in streamPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length)),
               match.numberOfRanges > 1 {
                let rawVal = (html as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: "\\/", with: "/")
                if rawVal.hasPrefix("http") {
                    return rawVal
                }
            }
        }
        return nil
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
            
            // Strip localized language path prefixes like /ru/, /de/, /fr/, /es/, /it/, /pt/, /pl/, /ja/, /zh/, /ko/, etc.
            var path = components.path
            let langRegex = "^/([a-z]{2})/"
            if let range = path.range(of: langRegex, options: [.regularExpression, .caseInsensitive]) {
                let matched = String(path[range])
                let reservedPaths = ["/v/", "/u/", "/b/", "/p/"]
                if !reservedPaths.contains(matched.lowercased()) {
                    path = "/" + String(path.dropFirst(matched.count))
                    components.path = path
                }
            }

            // Normalize video paths with ID to canonical host www.boyfriend.tv and path /videos/<id>/
            let videoIdPattern = "^/(?:videos|embed)/(\\d+)"
            if let regex = try? NSRegularExpression(pattern: videoIdPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: path, options: [], range: NSRange(location: 0, length: (path as NSString).length)),
               match.numberOfRanges > 1 {
                let videoId = (path as NSString).substring(with: match.range(at: 1))
                return "https://www.boyfriend.tv/videos/\(videoId)/"
            }

            components.host = "www.boyfriend.tv"
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

        return components.string ?? urlString
    }

    private func isThisVidURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("thisvid.com") || lower.contains("thisvid")
    }

    private func shouldRetryWithBrowserCookies(error _: Error, url: String, usingBrowserCookies: Bool, forceBrowserCookies: Bool) -> Bool {
        isBoyfriendTVURL(url) && !usingBrowserCookies && !forceBrowserCookies && configuredBrowserCookieSource() != nil
    }

    private func mapSiteSpecificError(_ error: Error, url: String) -> Error {
        if isBoyfriendTVURL(url) {
            if configuredBrowserCookieSource() == nil {
                return YtdlpError.boyfriendTVNeedsBrowserCookies
            } else {
                return YtdlpError.boyfriendTVLoginRequired
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

        // Retries, socket timeouts & performance optimization flags
        args.append(contentsOf: ["--retries", "10"])
        args.append(contentsOf: ["--fragment-retries", "10"])
        args.append(contentsOf: ["--socket-timeout", "15"])
        args.append("--no-mtime")

        let isYouTube = lowerUrl.contains("youtube.com") || lowerUrl.contains("youtu.be")
        let isThisVid = lowerUrl.contains("thisvid.com") || lowerUrl.contains("thisvid")
        let isFragmented: Bool
        if let info = mediaInfo, let opts = options {
            isFragmented = info.isSelectedFormatFragmented(options: opts)
        } else if let info = mediaInfo {
            isFragmented = info.isFragmented
        } else {
            isFragmented = lowerUrl.contains(".m3u8") ||
                lowerUrl.contains(".mpd") ||
                lowerUrl.contains("boyfriend.tv") ||
                lowerUrl.contains("boyfriendtv.com") ||
                lowerUrl.contains("cdn.boyfriend.tv")
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

        if lowerUrl.contains("boyfriend.tv") || lowerUrl.contains("boyfriendtv.com") || lowerUrl.contains("cdn.boyfriend.tv") {
            args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
            args.append(contentsOf: ["--add-header", "Origin:https://www.boyfriend.tv"])
            args.append(contentsOf: ["--add-header", "Accept:*/*"])
            let referer = lowerUrl.contains("/embed/") ? url : "https://www.boyfriend.tv/"
            args.append(contentsOf: ["--add-header", "Referer:\(referer)"])
            args.append(contentsOf: ["--hls-use-mpegts"])
        } else if lowerUrl.contains("justthegays.com") || lowerUrl.contains("justthegays.tv") {
            args.append(contentsOf: ["--add-header", "Referer:https://justthegays.com/"])
        } else if lowerUrl.contains("thisvid.com") || lowerUrl.contains("thisvid") {
            args.append(contentsOf: ["--add-header", "Referer:https://thisvid.com/"])
            args.append(contentsOf: ["--add-header", "Origin:https://thisvid.com"])
        } else if lowerUrl.contains("single-stream video site.com") {
            args.append(contentsOf: ["--add-header", "Referer:https://single-stream video site.com/"])
        } else if lowerUrl.contains(".m3u8") || lowerUrl.contains(".mpd") {
            args.append(contentsOf: ["--hls-use-mpegts"])
        } else if let components = URLComponents(string: url), let host = components.host, !host.isEmpty {
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
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProcessCreated: @escaping @Sendable (Process) -> Void,
        onProgress: @escaping @Sendable (Double, String?, String?) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await processRunner.runDownloadProcess(
            args: args,
            saveFolder: saveFolder,
            isCancelled: isCancelled,
            onProcessCreated: onProcessCreated,
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

        let ytdlpArgs = [path, "--ignore-config", "--cookies-from-browser", browser, "--cookies", cookiePath, "--skip-download", url]
        
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
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
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

    private func sanitizeFilename(_ filename: String) -> String {
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

        while let newlineIndex = buffer.firstIndex(of: 0x0A) { // 0x0A is '\n'
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            if let line = String(data: lineData, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                }
            }
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        if !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                }
            }
            buffer.removeAll()
        }
        return lines
    }
}

final class ThreadSafeOutputState: @unchecked Sendable {
    private var candidatePaths: [String] = []
    private var errorText: String = ""
    private let lock = NSLock()

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
