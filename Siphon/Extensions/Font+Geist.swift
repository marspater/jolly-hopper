import SwiftUI
import CoreText

extension Font {
    /// Custom Geist Sans font (Vercel & Basement Studio typeface)
    public static func geist(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
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
        return .custom(fontName, size: size)
    }

    /// Custom Geist Mono font (Vercel & Basement Studio monospaced typeface)
    public static func geistMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
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
        return .custom(fontName, size: size)
    }
}

public struct GeistFontRegistrar {
    private static var isRegistered = false

    public static func registerFonts() {
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
