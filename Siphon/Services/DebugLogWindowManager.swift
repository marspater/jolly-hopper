import SwiftUI
import AppKit

@MainActor
final class DebugLogWindowManager: NSObject, NSWindowDelegate {
    static let shared = DebugLogWindowManager()

    private var windowController: NSWindowController?

    func showDebugLogWindow() {
        if let existingController = windowController, let existingWindow = existingController.window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let debugView = DebugLogView()

        let hostingController = NSHostingController(rootView: debugView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.title = "Debug Logs"
        window.minSize = NSSize(width: 550, height: 350)
        window.contentViewController = hostingController
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.windowController = controller

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        windowController?.window?.close()
        windowController = nil
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
    }
}
