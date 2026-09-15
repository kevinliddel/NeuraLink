//
//  TutorialCard.swift
//  NeuraLink
//
//  The explanation card of the onboarding tour: glyph, copy, progress pips
//  and the Back / Next controls. Purely presentational — every action is a
//  closure owned by TutorialOverlay.
//
//  Created by Dedicatus on 15/09/2026.
//

import SwiftUI

struct TutorialCard: View {
    let step: TutorialStep
    let index: Int
    let total: Int
    let isFirst: Bool
    let isLast: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    /// Keeps the card readable on a phone while never touching the edges.
    static let maxWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(step.body)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)

            if let tip = step.tip {
                Label(tip, systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            pips
            controls
        }
        .padding(18)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    LinearGradient(
                        colors: [.cyan.opacity(0.85), .blue.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(index + 1) of \(total)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
    }

    /// Back / Skip / Next. Every label is `fixedSize`d: with a dozen-plus
    /// steps the pips used to squeeze this row until "Next" wrapped to two
    /// lines on a phone, which is why the pips now sit on their own row.
    private var controls: some View {
        HStack(spacing: 12) {
            if !isFirst {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous step")
            }

            Spacer(minLength: 0)

            if !isLast {
                Button("Skip", action: onSkip)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .fixedSize()
            }

            Button(action: onNext) {
                Text(isLast ? "Let's go" : "Next")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.borderless)
        }
        .padding(.top, 2)
    }

    /// Progress pips on their own row — the current one stretches into a
    /// dash. Scaled down so even a long tour fits the card width.
    private var pips: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { slot in
                Capsule()
                    .fill(.white.opacity(slot == index ? 0.95 : 0.26))
                    .frame(width: slot == index ? 14 : 5, height: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: index)
        .accessibilityHidden(true)
    }
}
