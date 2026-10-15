import SwiftUI
import AppKit

@MainActor
final class AddDownloadWindowManager: NSObject, NSWindowDelegate {
    static let shared = AddDownloadWindowManager()

    private var windowController: NSWindowController?
    private var collapsedWidth: CGFloat?
    private var advancedVisible = false
    private var lastLayout: Layout?
    static let advancedPaneWidth: CGFloat = 400

    struct Layout: Equatable {
        var contentHeight: CGFloat
        var chromeHeight: CGFloat
        var advancedVisible: Bool
        var allowsShrink: Bool
    }

    func showAddDownloadWindow(downloadManager: DownloadManager, appState: AppState, languageService: LanguageService, updateChecker: UpdateChecker) {
        if let existingController = windowController, let existingWindow = existingController.window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let addDownloadView = AddDownloadView()
            .environmentObject(downloadManager)
            .environmentObject(appState)
            .environmentObject(languageService)
            .environmentObject(updateChecker)

        let hostingController = NSHostingController(rootView: addDownloadView)

        let window = AddDownloadWindow(
            // Starts at the URL card's height; updateLayout adds room
            // as fetched details or batch input appear.
            contentRect: NSRect(x: 0, y: 0, width: 520, height: Self.compactHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false
        window.title = languageService.s("new_download")
        window.minSize = NSSize(width: 500, height: Self.compactHeight)
        window.contentViewController = hostingController
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.windowController = controller

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Header, URL card and footer, below the title bar.
    nonisolated static let compactHeight: CGFloat = 230

    /// One frame update owns both the form height and the advanced pane width.
    /// Use absolute content height so intermediate viewport sizes cannot add
    /// stale overflow repeatedly while the window is resizing.
    func updateLayout(_ layout: Layout, animated: Bool = true) {
        guard layout.contentHeight > 0, layout.chromeHeight > 0,
              let window = windowController?.window else { return }
        // An unchanged form is resize feedback or a user's manual resize.
        // Do not resize the window in response to itself.
        guard lastLayout != layout else { return }
        let titleBarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let desiredHeight = ceil(layout.contentHeight + layout.chromeHeight + titleBarHeight)
        var frame = Self.grownFrame(window.frame, by: desiredHeight - window.frame.height,
                                    within: window.screen?.visibleFrame, allowShrink: layout.allowsShrink) ?? window.frame
        if layout.advancedVisible != advancedVisible {
            if layout.advancedVisible { collapsedWidth = window.frame.width }
            let width = collapsedWidth ?? window.frame.width
            frame = Self.sidePanelFrame(frame, width: layout.advancedVisible ? width + Self.advancedPaneWidth + 1 : width,
                                        within: window.screen?.visibleFrame)
        }
        window.minSize.width = 500
        if abs(frame.width - window.frame.width) > 0.5 || abs(frame.height - window.frame.height) > 0.5 {
            // This native resize settles before the next MainActor layout
            // request and keeps embedded AppKit controls redrawing throughout.
            window.setFrame(frame, display: true,
                            animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        advancedVisible = layout.advancedVisible
        window.minSize.width = advancedVisible ? 500 + Self.advancedPaneWidth + 1 : 500
        if !advancedVisible { collapsedWidth = nil }
        lastLayout = layout
    }

    /// `frame` taller by `overflow` with its top edge fixed, clamped to
    /// `visible`; nil when there is nothing to grow.
    nonisolated static func grownFrame(_ frame: NSRect, by overflow: CGFloat, within visible: NSRect?, allowShrink: Bool = false) -> NSRect? {
        guard overflow > 0.5 || (allowShrink && overflow < -0.5) else { return nil }
        var grown = frame
        grown.size.height = max(Self.compactHeight, frame.height + overflow)
        grown.origin.y = frame.maxY - grown.height
        if let visible {
            grown.size.height = min(grown.size.height, visible.height)
            grown.origin.y = max(grown.origin.y, visible.minY)
        }
        return grown
    }

    nonisolated static func sidePanelFrame(_ frame: NSRect, width: CGFloat, within visible: NSRect?) -> NSRect {
        var result = frame
        result.size.width = min(width, visible?.width ?? width)
        if let visible {
            result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        }
        return result
    }

    func closeWindow() {
        windowController?.window?.close()
        windowController = nil
    }

    func windowWillClose(_ _: Notification) {
        collapsedWidth = nil
        advancedVisible = false
        lastLayout = nil
        windowController = nil
    }
}

private final class AddDownloadWindow: NSWindow {
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        SiphonAnimation.panelRevealDuration
    }
}
