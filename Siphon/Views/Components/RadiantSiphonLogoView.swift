//
//  RadiantSiphonLogoView.swift
//  Siphon
//

import SwiftUI
import AppKit

struct RadiantSiphonLogoView: View {
    @State private var isHovered: Bool = false

    var body: some View {
        let reduceMotion = AdaptiveRenderingEnvironment.shared.reduceMotion
        if reduceMotion {
            staticLogoView
        } else {
            animatedLogoView
        }
    }

    // MARK: - Animated Complex Radiant Logo

    private var animatedLogoView: some View {
        let minInterval = AdaptiveRenderingEnvironment.shared.isHighRefreshRate ? (1.0 / 120.0) : (1.0 / 60.0)
        return TimelineView(.animation(minimumInterval: minInterval)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let spinSpeed = isHovered ? 1.8 : 0.8
            let angle1 = Angle(degrees: (time * 24.0 * spinSpeed).truncatingRemainder(dividingBy: 360))
            let angle2 = Angle(degrees: -(time * 16.0 * spinSpeed).truncatingRemainder(dividingBy: 360))
            let breath = CGFloat(1.0 + (isHovered ? 0.15 : 0.08) * sin(time * 1.6))

            ZStack {
                // Layer 1: Outer Counter-Rotating Soft Chromatic Aura
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                SiphonTheme.accent.opacity(isHovered ? 0.50 : 0.30),
                                Color.cyan.opacity(isHovered ? 0.35 : 0.18),
                                Color.indigo.opacity(isHovered ? 0.25 : 0.12),
                                Color.cyan.opacity(isHovered ? 0.40 : 0.22),
                                SiphonTheme.accent.opacity(isHovered ? 0.50 : 0.30)
                            ]),
                            center: .center
                        )
                    )
                    .frame(width: 52, height: 52)
                    .rotationEffect(angle2)
                    .scaleEffect(breath)
                    .blur(radius: isHovered ? 10 : 7)

                // Layer 2: Inner Clockwise High-Energy Vortex
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                SiphonTheme.accent.opacity(isHovered ? 0.85 : 0.60),
                                Color.white.opacity(isHovered ? 0.55 : 0.25),
                                Color.cyan.opacity(isHovered ? 0.75 : 0.50),
                                SiphonTheme.accent.opacity(isHovered ? 0.85 : 0.60)
                            ]),
                            center: .center
                        )
                    )
                    .frame(width: 44, height: 44)
                    .rotationEffect(angle1)
                    .blur(radius: isHovered ? 6 : 4)

                // Layer 3: Central Pulsing Radiant Light Core
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.45 : 0.25),
                                Color.cyan.opacity(isHovered ? 0.50 : 0.30),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 20
                        )
                    )
                    .frame(width: 40, height: 40)
                    .scaleEffect(isHovered ? 1.12 : 1.0)

                // Layer 4: App Icon with Specular Glass Treatment
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isHovered ? 0.60 : 0.35),
                                        Color.white.opacity(isHovered ? 0.20 : 0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    )
                    .shadow(color: Color.black.opacity(0.30), radius: 3, y: 1.5)
            }
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(SiphonAnimation.hoverSpring) {
                    isHovered = hovering
                }
            }
        }
    }

    // MARK: - Reduced Motion Fallback

    private var staticLogoView: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            SiphonTheme.accent.opacity(isHovered ? 0.65 : 0.40),
                            Color.cyan.opacity(isHovered ? 0.35 : 0.18),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 24
                    )
                )
                .frame(width: 48, height: 48)
                .blur(radius: isHovered ? 8 : 4)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.30), lineWidth: 0.75)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 2.5, y: 1.5)
        }
        .frame(width: 56, height: 56)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(SiphonAnimation.hoverSpring) {
                isHovered = hovering
            }
        }
    }
}
