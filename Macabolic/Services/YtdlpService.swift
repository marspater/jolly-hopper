import Foundation
import JavaScriptCore



@MainActor
class YtdlpService: ObservableObject {
    @Published var isAvailable: Bool = false
    @Published var version: String?
    @Published var isUpdating: Bool = false
    @Published var updateProgress: Double = 0
    
    private var ytdlpPath: URL?
    private var ffmpegPath: URL?
    private let localVersion = "1.5.5"
    private let bundledYtdlpName = "yt-dlp_macos"
    
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
        isUpdating = true
        updateProgress = 0.1
        
        let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let appSupport = getAppSupportDirectory()
        let destination = appSupport.appendingPathComponent("yt-dlp")
        let tempDestination = appSupport.appendingPathComponent("yt-dlp.tmp_\(UUID().uuidString)")
        
        LoggerService.shared.log("Safely updating yt-dlp binary from \(downloadURL)", level: .info)
        
        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (downloadedTempURL, _) = try await URLSession.shared.download(from: downloadURL)
            
            if FileManager.default.fileExists(atPath: tempDestination.path) {
                try FileManager.default.removeItem(at: tempDestination)
            }
            try FileManager.default.moveItem(at: downloadedTempURL, to: tempDestination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDestination.path)
            
            // Verify binary execution before replacing target
            let testProcess = Process()
            testProcess.executableURL = tempDestination
            testProcess.arguments = ["--version"]
            let pipe = Pipe()
            testProcess.standardOutput = pipe
            testProcess.standardError = pipe
            
            try testProcess.run()
            testProcess.waitUntilExit()
            
            if testProcess.terminationStatus == 0 {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempDestination, to: destination)
                ytdlpPath = destination
                isAvailable = true
                await getVersion()
                LoggerService.shared.log("yt-dlp updated successfully to version \(version ?? "unknown")", level: .info)
            } else {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                LoggerService.shared.log("yt-dlp update validation failed: \(errStr)", level: .error)
                try? FileManager.default.removeItem(at: tempDestination)
            }
        } catch {
            LoggerService.shared.log("Failed to update yt-dlp: \(error.localizedDescription)", level: .error)
            try? FileManager.default.removeItem(at: tempDestination)
            isAvailable = FileManager.default.fileExists(atPath: destination.path)
        }
        
        updateProgress = 1.0
        isUpdating = false
    }

    func findFfmpeg() async {
        let appSupport = getAppSupportDirectory()
        let ffmpegInSupport = appSupport.appendingPathComponent("ffmpeg")
        let ffprobeInSupport = appSupport.appendingPathComponent("ffprobe")
        
        let systemFfmpegPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        
        var foundSystemPath: URL? = nil
        for path in systemFfmpegPaths {
            if FileManager.default.fileExists(atPath: path) {
                foundSystemPath = URL(fileURLWithPath: path)
                break
            }
        }
        
        if FileManager.default.fileExists(atPath: ffmpegInSupport.path) {
            ffmpegPath = ffmpegInSupport
        } else if let sysFfmpeg = foundSystemPath {
            ffmpegPath = sysFfmpeg
        }
        
        if ffmpegPath == nil || !FileManager.default.fileExists(atPath: ffprobeInSupport.path) {
            if foundSystemPath == nil {
                await downloadFfmpeg()
                await downloadFfprobe()
            }
        }
    }

    func downloadFfmpeg() async {
        let ffmpegURL = URL(string: "https://evermeet.cx/ffmpeg/get/zip")!
        let appSupport = getAppSupportDirectory()
        let destinationZip = appSupport.appendingPathComponent("ffmpeg.zip")
        let ffmpegDest = appSupport.appendingPathComponent("ffmpeg")
        
        LoggerService.shared.log("Safely updating FFmpeg from \(ffmpegURL)", level: .info)
        
        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (tempURL, _) = try await URLSession.shared.download(from: ffmpegURL)
            if FileManager.default.fileExists(atPath: destinationZip.path) {
                try FileManager.default.removeItem(at: destinationZip)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationZip)
            
            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProcess.arguments = ["-o", destinationZip.path, "-d", appSupport.path]
            try unzipProcess.run()
            unzipProcess.waitUntilExit()
            
            if FileManager.default.fileExists(atPath: ffmpegDest.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegDest.path)
                ffmpegPath = ffmpegDest
                LoggerService.shared.log("FFmpeg updated and verified.", level: .info)
            }
            try? FileManager.default.removeItem(at: destinationZip)
        } catch {
            LoggerService.shared.log("Failed to download FFmpeg: \(error.localizedDescription)", level: .error)
        }
    }

    func downloadFfprobe() async {
        let ffprobeURL = URL(string: "https://evermeet.cx/ffmpeg/get/ffprobe/zip")!
        let appSupport = getAppSupportDirectory()
        let destinationZip = appSupport.appendingPathComponent("ffprobe.zip")
        let ffprobeDest = appSupport.appendingPathComponent("ffprobe")
        
        LoggerService.shared.log("Safely updating FFprobe from \(ffprobeURL)", level: .info)
        
        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let (tempURL, _) = try await URLSession.shared.download(from: ffprobeURL)
            if FileManager.default.fileExists(atPath: destinationZip.path) {
                try FileManager.default.removeItem(at: destinationZip)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationZip)
            
            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProcess.arguments = ["-o", destinationZip.path, "-d", appSupport.path]
            try unzipProcess.run()
            unzipProcess.waitUntilExit()
            
            if FileManager.default.fileExists(atPath: ffprobeDest.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobeDest.path)
                LoggerService.shared.log("FFprobe updated and verified.", level: .info)
            }
            try? FileManager.default.removeItem(at: destinationZip)
        } catch {
            LoggerService.shared.log("Failed to download FFprobe: \(error.localizedDescription)", level: .error)
        }
    }
    
    func updateAllDependencies() async {
        await downloadYtdlp()
        await downloadFfmpeg()
        await downloadFfprobe()
    }
    

    func updateYtdlp() async {
        await downloadYtdlp()
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
        
        do {
             return try await fetchSingleVideoInfo(path: path.path, url: url)
        } catch {
            if url.contains("list=") || url.contains("/playlist") {
                 return try await fetchPlaylistSummaryInfo(path: path.path, url: url)
            }
            throw error // Playlist değilse orijinal hatayı fırlat
        }
    }
    
    private func fetchSingleVideoInfo(path: String, url: String) async throws -> MediaInfo {
        var args = [
            path,
            "--dump-json",
            "--no-playlist",
            "--no-warnings"
        ]
        
        appendCookieArgs(to: &args)

        // Handle Sucuri bypass
        var tempCookieFile: URL? = nil
        if let sucuriCookie = await resolveSucuriCookie(for: url) {
            if let tempFile = createTempCookiesFile(url: url, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFile = tempFile
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
        
        let output = try await runCommand(args)
        guard let data = output.data(using: .utf8) else { throw YtdlpError.parseError }
        return try JSONDecoder().decode(MediaInfo.self, from: data)
    }

    private func fetchPlaylistSummaryInfo(path: String, url: String) async throws -> MediaInfo {
        var args = [
            path,
            "--dump-single-json",
            "--flat-playlist",
            "--no-warnings"
        ]
        
        appendCookieArgs(to: &args)

        // Handle Sucuri bypass
        var tempCookieFile: URL? = nil
        if let sucuriCookie = await resolveSucuriCookie(for: url) {
            if let tempFile = createTempCookiesFile(url: url, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFile = tempFile
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
        
        appendCookieArgs(to: &args)

        // Handle Sucuri bypass
        var tempCookieFile: URL? = nil
        if let sucuriCookie = await resolveSucuriCookie(for: url) {
            if let tempFile = createTempCookiesFile(url: url, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFile = tempFile
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
        
        var args = [path.path]
        args.append("--no-playlist")
        
        if let ffmpegLoc = ffmpegPath?.deletingLastPathComponent().path {
            args.append(contentsOf: ["--ffmpeg-location", ffmpegLoc])
        } else {
            let appSupport = getAppSupportDirectory()
            args.append(contentsOf: ["--ffmpeg-location", appSupport.path])
        }
        args.append(contentsOf: ["--paths", "temp:/tmp"])
        
        let outputTemplate: String
        if let customFilename = options.customFilename, !customFilename.isEmpty {
            let safeName = sanitizeFilename(customFilename)
            outputTemplate = options.saveFolder.appendingPathComponent("\(safeName).%(ext)s").path
        } else {
            outputTemplate = options.saveFolder.appendingPathComponent("%(title)s.%(ext)s").path
        }
        args.append(contentsOf: ["-o", outputTemplate])
        
        args.append(contentsOf: buildFormatArgs(options: options))
        
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
            args.append(contentsOf: customArgs)
        }

        appendCookieArgs(to: &args)

        // Handle Sucuri bypass
        var tempCookieFile: URL? = nil
        if let sucuriCookie = await resolveSucuriCookie(for: url) {
            if let tempFile = createTempCookiesFile(url: url, cookieName: sucuriCookie.name, cookieValue: sucuriCookie.value) {
                tempCookieFile = tempFile
                args.append(contentsOf: ["--cookies", tempFile.path])
                args.append(contentsOf: ["--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"])
            }
        }
        
        appendSiteSpecificArgs(for: url, to: &args)

        args.append("--newline")
        args.append("--progress-template")
        args.append("%(progress._percent_str)s %(progress._speed_str)s %(progress._eta_str)s")
        
        args.append(url)
        
        let fullCommand = args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        onOutput("[COMMAND] \(fullCommand)\n")
        Task { @MainActor in
            LoggerService.shared.log(fullCommand, level: .command)
        }
        
        defer {
            if let fileURL = tempCookieFile {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        let outputPath = try await runDownloadProcess(
            args: args,
            saveFolder: options.saveFolder,
            onProcessCreated: onProcessCreated,
            onProgress: onProgress,
            onOutput: onOutput
        )
        
        if options.embedSubtitles && options.downloadSubtitles {
            cleanupSubtitleFiles(for: outputPath, in: options.saveFolder)
        }
        
        return URL(fileURLWithPath: outputPath, relativeTo: options.saveFolder).absoluteURL
    }
    
    private func cleanupSubtitleFiles(for videoPath: String, in folder: URL) {
        let fileManager = FileManager.default
        let videoURL = URL(fileURLWithPath: videoPath)
        let videoNameWithoutExt = videoURL.deletingPathExtension().lastPathComponent
        
        let subtitleExtensions = ["srt", "vtt", "ass", "sub", "ssa"]
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in contents {
                let fileName = file.deletingPathExtension().lastPathComponent
                let fileExt = file.pathExtension.lowercased()
                
                if subtitleExtensions.contains(fileExt) && fileName.hasPrefix(videoNameWithoutExt) {
                    try? fileManager.removeItem(at: file)
                }
            }
        } catch {
            print("Error cleaning up subtitle files: \(error)")
        }
    }
    

    
    private func buildFormatArgs(options: DownloadOptions) -> [String] {
        var args: [String] = []
        
        if options.fileType.isVideo {
            var videoBase = ""
            if let resolution = options.videoResolution {
                videoBase = resolution.ytdlpValue
            } else {
                videoBase = "bestvideo"
            }
            
            var formatStr = ""
            
            // Build video codec filter
            let videoCodecFilter = options.videoCodec?.ytdlpFilter ?? ""
            let audioCodecFilter = options.audioCodec?.ytdlpFilter ?? ""
            
            if !videoCodecFilter.isEmpty || !audioCodecFilter.isEmpty {
                // User selected specific codec(s)
                let audioBase = audioCodecFilter.isEmpty ? "bestaudio" : "bestaudio\(audioCodecFilter)"
                
                if !videoCodecFilter.isEmpty {
                    formatStr = "\(videoBase)\(videoCodecFilter)+\(audioBase)"
                    formatStr += "/\(videoBase)+\(audioBase)"
                    formatStr += "/\(videoBase)+bestaudio"
                } else {
                    formatStr = "\(videoBase)+\(audioBase)"
                    formatStr += "/\(videoBase)+bestaudio"
                }
            } else {
                formatStr = "\(videoBase)+bestaudio"
            }
            
            formatStr += "/best"
            
            args.append(contentsOf: ["-f", formatStr])
            args.append(contentsOf: ["--merge-output-format", options.fileType.fileExtension])
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
    
    private func appendCookieArgs(to args: inout [String]) {
        let browser = UserDefaults.standard.string(forKey: "browserForCookies") ?? "none"
        if browser != "none" {
            args.append(contentsOf: ["--cookies-from-browser", browser])
        }
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

        if lowerUrl.contains("boyfriendtv.com") {
            args.append(contentsOf: ["--add-header", "Referer:https://www.boyfriendtv.com/"])
            args.append(contentsOf: ["--extractor-args", "generic:impersonate"])
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
            env["PATH"] = "\(appSupport.path):\(currentPath)"
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
    
    private func runCommand(_ args: [String]) async throws -> String {
        return try await runCommandAsync(args)
    }
    
    private func runDownloadProcess(
        args: [String],
        saveFolder: URL,
        onProcessCreated: @escaping (Process) -> Void,
        onProgress: @escaping (Double, String?, String?) -> Void,
        onOutput: @escaping (String) -> Void
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
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
            env["PATH"] = "\(appSupport.path):\(currentPath)"
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
                        
                        let context = JSContext()
                        let docObj = JSValue(newObjectIn: context)
                        context?.setObject(docObj, forKeyedSubscript: "document" as NSString)
                        docObj?.setValue("", forProperty: "cookie")
                        
                        let locObj = JSValue(newObjectIn: context)
                        context?.setObject(locObj, forKeyedSubscript: "location" as NSString)
                        locObj?.setValue({ }, forProperty: "reload")
                        
                        context?.evaluateScript(jsCode)
                        
                        if let cookieVal = docObj?.forProperty("cookie")?.toString(), !cookieVal.isEmpty {
                            let cookieParts = cookieVal.components(separatedBy: ";")
                            if let firstPart = cookieParts.first {
                                let nvParts = firstPart.components(separatedBy: "=")
                                if nvParts.count == 2 {
                                    let cookieName = nvParts[0].trimmingCharacters(in: .whitespaces)
                                    let cookieValue = nvParts[1].trimmingCharacters(in: .whitespaces)
                                    return (cookieName, cookieValue)
                                }
                            }
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
