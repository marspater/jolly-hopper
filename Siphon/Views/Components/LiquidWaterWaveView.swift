//
//  LiquidWaterWaveView.swift
//  Siphon
//

import SwiftUI

// MARK: - Multi-Directional Organic Fluid Shape
// Simulates liquid boundary motion with multi-node harmonic orbital drift (non-repeating fluid currents)
struct OrganicFluidShape: Shape {
    var time: Double
    var speed: Double = 0.8
    var intensity: Double = 1.0

    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let t = time * speed
        let scale = CGFloat(intensity)

        // Starting point at bottom-left
        path.move(to: CGPoint(x: 0, y: h))

        // Control nodes calculated with multi-axis Lissajous harmonic displacement
        let node0Y = h * 0.45 + (sin(t * 1.1) * 3.5 + cos(t * 0.7) * 2.0) * scale
        path.addLine(to: CGPoint(x: 0, y: node0Y))

        let cp1X = w * 0.22 + (cos(t * 0.9 + 1.2) * 8.0) * scale
        let cp1Y = h * 0.38 + (sin(t * 1.4 + 0.4) * 4.5 + cos(t * 0.5) * 3.0) * scale

        let node1X = w * 0.48 + (sin(t * 0.8 + 2.1) * 6.0) * scale
        let node1Y = h * 0.46 + (cos(t * 1.2 + 1.1) * 4.0 - sin(t * 0.6) * 3.0) * scale

        path.addQuadCurve(to: CGPoint(x: node1X, y: node1Y), control: CGPoint(x: cp1X, y: cp1Y))

        let cp2X = w * 0.74 + (sin(t * 1.3 + 3.0) * 8.0) * scale
        let cp2Y = h * 0.40 + (cos(t * 0.7 + 2.0) * 4.5 + sin(t * 1.5) * 2.5) * scale

        let node2Y = h * 0.44 + (sin(t * 1.0 + 1.8) * 3.5 - cos(t * 0.9) * 2.0) * scale
        path.addQuadCurve(to: CGPoint(x: w, y: node2Y), control: CGPoint(x: cp2X, y: cp2Y))

        // Complete the fluid container path to bottom-right and close
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        return path
    }
}

// MARK: - Simulated Fluid Motion View
// Slow to medium speed fluid moving in randomized multi-directional liquid currents
struct LiquidWaterWaveView: View {
    let color: Color
    var isHovered: Bool = false
    var isActive: Bool = false

    init(color: Color, isHovered: Bool = false, isActive: Bool = false) {
        self.color = color
        self.isHovered = isHovered
        self.isActive = isActive
    }

    var body: some View {
        let reduceMotion = AdaptiveRenderingEnvironment.shared.reduceMotion
        if reduceMotion {
            LinearGradient(
                colors: [
                    color.opacity(isHovered ? 0.20 : 0.10),
                    color.opacity(0.03),
                    Color.clear
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        } else {
            let minInterval = AdaptiveRenderingEnvironment.shared.isHighRefreshRate ? (1.0 / 120.0) : (1.0 / 60.0)
            TimelineView(.animation(minimumInterval: minInterval)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let baseSpeed = isActive ? 1.4 : (isHovered ? 1.0 : 0.65)

                GeometryReader { proxy in
                    let width = max(1, proxy.size.width)
                    let height = max(1, proxy.size.height)

                    ZStack {
                        // 1. Organic Multi-Directional Liquid Blobs (viscous pools drifting in randomized axes)
                        let blob1X = width * (0.35 + 0.20 * sin(time * baseSpeed * 0.7))
                        let blob1Y = height * (0.55 + 0.25 * cos(time * baseSpeed * 0.9 + 1.0))
                        RadialGradient(
                            colors: [
                                color.opacity(isActive ? 0.25 : (isHovered ? 0.18 : 0.12)),
                                color.opacity(isActive ? 0.10 : (isHovered ? 0.06 : 0.03)),
                                Color.clear
                            ],
                            center: UnitPoint(x: blob1X / width, y: blob1Y / height),
                            startRadius: 4,
                            endRadius: max(width * 0.45, 60)
                        )
                        .blur(radius: 8)

                        let blob2X = width * (0.68 + 0.22 * cos(time * baseSpeed * 0.8 + 2.0))
                        let blob2Y = height * (0.50 + 0.20 * sin(time * baseSpeed * 0.6 + 0.5))
                        RadialGradient(
                            colors: [
                                color.opacity(isActive ? 0.22 : (isHovered ? 0.15 : 0.09)),
                                Color.white.opacity(isHovered ? 0.06 : 0.02),
                                Color.clear
                            ],
                            center: UnitPoint(x: blob2X / width, y: blob2Y / height),
                            startRadius: 2,
                            endRadius: max(width * 0.38, 50)
                        )
                        .blur(radius: 6)

                        // 2. Primary Deep Fluid Layer (moving in complex multi-directional current)
                        OrganicFluidShape(
                            time: time,
                            speed: baseSpeed * 0.8,
                            intensity: isHovered ? 1.25 : 1.0
                        )
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(isActive ? 0.24 : (isHovered ? 0.16 : 0.10)),
                                    color.opacity(isActive ? 0.12 : (isHovered ? 0.07 : 0.03)),
                                    Color.clear
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )

                        // 3. Shimmering Surface Liquid Layer (counter-moving current with subtle specular sheen)
                        OrganicFluidShape(
                            time: time + 4.2,
                            speed: baseSpeed * 1.15,
                            intensity: isHovered ? 1.1 : 0.85
                        )
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(isActive ? 0.16 : (isHovered ? 0.11 : 0.06)),
                                    Color.white.opacity(isHovered ? 0.10 : 0.04),
                                    Color.clear
                                ],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )
                    }
                }
            }
        }
    }
}
