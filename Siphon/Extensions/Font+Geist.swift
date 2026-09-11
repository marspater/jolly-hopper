import SwiftUI
import CoreText

extension Font {
    /// Custom Geist Sans font (Vercel & Basement Studio typeface)
    public static func geist(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        let fontName: String
        switch weight {
        case .black:
            fontName = "Geist-Black"
        case .bold:
            fontName = "Geist-Bold"
        case .heavy, .semibold:
            fontName = "Geist-SemiBold"
        case .medium:
            fontName = "Geist-Medium"
        default:
            fontName = "Geist-Regular"
        }
        return .custom(fontName, size: size, relativeTo: textStyle)
    }

    /// Custom Geist Mono font (Vercel & Basement Studio monospaced typeface)
    public static func geistMono(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        let fontName: String
        switch weight {
        case .bold, .heavy, .black:
            fontName = "GeistMono-Bold"
        case .semibold:
            fontName = "GeistMono-SemiBold"
        case .medium:
            fontName = "GeistMono-Medium"
        default:
            fontName = "GeistMono-Regular"
        }
        return .custom(fontName, size: size, relativeTo: textStyle)
    }

    // MARK: - Standardized Semantic Typography Scale
    // UI Scale
    public static var siphonMetadata: Font { .geist(11, weight: .regular, relativeTo: .caption) }
    public static var siphonMetadataMedium: Font { .geist(11, weight: .medium, relativeTo: .caption) }
    public static var siphonMetadataSemibold: Font { .geist(11, weight: .semibold, relativeTo: .caption) }
    public static var siphonMetadataMono: Font { .geistMono(11, weight: .regular, relativeTo: .caption) }
    public static var siphonMetadataMonoSemibold: Font { .geistMono(11, weight: .semibold, relativeTo: .caption) }

    public static var siphonSecondary: Font { .geist(12, weight: .regular, relativeTo: .subheadline) }
    public static var siphonSecondaryMedium: Font { .geist(12, weight: .medium, relativeTo: .subheadline) }
    public static var siphonSecondarySemibold: Font { .geist(12, weight: .semibold, relativeTo: .subheadline) }

    public static var siphonStandard: Font { .geist(13, weight: .regular, relativeTo: .body) }
    public static var siphonStandardMedium: Font { .geist(13, weight: .medium, relativeTo: .body) }
    public static var siphonStandardSemibold: Font { .geist(13, weight: .semibold, relativeTo: .body) }

    public static var siphonPrimary: Font { .geist(14, weight: .medium, relativeTo: .headline) }
    public static var siphonPrimarySemibold: Font { .geist(14, weight: .semibold, relativeTo: .headline) }

    public static var siphonWindowTitle: Font { .geist(18, weight: .semibold, relativeTo: .title3) }

    // Display Scale
    public static var siphonKPI: Font { .geist(26, weight: .bold, relativeTo: .title) }
    public static var siphonHomeTitle: Font { .geist(30, weight: .bold, relativeTo: .largeTitle) }
}

public struct GeistFontRegistrar {
    @MainActor private static var isRegistered = false

    @MainActor public static func registerFonts() {
        guard !isRegistered else { return }
        isRegistered = true

        let fontFiles = [
            "Geist-Regular.otf",
            "Geist-Medium.otf",
            "Geist-SemiBold.otf",
            "Geist-Bold.otf",
            "Geist-Black.otf",
            "GeistMono-Regular.otf",
            "GeistMono-Medium.otf",
            "GeistMono-SemiBold.otf",
            "GeistMono-Bold.otf"
        ]

        for fontFile in fontFiles {
            let name = (fontFile as NSString).deletingPathExtension
            let ext = (fontFile as NSString).pathExtension

            if let url = Bundle.main.url(forResource: name, withExtension: ext) ??
                         Bundle.main.url(forResource: fontFile, withExtension: nil) {
                CTFontManagerRegisterFontURLs([url] as CFArray, .process, true, nil)
            }
        }
    }
}
