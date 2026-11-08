import Foundation
import SiphonCore

extension HDRAction {
    func title(lang: LanguageService) -> String {
        switch self {
        case .preserveHDR:
            return lang.s("hdr_action_preserve")
        case .convertToSDR:
            return lang.s("hdr_action_convert_sdr")
        }
    }
}

extension AudioQuality {
    func title(lang: LanguageService) -> String {
        if self == .best {
            return lang.s("res_best")
        }
        return rawValue
    }
}

extension VideoResolution {
    func title(lang: LanguageService) -> String {
        switch self {
        case .best: return lang.s("res_best")
        case .r2160p: return "2160p (4K)"
        case .r1440p: return "1440p (2K)"
        case .r1080p: return "1080p (Full HD)"
        case .r720p: return "720p (HD)"
        case .r480p: return "480p"
        case .r360p: return "360p"
        case .r240p: return "240p"
        case .worst: return lang.s("res_worst")
        }
    }
}

extension ResolutionFallbackPolicy {
    func title(lang: LanguageService) -> String {
        switch self {
        case .strictCeiling:
            return lang.s("res_fallback_strict")
        case .allowHigher:
            return lang.s("res_fallback_allow_higher")
        }
    }
}

extension VideoCodec {
    func title(lang: LanguageService) -> String {
        switch self {
        case .auto: return lang.s("codec_auto")
        case .h264: return "H.264 (AVC)"
        case .h265: return "H.265 (HEVC)"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        }
    }
}

extension ConversionCodec {
    func title(lang: LanguageService) -> String {
        switch self {
        case .none: return lang.s("conversion_codec_none")
        case .h264: return lang.s("conversion_codec_h264")
        case .h265: return lang.s("conversion_codec_h265")
        case .vp9: return lang.s("conversion_codec_vp9")
        case .av1: return lang.s("conversion_codec_av1")
        }
    }
}

extension AudioCodec {
    func title(lang: LanguageService) -> String {
        switch self {
        case .auto: return lang.s("codec_auto")
        case .aac: return "AAC (M4A)"
        case .opus: return "Opus"
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        }
    }
}

extension DownloadPreset {
    func title(lang: LanguageService) -> String {
        switch self {
        case .bestQuality: return lang.s("preset_best_quality")
        case .maxCompatibility: return lang.s("preset_max_compatibility")
        case .smallestSize: return lang.s("preset_smallest_size")
        case .audioOnly: return lang.s("preset_audio_only")
        }
    }

    func description(lang: LanguageService) -> String {
        switch self {
        case .bestQuality: return lang.s("preset_best_quality_desc")
        case .maxCompatibility: return lang.s("preset_max_compatibility_desc")
        case .smallestSize: return lang.s("preset_smallest_size_desc")
        case .audioOnly: return lang.s("preset_audio_only_desc")
        }
    }
}

extension Download {
    func formatSubtitle(lang: LanguageService) -> String {
        var parts = [sourceDomain]
        parts += options.fileType.isVideo ? videoSubtitleParts() : audioSubtitleParts()
        parts.append(options.fileType.rawValue)
        if let dur = duration, !dur.isEmpty {
            parts.append(dur)
        }
        if options.downloadSubtitles {
            parts.append(subtitleSelectionPart(lang: lang))
        }
        return parts.joined(separator: " • ")
    }

    private func videoSubtitleParts() -> [String] {
        var parts: [String] = []
        if let resolution = resolutionSubtitlePart() {
            parts.append(resolution)
        }
        if let codec = options.videoCodec, codec != .auto {
            parts.append(codec.rawValue.uppercased())
        }
        if let hdr = diagnostics.hdrSummary ?? mediaInfo?.firstHDRSummary {
            parts.append(hdr)
        }
        return parts
    }

    private func resolutionSubtitlePart() -> String? {
        if let height = diagnostics.resolvedHeight {
            return "\(height)p"
        }
        if let res = options.videoResolution, res != .best, res != .worst {
            return res.rawValue.replacingOccurrences(of: "r", with: "")
        }
        if let diagRes = diagnostics.resolution, !diagRes.isEmpty {
            return diagRes
        }
        return mediaInfo?.maxFormatHeight.map { "\($0)p" }
    }

    private func audioSubtitleParts() -> [String] {
        var parts: [String] = []
        if let quality = options.audioQuality, quality != .best {
            parts.append(quality.rawValue)
        }
        if let codec = options.audioCodec, codec != .auto {
            let codecName = codec.rawValue.uppercased()
            if codecName != options.fileType.rawValue.uppercased() {
                parts.append(codecName)
            }
        }
        return parts
    }

    private func subtitleSelectionPart(lang: LanguageService) -> String {
        let count = options.subtitleLanguages.count
        let localizedCount = count == 1 ? lang.s("subtitles_selected_one") : String(format: lang.s("subtitles_selected"), count)
        guard let format = options.subtitleFormat else { return localizedCount }
        return "\(localizedCount) (\(format.displayName))"
    }

    func errorUXInfo(lang: LanguageService) -> ErrorUXInfo? {
        guard let error = errorMessage ?? (status == .failed ? lang.s("generic_error_desc") : nil) else {
            return nil
        }
        let rawError = rawErrorDetails(fallback: error)
        // Partial jobs retain finished files and remain actionable for retry.
        if hasPartialFailure || status == .completed {
            return ErrorUXInfo(
                headline: lang.s("some_items_failed"),
                description: error,
                actionType: .retry,
                rawError: rawError
            )
        }
        let advice = errorAdvice(for: error, lang: lang)
        return ErrorUXInfo(
            headline: lang.s("couldnt_download"),
            description: advice.description,
            actionType: advice.action,
            rawError: rawError
        )
    }

    /// The details box shows only the first lines, so yt-dlp's own error goes on top.
    private func rawErrorDetails(fallback error: String) -> String {
        guard !log.isEmpty else { return error }
        guard let terminalError = log.range(of: "ERROR:", options: .backwards) else { return log }
        return "\(log[log.lineRange(for: terminalError)].trimmingCharacters(in: .newlines))\n\n\(log)"
    }

    private struct ErrorRule {
        let matches: Bool
        let descriptionKey: String
        let action: ErrorActionType
    }

    private func errorAdvice(for error: String, lang: LanguageService) -> (description: String, action: ErrorActionType) {
        let lower = error.lowercased()
        // Missing dependency, not an unavailable video (its text says "not found").
        if lower.contains("yt-dlp executable not found") {
            return (error, .fixInSettings)
        }
        if let rule = errorRules(for: error, lower: lower, lang: lang).first(where: { $0.matches }) {
            return (lang.s(rule.descriptionKey), rule.action)
        }
        return (error.count > 60 ? lang.s("generic_error_desc") : error, .retry)
    }

    /// In priority order: the first match decides the advice.
    private func errorRules(for error: String, lower: String, lang: LanguageService) -> [ErrorRule] {
        let mentions: ([String]) -> Bool = { words in words.contains { lower.contains($0) } }
        let isYouTube = url.lowercased().contains("youtube.com") || url.lowercased().contains("youtu.be")
        return [
            ErrorRule(matches: isYouTube && lower.contains("sign in to confirm"), descriptionKey: "youtube_auth_required", action: .fixInSettings),
            ErrorRule(matches: mentions(["cloudflare", "anti-bot", "captcha", "challenge"]), descriptionKey: "anti_bot_desc", action: .retry),
            // Settings can't fix this one: the user signs in (Safari or Siphon's window), then retries.
            ErrorRule(matches: error == lang.s("site_sign_in_required"), descriptionKey: "site_sign_in_required_desc", action: .retry),
            // Checked before the cookie wording below: a 403 is often not a sign-in problem.
            ErrorRule(matches: error == lang.s("access_denied"), descriptionKey: "access_denied_desc", action: .retry),
            ErrorRule(matches: mentions(["sign in", "login", "cookies"]), descriptionKey: isYouTube ? "youtube_auth_required" : "login_required_desc", action: .fixInSettings),
            ErrorRule(matches: mentions(["drm"]), descriptionKey: "drm_protected_desc", action: .noAction),
            ErrorRule(matches: mentions(["unavailable", "private", "removed", "404", "not found"]), descriptionKey: "video_unavailable_desc", action: .retry),
            ErrorRule(matches: mentions(["no space left", "disk full", "disk space"]), descriptionKey: "disk_full_desc", action: .changeFolder),
            ErrorRule(matches: mentions(["permission denied"]), descriptionKey: "permission_denied_desc", action: .changeFolder),
            ErrorRule(matches: mentions(["timed out", "timeout", "connection"]), descriptionKey: "network_timeout_desc", action: .retry),
            ErrorRule(matches: mentions(["unsupported url"]), descriptionKey: "unsupported_url_desc", action: .noAction)
        ]
    }
}

extension DownloadStatus {
    func title(lang: LanguageService) -> String {
        switch self {
        case .fetching: return lang.s("fetching")
        case .queued: return lang.s("queued")
        case .downloading: return lang.s("downloading")
        case .processing: return lang.s("processing")
        case .completed: return lang.s("completed")
        case .failed: return lang.s("failed")
        case .stopped: return lang.s("stopped")
        case .paused: return lang.s("paused")
        case .fileExists: return lang.s("file_exists_status")
        }
    }
}

extension Download {
    enum ErrorActionType: Equatable {
        case fixInSettings
        case retry
        case changeFolder
        case noAction
    }

    struct ErrorUXInfo {
        let headline: String
        let description: String
        let actionType: ErrorActionType
        /// Unsanitized log text. Rows build this on every redraw, while the
        /// sanitized copy is needed only when the details are shown or copied.
        private let unsanitizedError: String
        var rawError: String { LogSanitizer.sanitizeDiagnosticText(unsanitizedError) }

        init(headline: String, description: String, actionType: ErrorActionType, rawError: String) {
            self.headline = headline
            self.description = description
            self.actionType = actionType
            self.unsanitizedError = rawError
        }
    }
}
