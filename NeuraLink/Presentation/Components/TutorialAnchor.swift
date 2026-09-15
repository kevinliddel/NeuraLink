//
//  TutorialAnchor.swift
//  NeuraLink
//
//  Lets any control publish its on-screen frame to the onboarding overlay
//  with `.tutorialAnchor(.fabSettings)`, so the spotlight tracks the real
//  layout instead of hard-coded coordinates.
//
//  Frames are reported in the `.global` space through a small registry
//  rather than through a PreferenceKey: navigation-bar items are hosted
//  outside the content view's preference tree, so anchor preferences never
//  reach an overlay on the content — a global frame always does.
//
//  Created by Dedicatus on 15/09/2026.
//

import SwiftUI

/// Live frames of the controls the tour can point at. Entries are added on
/// appear, refreshed on layout change, and removed on disappear — so a
/// button that isn't on screen (a folded-away FAB) has no frame at all.
@Observable
final class TutorialAnchorRegistry {
    static let shared = TutorialAnchorRegistry()

    @ObservationIgnored private var _frames: [TutorialAnchor: CGRect] = [:]

    private init() {}

    var frames: [TutorialAnchor: CGRect] {
        get {
            access(keyPath: \.frames)
            return _frames
        }
        set {
            withMutation(keyPath: \.frames) { _frames = newValue }
        }
    }

    func report(_ anchor: TutorialAnchor, frame: CGRect) {
        guard frames[anchor] != frame else { return }
        frames[anchor] = frame
    }

    func clear(_ anchor: TutorialAnchor) {
        guard frames[anchor] != nil else { return }
        frames[anchor] = nil
    }
}

extension View {
    /// Tags this view as the spotlight target for `anchor`.
    func tutorialAnchor(_ anchor: TutorialAnchor) -> some View {
        background(TutorialAnchorReporter(anchor: anchor))
    }
}

/// Measures its host and keeps the registry in sync. Reports happen from
/// `onAppear`/`onChange`, never during body evaluation.
private struct TutorialAnchorReporter: View {
    let anchor: TutorialAnchor

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onAppear { TutorialAnchorRegistry.shared.report(anchor, frame: frame) }
                .onChange(of: frame) { _, new in
                    TutorialAnchorRegistry.shared.report(anchor, frame: new)
                }
                .onDisappear { TutorialAnchorRegistry.shared.clear(anchor) }
        }
        .accessibilityHidden(true)
    }
}
