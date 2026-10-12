import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlaybackWindowManager: NSObject, NSWindowDelegate {
    static let shared = PlaybackWindowManager()
    private let service = PlaybackService()
    private var windowController: NSWindowController?
    private var loadTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    func open(_ source: PlaybackSource) {
        importTask?.cancel()
        let localFile: URL?
        if case .localFile(let url) = source { localFile = url } else { localFile = nil }
        showWindow(acceptsStreamURL: false, localFile: localFile)
        load(source)
    }

    func showStreamWindow() {
        importTask?.cancel()
        showWindow(acceptsStreamURL: true, localFile: nil)
    }

    func chooseLocalFile() {
        importTask?.cancel()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if PlaybackSourceResolver.prefersNativePlayer(url) { open(.localFile(url)) }
        else { NSWorkspace.shared.open(url) }
    }

    func chooseStreamFile() {
        importTask?.cancel()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importTask?.cancel()
        importTask = Task { [weak self] in
            do {
                let source = try await Task.detached(priority: .userInitiated) {
                    try PlaybackSourceDescriptor.read(from: url)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                self.loadTask?.cancel()
                self.service.stop()
                self.showWindow(acceptsStreamURL: false, localFile: nil, configuredSource: source)
            } catch is CancellationError {
                // Closing/replacing playback invalidates a pending import.
            } catch {
                guard !Task.isCancelled else { return }
                let alert = NSAlert()
                alert.messageText = LanguageService.s("playback_import_failed")
                alert.informativeText = ((error as? PlaybackError) ?? .invalidDescriptor).localizedDescription
                alert.addButton(withTitle: LanguageService.s("ok"))
                alert.runModal()
            }
        }
    }

    private func load(_ source: PlaybackSource) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.load(source)
                try Task.checkCancellation()
                service.play()
            } catch is CancellationError {
                // Superseded selection or closed window.
            } catch {
                // PlaybackService owns the localized failure shown in the player.
            }
        }
    }

    private func showWindow(acceptsStreamURL: Bool, localFile: URL?, configuredSource: PlaybackSource? = nil) {
        let view = PlayerView(service: service, acceptsStreamURL: acceptsStreamURL, localFile: localFile, configuredSource: configuredSource) { [weak self] source in
            self?.importTask?.cancel()
            self?.load(source)
        }
        if let window = windowController?.window {
            window.contentViewController = NSHostingController(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = LanguageService.s("playback_player")
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.delegate = self
        window.center()
        windowController = NSWindowController(window: window)
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        importTask?.cancel()
        importTask = nil
        loadTask?.cancel()
        loadTask = nil
        service.stop()
        windowController?.close()
        windowController = nil
    }

    func windowWillClose(_ notification: Notification) {
        importTask?.cancel()
        importTask = nil
        loadTask?.cancel()
        loadTask = nil
        service.stop()
        windowController = nil
    }
}
