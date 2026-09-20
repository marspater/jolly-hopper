import SwiftUI
import AppKit

@MainActor
final class PreferencesWindowManager: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowManager()
    
    private var windowController: NSWindowController?
    
    func showPreferencesWindow(languageService: LanguageService, updateChecker: UpdateChecker, downloadManager: DownloadManager, initialTab: PreferencesView.PreferenceTab = .general) {
        if let existingController = windowController, let existingWindow = existingController.window {
            if existingWindow.frame.height > 690 || existingWindow.frame.height < 646 {
                var f = existingWindow.frame
                f.size.height = 662
                f.size.width = max(f.size.width, 520)
                existingWindow.setFrame(f, display: true, animate: true)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let prefsView = PreferencesView(initialTab: initialTab)
            .environmentObject(languageService)
            .environmentObject(updateChecker)
            .environmentObject(downloadManager)
        
        let hostingController = NSHostingController(rootView: prefsView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 662),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.title = languageService.s("preferences")
        window.minSize = NSSize(width: 500, height: 646)
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
    
    func windowWillClose(_ _: Notification) {
        windowController = nil
    }
}
