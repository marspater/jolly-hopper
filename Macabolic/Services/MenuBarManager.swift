import SwiftUI
import AppKit

@MainActor
class MenuBarManager: NSObject {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var languageService: LanguageService?
    private var downloadManager: DownloadManager?
    
    func setup(languageService: LanguageService, downloadManager: DownloadManager) {
        if statusItem != nil { return }
        
        self.languageService = languageService
        self.downloadManager = downloadManager
        
        // Setup Popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        
        let contentView = MenuBarView()
            .environmentObject(languageService)
            .environmentObject(downloadManager)
        
        popover.contentViewController = NSHostingController(rootView: contentView)
        self.popover = popover
        
        // Setup Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Macabolic")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // Show by default (if key not set, show the icon)
        let showIcon = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        if !showIcon {
            statusItem?.isVisible = false
        }
    }
    
    func setVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
    }
    
    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                // Focus the app
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func closePopover() {
        popover?.performClose(nil)
    }
    
    func updateMenu() {
        // Menu is now a SwiftUI view, so it updates automatically via EnvironmentObject
        // But we can force a resize if needed or other updates here
    }
}
