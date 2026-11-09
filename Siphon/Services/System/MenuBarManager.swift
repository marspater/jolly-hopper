import SwiftUI
import AppKit
import SiphonCore

@MainActor
class MenuBarManager: NSObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var languageService: LanguageService?
    private var downloadManager: DownloadManager?
    private var openMainWindow: (() -> Void)?

    func setup(languageService: LanguageService, downloadManager: DownloadManager, openMainWindow: @escaping () -> Void) {
        if statusItem != nil || UITestLaunchMode.isActive { return }

        self.languageService = languageService
        self.downloadManager = downloadManager
        self.openMainWindow = openMainWindow

        // Setup Popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.behavior = .transient

        // Adaptive rendering sits above MenuBarView so the view itself reads live
        // capabilities (Increase Contrast), not only its descendants.
        let contentView = MenuBarView()
            .siphonAdaptiveRendering()
            .environmentObject(languageService)
            .environmentObject(downloadManager)

        popover.contentViewController = NSHostingController(rootView: contentView.defaultAppStorage(UITestLaunchMode.storage))
        self.popover = popover
        applyTheme()

        // Setup Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateStatusItemIcon(button: button)
            if #available(macOS 27.0, *) {
                statusItem?.expandedInterfaceDelegate = self
                popover.delegate = self
            } else {
                button.action = #selector(togglePopover)
                button.target = self
            }
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
                showPopover(from: button)
            }
        }
    }

    fileprivate func showPopover(from button: NSStatusBarButton) {
        applyTheme()
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Focus the app
        NSApp.bringToFront()
    }

    /// Brings the main window forward, or opens one when it was closed (for
    /// example after starting in the background).
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.bringToFront()
        if let window = NSApp.windows.first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SiphonMainWindow") }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
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

@available(macOS 27.0, *)
extension MenuBarManager: @MainActor NSStatusItemExpandedInterfaceDelegate, NSPopoverDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin _: NSStatusItemExpandedInterfaceSession) {
        if let button = statusItem.button { showPopover(from: button) }
    }

    func statusItemDidEndExpandedInterfaceSession(_: NSStatusItem, animated _: Bool) {
        closePopover()
    }

    /// The popover also closes by itself (a click elsewhere, `closePopover()`);
    /// the menu bar must be told, or the item stays in its expanded state.
    func popoverDidClose(_: Notification) {
        statusItem?.expandedInterfaceSession?.cancel()
    }
}

extension NSApplication {
    /// Cooperative activation on macOS 27. Older systems keep the forced call,
    /// so their window-raising behavior does not change.
    func bringToFront() {
        if #available(macOS 27.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
