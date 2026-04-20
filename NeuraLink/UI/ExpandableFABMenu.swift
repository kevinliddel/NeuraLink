//
//  ExpandableFABMenu.swift
//  NeuraLink
//
//  Created by Dedicatus on 20/04/2026.
//

import SwiftUI

/// Expanded child buttons that drop below the toolbar toggle.
/// The toggle itself lives in the NavigationBar as a ToolbarItem.
struct ExpandableFABMenu: View {
    @Binding var isExpanded: Bool
    let onSettings: () -> Void
    let onModelSelection: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isExpanded {
                FABChildButton(
                    icon: "gear",
                    action: {
                        collapse()
                        onSettings()
                    }
                )
                .transition(childTransition(delay: 0.06))

                FABChildButton(
                    icon: "figure.stand.dress.line.vertical.figure",
                    action: {
                        collapse()
                        onModelSelection()
                    }
                )
                .transition(childTransition(delay: 0.0))
            }
        }
        .padding(.trailing, 20)
    }

    private func collapse() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            isExpanded = false
        }
    }

    private func childTransition(delay: Double) -> AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.4)
                .combined(with: .opacity)
                .animation(.spring(response: 0.32, dampingFraction: 0.7).delay(delay)),
            removal: .scale(scale: 0.4)
                .combined(with: .opacity)
                .animation(.spring(response: 0.22, dampingFraction: 0.8))
        )
    }
}

private struct FABChildButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(
            action: action,
            label: {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5))
                    .clipShape(Circle())
            })
    }
}
