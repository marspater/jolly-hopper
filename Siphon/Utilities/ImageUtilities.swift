import AppKit
import QuickLookThumbnailing
import AVFoundation

public enum ImageUtilities {

    /// Generates a thumbnail image for a local file URL using QuickLookThumbnailing with AVFoundation fallback.
    /// - Parameters:
    ///   - url: The local file URL.
    ///   - size: Desired size in points (default: 240x136).
    ///   - scale: Display scale factor (default: 2.0).
    /// - Returns: An `NSImage` if a thumbnail could be generated, or `nil` otherwise.
    public static func generateThumbnail(
        for url: URL,
        size: CGSize = CGSize(width: 240, height: 136),
        scale: CGFloat = 2.0
    ) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        configureImageGenerator(generator)

        let time = CMTime(seconds: 1, preferredTimescale: 60)
        if let cgImage = try? await generator.image(at: time).image {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return nil
    }

    /// Configures video-frame thumbnail generation to preserve source color
    /// parameters. macOS 15+ can retain HDR metadata instead of silently
    /// tone-mapping every generated frame to SDR.
    static func configureImageGenerator(_ generator: AVAssetImageGenerator) {
        generator.appliesPreferredTrackTransform = true
        generator.dynamicRangePolicy = .matchSource
    }

    /// Resizes an `NSImage` into a square aspect-fit icon canvas.
    /// - Parameters:
    ///   - image: Source image to draw.
    ///   - targetSize: Canvas width and height (default: 512).
    /// - Returns: A square `NSImage` centered and aspect-fitted.
    public static func createAspectFitIcon(from image: NSImage, targetSize: CGFloat = 512) -> NSImage {
        let sourceSize = image.size
        guard sourceSize.width > 0 && sourceSize.height > 0 else { return image }

        let canvas = NSImage(size: NSSize(width: targetSize, height: targetSize))
        canvas.lockFocus()

        let widthRatio = targetSize / sourceSize.width
        let heightRatio = targetSize / sourceSize.height
        let scale = min(widthRatio, heightRatio)

        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        let x = (targetSize - scaledWidth) / 2.0
        let y = (targetSize - scaledHeight) / 2.0

        let destRect = NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight)
        let srcRect = NSRect(origin: .zero, size: sourceSize)

        image.draw(in: destRect, from: srcRect, operation: .copy, fraction: 1.0)
        canvas.unlockFocus()

        return canvas
    }
}
