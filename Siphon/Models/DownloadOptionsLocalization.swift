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
