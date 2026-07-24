import Foundation



@MainActor
class YtdlpService: ObservableObject {
    @Published var isAvailable: Bool = false
    @Published var version: String?
    @Published var isUpdating: Bool = false
    @Published var updateProgress: Double = 0

    var ytdlpPath: URL?
    var ffmpegPath: URL?
    var ffprobePath: URL?
    private let localVersion = "1.5.5"
    private let bundledYtdlpName = "yt-dlp_macos"

    #if DEBUG
    var mockCommandRunner: (([String]) async throws -> String)?
    #endif

    init() {
        Task {
            await setupBinaries()
        }
    }



    func setupBinaries() async {
        await findYtdlp()
        await findFfmpeg()
    }




    func findYtdlp() async {

        if let bundledPath = Bundle.main.url(forResource: "yt-dlp", withExtension: nil) {
            ytdlpPath = bundledPath
            isAvailable = true
            return
        }


        let appSupport = getAppSupportDirectory()
        let ytdlpInSupport = appSupport.appendingPathComponent("yt-dlp")

        if FileManager.default.fileExists(atPath: ytdlpInSupport.path) {
            ytdlpPath = ytdlpInSupport
            isAvailable = true
            return
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
        let appSupport = getAppSupportDirectory()
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

        let systemDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]

        for directory in systemDirectories {
            let ffmpeg = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            let ffprobe = URL(fileURLWithPath: directory).appendingPathComponent("ffprobe")
            if await validateFfmpegPair(ffmpeg: ffmpeg, ffprobe: ffprobe, context: "system") {
                setFfmpegPaths(ffmpeg: ffmpeg, ffprobe: ffprobe, source: "system")
                return
            }
        }

        LoggerService.shared.log("FFmpeg installation failed. Attempted path: \(appSupport.path)", level: .error)
    }

    private func repairAppSupportFfmpegPair(ffmpeg: URL, ffprobe: URL) async {
        if !isExecutableBinary(at: ffmpeg) || !isExecutableBinary(at: ffprobe) {
            LoggerService.shared.log("Downloading or repairing FFmpeg and FFprobe in \(ffmpeg.deletingLastPathComponent().path)", level: .info)
            await downloadFfmpeg()
            await downloadFfprobe()
        }
    }

    private func isExecutableBinary(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func validateBinary(_ url: URL, name: String, context: String) async -> Bool {
        guard isExecutableBinary(at: url) else {
            LoggerService.shared.log("\(name) at \(url.path) is missing or not executable for \(context).", level: .warning)
            return false
        }

        do {
            _ = try await runCommandAsync([url.path, "-version"])
            LoggerService.shared.log("Validated \(name) at \(url.path) for \(context).", level: .info)
            return true
        } catch {
            LoggerService.shared.log("Failed to validate \(name) at \(url.path) for \(context): \(error.localizedDescription)", level: .error)
            return false
        }
    }

    private func validateFfmpegPair(ffmpeg: URL, ffprobe: URL, context: String) async -> Bool {
        let ffmpegValid = await validateBinary(ffmpeg, name: "FFmpeg", context: context)
        let ffprobeValid = await validateBinary(ffprobe, name: "FFprobe", context: context)
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
            let attemptedPath = getAppSupportDirectory().path
            throw YtdlpError.ffmpegInstallationFailed(attemptedPath)
        }

        setFfmpegPaths(ffmpeg: ffmpeg, ffprobe: ffprobe, source: "yt-dlp")
        return ffmpeg
    }

    func downloadFfmpeg() async {
        #if arch(arm64)
        let ffmpegURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64.gz")!
        #else
        let ffmpegURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-x64.gz")!
        #endif
        
        let appSupport = getAppSupportDirectory()
        let destinationGz = appSupport.appendingPathComponent("ffmpeg.gz")
        let ffmpegDest = appSupport.appendingPathComponent("ffmpeg")

        LoggerService.shared.log("Safely updating FFmpeg from \(ffmpegURL)", level: .info)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (tempURL, _) = try await URLSession.shared.download(from: ffmpegURL)
            if FileManager.default.fileExists(atPath: destinationGz.path) {
                try FileManager.default.removeItem(at: destinationGz)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationGz)

            if FileManager.default.fileExists(atPath: ffmpegDest.path) {
                try? FileManager.default.removeItem(at: ffmpegDest)
            }

            let gzipProcess = Process()
            gzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            gzipProcess.arguments = ["-d", "-f", destinationGz.path]
            try gzipProcess.run()
            gzipProcess.waitUntilExit()

            if FileManager.default.fileExists(atPath: ffmpegDest.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegDest.path)
                
                // Strip quarantine attribute if present
                let xattrProcess = Process()
                xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattrProcess.arguments = ["-c", ffmpegDest.path]
                try? xattrProcess.run()
                xattrProcess.waitUntilExit()

                if await validateBinary(ffmpegDest, name: "FFmpeg", context: "download") {
                    ffmpegPath = ffmpegDest
                    LoggerService.shared.log("FFmpeg downloaded and validated at \(ffmpegDest.path).", level: .info)
                }
            }
            try? FileManager.default.removeItem(at: destinationGz)
        } catch {
            LoggerService.shared.log("Failed to download FFmpeg: \(error.localizedDescription)", level: .error)
        }
    }

    func downloadFfprobe() async {
        #if arch(arm64)
        let ffprobeURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-arm64.gz")!
        #else
        let ffprobeURL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-x64.gz")!
        #endif
        
        let appSupport = getAppSupportDirectory()
        let destinationGz = appSupport.appendingPathComponent("ffprobe.gz")
        let ffprobeDest = appSupport.appendingPathComponent("ffprobe")

        LoggerService.shared.log("Safely updating FFprobe from \(ffprobeURL)", level: .info)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (tempURL, _) = try await URLSession.shared.download(from: ffprobeURL)
            if FileManager.default.fileExists(atPath: destinationGz.path) {
                try FileManager.default.removeItem(at: destinationGz)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationGz)

            if FileManager.default.fileExists(atPath: ffprobeDest.path) {
                try? FileManager.default.removeItem(at: ffprobeDest)
            }

            let gzipProcess = Process()
            gzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            gzipProcess.arguments = ["-d", "-f", destinationGz.path]
            try gzipProcess.run()
            gzipProcess.waitUntilExit()

            if FileManager.default.fileExists(atPath: ffprobeDest.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobeDest.path)
                
                // Strip quarantine attribute if present
                let xattrProcess = Process()
                xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattrProcess.arguments = ["-c", ffprobeDest.path]
                try? xattrProcess.run()
                xattrProcess.waitUntilExit()

                if await validateBinary(ffprobeDest, name: "FFprobe", context: "download") {
                    ffprobePath = ffprobeDest
                    LoggerService.shared.log("FFprobe downloaded and validated at \(ffprobeDest.path).", level: .info)
                }
            }
            try? FileManager.default.removeItem(at: destinationGz)
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

        let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let appSupport = getAppSupportDirectory()
        let destination = appSupport.appendingPathComponent("yt-dlp")
        let tempDestination = appSupport.appendingPathComponent("yt-dlp.tmp_\(UUID().uuidString)")

        LoggerService.shared.log("Safely updating yt-dlp binary from \(downloadURL)", level: .info)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (downloadedTempURL, _) = try await URLSession.shared.download(from: downloadURL)
            updateProgress = 0.65

            if FileManager.default.fileExists(atPath: tempDestination.path) {
                try FileManager.default.removeItem(at: tempDestination)
            }
            try FileManager.default.moveItem(at: downloadedTempURL, to: tempDestination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDestination.path)

            let testProcess = Process()
            testProcess.executableURL = tempDestination
            testProcess.arguments = ["--version"]
            let pipe = Pipe()
            testProcess.standardOutput = pipe
            testProcess.standardError = pipe

            try testProcess.run()
            testProcess.waitUntilExit()

            guard testProcess.terminationStatus == 0 else {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: tempDestination)
                throw YtdlpUpdateError.validationFailed(errStr.isEmpty ? "yt-dlp exited with status \(testProcess.terminationStatus)" : errStr)
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempDestination, to: destination)
            ytdlpPath = destination
            isAvailable = true
            updateProgress = 0.9
            await getVersion()
            let installedVersion = version ?? "unknown"
            LoggerService.shared.log("yt-dlp updated successfully to version \(installedVersion)", level: .info)
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
            let output = try await runCommandAsync([path.path, "--version"])
            version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("Versiyon alınamadı: \(error)")
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
            if normalizedURL.contains("list=") || normalizedURL.contains("/playlist") {
                 return try await fetchPlaylistSummaryInfo(path: path.path, url: normalizedURL)
            }
            throw mapSiteSpecificError(error, url: normalizedURL)
        }
    }

    private func fetchSingleVideoInfo(path: String, url: String, forceBrowserCookies: Bool = false) async throws -> MediaInfo {
        if isBoyfriendTVURL(url) {
            if let btvMedia = await resolveBoyfriendTVMediaInfo(url: url) {
                var btvArgs = [
                    path,
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
                        thumbnail: parsedInfo.thumbnail,
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
            }
        }

        var args = [
            path,
            "--dump-json",
            "--no-playlist",
            "--no-warnings"
        ]
        
        let usingBrowserCookies = appendCookieArgs(to: &args, force: forceBrowserCookies)
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
        args.append(url)

        defer {
            if let fileURL = tempCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        do {
            let output = try await runCommand(args)
            guard let data = output.data(using: .utf8) else { throw YtdlpError.parseError }
            return try JSONDecoder().decode(MediaInfo.self, from: data)
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
            "--dump-single-json",
            "--flat-playlist",
            "--no-warnings"
        ]
        
        let usingBrowserCookies = appendCookieArgs(to: &args)
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
            "--dump-json",
            "--flat-playlist",
            "--no-warnings"
        ]
        let usingBrowserCookies = appendCookieArgs(to: &args)
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
        args.append(url)

        defer {
            if let fileURL = tempCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        let output = try await runCommand(args)

        var results: [MediaInfo] = []
        let decoder = JSONDecoder()

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            if let data = line.data(using: .utf8),
               let info = try? decoder.decode(MediaInfo.self, from: data) {
                results.append(info)
            }
        }

        return results
    }




    func download(
        url: String,
        options: DownloadOptions,
        onProcessCreated: @escaping (Process) -> Void,
        onProgress: @escaping (Double, String?, String?) -> Void,
        onOutput: @escaping (String) -> Void
    ) async throws -> URL {
        guard let path = ytdlpPath else {
            throw YtdlpError.notFound
        }
        let normalizedURL = normalizeURLForYtdlp(url)
        var targetURL = normalizedURL
        var btvTitle: String? = nil
        if isBoyfriendTVURL(url) {
            if let btvMedia = await resolveBoyfriendTVMediaInfo(url: url) {
                targetURL = btvMedia.streamURL
                btvTitle = btvMedia.title
            }
        }

        var args = [path.path]
        if ffmpegPath == nil || !FileManager.default.fileExists(atPath: ffmpegPath?.path ?? "") {
            await findFfmpeg()
        }
        
        let appSupport = getAppSupportDirectory()
        let ffmpegDir: String
        if let loc = ffmpegPath?.deletingLastPathComponent().path, FileManager.default.fileExists(atPath: loc + "/ffmpeg") {
            ffmpegDir = loc
        } else if FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("ffmpeg").path) {
            ffmpegDir = appSupport.path
        } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
            ffmpegDir = "/opt/homebrew/bin"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/ffmpeg") {
            ffmpegDir = "/usr/local/bin"
        } else {
            ffmpegDir = appSupport.path
        }
        args.append(contentsOf: ["--ffmpeg-location", ffmpegDir])
        args.append(contentsOf: ["--paths", "temp:/tmp"])

        let outputTemplate: String
        if let customFilename = options.customFilename ?? btvTitle, !customFilename.isEmpty {
            let safeName = sanitizeFilename(customFilename)
            outputTemplate = options.saveFolder.appendingPathComponent("\(safeName).%(ext)s").path
        } else {
            outputTemplate = options.saveFolder.appendingPathComponent("%(title)s.%(ext)s").path
        }
        args.append(contentsOf: ["-o", outputTemplate])

        args.append(contentsOf: buildFormatArgs(options: options))
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
        }

        args.append("--embed-metadata")
        args.append("--embed-chapters")

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

        if let additionalArgs = options.additionalArguments, !additionalArgs.isEmpty {
            let customArgs = splitArguments(additionalArgs)

            let blockedFlags = [
                "--exec",
                "--exec-before-download",
                "--config-location",
                "--config-locations",
                "--downloader",
                "--downloader-args",
                "--external-downloader",
                "--external-downloader-args"
            ]

            for arg in customArgs {
                for blockedFlag in blockedFlags {
                    if arg == blockedFlag || arg.hasPrefix("\(blockedFlag)=") {
                        throw YtdlpError.securityViolation("Blocked argument '\(blockedFlag)' is not allowed for security reasons.")
                    }
                }
            }

            args.append(contentsOf: customArgs)
        }

        let usingBrowserCookies = appendCookieArgs(to: &args)
        logCookieUsage(for: normalizedURL, usingBrowserCookies: usingBrowserCookies)

        // Handle Sucuri bypass
        var tempCookieFile: URL? = nil
        if let sucuriCookie = await resolveSucuriCookie(for: normalizedURL) {
            if let tempFile = createTempCookiesFile(url: normalizedURL, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFile = tempFile
                LoggerService.shared.log("Using temporary Sucuri cookie file for \(hostForLog(normalizedURL)) (cookie values not logged)", level: .info)
                args.append(contentsOf: ["--cookies", tempFile.path])
                args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
            }
        }
        
        appendSiteSpecificArgs(for: targetURL, to: &args)

        args.append("--newline")
        args.append("--progress-template")
        args.append("%(progress._percent_str)s %(progress._speed_str)s %(progress._eta_str)s")
        
        args.append(targetURL)
        
        let fullCommand = args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        for warning in codecFallbackWarnings {
            onOutput("\(warning)\n")
        }
        onOutput("[COMMAND] \(fullCommand)\n")
        Task { @MainActor in
            LoggerService.shared.log(fullCommand, level: .command)
        }

        defer {
            if let fileURL = tempCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        #if arch(arm64)
        // Enable Apple Silicon (M1-M5) VideoToolbox Hardware Acceleration
        args.append(contentsOf: ["--postprocessor-args", "ffmpeg:-hwaccel videotoolbox"])
        #endif

        let outputPath: String
        do {
            outputPath = try await runDownloadProcess(
                args: args,
                saveFolder: options.saveFolder,
                onProcessCreated: onProcessCreated,
                onProgress: onProgress,
                onOutput: onOutput
            )
        } catch let error as YtdlpError {
            if case .commandFailed(let output) = error, isCookiePermissionError(output), args.contains("--cookies-from-browser") {
                LoggerService.shared.log("Cookie permission denied by macOS TCC. Retrying download automatically without browser cookies...", level: .warning)
                onOutput("[VeloX Warning] macOS TCC permission denied reading browser cookies. Retrying download without browser cookies...\n")
                let cleanArgs = stripCookieArgs(from: args)
                outputPath = try await runDownloadProcess(
                    args: cleanArgs,
                    saveFolder: options.saveFolder,
                    onProcessCreated: onProcessCreated,
                    onProgress: onProgress,
                    onOutput: onOutput
                )
            } else {
                throw error
            }
        } catch {
            throw mapSiteSpecificError(error, url: normalizedURL)
        }
        
        if options.embedSubtitles && options.downloadSubtitles {
            cleanupSubtitleFiles(for: outputPath, in: options.saveFolder)
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
            print("Error cleaning up subtitle files: \(error)")
        }
    }



    private func buildFormatArgs(options: DownloadOptions) -> [String] {
        var args: [String] = []

        if options.fileType.isVideo {
            let videoBase = buildVideoSelector(for: options.videoResolution)
            let bestVideoBase = buildVideoSelector(for: options.videoResolution, ignoreWorst: true)
            let videoCodecFilter = options.videoCodec?.ytdlpFilter ?? ""
            let audioCodecFilter = options.audioCodec?.ytdlpFilter ?? ""

            let requestedVideo = "\(videoBase)\(videoCodecFilter)"
            let requestedAudio = "bestaudio\(audioCodecFilter)"
            let bestVideo = videoCodecFilter.isEmpty ? requestedVideo : bestVideoBase
            let bestAudio = "bestaudio"

            // Fallback order is intentionally explicit:
            // 1. requested video codec + requested audio codec
            // 2. requested video codec + best audio
            // 3. best video + requested audio
            // 4. best video + best audio
            // 5. best combined format
            let formatSelectors = [
                "\(requestedVideo)+\(requestedAudio)",
                "\(requestedVideo)+\(bestAudio)",
                "\(bestVideo)+\(requestedAudio)",
                "\(bestVideo)+\(bestAudio)",
                "best"
            ]

            args.append(contentsOf: ["-f", formatSelectors.joined(separator: "/")])
            args.append(contentsOf: ["-S", "res,fps,hdr:12,vbr,abr,filesize"])

            if let mergeOutputFormat = compatibleMergeOutputFormat(for: options) {
                args.append(contentsOf: ["--merge-output-format", mergeOutputFormat])
            }
        } else {
            // Audio-only download
            var audioFormat = "ba"

            if let audioCodec = options.audioCodec, let filter = audioCodec.ytdlpFilter {
                audioFormat = "ba\(filter)/ba"  // Preferred codec with fallback
            }

            args.append(contentsOf: ["-f", "\(audioFormat)/best"])
            args.append(contentsOf: ["-x", "--audio-format", options.fileType.fileExtension])

            if let quality = options.audioQuality {
                args.append(contentsOf: ["--audio-quality", quality.ytdlpValue])
            } else {
                args.append(contentsOf: ["--audio-quality", "0"]) // Best quality by default
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
            warnings.append("[VeloX] WARNING: Requested video codec \(videoCodec.rawValue) will fall back to the best available video codec if no matching format is available.")
        }

        if let audioCodec = options.audioCodec, audioCodec != .auto {
            warnings.append("[VeloX] WARNING: Requested audio codec \(audioCodec.rawValue) will fall back to the best available audio codec if no matching format is available.")
        }

        return warnings
    }

    private func appendCookieArgs(to args: inout [String], force: Bool = false) -> Bool {
        guard let browser = configuredBrowserCookieSource() else { return false }
        if force || !args.contains("--cookies-from-browser") {
            args.append(contentsOf: ["--cookies-from-browser", browser])
        }
        return true
    }

    private func configuredBrowserCookieSource() -> String? {
        let browser = UserDefaults.standard.string(forKey: UserDefaultsKeys.browserForCookies) ?? "none"
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
    }

    private func resolveBoyfriendTVMediaInfo(url: String) async -> BoyfriendTVExtractedMedia? {
        guard let pageURL = URL(string: url) else { return nil }
        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.boyfriend.tv/", forHTTPHeaderField: "Referer")
        
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        var title = "BoyfriendTV Video"
        if let titleRange = html.range(of: "<title>(.*?)</title>", options: .regularExpression) {
            let rawTitle = String(html[titleRange])
                .replacingOccurrences(of: "<title>", with: "")
                .replacingOccurrences(of: "</title>", with: "")
                .replacingOccurrences(of: "boyfriend.tv - ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawTitle.isEmpty {
                title = rawTitle
            }
        }
        
        var embedUrl: String = url
        if let embedRange = html.range(of: "\"embedUrl\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
            let rawEmbed = String(html[embedRange])
            if let firstColon = rawEmbed.firstIndex(of: ":"),
               let startQuote = rawEmbed[firstColon...].firstIndex(of: "\"") {
                let val = String(rawEmbed[startQuote...])
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "\\/", with: "/")
                if val.hasPrefix("http") {
                    embedUrl = val
                }
            }
        }
        
        if let hlsRange = html.range(of: "\"hlsAuto\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
            let rawHls = String(html[hlsRange])
            if let firstColon = rawHls.firstIndex(of: ":"),
               let startQuote = rawHls[firstColon...].firstIndex(of: "\"") {
                let streamUrl = String(rawHls[startQuote...])
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "\\/", with: "/")
                if streamUrl.hasPrefix("http") {
                    return BoyfriendTVExtractedMedia(streamURL: streamUrl, embedURL: embedUrl, title: title)
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
        guard let host = components.host?.lowercased(), isBoyfriendTVURL(host) else { return urlString }
        components.scheme = "https"
        let trackingPrefixes = ["utm_"]
        let trackingNames = Set(["fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_cid", "mc_eid", "ref", "source"])
        components.queryItems = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !trackingNames.contains(name) && !trackingPrefixes.contains { name.hasPrefix($0) }
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string ?? urlString
    }

    private func shouldRetryWithBrowserCookies(error _: Error, url: String, usingBrowserCookies: Bool, forceBrowserCookies: Bool) -> Bool {
        isBoyfriendTVURL(url) && !usingBrowserCookies && !forceBrowserCookies && configuredBrowserCookieSource() != nil
    }

    private func mapSiteSpecificError(_ error: Error, url: String) -> Error {
        if isBoyfriendTVURL(url), configuredBrowserCookieSource() == nil {
            return YtdlpError.boyfriendTVNeedsBrowserCookies
        }
        return error
    }

    private func appendSiteSpecificArgs(for url: String, to args: inout [String]) {
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

        // Retries and socket timeouts
        args.append(contentsOf: ["--retries", "10"])
        args.append(contentsOf: ["--fragment-retries", "10"])
        args.append(contentsOf: ["--socket-timeout", "15"])

        if lowerUrl.contains("boyfriend.tv") || lowerUrl.contains("boyfriendtv.com") || lowerUrl.contains("cdn.boyfriend.tv") {
            args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"])
            args.append(contentsOf: ["--add-header", "Origin:https://www.boyfriend.tv"])
            args.append(contentsOf: ["--add-header", "Accept:*/*"])
            let referer = lowerUrl.contains("/embed/") ? url : "https://www.boyfriend.tv/"
            args.append(contentsOf: ["--add-header", "Referer:\(referer)"])
            args.append(contentsOf: ["--hls-use-mpegts"])
            args.append(contentsOf: ["--concurrent-fragments", "5"])
        } else if lowerUrl.contains("justthegays.com") {
            args.append(contentsOf: ["--add-header", "Referer:https://justthegays.com/"])
            args.append(contentsOf: ["--extractor-args", "generic:impersonate"])
        } else if lowerUrl.contains(".m3u8") || lowerUrl.contains(".mpd") {
            args.append(contentsOf: ["--hls-use-mpegts"])
            args.append(contentsOf: ["--concurrent-fragments", "5"])
        } else {
            args.append(contentsOf: ["--extractor-args", "generic:impersonate"])
        }
    }



    private func runCommandAsync(_ args: [String]) async throws -> String {
        #if DEBUG
        if let mock = mockCommandRunner {
            return try await mock(args)
        }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            var env = ProcessInfo.processInfo.environment
            let appSupport = getAppSupportDirectory()
            let currentPath = env["PATH"] ?? ""
            env["PATH"] = "\(appSupport.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(currentPath)"
            process.environment = env


            let outputBuffer = ThreadSafeDataBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    outputBuffer.append(data)
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil

                let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingData.isEmpty {
                    outputBuffer.append(remainingData)
                }

                let output = outputBuffer.getString()

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: YtdlpError.commandFailed(output))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func isCookiePermissionError(_ errorOutput: String) -> Bool {
        let lower = errorOutput.lowercased()
        return lower.contains("operation not permitted") || lower.contains("cookies.binarycookies") || lower.contains("errno 1")
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
            return try await runCommandAsync(args)
        } catch let error as YtdlpError {
            if case .commandFailed(let output) = error, isCookiePermissionError(output), args.contains("--cookies-from-browser") {
                LoggerService.shared.log("Cookie permission denied by macOS TCC. Automatically retrying command without browser cookies...", level: .warning)
                let cleanArgs = stripCookieArgs(from: args)
                return try await runCommandAsync(cleanArgs)
            }
            throw error
        }
    }

    private func runDownloadProcess(
        args: [String],
        saveFolder: URL,
        onProcessCreated: @escaping (Process) -> Void,
        onProgress: @escaping (Double, String?, String?) -> Void,
        onOutput: @escaping (String) -> Void
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            // Keep a single Process instance so callers can cancel the configured download process.
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.currentDirectoryURL = saveFolder
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            var env = ProcessInfo.processInfo.environment
            let appSupport = getAppSupportDirectory()
            let currentPath = env["PATH"] ?? ""
            env["PATH"] = "\(appSupport.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(currentPath)"
            process.environment = env

            onProcessCreated(process)

            let outputState = ThreadSafeOutputState()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }

                if line.contains("[download] Destination:") {
                    let parts = line.components(separatedBy: "[download] Destination: ")
                    if parts.count > 1 {
                        outputState.setOutputPath(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }

                if line.contains("has already been downloaded") {
                    let parts = line.components(separatedBy: "[download] ")
                    if parts.count > 1 {
                        let pathPart = parts[1].components(separatedBy: " has already been downloaded")
                        if !pathPart.isEmpty {
                            outputState.setOutputPath(pathPart[0].trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }

                if line.contains("[Merger] Merging formats into") {
                    let parts = line.components(separatedBy: "\"")
                    if parts.count > 1 {
                        outputState.setOutputPath(parts[1])
                    }
                }

                DispatchQueue.main.async {
                    onOutput(line)

                    if line.contains("%") {
                        let components = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            .components(separatedBy: .whitespaces)
                            .filter { !$0.isEmpty }

                        if let percentStr = components.first,
                           let percent = Double(percentStr.replacingOccurrences(of: "%", with: "")) {
                            let speed = components.count > 1 ? components[1] : nil
                            let eta = components.count > 2 ? components[2] : nil
                            onProgress(percent / 100.0, speed, eta)
                        }
                    }
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }

                outputState.appendError(line)

                DispatchQueue.main.async {
                    onOutput("[ERROR] \(line)")
                }
            }

            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let currentOutputPath = outputState.getOutputPath()
                let errorOutput = outputState.getErrorText()

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: currentOutputPath)
                } else {
                    if errorOutput.contains("Cloudflare") || (errorOutput.contains("403") && errorOutput.contains("anti-bot")) {
                        continuation.resume(throwing: YtdlpError.cloudflareBlocked)
                    } else if errorOutput.contains("429") || errorOutput.contains("Too Many Requests") {
                        continuation.resume(throwing: YtdlpError.tooManyRequests)
                    } else if errorOutput.contains("subtitle") || errorOutput.contains("caption") {
                        continuation.resume(throwing: YtdlpError.subtitleError(errorOutput))
                    } else {
                        let cleanError = errorOutput.components(separatedBy: "\n")
                            .filter { $0.contains("ERROR:") }
                            .last?
                            .replacingOccurrences(of: "ERROR: ", with: "")
                            ?? errorOutput
                        continuation.resume(throwing: YtdlpError.downloadFailed(cleanError))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func getAppSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let veloxDir = appSupport.appendingPathComponent("VeloX")
        let legacyDir = appSupport.appendingPathComponent("Macabolic")

        if !FileManager.default.fileExists(atPath: veloxDir.path) && FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: veloxDir)
        }

        return veloxDir
    }

    private func splitArguments(_ input: String) -> [String] {
        var result: [String] = []
        var current: String = ""
        var inQuotes: Bool = false
        var quoteChar: Character? = nil

        var iterator = input.makeIterator()
        while let char = iterator.next() {
            if char == "\"" || char == "'" {
                if inQuotes {
                    if char == quoteChar {
                        inQuotes = false
                        quoteChar = nil
                    } else {
                        current.append(char)
                    }
                } else {
                    inQuotes = true
                    quoteChar = char
                }
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }

    private func resolveSucuriCookie(for urlString: String) async -> (name: String, value: String)? {
        guard let url = URL(string: urlString) else { return nil }
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
            print("Error resolving Sucuri cookie: \(error)")
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
        let tempCookiesURL = FileManager.default.temporaryDirectory.appendingPathComponent("velox_cookies_\(UUID().uuidString).txt")
        let host = URL(string: url)?.host ?? ""
        let cookieContent = "# Netscape HTTP Cookie File\n\(host)\tFALSE\t/\tFALSE\t2783382923\t\(cookieName)\t\(cookieValue)\n"
        do {
            try cookieContent.write(to: tempCookiesURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempCookiesURL.path)
            return tempCookiesURL
        } catch {
            print("Error writing cookies file: \(error)")
            return nil
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
            return "boyfriend.tv often requires signed-in browser cookies. Open Settings > Advanced > Browser Cookies, choose your browser, then try again."
        case .securityViolation(let message):
            return "Security violation: \(message)"
        }
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

final class ThreadSafeOutputState: @unchecked Sendable {
    private var path: String = ""
    private var errorText: String = ""
    private let lock = NSLock()

    func setOutputPath(_ newPath: String) {
        lock.lock()
        path = newPath
        lock.unlock()
    }

    func getOutputPath() -> String {
        lock.lock()
        defer { lock.unlock() }
        return path
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
