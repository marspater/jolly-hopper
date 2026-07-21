import SwiftUI
import AppKit

@MainActor
final class PreferencesWindowManager: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowManager()
    
    private var windowController: NSWindowController?
    
    func showPreferencesWindow(languageService: LanguageService, updateChecker: UpdateChecker, downloadManager: DownloadManager) {
        if let existingController = windowController, let existingWindow = existingController.window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let prefsView = PreferencesView()
            .environmentObject(languageService)
            .environmentObject(updateChecker)
            .environmentObject(downloadManager)
        
        let hostingController = NSHostingController(rootView: prefsView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.isReleasedWhenClosed = false
        window.title = languageService.s("preferences")
        window.minSize = NSSize(width: 580, height: 500)
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
