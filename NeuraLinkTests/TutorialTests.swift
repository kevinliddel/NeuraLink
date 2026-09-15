//
//  TutorialTests.swift
//  NeuraLinkTests
//
//  The onboarding tour: script integrity, the menu-pose invariant that keeps
//  a spotlight from pointing at a button that isn't on screen, and the
//  coordinator's step/persistence lifecycle.
//

import CoreGraphics
import Foundation
import Testing

@testable import NeuraLink

@Suite("Tutorial", .serialized)
@MainActor
struct TutorialTests {

    // MARK: - Script

    @Test("Every step has an id, a title and body, and ids are unique")
    func scriptIntegrity() {
        let steps = TutorialScript.steps
        #expect(!steps.isEmpty)
        for step in steps {
            #expect(!step.id.isEmpty)
            #expect(!step.title.isEmpty)
            #expect(!step.body.isEmpty)
            #expect(!step.icon.isEmpty)
        }
        #expect(Set(steps.map(\.id)).count == steps.count)
    }

    @Test("Each anchored step is posed at least as far as its target needs")
    func anchoredStepsArePosedFarEnough() {
        for step in TutorialScript.steps {
            guard let anchor = step.anchor else { continue }
            #expect(
                step.menu.rank >= anchor.requiredMenu.rank,
                "\(step.id) poses \(step.menu) but \(anchor) needs \(anchor.requiredMenu)")
        }
    }

    @Test("The tour covers every control the app can point at")
    func scriptCoversEveryAnchor() {
        let covered = Set(TutorialScript.steps.compactMap(\.anchor))
        for anchor in TutorialAnchor.allCases {
            #expect(covered.contains(anchor), "No tutorial step explains \(anchor)")
        }
    }

    // MARK: - Menu posing

    @Test("menuState never under-poses, even if a step declares too little")
    func menuStateClampsToAnchorRequirement() {
        let understated = TutorialStep(
            id: "x", icon: "gear", title: "t", body: "b",
            anchor: .fabPiP, menu: .collapsed)
        // The step asks for `.collapsed`, but PiP only exists in `.secondary`.
        #expect(understated.anchor?.requiredMenu == .secondary)
        #expect(understated.menu.rank < TutorialStep.MenuState.secondary.rank)

        let steps = TutorialScript.steps
        withTour { tutorial in
            for (index, step) in steps.enumerated() where step.anchor != nil {
                while tutorial.stepIndex < index { tutorial.advance() }
                #expect(tutorial.stepIndex == index)
                if let required = step.anchor?.requiredMenu {
                    #expect(tutorial.menuState.rank >= required.rank)
                }
            }
        }
    }

    @Test("No tour running means no menu posing")
    func idleCoordinatorPosesNothing() {
        let tutorial = TutorialCoordinator.shared
        #expect(!tutorial.isActive)
        #expect(tutorial.step == nil)
        #expect(tutorial.menuState == .collapsed)
    }

    // MARK: - Coordinator lifecycle

    @Test("Advancing walks the script and finishing marks the tour seen")
    func advanceToCompletion() {
        let original = TutorialSettings.shared.completedVersion
        defer { TutorialSettings.shared.completedVersion = original }

        TutorialSettings.shared.reset()
        let tutorial = TutorialCoordinator.shared
        tutorial.start()

        #expect(tutorial.isActive)
        #expect(tutorial.isFirstStep)
        #expect(tutorial.step?.id == TutorialScript.steps.first?.id)
        #expect(!TutorialSettings.shared.hasSeenCurrentTutorial)

        for _ in 0..<(tutorial.stepCount - 1) { tutorial.advance() }
        #expect(tutorial.isLastStep)
        #expect(tutorial.step?.id == TutorialScript.steps.last?.id)

        tutorial.advance()  // past the last step → finish
        #expect(!tutorial.isActive)
        #expect(tutorial.step == nil)
        #expect(TutorialSettings.shared.hasSeenCurrentTutorial)
    }

    @Test("Rewind steps back and never goes below the first step")
    func rewindClamps() {
        withTour { tutorial in
            tutorial.advance()
            tutorial.advance()
            #expect(tutorial.stepIndex == 2)
            tutorial.rewind()
            #expect(tutorial.stepIndex == 1)
            tutorial.rewind()
            tutorial.rewind()
            #expect(tutorial.stepIndex == 0)
            #expect(tutorial.isFirstStep)
            #expect(tutorial.isActive)
        }
    }

    @Test("Skipping counts as seen, so it doesn't nag on the next launch")
    func skipMarksSeen() {
        let original = TutorialSettings.shared.completedVersion
        defer { TutorialSettings.shared.completedVersion = original }

        TutorialSettings.shared.reset()
        let tutorial = TutorialCoordinator.shared
        tutorial.start()
        tutorial.advance()
        tutorial.skip()

        #expect(!tutorial.isActive)
        #expect(TutorialSettings.shared.hasSeenCurrentTutorial)
    }

    // MARK: - Persistence

    @Test("A version bump re-arms the tour for someone who already saw it")
    func versionBumpReArmsTour() {
        let settings = TutorialSettings.shared
        let original = settings.completedVersion
        defer { settings.completedVersion = original }

        settings.markSeen()
        #expect(settings.hasSeenCurrentTutorial)

        // Simulates shipping a newer script than the one last completed.
        settings.completedVersion = TutorialScript.version - 1
        #expect(!settings.hasSeenCurrentTutorial)

        settings.reset()
        #expect(settings.completedVersion == 0)
        #expect(!settings.hasSeenCurrentTutorial)
    }

    // MARK: - Spotlight resolution

    /// iPhone-shaped overlay: 59pt status bar, 44pt navigation bar under it.
    private var resolver: TutorialSpotlightResolver {
        TutorialSpotlightResolver(
            size: CGSize(width: 393, height: 852),
            safeAreaTop: 59, safeAreaLeading: 0, safeAreaTrailing: 0)
    }

    @Test("A measured in-scene frame is used as-is")
    func measuredSceneFrameWins() {
        let measured = CGRect(x: 320, y: 300, width: 44, height: 44)
        #expect(resolver.resolve(anchor: .fabSettings, measured: measured) == measured)
    }

    @Test("An in-scene control with no frame has no spotlight")
    func unmeasuredSceneControlHasNoSpotlight() {
        #expect(resolver.resolve(anchor: .fabSettings, measured: nil) == nil)
        #expect(resolver.resolve(anchor: .statusHint, measured: nil) == nil)
    }

    @Test("Navigation-bar items fall back to the bar's own geometry")
    func navigationBarEstimate() {
        let leading = resolver.resolve(anchor: .chatHistory, measured: nil)
        let trailing = resolver.resolve(anchor: .menuToggle, measured: nil)
        #expect(leading != nil)
        #expect(trailing != nil)
        // Inside the 44pt bar strip that sits under the status bar…
        let barCenterY: CGFloat = 59 + 22
        #expect(leading?.midY == barCenterY)
        #expect(trailing?.midY == barCenterY)
        // …and each on its own side.
        let midScreen: CGFloat = 393 / 2
        #expect((leading?.midX ?? 0) < midScreen)
        #expect((trailing?.midX ?? 0) > midScreen)
    }

    @Test("The tour explains where the AI itself comes from, and the profile")
    func scriptCoversSetupAndProfile() {
        let ids = Set(TutorialScript.steps.map(\.id))
        // Nobody can use the app without wiring up a brain first, and the
        // profile/memory pages are only reachable through the sidebar.
        #expect(ids.contains("brains"))
        #expect(ids.contains("profile"))

        let brains = TutorialScript.steps.first { $0.id == "brains" }
        let copy = ((brains?.body ?? "") + (brains?.tip ?? "")).lowercased()
        #expect(copy.contains("openai"))
        #expect(copy.contains("key"))
        #expect(copy.contains("offline"))
    }

    @Test("A bar-local frame is rejected, a window frame is trusted")
    func navigationBarFramePlausibility() {
        // What a frame looks like when reported in the bar's own space: at
        // the very top of the screen, above the status bar's midpoint.
        let barLocal = CGRect(x: 8, y: 2, width: 40, height: 40)
        #expect(!resolver.isPlausible(barLocal, for: .chatHistory))
        #expect(resolver.resolve(anchor: .chatHistory, measured: barLocal)
            == resolver.estimate(for: .chatHistory))

        // The same item measured in window coordinates is used directly.
        let windowSpace = CGRect(x: 16, y: 61, width: 40, height: 40)
        #expect(resolver.isPlausible(windowSpace, for: .chatHistory))
        #expect(resolver.resolve(anchor: .chatHistory, measured: windowSpace) == windowSpace)
    }

    @Test("A bar item measured on the wrong side is rejected")
    func navigationBarWrongSideRejected() {
        let onTheLeft = CGRect(x: 16, y: 61, width: 40, height: 40)
        #expect(!resolver.isPlausible(onTheLeft, for: .menuToggle))
        #expect(resolver.resolve(anchor: .menuToggle, measured: onTheLeft)
            == resolver.estimate(for: .menuToggle))
    }

    @Test("Degenerate and off-screen frames are never spotlighted")
    func degenerateFramesRejected() {
        #expect(!resolver.isPlausible(.zero, for: .fabSettings))
        #expect(!resolver.isPlausible(
            CGRect(x: -400, y: 300, width: 44, height: 44), for: .fabSettings))
        #expect(resolver.resolve(
            anchor: .fabSettings, measured: CGRect(x: 0, y: 0, width: 0, height: 0)) == nil)
    }

    // MARK: - Helpers

    /// Runs `work` against a live tour and always leaves the coordinator idle
    /// and the stored version untouched.
    private func withTour(_ work: (TutorialCoordinator) -> Void) {
        let original = TutorialSettings.shared.completedVersion
        let tutorial = TutorialCoordinator.shared
        tutorial.start()
        work(tutorial)
        tutorial.skip()
        TutorialSettings.shared.completedVersion = original
    }
}
