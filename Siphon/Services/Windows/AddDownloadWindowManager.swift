import SwiftUI
import AppKit

@MainActor
final class AddDownloadWindowManager: NSObject, NSWindowDelegate {
    static let shared = AddDownloadWindowManager()

    private var windowController: NSWindowController?

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

        let window = NSWindow(
            // Starts at the URL card's height; growToFit(overflow:) adds room
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
        window.minSize = NSSize(width: 480, height: Self.compactHeight)
        window.contentViewController = hostingController
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.windowController = controller

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Header, URL card and footer, below the title bar.
    static let compactHeight: CGFloat = 230

    /// Grows the window by `overflow` points with its top edge fixed, staying
    /// inside the screen's visible frame. It never shrinks a window the user
    /// made larger.
    func growToFit(overflow: CGFloat) {
        guard overflow > 0.5, let window = windowController?.window else { return }
        var frame = window.frame
        frame.size.height += overflow
        frame.origin.y -= overflow
        if let visible = window.screen?.visibleFrame {
            frame.size.height = min(frame.size.height, visible.height)
            frame.origin.y = max(frame.origin.y, visible.minY)
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    func closeWindow() {
        windowController?.window?.close()
        windowController = nil
    }

    func windowWillClose(_ _: Notification) {
        windowController = nil
    }
}
