//
//  LiquidWaterWaveView.swift
//  Siphon
//

import SwiftUI

struct WaterWaveShape: Shape {
    var phase: CGFloat
    var amplitude: CGFloat = 4.0
    var frequency: CGFloat = 1.5

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let midY = height * 0.45

        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: midY))

        let step: CGFloat = 3
        for x in stride(from: 0, through: width, by: step) {
            let relativeX = x / width
            let sine = sin((relativeX * 2 * .pi * frequency) + phase)
            let y = midY + sine * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        return path
    }
}

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
                    color.opacity(isHovered ? 0.22 : 0.12),
                    color.opacity(0.04),
                    Color.clear
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        } else {
            let minInterval = AdaptiveRenderingEnvironment.shared.isHighRefreshRate ? (1.0 / 120.0) : (1.0 / 60.0)
            TimelineView(.animation(minimumInterval: minInterval)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let speed: Double = isActive ? 1.8 : (isHovered ? 1.3 : 0.8)
                let phase1 = CGFloat(time * speed)
                let phase2 = CGFloat(time * (speed * 1.3) + 1.2)

                ZStack {
                    // Back deep water layer
                    WaterWaveShape(phase: phase1, amplitude: isHovered ? 5.0 : 3.5, frequency: 1.2)
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(isActive ? 0.26 : (isHovered ? 0.18 : 0.11)),
                                    color.opacity(isActive ? 0.12 : (isHovered ? 0.08 : 0.04)),
                                    Color.clear
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )

                    // Front shimmering water crest
                    WaterWaveShape(phase: phase2, amplitude: isHovered ? 4.0 : 2.5, frequency: 1.8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(isActive ? 0.18 : (isHovered ? 0.14 : 0.07)),
                                    Color.white.opacity(isHovered ? 0.10 : 0.04),
                                    Color.clear
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                }
            }
        }
    }
}
