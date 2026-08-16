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
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.behavior = .transient
        
        let contentView = MenuBarView()
            .environmentObject(languageService)
            .environmentObject(downloadManager)
        
        popover.contentViewController = NSHostingController(rootView: contentView)
        self.popover = popover
        applyTheme()
        
        // Setup Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            updateStatusItemIcon(button: button)
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // Show by default (if key not set, show the icon)
        let showIcon = UserDefaults.standard.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool ?? true
        if !showIcon {
            statusItem?.isVisible = false
        }
    }
    
    private func updateStatusItemIcon(button: NSStatusBarButton) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15.5, weight: .semibold, scale: .medium)
        if let baseImage = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Siphon") {
            let configuredImage = baseImage.withSymbolConfiguration(symbolConfig) ?? baseImage
            configuredImage.isTemplate = true
            button.image = configuredImage
            button.imagePosition = .imageOnly
        }
    }

    func applyTheme() {
        let theme = UserDefaults.standard.string(forKey: UserDefaultsKeys.theme) ?? "system"
        switch theme {
        case "dark":
            popover?.appearance = NSAppearance(named: .darkAqua)
        case "light":
            popover?.appearance = NSAppearance(named: .aqua)
        default:
            popover?.appearance = nil
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
                applyTheme()
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
        applyTheme()
        if let button = statusItem?.button {
            updateStatusItemIcon(button: button)
        }
    }
}
