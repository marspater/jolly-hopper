//
//  LiquidWaterWaveView.swift
//  Siphon
//

import SwiftUI

// MARK: - 2D Lissajous Harmonic Fluid Shape
// Closed organic fluid boundary parameterized by multi-harmonic Lissajous orbits.
// Generates continuous, smooth C^1 cubic Bézier splines moving in multi-directional fluid currents.
struct LissajousHarmonicBlobShape: Shape {
    var time: Double
    var speed: Double = 0.8
    var intensity: Double = 1.0
    var phaseOffset: Double = 0.0
    var freqX: Double = 0.73
    var freqY: Double = 1.09
    var harmonicRatio: Double = 1.5

    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        guard w > 2 && h > 2 else { return path }

        let t = (time + phaseOffset) * speed
        let scale = CGFloat(intensity)

        // 2D Lissajous orbit for the fluid body center (smooth randomized multi-directional drift)
        let maxDriftX = w * 0.20 * scale
        let maxDriftY = h * 0.16 * scale
        let centerX = (w * 0.50) + maxDriftX * CGFloat(sin(t * freqX))
        let centerY = (h * 0.50) + maxDriftY * CGFloat(cos(t * freqY))

        // Base radii adapted to container dimensions
        let baseRadiusX = max(w * 0.46, 20)
        let baseRadiusY = max(h * 0.48, 16)

        // Sample N nodes along the closed 2D Lissajous harmonic perimeter
        let nodeCount = 16
        var points: [CGPoint] = []
        points.reserveCapacity(nodeCount)

        for i in 0..<nodeCount {
            let theta = (Double(i) / Double(nodeCount)) * 2.0 * Double.pi

            // Multi-frequency Lissajous harmonic radial modulation
            let h1 = 0.16 * sin(2.0 * theta + t * 1.2)
            let h2 = 0.12 * cos(3.0 * theta - t * 0.9 * harmonicRatio + 1.2)
            let h3 = 0.06 * sin(5.0 * theta + t * 1.4)
            let radiusMod = CGFloat(1.0 + (h1 + h2 + h3) * intensity)

            let px = centerX + (baseRadiusX * radiusMod) * CGFloat(cos(theta))
            let py = centerY + (baseRadiusY * radiusMod) * CGFloat(sin(theta))
            points.append(CGPoint(x: px, y: py))
        }

        // Draw smooth closed cubic Bézier spline through all points with C^1 continuity
        guard points.count >= 3 else { return path }
        path.move(to: points[0])

        for i in 0..<nodeCount {
            let pPrev = points[(i - 1 + nodeCount) % nodeCount]
            let pCurr = points[i]
            let pNext = points[(i + 1) % nodeCount]
            let pNextNext = points[(i + 2) % nodeCount]

            // Catmull-Rom tangent control points
            let cp1 = CGPoint(
                x: pCurr.x + (pNext.x - pPrev.x) / 6.0,
                y: pCurr.y + (pNext.y - pPrev.y) / 6.0
            )
            let cp2 = CGPoint(
                x: pNext.x - (pNextNext.x - pCurr.x) / 6.0,
                y: pNext.y - (pNextNext.y - pCurr.y) / 6.0
            )

            path.addCurve(to: pNext, control1: cp1, control2: cp2)
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Simulated Organic Fluid Motion View
// Multi-directional viscous liquid pools flowing along Lissajous harmonic curves
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
                let baseSpeed = isActive ? 1.3 : (isHovered ? 0.95 : 0.65)

                ZStack {
                    // Layer 1: Deep Primary Viscous Fluid Body (Clockwise Lissajous Orbit)
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: baseSpeed * 0.85,
                        intensity: isHovered ? 1.2 : 0.95,
                        phaseOffset: 0.0,
                        freqX: 0.62,
                        freqY: 0.94,
                        harmonicRatio: 1.5
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(isActive ? 0.32 : (isHovered ? 0.22 : 0.14)),
                                color.opacity(isActive ? 0.14 : (isHovered ? 0.08 : 0.04)),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                    // Layer 2: Complementary Counter-Drifting Fluid Body (Counter Lissajous Current)
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: baseSpeed * 1.12,
                        intensity: isHovered ? 1.1 : 0.85,
                        phaseOffset: 3.8,
                        freqX: 0.88,
                        freqY: 0.58,
                        harmonicRatio: 2.2
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(isActive ? 0.22 : (isHovered ? 0.15 : 0.09)),
                                Color.white.opacity(isHovered ? 0.08 : 0.03),
                                Color.clear
                            ],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                    )

                    // Layer 3: Specular Fluid Sheen Edge (Crisp Mathematical Vector Contour)
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: baseSpeed * 0.85,
                        intensity: isHovered ? 1.2 : 0.95,
                        phaseOffset: 0.0,
                        freqX: 0.62,
                        freqY: 0.94,
                        harmonicRatio: 1.5
                    )
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.35 : 0.18),
                                color.opacity(isHovered ? 0.40 : 0.20),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )

                    // Layer 4: Luminous Inner Core Sheen
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: baseSpeed * 1.35,
                        intensity: 0.70,
                        phaseOffset: 1.5,
                        freqX: 1.15,
                        freqY: 0.78,
                        harmonicRatio: 1.8
                    )
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.12 : 0.05),
                                color.opacity(isHovered ? 0.16 : 0.06),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 40
                        )
                    )
                }
            }
        }
    }
}
