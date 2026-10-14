//
//  KeepsakeUnlockCapsule.swift
//  NeuraLink
//
//  The moment a keepsake is collected (docs/LIVING_COMPANION.md): a card
//  rises from the bottom of the scene with the badge, the title and one
//  line of meaning, plays a success haptic, and leaves on its own or on
//  tap. Same placement and glass as the photoshoot capsule.
//
//  Created by Dedicatus on 14/10/2026.
//

import SwiftUI

struct KeepsakeUnlockCapsule: View {
    @State private var controller = KeepsakeUnlockController.shared

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        // The ZStack always exists, so the insertion and removal of the card
        // happen inside its animation and the transition actually plays.
        ZStack {
            if let keepsake = controller.current {
                VStack {
                    Spacer()
                    card(keepsake)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 120)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: controller.current?.id)
        .sensoryFeedback(.success, trigger: controller.current?.id) { _, new in new != nil }
    }

    private func card(_ keepsake: CompanionMilestone) -> some View {
        HStack(spacing: 12) {
            Image(systemName: keepsake.kind.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.purple.opacity(0.85), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .symbolEffect(.bounce, value: keepsake.id)

            VStack(alignment: .leading, spacing: 2) {
                Text("Keepsake collected")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .textCase(.uppercase)
                Text(keepsake.kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(keepsake.kind.detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                controller.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .tint(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .contentShape(shape)
        .onTapGesture { controller.dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keepsake collected: \(keepsake.kind.title). \(keepsake.kind.detail)")
    }
}
