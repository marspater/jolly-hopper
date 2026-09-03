import SwiftUI
#if os(macOS)
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let nsView = NSVisualEffectView()
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        return nsView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
#endif

extension View {
    @ViewBuilder
    func siphonFormStyle() -> some View {
        if #available(macOS 13.0, *) {
            self.formStyle(.grouped)
                .scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

// MARK: - Adaptive Rendering Environment & Display Capabilities
public struct RenderingCapabilities: Sendable, Equatable {
    public let supportsEDR: Bool
    public let supportsP3: Bool
    public let reduceTransparency: Bool
    public let reduceMotion: Bool
    
    public init(
        supportsEDR: Bool,
        supportsP3: Bool,
        reduceTransparency: Bool,
        reduceMotion: Bool = false
    ) {
        self.supportsEDR = supportsEDR
        self.supportsP3 = supportsP3
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
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
        capabilities.reduceTransparency ? .opaque : .glass
    }
    
    public var colorGamut: ColorGamut {
        capabilities.supportsP3 ? .p3 : .sRGB
    }

    public var reduceMotion: Bool {
        capabilities.reduceMotion
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
    }
    
    public func refresh() {
        self.capabilities = Self.detectCapabilities()
    }
    
    public static func detectCapabilities() -> RenderingCapabilities {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var supportsEDR = false
        var supportsP3 = false
        
        for screen in NSScreen.screens {
            if screen.maximumExtendedDynamicRangeColorComponentValue > 1.0 || screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0 {
                supportsEDR = true
            }
            if screen.canRepresent(.p3) || screen.colorSpace == .displayP3 {
                supportsP3 = true
            }
        }
        
        if NSScreen.main?.canRepresent(.p3) == true {
            supportsP3 = true
        }
        
        return RenderingCapabilities(
            supportsEDR: supportsEDR,
            supportsP3: supportsP3,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion
        )
    }
}

// MARK: - Standardized Siphon Design System & Theme
public enum SiphonTheme {
    // Primary Accent & Gradients with Display P3 wide color gamut support
    public static let accent = Color(.displayP3, red: 0.10, green: 0.48, blue: 1.0, opacity: 1.0)
    public static let primaryGradient = LinearGradient(
        colors: [
            Color(.displayP3, red: 0.18, green: 0.52, blue: 1.0, opacity: 1.0),
            Color(.displayP3, red: 0.06, green: 0.40, blue: 0.94, opacity: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // Semantic Status Colors (Display P3 with graceful sRGB fallback)
    public static let statusDownloading = Color(.displayP3, red: 0.08, green: 0.48, blue: 0.98, opacity: 1.0)
    public static let statusQueued = Color(.displayP3, red: 0.96, green: 0.55, blue: 0.10, opacity: 1.0)
    public static let statusCompleted = Color(.displayP3, red: 0.18, green: 0.72, blue: 0.38, opacity: 1.0)
    public static let statusFailed = Color(.displayP3, red: 0.94, green: 0.26, blue: 0.30, opacity: 1.0)
    public static let statusHdr = Color(.displayP3, red: 0.98, green: 0.65, blue: 0.15, opacity: 1.0)
    
    public static let downloading = statusDownloading
    public static let queued = statusQueued
    public static let completed = statusCompleted
    public static let failed = statusFailed
    public static let hdr = statusHdr
    
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
    
    // Semantic Radii Tokens
    public static let radiusSmall: CGFloat = 6
    public static let radiusControl: CGFloat = 8
    public static let radiusCard: CGFloat = 12
    public static let radiusSheet: CGFloat = 16
    
    // Elevated Card & Tile Backgrounds (Less transparency on cards, solid separation from window)
    @ViewBuilder
    public static func cardBackground(cornerRadius: CGFloat = radiusCard, isHovered: Bool = false) -> some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.92 : 0.84))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.regularMaterial)
                )
        }
    }
    
    @ViewBuilder
    public static func cardBorder(cornerRadius: CGFloat = radiusCard, isHovered: Bool = false, accentColor: Color? = nil) -> some View {
        let isOpaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if let accent = accentColor {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            accent.opacity(isHovered ? 0.55 : 0.40),
                            accent.opacity(isHovered ? 0.20 : 0.12),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        } else if isOpaque {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.primary.opacity(isHovered ? 0.24 : 0.14), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.28 : 0.18),
                            Color.white.opacity(isHovered ? 0.08 : 0.04),
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
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
            } else {
                Capsule()
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.04))
                    .background(
                        Capsule()
                            .fill(.thinMaterial)
                    )
            }
        }
    }
    
    @ViewBuilder
    public static func pillBorder(isSelected: Bool = false, isHovered: Bool = false) -> some View {
        if isSelected {
            Capsule()
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        } else {
            Capsule()
                .stroke(Color.primary.opacity(isHovered ? 0.12 : 0.06), lineWidth: 1)
        }
    }
    
    // Control / Button Backgrounds (Solid, tactile surfaces)
    @ViewBuilder
    public static func controlBackground(cornerRadius: CGFloat = radiusControl, isHovered: Bool = false) -> some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlColor))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlColor).opacity(isHovered ? 0.95 : 0.88))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.regularMaterial)
                )
        }
    }
    
    @ViewBuilder
    public static func controlBorder(cornerRadius: CGFloat = radiusControl, isHovered: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(Color.primary.opacity(isHovered ? 0.16 : 0.08), lineWidth: 1)
    }
    
    // Settings & Diagnostics Subtle Divider
    @ViewBuilder
    public static var subtleDivider: some View {
        Divider()
            .opacity(0.20)
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
    
    public func body(content: Content) -> some View {
        let isOpaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let effectiveTint = isDestructive ? SiphonTheme.statusFailed : (tintColor ?? SiphonTheme.accent)
        
        content
            .background {
                if isOpaque {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color(nsColor: isHovered ? .selectedControlColor : .controlBackgroundColor))
                } else {
                    ZStack {
                        if isHovered && !isSelected {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(effectiveTint.opacity(0.18))
                                .blur(radius: 6)
                                .padding(-1)
                                .allowedDynamicRange(AdaptiveRenderingEnvironment.shared.capabilities.supportsEDR ? .high : .standard)
                        }
                        
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                isSelected
                                    ? effectiveTint.opacity(0.85)
                                    : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
                            )
                            .background(
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .fill(.ultraThinMaterial)
                            )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: isSelected
                                ? [Color.white.opacity(0.35), Color.white.opacity(0.10), Color.clear]
                                : (isHovered
                                    ? [effectiveTint.opacity(0.50), effectiveTint.opacity(0.20), Color.clear]
                                    : [Color.white.opacity(0.18), Color.white.opacity(0.04), Color.clear]),
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.30, dampingFraction: 0.68, blendDuration: 0), value: isHovered)
            .animation(.spring(response: 0.32, dampingFraction: 0.70, blendDuration: 0), value: isSelected)
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
    
    public func makeBody(configuration: Configuration) -> some View {
        let reduceMotion = AdaptiveRenderingEnvironment.shared.capabilities.reduceMotion
        let effectivePressScale = reduceMotion ? 1.0 : scaleAmount
        let effectiveHoverScale = reduceMotion ? 1.0 : hoverScale
        
        configuration.label
            .scaleEffect(configuration.isPressed ? effectivePressScale : (isHovered ? effectiveHoverScale : 1.0))
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.65, blendDuration: 0), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.70, blendDuration: 0), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == BouncyButtonStyle {
    public static var bouncy: BouncyButtonStyle { BouncyButtonStyle() }
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
    
    public func makeBody(configuration: Configuration) -> some View {
        let reduceMotion = AdaptiveRenderingEnvironment.shared.capabilities.reduceMotion
        configuration.label
            .font(.geist(13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, SiphonTheme.spacing16)
            .padding(.vertical, 6)
            .background(SiphonTheme.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: SiphonTheme.accent.opacity(isHovered ? 0.35 : 0.20), radius: isHovered ? 8 : 4, y: 2)
            .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? 0.97 : (isHovered ? 1.015 : 1.0)))
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.70), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonSecondaryButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat = SiphonTheme.radiusControl
    @State private var isHovered = false
    
    public init(cornerRadius: CGFloat = SiphonTheme.radiusControl) {
        self.cornerRadius = cornerRadius
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        let reduceMotion = AdaptiveRenderingEnvironment.shared.capabilities.reduceMotion
        configuration.label
            .font(.geist(13, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, SiphonTheme.spacing14)
            .padding(.vertical, 6)
            .background(SiphonTheme.controlBackground(cornerRadius: cornerRadius, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                SiphonTheme.controlBorder(cornerRadius: cornerRadius, isHovered: isHovered)
            )
            .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? 0.97 : (isHovered ? 1.015 : 1.0)))
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.70), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonGhostButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat = SiphonTheme.radiusControl
    @State private var isHovered = false
    
    public init(cornerRadius: CGFloat = SiphonTheme.radiusControl) {
        self.cornerRadius = cornerRadius
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        let reduceMotion = AdaptiveRenderingEnvironment.shared.capabilities.reduceMotion
        configuration.label
            .font(.geist(12, weight: .medium))
            .foregroundColor(isHovered ? .primary : .secondary)
            .padding(.horizontal, SiphonTheme.spacing10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.0))
            )
            .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? 0.97 : 1.0))
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.70), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

public struct SiphonIconButtonStyle: ButtonStyle {
    public var size: CGFloat = 26
    @State private var isHovered = false
    
    public init(size: CGFloat = 26) {
        self.size = size
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        let reduceMotion = AdaptiveRenderingEnvironment.shared.capabilities.reduceMotion
        configuration.label
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.0))
            )
            .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? 0.92 : (isHovered ? 1.05 : 1.0)))
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.70), value: isHovered)
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
                .font(.geist(11, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .foregroundColor(foregroundColor)
        .background(
            Capsule()
                .fill(foregroundColor.opacity(0.12))
                .background(Capsule().fill(.ultraThinMaterial))
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
                .font(isMonospaced ? .geistMono(10, weight: .semibold) : .geist(10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .foregroundColor(isHdr ? .white : tintColor)
        .background {
            if isHdr {
                LinearGradient(
                    colors: [SiphonTheme.statusHdr, Color.orange],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .allowedDynamicRange(AdaptiveRenderingEnvironment.shared.capabilities.supportsEDR ? .high : .standard)
            } else {
                tintColor.opacity(0.12)
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
                    .font(.geist(16, weight: .semibold))
                    .foregroundColor(.primary)
                Text(message)
                    .font(.geist(13))
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
                            .font(.geist(13, weight: .semibold))
                    }
                }
                .buttonStyle(.siphonPrimary(cornerRadius: 16))
                .padding(.top, SiphonTheme.spacing4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SiphonTheme.spacing32)
    }
}

// MARK: - Standardized Input View Modifier
extension View {
    @ViewBuilder
    public func siphonInputStyle(cornerRadius: CGFloat = SiphonTheme.radiusControl) -> some View {
        self.padding(.horizontal, SiphonTheme.spacing10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
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
                        Color(.displayP3, red: 0.10, green: 0.38, blue: 0.90, opacity: 0.06),
                        Color(.displayP3, red: 0.32, green: 0.16, blue: 0.70, opacity: 0.025),
                        Color.clear
                    ]),
                    center: .topLeading,
                    startRadius: 40,
                    endRadius: 650
                )
                
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(.displayP3, red: 0.06, green: 0.55, blue: 0.85, opacity: 0.035),
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
