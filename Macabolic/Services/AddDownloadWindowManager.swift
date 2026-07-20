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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.isReleasedWhenClosed = false
        window.title = "Add New Download"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = hostingController
        window.delegate = self
        
        // Liquid glass backdrop
        let visualEffectView = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .sidebar
        visualEffectView.state = .active
        
        if let contentView = window.contentView {
            contentView.addSubview(visualEffectView, positioned: .below, relativeTo: nil)
        }
        
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
