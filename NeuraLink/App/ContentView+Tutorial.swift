//
//  ContentView+Tutorial.swift
//  NeuraLink
//
//  Hosts the onboarding tour on top of the live scene: renders the spotlight
//  overlay, poses the FAB menu so whichever control the current beat
//  explains is actually on screen while it's explained, and opens (and
//  later closes) the Settings sheet for the beat whose target lives there.
//
//  Created by Dedicatus on 15/09/2026.
//

import SwiftUI

extension View {
    /// Adds the onboarding tour layer, driven by `TutorialCoordinator.shared`.
    /// The first two bindings are the host's FAB menu state, the third its
    /// Settings sheet; the tour poses all three.
    func tutorialLayer(
        isMenuExpanded: Binding<Bool>,
        isSecondaryExpanded: Binding<Bool>,
        isSettingsPresented: Binding<Bool>
    ) -> some View {
        modifier(
            TutorialLayer(
                isMenuExpanded: isMenuExpanded,
                isSecondaryExpanded: isSecondaryExpanded,
                isSettingsPresented: isSettingsPresented))
    }
}

private struct TutorialLayer: ViewModifier {
    @Binding var isMenuExpanded: Bool
    @Binding var isSecondaryExpanded: Bool
    @Binding var isSettingsPresented: Bool

    @State private var tutorial = TutorialCoordinator.shared
    /// True while the sheet is up because the tour opened it — only then is
    /// it the tour's to close again.
    @State private var didPresentSettings = false

    func body(content: Content) -> some View {
        content
            .overlay { TutorialOverlayHost(screen: .scene) }
            .onChange(of: tutorial.menuState) { _, state in poseMenu(state) }
            .onChange(of: tutorial.screen) { _, screen in poseScreen(screen) }
            .onChange(of: tutorial.isActive) { _, active in
                if active {
                    poseMenu(tutorial.menuState)
                    poseScreen(tutorial.screen)
                } else {
                    poseMenu(.collapsed)
                    poseScreen(.scene)
                }
            }
    }

    // MARK: - Menu posing

    private func poseMenu(_ state: TutorialStep.MenuState) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            switch state {
            case .collapsed:
                isMenuExpanded = false
                isSecondaryExpanded = false
            case .primary:
                isMenuExpanded = true
                isSecondaryExpanded = false
            case .secondary:
                isMenuExpanded = true
                isSecondaryExpanded = true
            }
        }
    }

    // MARK: - Screen posing

    /// Presents the Settings sheet for a beat that lives inside it, and
    /// dismisses it again when the tour moves on or ends — but only a sheet
    /// the tour itself opened; one the user already had up is left alone.
    /// The sheet pushes the Autonomy screen on its own (AISettingsView).
    private func poseScreen(_ screen: TutorialStep.Screen) {
        switch screen {
        case .autonomySettings:
            guard !isSettingsPresented else { return }
            didPresentSettings = true
            isSettingsPresented = true
        case .scene:
            guard didPresentSettings else { return }
            didPresentSettings = false
            isSettingsPresented = false
        }
    }
}
