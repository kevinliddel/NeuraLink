//
//  ContentView+Tutorial.swift
//  NeuraLink
//
//  Hosts the onboarding tour on top of the live scene: renders the spotlight
//  overlay, and poses the FAB menu so whichever control the current beat
//  explains is actually on screen while it's explained.
//
//  Created by Dedicatus on 15/09/2026.
//

import SwiftUI

extension View {
    /// Adds the onboarding tour layer, driven by `TutorialCoordinator.shared`.
    /// The two bindings are the host's FAB menu state, which the tour poses.
    func tutorialLayer(
        isMenuExpanded: Binding<Bool>,
        isSecondaryExpanded: Binding<Bool>
    ) -> some View {
        modifier(
            TutorialLayer(
                isMenuExpanded: isMenuExpanded,
                isSecondaryExpanded: isSecondaryExpanded))
    }
}

private struct TutorialLayer: ViewModifier {
    @Binding var isMenuExpanded: Bool
    @Binding var isSecondaryExpanded: Bool

    @State private var tutorial = TutorialCoordinator.shared
    @State private var anchors = TutorialAnchorRegistry.shared

    func body(content: Content) -> some View {
        content
            .overlay { overlay }
            .onChange(of: tutorial.menuState) { _, state in pose(state) }
            .onChange(of: tutorial.isActive) { _, active in
                if active {
                    pose(tutorial.menuState)
                } else {
                    pose(.collapsed)
                }
            }
    }

    @ViewBuilder
    private var overlay: some View {
        GeometryReader { proxy in
            if let step = tutorial.step {
                TutorialOverlay(
                    step: step,
                    index: tutorial.stepIndex,
                    total: tutorial.stepCount,
                    isFirst: tutorial.isFirstStep,
                    isLast: tutorial.isLastStep,
                    spotlight: spotlight(for: step, in: proxy),
                    size: proxy.size,
                    onBack: { tutorial.rewind() },
                    onNext: { tutorial.advance() },
                    onSkip: { tutorial.skip() })
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: tutorial.isActive)
    }

    // MARK: - Geometry

    /// Anchored frames are reported globally; the overlay draws in its own
    /// space, so shift them by the overlay's origin before the resolver
    /// decides whether to trust them.
    private func spotlight(for step: TutorialStep, in proxy: GeometryProxy) -> CGRect? {
        guard let anchor = step.anchor else { return nil }
        let origin = proxy.frame(in: .global).origin
        let measured = anchors.frames[anchor]?.offsetBy(dx: -origin.x, dy: -origin.y)
        // NOT `proxy.safeAreaInsets`: this reader ignores the safe area, so it
        // reports zero — which put the navigation-bar spotlight up in the
        // status bar. The window knows the real insets.
        let insets = WindowSafeArea.insets
        let resolver = TutorialSpotlightResolver(
            size: proxy.size,
            safeAreaTop: insets.top,
            safeAreaLeading: insets.left,
            safeAreaTrailing: insets.right)
        return resolver.resolve(anchor: anchor, measured: measured)
    }

    // MARK: - Menu posing

    private func pose(_ state: TutorialStep.MenuState) {
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
}
