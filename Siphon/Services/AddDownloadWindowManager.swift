import SwiftUI
import AppKit

@MainActor
final class AddDownloadWindowManager: NSObject, NSWindowDelegate {
    static let shared = AddDownloadWindowManager()
    
    private var windowController: NSWindowController?
    
    func showAddDownloadWindow(downloadManager: DownloadManager, appState: AppState, languageService: LanguageService) {
        if let existingController = windowController, let existingWindow = existingController.window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let addDownloadView = AddDownloadView()
            .environmentObject(downloadManager)
            .environmentObject(appState)
            .environmentObject(languageService)
        
        let hostingController = NSHostingController(rootView: addDownloadView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
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
        window.title = "Add New Download"
        window.minSize = NSSize(width: 520, height: 420)
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
