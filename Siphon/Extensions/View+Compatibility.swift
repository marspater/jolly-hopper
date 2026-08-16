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

// MARK: - Standardized Siphon Design System & Theme
public enum SiphonTheme {
    // Primary Accent & Gradients
    public static let accent = Color(red: 0.12, green: 0.48, blue: 1.0)
    public static let primaryGradient = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.52, blue: 1.0),
            Color(red: 0.08, green: 0.40, blue: 0.94)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Status Colors (WCAG AA compliant contrast in both Light & Dark modes)
    public static let downloading = Color(red: 0.08, green: 0.48, blue: 0.98)
    public static let queued = Color(red: 0.94, green: 0.52, blue: 0.08)
    public static let completed = Color(red: 0.14, green: 0.65, blue: 0.35)
    public static let failed = Color(red: 0.90, green: 0.25, blue: 0.32)

    // Elevated Card & Tile Backgrounds
    @ViewBuilder
    public static func cardBackground(cornerRadius: CGFloat = 14, isHovered: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            )
    }

    @ViewBuilder
    public static func cardBorder(cornerRadius: CGFloat = 14, isHovered: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(isHovered ? Color.primary.opacity(0.14) : Color.primary.opacity(0.07), lineWidth: 1)
    }

    // Pill / Badge Backgrounds
    @ViewBuilder
    public static func pillBackground(isSelected: Bool = false, isHovered: Bool = false) -> some View {
        if isSelected {
            Capsule()
                .fill(primaryGradient)
                .shadow(color: accent.opacity(0.35), radius: 6, y: 2)
        } else {
            Capsule()
                .fill(isHovered ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03))
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
        }
    }

    @ViewBuilder
    public static func pillBorder(isSelected: Bool = false, isHovered: Bool = false) -> some View {
        if isSelected {
            Capsule()
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        } else {
            Capsule()
                .stroke(isHovered ? Color.primary.opacity(0.14) : Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}
