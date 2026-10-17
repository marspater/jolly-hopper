import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    @ViewBuilder
    func siphonFormStyle() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(OverlayScrollerStyle())
    }
}

/// Forms sit on Siphon's translucent window background, where legacy
/// (always-visible) scrollers draw a wide black track. Keep the window's scroll
/// views on the thin overlay style, also after the system preference flips when
/// a mouse connects (NSScrollView resets its own style on that notification).
private struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context _: Context) -> Probe { Probe() }
    func updateNSView(_: Probe, context _: Context) {}

    final class Probe: NSView {
        private var isObserving = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            if !isObserving {
                isObserving = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(preferredStyleChanged),
                    name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
                )
            }
            apply()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func preferredStyleChanged() {
            // Run after the scroll views' own handlers have reset their style.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        // The Form's scroll view is a sibling of this probe, not an ancestor.
        private func apply() {
            guard let root = window?.contentView else { return }
            var stack = [root]
            while let view = stack.popLast() {
                (view as? NSScrollView)?.scrollerStyle = .overlay
                stack.append(contentsOf: view.subviews)
            }
        }
    }
}

// MARK: - Adaptive Rendering Environment & Display Capabilities
public struct RenderingCapabilities: Sendable, Equatable {
    public let supportsEDR: Bool
    public let supportsP3: Bool
    public let reduceTransparency: Bool
    public let reduceMotion: Bool
    public let increaseContrast: Bool
    public let maxRefreshRate: Int

    public var isHighRefreshRate: Bool {
        maxRefreshRate >= 120
    }

    /// Siphon renders custom frame-scheduled animation at a 60 Hz baseline,
    /// stepping up to 120 Hz on displays that can actually present it.
    /// Physics timings remain identical across refresh rates.
    public var preferredAnimationFrameRate: Int {
        maxRefreshRate >= 120 ? 120 : 60
    }

    public var animationMinimumInterval: TimeInterval {
        1.0 / Double(preferredAnimationFrameRate)
    }

    public init(
        supportsEDR: Bool,
        supportsP3: Bool,
        reduceTransparency: Bool,
        reduceMotion: Bool = false,
        increaseContrast: Bool = false,
        maxRefreshRate: Int = 60
    ) {
        self.supportsEDR = supportsEDR
        self.supportsP3 = supportsP3
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        self.maxRefreshRate = maxRefreshRate
    }
}

@MainActor
public final class AdaptiveRenderingEnvironment: ObservableObject {
    public static let shared = AdaptiveRenderingEnvironment()

    @Published public private(set) var capabilities: RenderingCapabilities

    public var reduceMotion: Bool {
        capabilities.reduceMotion
    }

    public var isHighRefreshRate: Bool {
        capabilities.isHighRefreshRate
    }

    public var maxRefreshRate: Int {
        capabilities.maxRefreshRate
    }
    @Published public var isAppActive: Bool = true

    public var shouldAnimateAmbient: Bool {
        isAppActive && !capabilities.reduceMotion
    }

    private init() {
        self.capabilities = Self.detectCapabilities()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppActive = true
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppActive = false
            }
        }
    }

    public func refresh() {
        self.capabilities = Self.detectCapabilities()
    }

    public static func detectCapabilities() -> RenderingCapabilities {
        detectCapabilities(for: NSScreen.main)
    }

    public static func detectCapabilities(for screen: NSScreen?) -> RenderingCapabilities {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let supportsEDR: Bool
        let supportsP3: Bool
        let maxRate: Int

        if let screen {
            supportsEDR =
                screen.maximumExtendedDynamicRangeColorComponentValue > 1.0 ||
                screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
            supportsP3 = screen.canRepresent(.p3) || screen.colorSpace == .displayP3
            maxRate = max(60, screen.maximumFramesPerSecond)
        } else {
            supportsEDR = false
            supportsP3 = false
            maxRate = 60
        }

        return RenderingCapabilities(
            supportsEDR: supportsEDR,
            supportsP3: supportsP3,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
            increaseContrast: increaseContrast,
            maxRefreshRate: maxRate
        )
    }
}

public enum SiphonAnimation {
    @MainActor
    public static var fluidSpring: Animation {
        .spring(response: 0.34, dampingFraction: 0.76, blendDuration: 0)
    }

    @MainActor
    public static var hoverSpring: Animation {
        .spring(response: 0.26, dampingFraction: 0.70, blendDuration: 0)
    }

    @MainActor
    public static var bouncySpring: Animation {
        .spring(response: 0.28, dampingFraction: 0.60, blendDuration: 0)
    }

    @MainActor
    public static var snappySpring: Animation {
        .spring(response: 0.20, dampingFraction: 0.78, blendDuration: 0)
    }

    public static let panelRevealDuration: TimeInterval = 0.34
    public static let panelReveal = Animation.easeInOut(duration: panelRevealDuration)

    /// Shared tactile motion used by all custom button styles. These values are
    /// independent of refresh rate; 120 Hz displays simply sample them more often.
    public static let buttonPressSpring = Animation.spring(
        response: 0.24,
        dampingFraction: 0.68,
        blendDuration: 0
    )
    public static let buttonHoverSpring = Animation.spring(
        response: 0.28,
        dampingFraction: 0.72,
        blendDuration: 0
    )
}

// MARK: - Per-window Rendering Capabilities

private struct SiphonRenderingCapabilitiesKey: EnvironmentKey {
    static let defaultValue = RenderingCapabilities(
        supportsEDR: false,
        supportsP3: false,
        reduceTransparency: false,
        reduceMotion: false,
        maxRefreshRate: 60
    )
}

extension EnvironmentValues {
    var siphonRenderingCapabilities: RenderingCapabilities {
        get { self[SiphonRenderingCapabilitiesKey.self] }
        set { self[SiphonRenderingCapabilitiesKey.self] = newValue }
    }
}

@MainActor
private final class SiphonScreenObserverView: NSView {
    var onScreenChange: ((NSScreen?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenProfileNotification, object: nil)

        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenDidChange),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenDidChange),
                name: NSWindow.didChangeScreenProfileNotification,
                object: window
            )
        }

        onScreenChange?(window?.screen)
    }

    @objc private func screenDidChange() {
        onScreenChange?(window?.screen)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private struct SiphonScreenObserver: NSViewRepresentable {
    let onScreenChange: (NSScreen?) -> Void

    func makeNSView(context _: Context) -> SiphonScreenObserverView {
        let view = SiphonScreenObserverView()
        view.onScreenChange = onScreenChange
        return view
    }

    func updateNSView(_ nsView: SiphonScreenObserverView, context _: Context) {
        nsView.onScreenChange = onScreenChange
    }
}

@MainActor
private struct SiphonAdaptiveRenderingModifier: ViewModifier {
    @State private var activeScreen: NSScreen?
    @State private var capabilities = RenderingCapabilities(
        supportsEDR: false,
        supportsP3: false,
        reduceTransparency: false,
        reduceMotion: false,
        maxRefreshRate: 60
    )

    func body(content: Content) -> some View {
        content
            .environment(\.siphonRenderingCapabilities, capabilities)
            .background(
                SiphonScreenObserver { screen in
                    activeScreen = screen
                    refresh(for: screen)
                }
                .frame(width: 0, height: 0)
            )
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
                )
            ) { _ in
                refresh(for: activeScreen)
            }
    }

    private func refresh(for screen: NSScreen?) {
        capabilities = AdaptiveRenderingEnvironment.detectCapabilities(for: screen)
    }
}

// MARK: - Reusable Managed Transient Feedback Pattern
@MainActor
public final class TransientFeedbackState: ObservableObject {
    public struct Item: Equatable {
        public let id = UUID()
        public let message: String
        public let isSuccess: Bool
        public let icon: String?

        public init(message: String, isSuccess: Bool, icon: String? = nil) {
            self.message = message
            self.isSuccess = isSuccess
            self.icon = icon
        }
    }

    @Published public private(set) var current: Item?
    private var dismissTask: Task<Void, Never>?

    public init() {
        // Intentionally empty initializer for ObservableObject instantiation (swift:S1186)
    }

    public var isShowing: Bool { current != nil }

    /// Shows `message` and schedules its dismissal. A repeat call cancels the
    /// pending dismissal, so each confirmation stays up for its full duration.
    public func show(
        _ message: String,
        isSuccess: Bool,
        icon: String? = nil,
        duration: TimeInterval = 3.5
    ) {
        dismissTask?.cancel()
        withAnimation(SiphonAnimation.snappySpring) {
            current = Item(message: message, isSuccess: isSuccess, icon: icon)
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(SiphonAnimation.snappySpring) {
                self?.current = nil
            }
        }
    }

    public func clear() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    deinit {
        dismissTask?.cancel()
    }
}

// MARK: - Standardized Siphon Design System & Theme
public enum SiphonTheme {
    // Palette: every Siphon-owned color is authored in Display P3 from one
    // OKLCH system. Each semantic hue keeps a single hue angle for its fill and
    // text tones; fills sit at ~95% of the P3 chroma limit for their lightness,
    // text tones are solved for >= 5:1 against the window surface.
    // Brand hues: cyan 222 · blue 258 · indigo 266 · violet 292.

    // Brand blue ramp (hue 258): accentText(dark) .73 · accent .60 · accentDeep .54 · accentInk .48
    public static let accent = Color(.displayP3, red: 0.198, green: 0.462, blue: 0.976, opacity: 1.0)      // oklch(0.60 0.224 258)
    public static let accentDeep = Color(.displayP3, red: 0.064, green: 0.373, blue: 0.929, opacity: 1.0)  // oklch(0.54 0.241 258)
    /// Darkest accent stop, leaning indigo. Keeps white primary-button labels at
    /// or above 4.5:1 across the whole gradient.
    public static let accentInk = Color(.displayP3, red: 0.122, green: 0.194, blue: 0.936, opacity: 1.0)   // oklch(0.48 0.282 266)
    public static let accentSecondary = Color(.displayP3, red: 0.150, green: 0.767, blue: 0.982, opacity: 1.0) // oklch(0.76 0.177 222)
    public static let accentViolet = Color(.displayP3, red: 0.431, green: 0.107, blue: 0.939, opacity: 1.0)    // oklch(0.52 0.284 292)
    public static let sourceYouTube = Color(.displayP3, red: 0.96, green: 0.08, blue: 0.08, opacity: 1.0)
    public static let primaryGradient = LinearGradient(
        colors: [
            accentDeep,
            accentInk
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Semantic Status Colors (Display P3 with graceful sRGB fallback).
    // Use these saturated values for fills, rings, tints and motion only.
    public static let statusDownloading = accent
    public static let statusQueued = Color(.displayP3, red: 0.973, green: 0.595, blue: 0.129, opacity: 1.0)    // oklch(0.77 0.192 62)
    public static let statusCompleted = Color(.displayP3, red: 0.132, green: 0.762, blue: 0.292, opacity: 1.0) // oklch(0.70 0.255 150)
    public static let statusFailed = Color(.displayP3, red: 0.960, green: 0.131, blue: 0.191, opacity: 1.0)    // oklch(0.64 0.278 25)
    public static let statusHdr = Color(.displayP3, red: 0.990, green: 0.722, blue: 0.161, opacity: 1.0)       // oklch(0.83 0.187 78)
    public static let statusHdrSecondary = Color(.displayP3, red: 0.965, green: 0.472, blue: 0.114, opacity: 1.0) // oklch(0.72 0.212 48)
    /// Label on the HDR gradient. White on amber reads under 2:1; this deep brown reads above 8:1.
    public static let hdrLabel = Color(.displayP3, red: 0.20, green: 0.09, blue: 0.0, opacity: 1.0)

    // MARK: - Readable Text Colors
    // Text and small icons need at least 4.5:1 against the window surface in
    // both appearances, which the saturated fills above do not reach. Each tone
    // shares its fill's hue; amber and green fills already clear 5:1 in Dark.
    private static let accentTextLight = accentDeep
    private static let accentTextDark = Color(.displayP3, red: 0.472, green: 0.653, blue: 0.990, opacity: 1.0)          // oklch(0.73 0.148 258)
    private static let statusQueuedTextLight = Color(.displayP3, red: 0.578, green: 0.341, blue: 0.036, opacity: 1.0)   // oklch(0.52 0.133 62)
    private static let statusCompletedTextLight = Color(.displayP3, red: 0.044, green: 0.483, blue: 0.166, opacity: 1.0) // oklch(0.50 0.186 150)
    private static let statusFailedTextLight = Color(.displayP3, red: 0.791, green: 0.070, blue: 0.139, opacity: 1.0)   // oklch(0.55 0.244 25)
    private static let statusFailedTextDark = Color(.displayP3, red: 0.992, green: 0.498, blue: 0.459, opacity: 1.0)    // oklch(0.75 0.187 25)

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }

    /// Accent-colored text, links and small icons.
    public static let accentText = adaptive(light: accentTextLight, dark: accentTextDark)
    public static let statusDownloadingText = accentText
    public static let statusQueuedText = adaptive(light: statusQueuedTextLight, dark: statusQueued)
    public static let statusCompletedText = adaptive(light: statusCompletedTextLight, dark: statusCompleted)
    public static let statusFailedText = adaptive(light: statusFailedTextLight, dark: statusFailedTextDark)

    static func statusForeground(for status: DownloadStatus, colorScheme: ColorScheme) -> Color {
        let isDark = colorScheme == .dark
        switch status {
        case .downloading, .fetching, .processing: return isDark ? accentTextDark : accentTextLight
        case .queued, .paused, .fileExists: return isDark ? statusQueued : statusQueuedTextLight
        case .completed: return isDark ? statusCompleted : statusCompletedTextLight
        case .failed, .stopped: return isDark ? statusFailedTextDark : statusFailedTextLight
        }
    }

    public static func accentForeground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? accentTextDark : accentTextLight
    }

    // MARK: - AppKit Theme Synchronization
    @MainActor
    public static func applyTheme(_ theme: String) {
        let appearance: NSAppearance?
        switch theme.lowercased() {
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
        case "light":
            appearance = NSAppearance(named: .aqua)
        default:
            appearance = nil
        }

        NSApp.appearance = appearance
        MenuBarManager.shared.applyTheme()
        for window in NSApp.windows {
            window.appearance = appearance
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
        }
    }

    // Standard Spacing Scale (4pt/8pt rhythm)
    public static let spacing2: CGFloat = 2
    public static let spacing4: CGFloat = 4
    public static let spacing6: CGFloat = 6
    public static let spacing8: CGFloat = 8
    public static let spacing10: CGFloat = 10
    public static let spacing12: CGFloat = 12
    public static let spacing14: CGFloat = 14
    public static let spacing16: CGFloat = 16
    public static let spacing20: CGFloat = 20
    public static let spacing24: CGFloat = 24
    public static let spacing32: CGFloat = 32

    // MARK: - Semantic Adaptive Surfaces & Tokens
    public static var surface: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    public static var surfaceElevated: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    public static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    public static var focusRing: Color {
        Color(nsColor: .keyboardFocusIndicatorColor)
    }

    public static var selection: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    /// Translucent lift for cards, pills and controls inside a window. Only the
    /// window root and floating bars carry a blur material; nested surfaces use
    /// this fill so the compositor samples the backdrop once.
    public static let surfaceRaised = adaptive(
        light: Color.white.opacity(0.40),
        dark: Color.white.opacity(0.05)
    )

    public static var destructiveSurface: Color {
        statusFailed.opacity(0.12)
    }

    // Semantic Radii Tokens (continuous corners):
    // 6 = tags, compact metadata, code blocks
    // 8 = buttons, inputs, controls, selected sidebar rows
    // 12 = cards, list rows, glass surfaces
    // 14 = home status bar group
    // 16 = modal/sheet containers
    // 24 = URL hero card (its URL field is concentric inside it)
    // Capsule = status badges, pills, compact selection
    public static let radiusSmall: CGFloat = 6
    public static let radiusControl: CGFloat = 8
    public static let radiusCard: CGFloat = 12
    public static let radiusStatusGroup: CGFloat = 14
    public static let radiusSheet: CGFloat = 16
    public static let radiusHero: CGFloat = 24

    // Shared translucency steps. Pair each with Color.primary or a tint.
    public enum Opacity {
        public static let fillCard: Double = 0.03
        public static let fillCardHover: Double = 0.065
        public static let fillPill: Double = 0.045
        public static let fillPillHover: Double = 0.09
        public static let fillGhostHover: Double = 0.08
        public static let fillPlaceholder: Double = 0.06
        public static let tintBadge: Double = 0.12
        public static let tintFieldFocus: Double = 0.10
        public static let tintSidebarSelected: Double = 0.18
        public static let borderHairline: Double = 0.08
        public static let borderRest: Double = 0.15
        public static let borderHover: Double = 0.26
        public static let borderIncreaseContrast: Double = 0.42
        public static let tintCallout: Double = 0.10
        public static let borderCallout: Double = 0.25
    }

    // Elevated Card & Tile Backgrounds (Unified macOS Translucent Glass)
    @ViewBuilder
    public static func cardBackground(cornerRadius: CGFloat = radiusCard, isHovered: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(surfaceRaised)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? Opacity.fillCardHover : Opacity.fillCard))
        }
    }

    // MARK: - Semantic Adaptive Borders
    @ViewBuilder
    public static func borderSubtle(cornerRadius: CGFloat = radiusControl, isHovered: Bool = false, accentColor: Color? = nil) -> some View {
        // Drawn on the GPU: as a plain layer, a gradient stroke is rasterized on
        // the CPU at the card's full size, once per row a list scrolls into view.
        Group {
            if let accent = accentColor {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                accent.opacity(isHovered ? 0.72 : 0.44),
                                accent.opacity(isHovered ? 0.30 : 0.14),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(isHovered ? 0.26 : 0.14),
                                Color.primary.opacity(isHovered ? 0.10 : 0.05),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
        }
        .drawingGroup()
        .overlay(IncreasedContrastEdge(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    public static func cardBorder(cornerRadius: CGFloat = radiusCard, isHovered: Bool = false, accentColor: Color? = nil) -> some View {
        // Drawn on the GPU: as a plain layer, a gradient stroke is rasterized on
        // the CPU at the card's full size, once per row a list scrolls into view.
        Group {
            if let accent = accentColor {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                accent.opacity(isHovered ? 0.62 : 0.42),
                                accent.opacity(isHovered ? 0.24 : 0.13),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(isHovered ? Opacity.borderHover : Opacity.borderRest),
                                Color.primary.opacity(isHovered ? 0.10 : 0.05),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
        }
        .drawingGroup()
        .overlay(IncreasedContrastEdge(cornerRadius: cornerRadius))
    }

    // Pill / Badge Backgrounds (Capsule)
    @ViewBuilder
    public static func pillBackground(isSelected: Bool = false, isHovered: Bool = false) -> some View {
        if isSelected {
            Capsule()
                .fill(primaryGradient)
                .shadow(color: accent.opacity(0.30), radius: 6, y: 2)
        } else {
            Capsule()
                .fill(Color.primary.opacity(isHovered ? Opacity.fillPillHover : Opacity.fillPill))
                .background(Capsule().fill(surfaceRaised))
        }
    }

    @ViewBuilder
    public static func tintedPillBackground(
        tint: Color,
        opacity: Double = Opacity.tintBadge
    ) -> some View {
        Capsule()
            .fill(tint.opacity(opacity))
            .background(Capsule().fill(surfaceRaised))
    }

    private static func pillBorderOpacity(showBorders: Bool, isHovered: Bool) -> Double {
        if showBorders {
            return Opacity.borderIncreaseContrast
        } else if isHovered {
            return 0.12
        } else {
            return 0.06
        }
    }

    @ViewBuilder
    public static func pillBorder(
        isSelected: Bool = false,
        isHovered: Bool = false,
        showBorders: Bool = false
    ) -> some View {
        if isSelected {
            Capsule()
                .stroke(
                    Color.primary.opacity(showBorders ? 0.50 : 0.25),
                    lineWidth: showBorders ? 1.5 : 1
                )
        } else {
            Capsule()
                .stroke(
                    Color.primary.opacity(pillBorderOpacity(showBorders: showBorders, isHovered: isHovered)),
                    lineWidth: showBorders ? 1.5 : 1
                )
        }
    }

    // Control / Button Backgrounds (Tactile glass surfaces)
    @ViewBuilder
    public static func controlBackground(cornerRadius: CGFloat = radiusControl, isHovered: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlColor).opacity(isHovered ? 0.68 : 0.46))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(isHovered ? 0.10 : 0.035),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    @ViewBuilder
    public static func controlBorder(cornerRadius: CGFloat = radiusControl, isHovered: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(isHovered ? 0.32 : 0.18),
                        Color.primary.opacity(isHovered ? 0.14 : 0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .drawingGroup()
            .overlay(IncreasedContrastEdge(cornerRadius: cornerRadius))
    }

    // Inset Field & Search/Path Box Background (Distinct contrast inside glass cards)
    @ViewBuilder
    public static func fieldBackground(cornerRadius: CGFloat = radiusControl, isFocused: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.64))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.045),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(accent.opacity(Opacity.tintFieldFocus))
            }
        }
    }

    @ViewBuilder
    public static func fieldBorder(cornerRadius: CGFloat = radiusControl, isFocused: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: isFocused
                        ? [accent.opacity(0.90), accent.opacity(0.48)]
                        : [
                            Color.primary.opacity(0.20),
                            Color.primary.opacity(0.07),
                            Color.clear
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: isFocused ? 2.0 : 1
            )
            .shadow(color: isFocused ? accent.opacity(0.18) : .clear, radius: isFocused ? 4 : 0)
            .overlay(IncreasedContrastEdge(cornerRadius: cornerRadius).opacity(isFocused ? 0 : 1))
    }

    // Settings & Diagnostics Subtle Divider
    @ViewBuilder
    public static var subtleDivider: some View {
        Divider()
            .overlay(separator)
    }
}

/// Increase Contrast / Show Borders: a solid hairline over a shared border,
/// whose faint gradient alone fades out. Drawn inside the border, so layout
/// does not change.
private struct IncreasedContrastEdge: View {
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if contrast == .increased {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(SiphonTheme.Opacity.borderIncreaseContrast), lineWidth: 1)
        }
    }
}

// MARK: - Adaptive Window Surface

public struct SiphonWindowBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {
        // Intentionally empty initializer for ViewModifier struct instantiation (swift:S1186)
    }

    public func body(content: Content) -> some View {
        content
            // Default for every Text, label and field in the window, so nothing
            // falls back to SF Pro; views still set their own Siphon font on top.
            .font(.siphonStandard)
            .tint(SiphonTheme.accent)
            .background(windowSurface)
            .background {
                // Faint brand wash behind the material, shared by every window.
                ZStack {
                    RadialGradient(
                        colors: [SiphonTheme.accentDeep.opacity(0.06), SiphonTheme.accentViolet.opacity(0.025), .clear],
                        center: .topLeading,
                        startRadius: 40,
                        endRadius: 650
                    )
                    RadialGradient(
                        colors: [SiphonTheme.accentSecondary.opacity(0.035), .clear],
                        center: .bottomTrailing,
                        startRadius: 60,
                        endRadius: 550
                    )
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
    }

    private var windowSurface: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(SiphonTheme.surfaceElevated)
        }
        // In Dark Mode a bright window behind ultra-thin glass turns it light
        // grey, under white and light-blue text. Regular glass stays dark.
        return AnyShapeStyle(colorScheme == .dark ? Material.regular : Material.ultraThin)
    }
}

// MARK: - Native Liquid Glass Surface

public struct SiphonGlassSurfaceModifier: ViewModifier {
    public var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = SiphonTheme.radiusCard) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            // Not .interactive(): this surface holds buttons, and interactive
            // glass swallows their hover tracking and press scale on macOS.
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay(SiphonTheme.cardBorder(cornerRadius: cornerRadius))
                .clipShape(shape)
        }
    }
}

// MARK: - Modern Smooth Spinner
public struct SiphonSpinner: View {
    public var size: CGFloat
    public var color: Color
    public var lineWidth: CGFloat

    @State private var isSpinning = false

    public init(size: CGFloat = 14, color: Color = .white, lineWidth: CGFloat = 2) {
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [color.opacity(0.2), color]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(Angle(degrees: isSpinning ? 360 : 0))
            .onAppear {
                withAnimation(
                    .linear(duration: 0.85)
                    .repeatForever(autoreverses: false)
                ) {
                    isSpinning = true
                }
            }
    }
}

// MARK: - Interactive Liquid Glass Control Sub-Components
public struct SiphonInteractiveGlassBackground: View {
    public var cornerRadius: CGFloat
    public var isHovered: Bool
    public var isSelected: Bool
    public var effectiveTint: Color

    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities

    public init(
        cornerRadius: CGFloat = SiphonTheme.radiusControl,
        isHovered: Bool = false,
        isSelected: Bool = false,
        effectiveTint: Color = SiphonTheme.accent
    ) {
        self.cornerRadius = cornerRadius
        self.isHovered = isHovered
        self.isSelected = isSelected
        self.effectiveTint = effectiveTint
    }

    private var overlayColor: Color {
        if isSelected {
            return effectiveTint.opacity(0.88)
        } else if isHovered {
            return effectiveTint.opacity(0.19)
        } else {
            return Color.primary.opacity(SiphonTheme.Opacity.fillPill)
        }
    }

    public var body: some View {
        ZStack {
            if isHovered && !isSelected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(effectiveTint.opacity(0.22))
                    .blur(radius: 8)
                    .padding(-1)
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlColor).opacity(isHovered ? 0.64 : 0.42))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(overlayColor)
        }
    }
}

public struct SiphonInteractiveGlassBorder: View {
    public var cornerRadius: CGFloat
    public var isHovered: Bool
    public var isSelected: Bool
    public var effectiveTint: Color

    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities

    public init(
        cornerRadius: CGFloat = SiphonTheme.radiusControl,
        isHovered: Bool = false,
        isSelected: Bool = false,
        effectiveTint: Color = SiphonTheme.accent
    ) {
        self.cornerRadius = cornerRadius
        self.isHovered = isHovered
        self.isSelected = isSelected
        self.effectiveTint = effectiveTint
    }

    private var showBorders: Bool {
        renderingCapabilities.increaseContrast
    }

    private var gradientColors: [Color] {
        if isSelected {
            return [effectiveTint.opacity(0.88), effectiveTint.opacity(0.44)]
        } else if isHovered {
            let topOpacity = showBorders ? 0.88 : 0.70
            let bottomOpacity = showBorders ? 0.46 : 0.28
            return [effectiveTint.opacity(topOpacity), effectiveTint.opacity(bottomOpacity)]
        } else {
            let topOpacity = showBorders ? 0.42 : 0.20
            let bottomOpacity = showBorders ? 0.20 : 0.07
            return [Color.primary.opacity(topOpacity), Color.primary.opacity(bottomOpacity)]
        }
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: showBorders ? 1.5 : 1
            )
    }
}

// MARK: - Interactive Liquid Glass Control Modifier & Environmental Field
public struct SiphonInteractiveGlassModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var isDestructive: Bool
    public var isSelected: Bool
    public var tintColor: Color?

    @State private var isHovered = false

    public init(
        cornerRadius: CGFloat = SiphonTheme.radiusControl,
        isDestructive: Bool = false,
        isSelected: Bool = false,
        tintColor: Color? = nil
    ) {
        self.cornerRadius = cornerRadius
        self.isDestructive = isDestructive
        self.isSelected = isSelected
        self.tintColor = tintColor
    }

    private func glassTint(_ tint: Color) -> Color? {
        if isSelected { return tint }
        return isHovered ? tint.opacity(0.19) : nil
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let effectiveTint = isDestructive ? SiphonTheme.statusFailed : (tintColor ?? SiphonTheme.accent)

        if #available(macOS 26.0, *) {
            // Interactive glass swallows pointer tracking on macOS: hover tints
            // and the button style's press scale stop, so tint on hover ourselves.
            content
                .glassEffect(
                    .regular.tint(glassTint(effectiveTint)),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .animation(SiphonAnimation.hoverSpring, value: isHovered)
                .animation(SiphonAnimation.fluidSpring, value: isSelected)
                .onHover { hovering in
                    isHovered = hovering
                }
        } else {
            content
                .background {
                    SiphonInteractiveGlassBackground(
                        cornerRadius: cornerRadius,
                        isHovered: isHovered,
                        isSelected: isSelected,
                        effectiveTint: effectiveTint
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    SiphonInteractiveGlassBorder(
                        cornerRadius: cornerRadius,
                        isHovered: isHovered,
                        isSelected: isSelected,
                        effectiveTint: effectiveTint
                    )
                )
                .shadow(color: Color.black.opacity(isHovered ? 0.16 : 0.08), radius: isHovered ? 4 : 2, y: 1)
                .animation(SiphonAnimation.hoverSpring, value: isHovered)
                .animation(SiphonAnimation.fluidSpring, value: isSelected)
                .onHover { hovering in
                    isHovered = hovering
                }
        }
    }
}

// MARK: - Fluid Bouncy Button Style
public struct BouncyButtonStyle: ButtonStyle {
    public var scaleAmount: CGFloat = 0.97
    public var hoverScale: CGFloat = 1.015

    @State private var isHovered = false

    public init(scaleAmount: CGFloat = 0.97, hoverScale: CGFloat = 1.015) {
        self.scaleAmount = scaleAmount
        self.hoverScale = hoverScale
    }

    private func buttonScale(isPressed: Bool) -> CGFloat {
        if isPressed {
            return scaleAmount
        } else if isHovered {
            return hoverScale
        } else {
            return 1.0
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .siphonMotionScale(buttonScale(isPressed: configuration.isPressed))
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == BouncyButtonStyle {
    public static var bouncy: BouncyButtonStyle { BouncyButtonStyle() }
    public static var bouncySubtle: BouncyButtonStyle {
        BouncyButtonStyle(scaleAmount: 0.985, hoverScale: 1.01)
    }
    public static func bouncy(scale: CGFloat = 0.97, hover: CGFloat = 1.015) -> BouncyButtonStyle {
        BouncyButtonStyle(scaleAmount: scale, hoverScale: hover)
    }
}

// MARK: - Standardized Siphon Button Styles
public struct SiphonPrimaryButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat = SiphonTheme.radiusControl
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    /// `.controlSize(.small)` gives the compact size used in rows and callouts.
    @Environment(\.controlSize) private var controlSize

    private var isCompact: Bool { controlSize == .small || controlSize == .mini }

    public init(cornerRadius: CGFloat = SiphonTheme.radiusControl) {
        self.cornerRadius = cornerRadius
    }

    private func buttonScale(isPressed: Bool) -> CGFloat {
        if !isEnabled {
            return 1.0
        } else if isPressed {
            return 0.965
        } else if isHovered {
            return 1.02
        } else {
            return 1.0
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .siphonMetadataSemibold : .siphonStandardSemibold)
            .foregroundColor(isEnabled ? .white : .secondary)
            .frame(minHeight: isCompact ? 14 : 18, alignment: .center)
            .padding(.horizontal, isCompact ? SiphonTheme.spacing10 : SiphonTheme.spacing16)
            .padding(.vertical, isCompact ? 3 : 6)
            .background {
                // Disabled primary actions drop to a neutral well so the
                // gradient only ever advertises an action that can succeed.
                if isEnabled {
                    SiphonTheme.primaryGradient
                } else {
                    Color.primary.opacity(SiphonTheme.Opacity.fillGhostHover)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isEnabled ? Color.white.opacity(0.25) : Color.primary.opacity(SiphonTheme.Opacity.fillGhostHover), lineWidth: 1)
            )
            .shadow(color: isEnabled ? SiphonTheme.accent.opacity(isHovered ? 0.35 : 0.20) : .clear, radius: isHovered ? 8 : 4, y: 2)
            .siphonMotionScale(buttonScale(isPressed: configuration.isPressed))
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonSecondaryButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat = SiphonTheme.radiusControl
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    /// `.controlSize(.small)` gives the compact size used in rows and callouts.
    @Environment(\.controlSize) private var controlSize

    private var isCompact: Bool { controlSize == .small || controlSize == .mini }

    public init(cornerRadius: CGFloat = SiphonTheme.radiusControl) {
        self.cornerRadius = cornerRadius
    }

    private func buttonScale(isPressed: Bool) -> CGFloat {
        if isPressed {
            return 0.97
        } else if isHovered {
            return 1.018
        } else {
            return 1.0
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .siphonMetadataMedium : .siphonStandardMedium)
            .foregroundColor(.primary)
            .frame(minHeight: isCompact ? 14 : 18, alignment: .center)
            .padding(.horizontal, isCompact ? SiphonTheme.spacing10 : SiphonTheme.spacing14)
            .padding(.vertical, isCompact ? 3 : 6)
            .background(SiphonTheme.controlBackground(cornerRadius: cornerRadius, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                SiphonTheme.controlBorder(cornerRadius: cornerRadius, isHovered: isHovered)
            )
            .siphonMotionScale(buttonScale(isPressed: configuration.isPressed))
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
            .opacity(isEnabled ? 1.0 : 0.45)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonGhostButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat = SiphonTheme.radiusControl
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities

    public init(cornerRadius: CGFloat = SiphonTheme.radiusControl) {
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        let showBorders = renderingCapabilities.increaseContrast
        configuration.label
            .font(.siphonSecondaryMedium)
            .foregroundColor(isHovered ? .primary : .secondary)
            .frame(minHeight: 16, alignment: .center)
            .padding(.horizontal, SiphonTheme.spacing10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? SiphonTheme.Opacity.fillGhostHover : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.secondary.opacity(showBorders ? 0.65 : 0.0), lineWidth: 1)
            )
            .siphonMotionScale(configuration.isPressed ? 0.97 : 1.0)
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
            .opacity(isEnabled ? 1.0 : 0.45)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonIconButtonStyle: ButtonStyle {
    public var size: CGFloat = 26
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities

    public init(size: CGFloat = 26) {
        self.size = size
    }

    private func buttonScale(isPressed: Bool) -> CGFloat {
        if isPressed {
            return 0.92
        } else if isHovered {
            return 1.06
        } else {
            return 1.0
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        let showBorders = renderingCapabilities.increaseContrast
        return configuration.label
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color.primary.opacity(isHovered ? SiphonTheme.Opacity.fillGhostHover : 0.0))
            )
            .overlay(
                Circle()
                    .stroke(Color.secondary.opacity(showBorders ? 0.65 : 0.0), lineWidth: 1)
            )
            .siphonMotionScale(buttonScale(isPressed: configuration.isPressed))
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
            .opacity(isEnabled ? 1.0 : 0.45)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == SiphonPrimaryButtonStyle {
    public static var siphonPrimary: SiphonPrimaryButtonStyle { SiphonPrimaryButtonStyle() }
    public static func siphonPrimary(cornerRadius: CGFloat = SiphonTheme.radiusControl) -> SiphonPrimaryButtonStyle {
        SiphonPrimaryButtonStyle(cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == SiphonSecondaryButtonStyle {
    public static var siphonSecondary: SiphonSecondaryButtonStyle { SiphonSecondaryButtonStyle() }
    public static func siphonSecondary(cornerRadius: CGFloat = SiphonTheme.radiusControl) -> SiphonSecondaryButtonStyle {
        SiphonSecondaryButtonStyle(cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == SiphonGhostButtonStyle {
    public static var siphonGhost: SiphonGhostButtonStyle { SiphonGhostButtonStyle() }
    public static func siphonGhost(cornerRadius: CGFloat = SiphonTheme.radiusControl) -> SiphonGhostButtonStyle {
        SiphonGhostButtonStyle(cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == SiphonIconButtonStyle {
    public static var siphonIcon: SiphonIconButtonStyle { SiphonIconButtonStyle() }
    public static func siphonIcon(size: CGFloat = 26) -> SiphonIconButtonStyle {
        SiphonIconButtonStyle(size: size)
    }
}

// MARK: - Shared Animated Card Lift
public struct SiphonCardHoverModifier: ViewModifier {
    public let isHovered: Bool
    public var tint: Color = SiphonTheme.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        let lifts = isHovered && !reduceMotion
        content
            .scaleEffect(lifts ? 1.012 : 1.0)
            .offset(y: lifts ? -2 : 0)
            .shadow(
                color: tint.opacity(isHovered ? 0.20 : 0.035),
                radius: isHovered ? 14 : 4,
                y: isHovered ? 5 : 2
            )
    }
}

/// Scale feedback for hover and press. Under Reduce Motion the view stays at
/// its size; tint, border and shadow changes still show the state.
private struct SiphonMotionScaleModifier: ViewModifier {
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.scaleEffect(reduceMotion ? 1.0 : scale)
    }
}

extension View {
    func siphonMotionScale(_ scale: CGFloat) -> some View {
        modifier(SiphonMotionScaleModifier(scale: scale))
    }
}

extension View {
    /// Lift and shadow for a hovered card. The caller sets `isHovered` inside
    /// `withAnimation(SiphonAnimation.hoverSpring)`, so the card's background,
    /// border and lift share one transaction.
    public func siphonCardHover(isHovered: Bool, tint: Color = SiphonTheme.accent) -> some View {
        modifier(SiphonCardHoverModifier(isHovered: isHovered, tint: tint))
    }
}

// MARK: - Menu Picker
/// Label chrome for a Siphon pop-up: content, an up/down chevron and the
/// control surface. Use inside `Menu { } label:` with `siphonMenuStyle()`.
struct SiphonMenuLabel<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var isCompact: Bool { controlSize == .small || controlSize == .mini }
    private var cornerRadius: CGFloat { isCompact ? SiphonTheme.radiusSmall : SiphonTheme.radiusControl }

    var body: some View {
        HStack(spacing: SiphonTheme.spacing6) {
            content
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: isCompact ? 8 : 9, weight: .semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .font(isCompact ? .siphonMetadata : .siphonStandard)
        .foregroundColor(.primary)
        .padding(.horizontal, isCompact ? SiphonTheme.spacing8 : SiphonTheme.spacing10)
        .padding(.vertical, isCompact ? 2 : 4)
        .background(SiphonTheme.controlBackground(cornerRadius: cornerRadius, isHovered: isHovered && isEnabled))
        .overlay(SiphonTheme.controlBorder(cornerRadius: cornerRadius, isHovered: isHovered && isEnabled))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .opacity(isEnabled ? 1.0 : 0.45)
        .animation(SiphonAnimation.hoverSpring, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Inset text field chrome: field fill and border, plus the 2 pt accent focus
/// edge while the field is focused in the key window.
private struct SiphonFieldModifier: ViewModifier {
    let isFocused: Bool
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SiphonTheme.radiusControl, style: .continuous)
        let showsFocus = isFocused && appearsActive
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, SiphonTheme.spacing10)
            .padding(.vertical, SiphonTheme.spacing6)
            .background(SiphonTheme.fieldBackground(isFocused: showsFocus))
            .clipShape(shape)
            .overlay(SiphonTheme.fieldBorder(isFocused: showsFocus))
            .animation(SiphonAnimation.snappySpring, value: showsFocus)
    }
}

extension View {
    /// Siphon's inset field. Use instead of `.textFieldStyle(.roundedBorder)`,
    /// whose AppKit bezel does not match the field tokens.
    func siphonField(isFocused: Bool = false) -> some View {
        modifier(SiphonFieldModifier(isFocused: isFocused))
    }

    /// Menu presentation whose label SwiftUI draws as authored. The default,
    /// `.borderlessButton` and `.borderedButton` menu styles hand the label to an
    /// AppKit button that ignores SwiftUI fonts and renders SF Pro.
    func siphonMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}

/// Siphon's pop-up choice. A `.menu` Picker hands its title to an AppKit pop-up
/// button that ignores SwiftUI fonts, so the chosen value rendered in SF Pro;
/// this draws the closed state in Geist and keeps native menu items, with a
/// checkmark on the current choice.
struct SiphonMenuPicker<Value: Hashable>: View {
    typealias Option = (value: Value, title: String)

    private let label: String?
    private let fillsWidth: Bool
    @Binding private var selection: Value
    private let sections: [(header: String?, options: [Option])]

    /// `label` adds a leading title, laid out like a Form row.
    init(_ label: String? = nil, selection: Binding<Value>, fillsWidth: Bool = false, options: [Option]) {
        self.init(label, selection: selection, fillsWidth: fillsWidth, sections: [(nil, options)])
    }

    init(_ label: String? = nil, selection: Binding<Value>, fillsWidth: Bool = false, sections: [(header: String?, options: [Option])]) {
        self.label = label
        self.fillsWidth = fillsWidth
        _selection = selection
        self.sections = sections.filter { !$0.options.isEmpty }
    }

    private var currentTitle: String {
        sections.lazy.flatMap(\.options).first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        if let label {
            LabeledContent(label) { menu }
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            Picker(label ?? "", selection: $selection) {
                ForEach(sections.indices, id: \.self) { index in
                    let section = sections[index]
                    if let header = section.header {
                        Section(header) { items(section.options) }
                    } else {
                        items(section.options)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            SiphonMenuLabel {
                Text(currentTitle).truncationMode(.tail)
                if fillsWidth { Spacer(minLength: 0) }
            }
        }
        .siphonMenuStyle()
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .help(currentTitle)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(currentTitle)
    }

    private func items(_ options: [Option]) -> some View {
        ForEach(options.indices, id: \.self) { index in
            Text(options[index].title).tag(options[index].value)
        }
    }
}

// MARK: - Segmented Capsule Picker
/// Siphon's only segmented control. The selected option rides a
/// primary-gradient bubble that slides between segments.
struct SiphonSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var horizontalPadding: CGFloat = SiphonTheme.spacing12
    /// SF Symbol shown before an option's title.
    var icon: (Value) -> String? = { _ in nil }
    /// Full-width bar of equal segments, 38 pt tall (Settings tabs).
    var isLarge = false
    var fillsWidth = false

    @Namespace private var bubble
    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities

    var body: some View {
        HStack(spacing: SiphonTheme.spacing2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    withAnimation(SiphonAnimation.fluidSpring) {
                        selection = option.value
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = icon(option.value) {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        Text(option.title)
                            .font(isLarge ? .siphonSecondarySemibold : .siphonMetadataSemibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundColor(isSelected ? .white : .secondary)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, SiphonTheme.spacing4)
                    .frame(maxWidth: isLarge || fillsWidth ? .infinity : nil, maxHeight: isLarge ? .infinity : nil)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(SiphonTheme.primaryGradient)
                                .shadow(color: SiphonTheme.accent.opacity(0.30), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "bubble", in: bubble)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.bouncy)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(SiphonTheme.spacing2)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .frame(height: isLarge ? 38 : nil)
        .background(SiphonTheme.pillBackground(isSelected: false))
        .clipShape(Capsule())
        .overlay(SiphonTheme.pillBorder(isSelected: false, showBorders: renderingCapabilities.increaseContrast))
    }
}

// MARK: - Standardized Badges & Indicators
struct SiphonStatusBadge: View {
    let status: DownloadStatus
    let title: String
    let foregroundColor: Color

    init(status: DownloadStatus, title: String, foregroundColor: Color) {
        self.status = status
        self.title = title
        self.foregroundColor = foregroundColor
    }

    public var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .downloading, .fetching, .processing:
                SiphonSpinner(size: 10, color: foregroundColor, lineWidth: 1.8)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            case .stopped:
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            case .queued:
                Image(systemName: "clock.fill")
                    .font(.system(size: 11, weight: .semibold))
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            case .fileExists:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            }

            Text(title)
                .font(.siphonMetadataSemibold)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .foregroundColor(foregroundColor)
        .background(
            SiphonTheme.tintedPillBackground(
                tint: foregroundColor,
                opacity: SiphonTheme.Opacity.tintBadge
            )
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            foregroundColor.opacity(0.40),
                            foregroundColor.opacity(0.12),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .drawingGroup()
        )
        // The glyph only restates the title; VoiceOver reads the title once.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

public struct SiphonTagBadge: View {
    public let text: String
    public var systemImage: String?
    public var tintColor: Color = .secondary
    public var isHdr: Bool = false
    public var isMonospaced: Bool = false

    public init(
        text: String,
        systemImage: String? = nil,
        tintColor: Color = .secondary,
        isHdr: Bool = false,
        isMonospaced: Bool = false
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tintColor = tintColor
        self.isHdr = isHdr
        self.isMonospaced = isMonospaced
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon = systemImage {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }

            Text(text)
                .font(isMonospaced ? .siphonMicroMonoSemibold : .siphonMicroSemibold)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .foregroundColor(isHdr ? SiphonTheme.hdrLabel : tintColor)
        .background {
            if isHdr {
                LinearGradient(
                    colors: [SiphonTheme.statusHdr, SiphonTheme.statusHdrSecondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                tintColor.opacity(SiphonTheme.Opacity.tintBadge)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall, style: .continuous)
                .strokeBorder(
                    isHdr ? Color.white.opacity(0.3) : tintColor.opacity(0.22),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Standardized Empty State View
public struct SiphonEmptyStateView: View {
    public let icon: String
    public let title: String
    public let message: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: SiphonTheme.spacing16) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.7))
                    .accessibilityHidden(true)
            }

            VStack(spacing: SiphonTheme.spacing6) {
                Text(title)
                    .font(.siphonHeadline)
                    .foregroundColor(.primary)
                Text(message)
                    .font(.siphonStandard)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack(spacing: SiphonTheme.spacing6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(actionTitle)
                            .font(.siphonStandardSemibold)
                    }
                }
                .buttonStyle(.siphonPrimary(cornerRadius: SiphonTheme.radiusControl))
                .padding(.top, SiphonTheme.spacing4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SiphonTheme.spacing32)
    }
}

// MARK: - Window & Glass Surface Modifiers
extension View {
    /// Uses the app's glass surface while respecting Reduce Transparency, and
    /// sets Siphon's default font for the whole window.
    public func siphonWindowBackground() -> some View {
        modifier(SiphonWindowBackgroundModifier())
    }

    /// Uses native interactive Liquid Glass on macOS 26+ with the existing
    /// adaptive material treatment as a fallback.
    public func siphonGlassSurface(cornerRadius: CGFloat = SiphonTheme.radiusCard) -> some View {
        modifier(SiphonGlassSurfaceModifier(cornerRadius: cornerRadius))
    }
}

extension View {
    /// Tinted inline notice (permission hints, errors, playlist banners).
    /// `tint` is the saturated status or accent colour, never a `*Text` token.
    public func siphonCallout(tint: Color, cornerRadius: CGFloat = SiphonTheme.radiusControl) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(tint.opacity(SiphonTheme.Opacity.tintCallout), in: shape)
            .overlay(shape.stroke(tint.opacity(SiphonTheme.Opacity.borderCallout), lineWidth: 1))
    }
}

extension View {
    /// Injects display capabilities for the screen that currently contains this
    /// window. Custom frame-scheduled animation uses 60 Hz by default and 120 Hz
    /// only on displays that support it.
    public func siphonAdaptiveRendering() -> some View {
        modifier(SiphonAdaptiveRenderingModifier())
    }
}

extension View {
    @ViewBuilder
    public func siphonInteractiveGlass(
        cornerRadius: CGFloat = SiphonTheme.radiusControl,
        isDestructive: Bool = false,
        isSelected: Bool = false,
        tintColor: Color? = nil
    ) -> some View {
        self.modifier(
            SiphonInteractiveGlassModifier(
                cornerRadius: cornerRadius,
                isDestructive: isDestructive,
                isSelected: isSelected,
                tintColor: tintColor
            )
        )
    }
}

// MARK: - Section Header
// Kept at the end of the file: static analyzers misread this constrained
// result-builder initializer and attribute the following declarations to it.
extension Section where Parent == Text, Footer == EmptyView, Content: View {
    /// Form and sidebar section with a Geist header. `Section("title")` draws
    /// its header in the system font, or in the window's regular body font.
    init(siphonHeader title: String, font: Font = .siphonStandardSemibold, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title).font(font) })
    }
}
