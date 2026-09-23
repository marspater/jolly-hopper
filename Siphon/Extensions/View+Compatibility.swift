import SwiftUI
#if os(macOS)
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let nsView = NSVisualEffectView()
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        return nsView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
#endif

extension View {
    @ViewBuilder
    func siphonFormStyle() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
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

public enum MaterialMode: Sendable, Equatable {
    case glass      // Standard liquid glass with restrained translucency
    case opaque     // Accessibility Reduce Transparency fallback
}

public enum ColorGamut: Sendable, Equatable {
    case p3         // Wide Display P3 color gamut
    case sRGB       // Standard sRGB color fallback
}

@MainActor
public final class AdaptiveRenderingEnvironment: ObservableObject {
    public static let shared = AdaptiveRenderingEnvironment()
    
    @Published public private(set) var capabilities: RenderingCapabilities
    
    public var materialMode: MaterialMode {
        .glass
    }
    
    public var colorGamut: ColorGamut {
        capabilities.supportsP3 ? .p3 : .sRGB
    }

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
        isAppActive
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
        NotificationCenter.default.removeObserver(self)

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

    public func show(_ message: String, isSuccess: Bool, icon: String? = nil, duration: TimeInterval = 3.5) {
        dismissTask?.cancel()
        current = Item(message: message, isSuccess: isSuccess, icon: icon)
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.current = nil
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
    // Primary Accent & Gradients with Display P3 wide color gamut support
    public static let accent = Color(.displayP3, red: 0.10, green: 0.48, blue: 1.0, opacity: 1.0)
    public static let accentDeep = Color(.displayP3, red: 0.06, green: 0.40, blue: 0.94, opacity: 1.0)
    /// Darkest accent stop. Keeps white primary-button labels at or above 4.5:1
    /// across the whole gradient.
    public static let accentInk = Color(.displayP3, red: 0.04, green: 0.32, blue: 0.82, opacity: 1.0)
    public static let accentSecondary = Color(.displayP3, red: 0.10, green: 0.76, blue: 0.98, opacity: 1.0)
    public static let accentViolet = Color(.displayP3, red: 0.38, green: 0.24, blue: 0.82, opacity: 1.0)
    public static let backdropBlue = Color(.displayP3, red: 0.10, green: 0.38, blue: 0.90, opacity: 1.0)
    public static let backdropViolet = Color(.displayP3, red: 0.32, green: 0.16, blue: 0.70, opacity: 1.0)
    public static let backdropCyan = Color(.displayP3, red: 0.06, green: 0.55, blue: 0.85, opacity: 1.0)
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
    public static let statusDownloading = Color(.displayP3, red: 0.08, green: 0.48, blue: 0.98, opacity: 1.0)
    public static let statusQueued = Color(.displayP3, red: 0.96, green: 0.55, blue: 0.10, opacity: 1.0)
    public static let statusCompleted = Color(.displayP3, red: 0.18, green: 0.72, blue: 0.38, opacity: 1.0)
    public static let statusFailed = Color(.displayP3, red: 0.94, green: 0.26, blue: 0.30, opacity: 1.0)
    public static let statusHdr = Color(.displayP3, red: 0.98, green: 0.65, blue: 0.15, opacity: 1.0)
    public static let statusHdrSecondary = Color(.displayP3, red: 1.0, green: 0.46, blue: 0.08, opacity: 1.0)
    /// Label on the HDR gradient. White on amber reads under 2:1; this deep brown reads above 8:1.
    public static let hdrLabel = Color(.displayP3, red: 0.20, green: 0.09, blue: 0.0, opacity: 1.0)

    // MARK: - Readable Text Colors
    // Text and small icons need at least 4.5:1 against the window surface in
    // both appearances, which the saturated fills above do not reach.
    private static let accentTextLight = Color(.displayP3, red: 0.02, green: 0.34, blue: 0.76, opacity: 1.0)
    private static let accentTextDark = Color(.displayP3, red: 0.36, green: 0.62, blue: 1.0, opacity: 1.0)
    private static let statusQueuedTextLight = Color(.displayP3, red: 0.62, green: 0.30, blue: 0.0, opacity: 1.0)
    private static let statusCompletedTextLight = Color(.displayP3, red: 0.06, green: 0.43, blue: 0.19, opacity: 1.0)
    private static let statusFailedTextLight = Color(.displayP3, red: 0.76, green: 0.10, blue: 0.16, opacity: 1.0)
    private static let statusFailedTextDark = Color(.displayP3, red: 1.0, green: 0.42, blue: 0.44, opacity: 1.0)

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }

    /// Accent-colored text, links and small icons.
    public static let accentText = adaptive(light: accentTextLight, dark: accentTextDark)
    public static let statusDownloadingText = adaptive(light: accentTextLight, dark: accentTextDark)
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

    public static var destructiveSurface: Color {
        statusFailed.opacity(0.12)
    }

    // Semantic Radii Tokens (continuous corners):
    // 6 = tags, compact metadata, code blocks
    // 8 = buttons, inputs, controls, selected sidebar rows
    // 12 = cards, list rows, glass surfaces
    // 14 = home status bar group
    // 16 = modal/sheet containers
    // 18 = URL hero card
    // Capsule = status badges, pills, compact selection
    public static let radiusSmall: CGFloat = 6
    public static let radiusControl: CGFloat = 8
    public static let radiusCard: CGFloat = 12
    public static let radiusStatusGroup: CGFloat = 14
    public static let radiusSheet: CGFloat = 16
    public static let radiusHero: CGFloat = 18

    // Shared translucency steps. Pair each with Color.primary or a tint.
    public enum Opacity {
        public static let fillCard: Double = 0.03
        public static let fillCardHover: Double = 0.065
        public static let fillPill: Double = 0.045
        public static let fillPillHover: Double = 0.09
        public static let fillGhostHover: Double = 0.08
        public static let tintBadge: Double = 0.12
        public static let tintFieldFocus: Double = 0.10
        public static let tintSidebarSelected: Double = 0.18
        public static let borderRest: Double = 0.15
        public static let borderHover: Double = 0.26
        public static let borderIncreaseContrast: Double = 0.42
    }
    
    // Elevated Card & Tile Backgrounds (Unified macOS Translucent Glass)
    @ViewBuilder
    public static func cardBackground(cornerRadius: CGFloat = radiusCard, isHovered: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? Opacity.fillCardHover : Opacity.fillCard))
        }
    }
    
    // MARK: - Semantic Adaptive Borders
    @ViewBuilder
    public static func borderSubtle(cornerRadius: CGFloat = radiusControl, isHovered: Bool = false, accentColor: Color? = nil) -> some View {
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

    @ViewBuilder
    public static func cardBorder(cornerRadius: CGFloat = radiusCard, isHovered: Bool = false, accentColor: Color? = nil) -> some View {
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
                .background(
                    Capsule()
                        .fill(.thinMaterial)
                )
        }
    }
    
    @ViewBuilder
    public static func tintedPillBackground(
        tint: Color,
        opacity: Double = Opacity.tintBadge
    ) -> some View {
        Capsule()
            .fill(tint.opacity(opacity))
            .background(
                Capsule()
                    .fill(.thinMaterial)
            )
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
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)
                )

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
    }

    // Inset Field & Search/Path Box Background (Distinct contrast inside glass cards)
    @ViewBuilder
    public static func fieldBackground(cornerRadius: CGFloat = radiusControl, isFocused: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.64))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)
                )

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
    }
    
    // Settings & Diagnostics Subtle Divider
    @ViewBuilder
    public static var subtleDivider: some View {
        Divider()
            .overlay(separator)
    }
}

// MARK: - Adaptive Window Surface

public struct SiphonWindowBackgroundModifier: ViewModifier {
    public init() {
        // Intentionally empty initializer for ViewModifier struct instantiation (swift:S1186)
    }

    public func body(content: Content) -> some View {
        content.background(.ultraThinMaterial)
    }
}

// MARK: - Native Liquid Glass Surface

public struct SiphonGlassSurfaceModifier: ViewModifier {
    public var cornerRadius: CGFloat

    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared

    public init(cornerRadius: CGFloat = SiphonTheme.radiusCard) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
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
    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared
    
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
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)
                )

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
    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared
    
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
    
    public func body(content: Content) -> some View {
        let effectiveTint = isDestructive ? SiphonTheme.statusFailed : (tintColor ?? SiphonTheme.accent)
        
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
            .scaleEffect(isHovered ? 1.012 : 1.0)
            .animation(SiphonAnimation.hoverSpring, value: isHovered)
            .animation(SiphonAnimation.fluidSpring, value: isSelected)
            .onHover { hovering in
                isHovered = hovering
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
            .scaleEffect(buttonScale(isPressed: configuration.isPressed))
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
    
    public init(cornerRadius: CGFloat = SiphonTheme.radiusControl) {
        self.cornerRadius = cornerRadius
    }
    
    private func buttonScale(isPressed: Bool) -> CGFloat {
        if isPressed {
            return 0.965
        } else if isHovered {
            return 1.02
        } else {
            return 1.0
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.siphonStandardSemibold)
            .foregroundColor(.white)
            .frame(minHeight: 18, alignment: .center)
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.vertical, 6)
            .background(SiphonTheme.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: SiphonTheme.accent.opacity(isHovered ? 0.35 : 0.20), radius: isHovered ? 8 : 4, y: 2)
            .scaleEffect(buttonScale(isPressed: configuration.isPressed))
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonSecondaryButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat = SiphonTheme.radiusControl
    @State private var isHovered = false
    
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
            .font(.siphonStandardMedium)
            .foregroundColor(.primary)
            .frame(minHeight: 18, alignment: .center)
            .padding(.horizontal, SiphonTheme.spacing14)
            .padding(.vertical, 6)
            .background(SiphonTheme.controlBackground(cornerRadius: cornerRadius, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                SiphonTheme.controlBorder(cornerRadius: cornerRadius, isHovered: isHovered)
            )
            .scaleEffect(buttonScale(isPressed: configuration.isPressed))
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonGhostButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat = SiphonTheme.radiusControl
    @State private var isHovered = false
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
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isHovered ? SiphonTheme.Opacity.fillGhostHover : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.secondary.opacity(showBorders ? 0.65 : 0.0), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonIconButtonStyle: ButtonStyle {
    public var size: CGFloat = 26
    @State private var isHovered = false
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
            .scaleEffect(buttonScale(isPressed: configuration.isPressed))
            .animation(SiphonAnimation.buttonPressSpring, value: configuration.isPressed)
            .animation(SiphonAnimation.buttonHoverSpring, value: isHovered)
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

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.012 : 1.0)
            .offset(y: isHovered ? -2 : 0)
            .shadow(
                color: tint.opacity(isHovered ? 0.20 : 0.035),
                radius: isHovered ? 14 : 4,
                y: isHovered ? 5 : 2
            )
            .animation(SiphonAnimation.bouncySpring, value: isHovered)
    }
}

extension View {
    public func siphonCardHover(isHovered: Bool, tint: Color = SiphonTheme.accent) -> some View {
        modifier(SiphonCardHoverModifier(isHovered: isHovered, tint: tint))
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
        )
    }
}

public struct SiphonTagBadge: View {
    public let text: String
    public var systemImage: String? = nil
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
        .clipShape(RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: SiphonTheme.radiusSmall)
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
    public var actionTitle: String? = nil
    public var action: (() -> Void)? = nil
    
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
    /// Uses the app's glass surface while respecting Reduce Transparency.
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
    
    @ViewBuilder
    public func siphonEnvironmentalBackdrop() -> some View {
        self.background(
            ZStack {
                RadialGradient(
                    gradient: Gradient(colors: [
                        SiphonTheme.backdropBlue.opacity(0.06),
                        SiphonTheme.backdropViolet.opacity(0.025),
                        Color.clear
                    ]),
                    center: .topLeading,
                    startRadius: 40,
                    endRadius: 650
                )
                
                RadialGradient(
                    gradient: Gradient(colors: [
                        SiphonTheme.backdropCyan.opacity(0.035),
                        Color.clear
                    ]),
                    center: .bottomTrailing,
                    startRadius: 60,
                    endRadius: 550
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }
}
