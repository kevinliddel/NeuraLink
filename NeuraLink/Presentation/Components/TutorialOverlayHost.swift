//
//  TutorialOverlayHost.swift
//  NeuraLink
//
//  Draws the tour's spotlight overlay for the beats that belong to one
//  screen. The scene hosts one for `.scene`; the Settings sheet hosts one
//  for `.autonomySettings`, so a beat about a switch inside the sheet cuts
//  its hole in the sheet instead of in the scene underneath it.
//
//  Created by Dedicatus on 30/10/2026.
//

import SwiftUI

struct TutorialOverlayHost: View {
    /// The screen this host draws on. Beats for any other screen render
    /// nothing here — their own host shows them.
    let screen: TutorialStep.Screen

    @State private var tutorial = TutorialCoordinator.shared
    @State private var anchors = TutorialAnchorRegistry.shared

    var body: some View {
        GeometryReader { proxy in
            if let step = tutorial.step, tutorial.screen == screen {
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
        .animation(.easeInOut(duration: 0.25), value: tutorial.screen)
    }

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
}
