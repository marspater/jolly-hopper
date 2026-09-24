//
//  LiquidWaterWaveView.swift
//  Siphon
//

import SwiftUI

// MARK: - Liquid Progress Shape

/// A fill that grows from the leading edge to `level` of the width. Its
/// trailing edge is a soft travelling wave, so live progress reads as liquid
/// rather than a hard bar.
struct LiquidProgressShape: Shape {
    var level: Double
    var phase: Double
    var amplitude: CGFloat = 2.5

    // Only the level springs; the phase comes straight from the timeline clock.
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(level, 0), 1)
        guard clamped > 0, rect.width > 0, rect.height > 0 else { return Path() }

        let edgeX = rect.minX + rect.width * CGFloat(clamped)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: edgeX, y: rect.minY))

        // One gentle wavelength down the edge; flat at full progress.
        let amp = clamped >= 1 ? 0 : amplitude
        let steps = 24
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let y = rect.minY + rect.height * CGFloat(t)
            let x = edgeX + amp * CGFloat(sin(t * 2 * .pi + phase))
            path.addLine(to: CGPoint(x: min(x, rect.maxX), y: y))
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Status Segment Background

/// Background for a Home status segment.
///
/// Motion only explains live state: an idle segment stays flat, a segment with
/// items gets a static tint, and only a live progress segment animates its
/// liquid edge (paused while the app is inactive or Reduce Motion is on).
struct StatusSegmentFill: View {
    let color: Color
    /// Aggregate progress (0...1) for a live segment; nil for static segments.
    var progress: Double?
    var isHovered: Bool = false
    var isActive: Bool = false

    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared
    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isActive {
                // Static tint: says "this segment has items" without motion.
                LinearGradient(
                    colors: [color.opacity(isHovered ? 0.16 : 0.10), color.opacity(0.02)],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .transition(.opacity)
            } else if isHovered {
                color.opacity(0.05)
                    .transition(.opacity)
            }

            if isActive, let progress {
                if renderingEnvironment.shouldAnimateAmbient && !reduceMotion {
                    TimelineView(.animation(minimumInterval: renderingCapabilities.animationMinimumInterval)) { timeline in
                        liquid(progress: progress, phase: timeline.date.timeIntervalSinceReferenceDate * 2.2)
                    }
                } else {
                    liquid(progress: progress, phase: 0)
                }
            }
        }
        .animation(SiphonAnimation.hoverSpring, value: isHovered)
        .animation(SiphonAnimation.fluidSpring, value: isActive)
    }

    private func liquid(progress: Double, phase: Double) -> some View {
        LiquidProgressShape(level: progress, phase: phase)
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.10), color.opacity(isHovered ? 0.24 : 0.18)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .animation(SiphonAnimation.fluidSpring, value: progress)
    }
}
