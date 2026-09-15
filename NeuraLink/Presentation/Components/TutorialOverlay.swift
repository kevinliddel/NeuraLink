//
//  TutorialOverlay.swift
//  NeuraLink
//
//  The tour's spotlight layer: dims the whole screen, punches a hole around
//  the control being explained, pulses a ring on it, and floats the
//  explanation card clear of the cut-out. Swallows every touch so the app
//  underneath can't be poked mid-tour — advancing is the card (or a tap
//  anywhere on the dim).
//
//  Created by Dedicatus on 15/09/2026.
//

import SwiftUI

struct TutorialOverlay: View {
    let step: TutorialStep
    let index: Int
    let total: Int
    let isFirst: Bool
    let isLast: Bool
    /// Frame of the highlighted control, in this overlay's coordinate space.
    /// Nil for beats that explain the scene or on-demand UI.
    let spotlight: CGRect?
    /// Full size of the overlay, used to decide which side the card sits on.
    let size: CGSize
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    /// Breathing room between the highlighted control and the hole's edge.
    private static let spotlightPadding: CGFloat = 10
    /// Gap between the hole and the card.
    private static let cardGap: CGFloat = 22

    @State private var pulse = false

    var body: some View {
        ZStack {
            dimming
            if let hole = paddedSpotlight {
                ring(around: hole)
            }
            card
        }
        .animation(.easeInOut(duration: 0.28), value: step.id)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: - Layers

    /// Scrim with the spotlight punched out. Also the tap-anywhere target.
    private var dimming: some View {
        Rectangle()
            .fill(.black.opacity(0.74))
            .mask {
                ZStack {
                    Rectangle()
                    if let hole = paddedSpotlight {
                        RoundedRectangle(cornerRadius: cornerRadius(for: hole), style: .continuous)
                            .frame(width: hole.width, height: hole.height)
                            .position(x: hole.midX, y: hole.midY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onNext)
            .accessibilityHidden(true)
    }

    private func ring(around hole: CGRect) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius(for: hole), style: .continuous)
            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
            .frame(width: hole.width, height: hole.height)
            .scaleEffect(pulse ? 1.06 : 1.0)
            .position(x: hole.midX, y: hole.midY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var card: some View {
        let content = TutorialCard(
            step: step,
            index: index,
            total: total,
            isFirst: isFirst,
            isLast: isLast,
            onBack: onBack,
            onNext: onNext,
            onSkip: onSkip)

        VStack(spacing: 0) {
            if paddedSpotlight == nil {
                // No target: centre the card on screen.
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
            } else if placeCardBelowSpotlight {
                content
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                content
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, cardTopInset)
        .padding(.bottom, cardBottomInset)
        .frame(width: size.width, height: size.height)
        .transition(.opacity)
    }

    // MARK: - Geometry

    private var paddedSpotlight: CGRect? {
        spotlight.map { $0.insetBy(dx: -Self.spotlightPadding, dy: -Self.spotlightPadding) }
    }

    /// Circular for square-ish controls (every FAB and toolbar button),
    /// capsule-ish for the wide status hint.
    private func cornerRadius(for hole: CGRect) -> CGFloat {
        min(hole.width, hole.height) / 2
    }

    /// A spotlight in the upper half gets its card underneath, and vice
    /// versa; with no spotlight the card is vertically centred.
    private var placeCardBelowSpotlight: Bool {
        guard let hole = paddedSpotlight else { return false }
        return hole.midY < size.height * 0.5
    }

    private var cardTopInset: CGFloat {
        guard let hole = paddedSpotlight, placeCardBelowSpotlight else { return 0 }
        return max(0, hole.maxY + Self.cardGap)
    }

    private var cardBottomInset: CGFloat {
        guard let hole = paddedSpotlight, !placeCardBelowSpotlight else { return 0 }
        return max(0, size.height - hole.minY + Self.cardGap)
    }
}
