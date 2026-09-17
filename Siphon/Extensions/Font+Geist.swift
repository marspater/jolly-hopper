import SwiftUI
import Foundation
import CoreText

extension Font {
    private static let geistSansFontNames: [Font.Weight: String] = [
        .black: "Geist-Black",
        .bold: "Geist-Bold",
        .heavy: "Geist-SemiBold",
        .semibold: "Geist-SemiBold",
        .medium: "Geist-Medium"
    ]

    private static let geistMonoFontNames: [Font.Weight: String] = [
        .bold: "GeistMono-Bold",
        .heavy: "GeistMono-Bold",
        .black: "GeistMono-Bold",
        .semibold: "GeistMono-SemiBold",
        .medium: "GeistMono-Medium"
    ]

    /// Custom Geist Sans font (Vercel & Basement Studio typeface)
    public static func geist(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        let fontName = geistSansFontNames[weight] ?? "Geist-Regular"
        return .custom(fontName, size: size, relativeTo: textStyle)
    }

    /// Custom Geist Mono font (Vercel & Basement Studio monospaced typeface)
    public static func geistMono(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        let fontName = geistMonoFontNames[weight] ?? "GeistMono-Regular"
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
    public static var siphonKPI: Font { .geist(32, weight: .bold, relativeTo: .largeTitle) }
    public static var siphonHomeTitle: Font { .geist(30, weight: .bold, relativeTo: .largeTitle) }
}

public struct GeistFontRegistrar {
    @MainActor private static var isRegistered = false

    /// List of font resource filenames to register.
    public static let fontFiles = [
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

    @MainActor public static func registerFonts() {
        guard !isRegistered else { return }
        isRegistered = true

        registerFontResources(fontFiles, from: .main)
    }

    /// Registers a list of font resource files from the specified bundle with CoreText.
    @discardableResult
    public static func registerFontResources(_ fontFiles: [String], from bundle: Bundle = .main) -> Bool {
        let urls = fontFiles.compactMap { locateResource(for: $0, in: bundle) }
        guard !urls.isEmpty else { return false }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        return true
    }

    /// Resolves the URL for a resource file name (with or without extension) in a bundle.
    public static func locateResource(for fileName: String, in bundle: Bundle = .main) -> URL? {
        let fileURL = URL(fileURLWithPath: fileName)
        let name = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension

        let pathExtension: String? = ext.isEmpty ? nil : ext
        return bundle.url(forResource: name, withExtension: pathExtension) ??
               bundle.url(forResource: fileName, withExtension: nil)
    }
}
