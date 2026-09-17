//
//  LiquidWaterWaveView.swift
//  Siphon
//

import SwiftUI

// MARK: - 2D Lissajous Harmonic Fluid Shape
// Closed organic fluid boundary parameterized by multi-harmonic Lissajous orbits.
// Incorporates velocity-aligned squash-and-stretch hydrodynamics and Catmull-Rom C^1 splines.
struct LissajousHarmonicBlobShape: Shape {
    var time: Double
    var speed: Double = 0.6
    var intensity: Double = 1.0
    var seed: Double = 0.0
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

        // Incorporate seed to mathematically guarantee incommensurate frequencies per card
        let fx = freqX + sin(seed * 2.37) * 0.07
        let fy = freqY + cos(seed * 3.19) * 0.07
        let t = (time + (seed * 19.37) + phaseOffset) * speed
        let scale = CGFloat(intensity)

        // 2D Lissajous orbit for the fluid body center (soft undercurrent below text)
        let maxDriftX = w * 0.20 * scale
        let maxDriftY = h * 0.14 * scale
        let centerX = (w * 0.50) + maxDriftX * CGFloat(sin(t * fx))
        let centerY = (h * 0.58) + maxDriftY * CGFloat(cos(t * fy + seed * 0.5))

        // Instantaneous Lissajous velocity vector (dC/dt) for hydrodynamic elongation
        let vx = Double(maxDriftX) * fx * cos(t * fx)
        let vy = -Double(maxDriftY) * fy * sin(t * fy + seed * 0.5)
        let speedMag = sqrt(vx * vx + vy * vy)
        let flowAngle = atan2(vy, vx)

        // Squash-and-stretch along velocity vector preserving fluid area
        let normalizedSpeed = min(speedMag / (Double(max(w, h)) * 0.18 + 0.001), 1.0)
        let stretchParallel = CGFloat(1.0 + 0.16 * normalizedSpeed * intensity)
        let stretchPerp = CGFloat(1.0 / sqrt(stretchParallel))

        // Base radii adapted to container dimensions
        let baseRadiusX = max(w * 0.45, 20)
        let baseRadiusY = max(h * 0.42, 14)

        // Sample 20 nodes along the closed 2D harmonic perimeter
        let nodeCount = 20
        var points: [CGPoint] = []
        points.reserveCapacity(nodeCount)

        for i in 0..<nodeCount {
            let theta = (Double(i) / Double(nodeCount)) * 2.0 * Double.pi
            let relAngle = theta - flowAngle

            // Multi-frequency Lissajous harmonic radial modulation (capillary & surface waves)
            let h1 = 0.14 * sin(2.0 * theta - t * 1.3 + seed)
            let h2 = 0.09 * cos(3.0 * theta + t * 1.0 * harmonicRatio + 1.1 + seed * 0.7)
            let h3 = 0.05 * sin(4.0 * theta - t * 1.6 + seed * 1.4)
            let radiusMod = CGFloat(1.0 + (h1 + h2 + h3) * intensity)

            // Velocity-aligned directional deformation
            let cosRel = CGFloat(cos(relAngle))
            let sinRel = CGFloat(sin(relAngle))
            let dirStretch = sqrt((stretchParallel * cosRel) * (stretchParallel * cosRel) +
                                  (stretchPerp * sinRel) * (stretchPerp * sinRel))

            let px = centerX + (baseRadiusX * radiusMod * dirStretch) * CGFloat(cos(theta))
            let py = centerY + (baseRadiusY * radiusMod * dirStretch) * CGFloat(sin(theta))
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
    var seed: Double = 0.0
    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared

    init(color: Color, isHovered: Bool = false, isActive: Bool = false, seed: Double = 0.0) {
        self.color = color
        self.isHovered = isHovered
        self.isActive = isActive
        self.seed = seed
    }

    var body: some View {
        if !renderingEnvironment.shouldAnimateAmbient || (!isActive && !isHovered) {
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
            // Decorative motion should never compete with download progress rendering.
            // 30 fps is visually continuous for this slow ambient treatment while
            // avoiding constant redraws for every visible status segment.
            let minInterval = 1.0 / 30.0
            TimelineView(.animation(minimumInterval: minInterval)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let baseSpeed = isActive ? 0.95 : (isHovered ? 0.72 : 0.46)

                ZStack {
                    // Layer 1: Deep Primary Viscous Fluid Body (Clockwise Lissajous Orbit)
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: baseSpeed * 0.85,
                        intensity: 0.95,
                        seed: seed,
                        phaseOffset: 0.0,
                        freqX: 0.58,
                        freqY: 0.86,
                        harmonicRatio: 1.4
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(isActive ? 0.26 : 0.14),
                                color.opacity(isActive ? 0.10 : 0.04),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                    // Layer 2: Complementary Counter-Drifting Fluid Body (Counter Lissajous Current)
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: baseSpeed * 1.08,
                        intensity: 0.85,
                        seed: seed + 3.1415,
                        phaseOffset: 2.7,
                        freqX: 0.82,
                        freqY: 0.54,
                        harmonicRatio: 2.1
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(isActive ? 0.16 : 0.08),
                                Color.primary.opacity(0.03),
                                Color.clear
                            ],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                    )

                    // Layer 3: Soft ambient liquid rim
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: baseSpeed * 0.85,
                        intensity: 0.95,
                        seed: seed,
                        phaseOffset: 0.0,
                        freqX: 0.58,
                        freqY: 0.86,
                        harmonicRatio: 1.4
                    )
                    .stroke(
                        color.opacity(0.14),
                        lineWidth: 0.5
                    )

                    // Layer 4: Soft ambient liquid glow
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: baseSpeed * 1.25,
                        intensity: 0.65,
                        seed: seed + 1.5707,
                        phaseOffset: 1.2,
                        freqX: 1.05,
                        freqY: 0.72,
                        harmonicRatio: 1.7
                    )
                    .fill(
                        RadialGradient(
                            colors: [
                                color.opacity(isActive ? 0.10 : 0.05),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 4,
                            endRadius: 45
                        )
                    )
                }
            }
        }
    }
}
