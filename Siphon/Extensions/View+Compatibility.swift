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
            reduceTransparency: reduceTransparency
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
    
    // Radii Tokens
    public static let radiusControl: CGFloat = 8
    public static let radiusCard: CGFloat = 12
    public static let radiusSheet: CGFloat = 14
    
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
    public var scaleAmount: CGFloat = 0.95
    public var hoverScale: CGFloat = 1.025
    
    @State private var isHovered = false
    
    public init(scaleAmount: CGFloat = 0.95, hoverScale: CGFloat = 1.025) {
        self.scaleAmount = scaleAmount
        self.hoverScale = hoverScale
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scaleAmount : (isHovered ? hoverScale : 1.0))
            .animation(.spring(response: 0.28, dampingFraction: 0.65, blendDuration: 0), value: configuration.isPressed)
            .animation(.spring(response: 0.32, dampingFraction: 0.70, blendDuration: 0), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == BouncyButtonStyle {
    public static var bouncy: BouncyButtonStyle { BouncyButtonStyle() }
    public static func bouncy(scale: CGFloat = 0.95, hover: CGFloat = 1.025) -> BouncyButtonStyle {
        BouncyButtonStyle(scaleAmount: scale, hoverScale: hover)
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
