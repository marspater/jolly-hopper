import SwiftUI
import AppKit

struct ReadOnlyLogView: NSViewRepresentable {
    var text: String
    var fontSize: CGFloat = 11

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

        if textView.string != text {
            let oldLen = textView.string.count
            if oldLen > 0 && text.hasPrefix(textView.string) {
                let suffixIndex = text.index(text.startIndex, offsetBy: oldLen)
                let appendText = String(text[suffixIndex...])
                if let storage = textView.textStorage {
                    let geistFont = NSFont(name: "GeistMono-Regular", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: geistFont,
                        .foregroundColor: NSColor.labelColor
                    ]
                    let attrString = NSAttributedString(string: appendText, attributes: attrs)
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
