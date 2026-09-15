//
//  TutorialStep.swift
//  NeuraLink
//
//  One beat of the game-style onboarding tour: a spotlight target, the copy
//  that explains it, and the menu state the UI must be in for the target to
//  actually be on screen.
//
//  Created by Dedicatus on 15/09/2026.
//

import Foundation

/// A control the tour can point at. Views tag themselves with
/// `.tutorialAnchor(_:)` and the overlay resolves the tagged frame; anchors
/// the preference system can't reach (navigation-bar items) fall back to a
/// geometric estimate — see `TutorialOverlay`.
enum TutorialAnchor: String, CaseIterable, Sendable {
    /// Navigation bar, leading — opens the chat-history sidebar.
    case chatHistory
    /// Navigation bar, trailing — fans the FAB menu out and in.
    case menuToggle
    /// FAB, primary row.
    case fabSettings
    case fabRelationship
    /// FAB chevron — unfolds the secondary row.
    case fabChevron
    /// FAB, secondary row.
    case fabModels
    case fabCamera
    case fabSong
    case fabPiP
    /// The bottom status capsule ("Start talking", "Listening", …).
    case statusHint

    /// Navigation-bar items are hosted by UIKit's bar, outside the content
    /// view's own hierarchy, so a measured frame for them can't be trusted
    /// blindly — see TutorialSpotlightResolver.
    var isNavigationBarItem: Bool {
        self == .chatHistory || self == .menuToggle
    }

    /// The least-unfolded menu state in which this control exists on screen.
    /// The tour poses the UI to at least this state before spotlighting it,
    /// so a step can never point at a button that isn't there.
    var requiredMenu: TutorialStep.MenuState {
        switch self {
        case .fabSettings, .fabRelationship, .fabChevron:
            return .primary
        case .fabModels, .fabCamera, .fabSong, .fabPiP:
            return .secondary
        case .chatHistory, .menuToggle, .statusHint:
            return .collapsed
        }
    }
}

/// A single tour card.
struct TutorialStep: Identifiable, Equatable, Sendable {

    /// How much of the FAB menu must be unfolded for this step's target to be
    /// visible. The host view mirrors this onto its own menu state.
    enum MenuState: Equatable, Sendable {
        /// Menu closed — the step targets the scene, the toolbar, or nothing.
        case collapsed
        /// Primary row (Settings / Acquaintances / chevron) showing.
        case primary
        /// Both rows showing.
        case secondary

        /// How unfolded this state is. Higher states also show everything the
        /// lower ones show, which is what makes `max` meaningful.
        var rank: Int {
            switch self {
            case .collapsed: return 0
            case .primary: return 1
            case .secondary: return 2
            }
        }
    }

    let id: String
    /// SF Symbol shown on the card, echoing the real control's glyph.
    let icon: String
    let title: String
    let body: String
    /// Optional extra line for a hidden gesture (long-press, drag, …).
    let tip: String?
    /// Control to spotlight. `nil` centres the card with no cut-out — used
    /// for beats about the scene itself or UI that only appears on demand.
    let anchor: TutorialAnchor?
    let menu: MenuState

    init(
        id: String,
        icon: String,
        title: String,
        body: String,
        tip: String? = nil,
        anchor: TutorialAnchor? = nil,
        menu: MenuState = .collapsed
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.body = body
        self.tip = tip
        self.anchor = anchor
        self.menu = menu
    }
}
