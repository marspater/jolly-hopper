import SwiftUI
import AppKit

struct ReadOnlyLogView: NSViewRepresentable {
    var text: String
    var fontSize: CGFloat = 11

    final class Coordinator {
        private var cachedFontSize: CGFloat = 0
        private var cachedAttrs: [NSAttributedString.Key: Any] = [:]

        func attrs(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
            if fontSize == cachedFontSize && !cachedAttrs.isEmpty {
                return cachedAttrs
            }
            let geistFont = NSFont(name: "GeistMono-Regular", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let newAttrs: [NSAttributedString.Key: Any] = [
                .font: geistFont,
                .foregroundColor: NSColor.labelColor
            ]
            cachedFontSize = fontSize
            cachedAttrs = newAttrs
            return newAttrs
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let geistFont = NSFont(name: "GeistMono-Regular", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.font = geistFont
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.clear
        textView.drawsBackground = false
        textView.importsGraphics = false
        textView.isRichText = false

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Bolt Performance Optimization: Read `textView.string` once into a local constant and use cached font attributes in Coordinator
        // and safe character-boundary slicing (`dropFirst`) to eliminate multiple Objective-C string bridging allocations,
        // repeated system font table lookups, and dictionary allocations during high-frequency log updates.
        let currentText = textView.string
        if currentText != text {
            if !currentText.isEmpty && text.hasPrefix(currentText) {
                let appendText = String(text.dropFirst(currentText.count))
                if let storage = textView.textStorage {
                    let attrString = NSAttributedString(string: appendText, attributes: context.coordinator.attrs(fontSize: fontSize))
                    storage.append(attrString)
                } else {
                    textView.string = text
                }
            } else {
                textView.string = text
                let geistFont = NSFont(name: "GeistMono-Regular", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                textView.font = geistFont
                textView.textColor = NSColor.labelColor
            }

            // Auto-scroll to bottom on update
            let range = NSRange(location: text.utf16.count, length: 0)
            textView.scrollRangeToVisible(range)
        }
    }
}
