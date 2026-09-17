//
//  LiquidWaterWaveView.swift
//  Siphon
//

import SwiftUI

/// A continuous water surface that fills to the bottom of its tile.
private struct WaterSurfaceShape: Shape {
    var time: Double
    var seed: Double
    var depth: CGFloat
    var amplitude: CGFloat
    var direction: Double

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        var path = Path()
        let phase = time * direction + seed
        let steps = 80
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let swell = sin(fraction * .pi * 2 + phase)
            let ripple = sin(fraction * .pi * 4 - phase * 0.7 + seed) * 0.28
            let point = CGPoint(
                x: rect.minX + rect.width * fraction,
                y: rect.minY + rect.height * depth + amplitude * CGFloat(swell + ripple)
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct LiquidWaterWaveView: View {
    let color: Color
    var isHovered: Bool = false
    var isActive: Bool = false
    var seed: Double = 0
    @State private var startedAt = Date()
    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared

    var body: some View {
        // Keep phase and speed independent of hover/selection to avoid jumps.
        // Reduced motion and inactive apps use a still surface.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: !renderingEnvironment.shouldAnimateAmbient)) { timeline in
            let time = renderingEnvironment.shouldAnimateAmbient
                ? timeline.date.timeIntervalSince(startedAt) * 0.55 : 0
            GeometryReader { geometry in
                ZStack {
                    WaterSurfaceShape(time: time, seed: seed, depth: 0.62,
                                      amplitude: geometry.size.height * 0.10, direction: 1)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    WaterSurfaceShape(time: time, seed: seed + 2.4, depth: 0.74,
                                      amplitude: geometry.size.height * 0.08, direction: -0.8)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.28), color.opacity(0.08)],
                            startPoint: .top, endPoint: .bottom
                        ))
                }
                .opacity(isActive ? 1 : (isHovered ? 0.85 : 0.55))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
