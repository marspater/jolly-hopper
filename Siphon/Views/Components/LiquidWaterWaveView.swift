//
//  LiquidWaterWaveView.swift
//  Siphon
//

import SwiftUI

// MARK: - 2D Lissajous Harmonic Fluid Shape

/// A soft, closed liquid form that drifts and deforms along a smooth orbit.
///
/// The shape intentionally stays organic rather than reading as a literal wave:
/// it is ambient decoration behind the status content, not a second progress
/// indicator competing with the ring and count.
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
        guard rect.width > 2, rect.height > 2 else { return Path() }

        let width = rect.width
        let height = rect.height
        let fx = freqX + sin(seed * 2.37) * 0.07
        let fy = freqY + cos(seed * 3.19) * 0.07
        let t = (time + (seed * 19.37) + phaseOffset) * speed
        let scale = CGFloat(intensity)

        // Keep the drift inside the card so the content remains legible.
        let maxDriftX = width * 0.16 * scale
        let maxDriftY = height * 0.11 * scale
        let centerX = (width * 0.50) + maxDriftX * CGFloat(sin(t * fx))
        let centerY = (height * 0.58) + maxDriftY * CGFloat(cos(t * fy + seed * 0.5))

        // Deform the blob in the direction it is travelling, without a visible
        // squash-and-stretch snap when hover or selection changes.
        let vx = Double(maxDriftX) * fx * cos(t * fx)
        let vy = -Double(maxDriftY) * fy * sin(t * fy + seed * 0.5)
        let speedMagnitude = sqrt(vx * vx + vy * vy)
        let flowAngle = atan2(vy, vx)
        let normalizedSpeed = min(speedMagnitude / (Double(max(width, height)) * 0.18 + 0.001), 1.0)
        let stretchParallel = CGFloat(1.0 + 0.12 * normalizedSpeed * intensity)
        let stretchPerpendicular = CGFloat(1.0 / sqrt(stretchParallel))

        let baseRadiusX = max(width * 0.43, 20)
        let baseRadiusY = max(height * 0.42, 14)

        // More points plus lower harmonic energy gives the old organic motion a
        // cleaner silhouette and avoids the jagged, woven appearance.
        let nodeCount = 28
        var points: [CGPoint] = []
        points.reserveCapacity(nodeCount)

        for index in 0..<nodeCount {
            let theta = (Double(index) / Double(nodeCount)) * 2.0 * Double.pi
            let relativeAngle = theta - flowAngle

            let firstHarmonic = 0.10 * sin(2.0 * theta - t * 1.3 + seed)
            let secondHarmonic = 0.065 * cos(3.0 * theta + t * harmonicRatio + 1.1 + seed * 0.7)
            let thirdHarmonic = 0.025 * sin(4.0 * theta - t * 1.6 + seed * 1.4)
            let radius = CGFloat(1.0 + (firstHarmonic + secondHarmonic + thirdHarmonic) * intensity)

            let cosine = CGFloat(cos(relativeAngle))
            let sine = CGFloat(sin(relativeAngle))
            let directionalStretch = sqrt(
                (stretchParallel * cosine) * (stretchParallel * cosine) +
                (stretchPerpendicular * sine) * (stretchPerpendicular * sine)
            )

            points.append(CGPoint(
                x: centerX + (baseRadiusX * radius * directionalStretch) * CGFloat(cos(theta)),
                y: centerY + (baseRadiusY * radius * directionalStretch) * CGFloat(sin(theta))
            ))
        }

        var path = Path()
        path.move(to: points[0])

        for index in 0..<nodeCount {
            let previous = points[(index - 1 + nodeCount) % nodeCount]
            let current = points[index]
            let next = points[(index + 1) % nodeCount]
            let nextNext = points[(index + 2) % nodeCount]

            let controlPoint1 = CGPoint(
                x: current.x + (next.x - previous.x) / 6.0,
                y: current.y + (next.y - previous.y) / 6.0
            )
            let controlPoint2 = CGPoint(
                x: next.x - (nextNext.x - current.x) / 6.0,
                y: next.y - (nextNext.y - current.y) / 6.0
            )

            path.addCurve(to: next, control1: controlPoint1, control2: controlPoint2)
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Simulated Organic Fluid Motion View

/// Multi-directional viscous liquid pools flowing behind status content.
struct LiquidWaterWaveView: View {
    let color: Color
    var isHovered: Bool = false
    var isActive: Bool = false
    var seed: Double = 0.0

    @State private var startedAt = Date()
    @ObservedObject private var renderingEnvironment = AdaptiveRenderingEnvironment.shared
    @Environment(\.siphonRenderingCapabilities) private var renderingCapabilities

    var body: some View {
        if !renderingEnvironment.shouldAnimateAmbient {
            LinearGradient(
                colors: [
                    color.opacity(isHovered ? 0.16 : 0.08),
                    color.opacity(0.025),
                    Color.clear
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        } else {
            // Keep the phase and speed independent of hover/selection so the
            // liquid continues smoothly instead of jumping when state changes.
            TimelineView(.animation(minimumInterval: renderingCapabilities.animationMinimumInterval)) { timeline in
                let time = timeline.date.timeIntervalSince(startedAt)
                let visibility = isActive ? 1.0 : (isHovered ? 0.86 : 0.58)

                ZStack {
                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: 0.66,
                        intensity: 0.92,
                        seed: seed,
                        phaseOffset: 0.0,
                        freqX: 0.58,
                        freqY: 0.86,
                        harmonicRatio: 1.4
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.32 * visibility),
                                color.opacity(0.11 * visibility),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: 0.66,
                        intensity: 0.82,
                        seed: seed + 3.1415,
                        phaseOffset: 2.7,
                        freqX: 0.82,
                        freqY: 0.54,
                        harmonicRatio: 2.1
                    )
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.19 * visibility),
                                Color.primary.opacity(0.035),
                                Color.clear
                            ],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                    )

                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: 0.66,
                        intensity: 0.92,
                        seed: seed,
                        phaseOffset: 0.0,
                        freqX: 0.58,
                        freqY: 0.86,
                        harmonicRatio: 1.4
                    )
                    .stroke(color.opacity(0.18 * visibility), lineWidth: 0.65)

                    LissajousHarmonicBlobShape(
                        time: time,
                        speed: 0.68,
                        intensity: 0.62,
                        seed: seed + 1.5707,
                        phaseOffset: 1.2,
                        freqX: 1.05,
                        freqY: 0.72,
                        harmonicRatio: 1.7
                    )
                    .fill(
                        RadialGradient(
                            colors: [
                                color.opacity(0.13 * visibility),
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
