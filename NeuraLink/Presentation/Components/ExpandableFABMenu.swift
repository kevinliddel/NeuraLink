//
//  ExpandableFABMenu.swift
//  NeuraLink
//
//  Created by Dedicatus on 20/04/2026.
//

import SwiftUI

struct ExpandableFABMenu: View {
    @Binding var isExpanded: Bool
    @State private var isSecondaryExpanded = false

    let onSettings: () -> Void
    let onUserSettings: () -> Void
    let onRelationship: () -> Void
    let onModelSelection: () -> Void
    let onCameraToggle: () -> Void
    let onPiP: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isExpanded {
                // Primary 3 — text reveals when secondary expands
                FABButton(
                    icon: Image(systemName: "gear"),
                    label: "Settings",
                    showLabel: isSecondaryExpanded
                ) { collapse(); onSettings() }
                .transition(childTransition(delay: 0.00))

                FABButton(
                    icon: Image(systemName: "person.crop.circle"),
                    label: "User Settings",
                    showLabel: isSecondaryExpanded
                ) { collapse(); onUserSettings() }
                .transition(childTransition(delay: 0.04))

                FABButton(
                    icon: Image(systemName: "suit.heart.fill"),
                    label: "Acquaintances",
                    showLabel: isSecondaryExpanded
                ) { collapse(); onRelationship() }
                .transition(childTransition(delay: 0.08))

                // Secondary 3 — appear above chevron with same animation; text always visible
                if isSecondaryExpanded {
                    FABButton(
                        icon: Image("neuralink").renderingMode(.template),
                        label: "Models",
                        showLabel: true
                    ) { collapse(); onModelSelection() }
                    .transition(childTransition(delay: 0.00))

                    FABButton(
                        icon: Image(systemName: "video.doorbell.fill"),
                        label: "Camera",
                        showLabel: true
                    ) { collapse(); onCameraToggle() }
                    .transition(childTransition(delay: 0.04))

                    FABButton(
                        icon: Image(systemName: "pip.fill"),
                        label: "PiP",
                        showLabel: true
                    ) { collapse(); onPiP() }
                    .transition(childTransition(delay: 0.08))
                }

                // Chevron — always last
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                        isSecondaryExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isSecondaryExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(childTransition(delay: 0.12))
            }
        }
        .padding(.trailing, 20)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { isSecondaryExpanded = false }
        }
    }

    private func collapse() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            isExpanded = false
            isSecondaryExpanded = false
        }
    }

    private func childTransition(delay: Double) -> AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.4).combined(with: .opacity)
                .animation(.spring(response: 0.32, dampingFraction: 0.7).delay(delay)),
            removal: .scale(scale: 0.4).combined(with: .opacity)
                .animation(.spring(response: 0.22, dampingFraction: 0.8))
        )
    }
}

// MARK: - Unified FAB button

private struct FABButton: View {
    let icon: Image
    let label: String
    let showLabel: Bool
    let action: () -> Void

    @State private var textVisible = false

    var body: some View {
        HStack(spacing: 8) {
            if textVisible {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button(action: action) {
                icon
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 17, weight: .regular))
                    .imageScale(.large)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        // Trigger on first appear (handles secondary buttons whose showLabel is already true)
        .onAppear {
            guard showLabel else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75).delay(0.18)) {
                textVisible = true
            }
        }
        // React to external changes (handles primary buttons reacting to chevron)
        .onChange(of: showLabel) { _, show in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75).delay(show ? 0.18 : 0)) {
                textVisible = show
            }
        }
        .onDisappear { textVisible = false }
        .accessibilityLabel(label)
    }
}
