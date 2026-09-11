//
//  PhoneWidgetTests.swift
//  NeuraLinkTests
//
//  The companion's phone widget: tool→card synthesis, manager lifecycle,
//  and the executor wrapping that turns auto-opens into tap-to-open.
//

import CoreGraphics
import Foundation
import Testing

@testable import NeuraLink

@Suite("Phone Widget", .serialized)
struct PhoneWidgetTests {

    // MARK: - Card synthesis

    @Test("Web search, music, app, note, and weather map to cards")
    func cardMapping() {
        let search = PhoneWidgetManager.card(
            for: AppFunctionTool.searchWeb, arguments: ["query": "best ramen"], result: "")
        #expect(search?.kind == .webSearch)
        #expect(search?.appName == "Safari")
        #expect(search?.detail == "best ramen")

        let music = PhoneWidgetManager.card(
            for: AppFunctionTool.playMusic, arguments: ["query": "JVKE"], result: "")
        #expect(music?.kind == .music)
        #expect(music?.appName == "Apple Music")

        let app = PhoneWidgetManager.card(
            for: AppFunctionTool.openApp, arguments: ["app": "Maps"], result: "")
        #expect(app?.kind == .app)
        #expect(app?.appName == "Maps")

        let note = PhoneWidgetManager.card(
            for: AppFunctionTool.createNote,
            arguments: ["title": "Groceries", "body": "milk"], result: "")
        #expect(note?.kind == .note)
        #expect(note?.detail == "Groceries")

        // Weather is display-only: the RESULT is the payload.
        let weather = PhoneWidgetManager.card(
            for: AppFunctionTool.getWeather,
            arguments: ["location": "tokyo"],
            result: "Current weather in Tokyo: partly cloudy. Temperature 22°C.")
        #expect(weather?.kind == .weather)
        #expect(weather?.appName == "Tokyo")
        #expect(weather?.detail.contains("22°C") == true)
    }

    @Test("Tools without a phone moment map to nil")
    func noCardForOtherTools() {
        #expect(PhoneWidgetManager.card(for: AppFunctionTool.setEmotion, arguments: [:], result: "") == nil)
        #expect(PhoneWidgetManager.card(for: AppFunctionTool.createReminder, arguments: [:], result: "") == nil)
        #expect(PhoneWidgetManager.card(for: AppFunctionTool.rememberFact, arguments: [:], result: "") == nil)
    }

    @Test("Display-only cards hide the open affordance and tap just dismisses")
    @MainActor
    func displayOnlyCard() {
        let manager = PhoneWidgetManager.shared
        manager.dismiss()
        defer { manager.dismiss() }

        let weather = ToolActionCard(
            kind: .weather, appName: "Tokyo", systemImage: "cloud.sun.fill",
            title: "Weather", detail: "22°C, partly cloudy")
        manager.present(card: weather, action: nil)
        #expect(manager.card == weather)
        #expect(!manager.canOpen)

        // Tap: nothing to fire, phone goes away cleanly.
        manager.openAndDismiss()
        #expect(manager.card == nil)

        // A tappable card restores the affordance.
        manager.present(
            card: ToolActionCard(
                kind: .webSearch, appName: "Safari", systemImage: "safari.fill",
                title: "Web Search", detail: "q")
        ) {}
        #expect(manager.canOpen)
    }

    // MARK: - Manager lifecycle

    @Test("Tap fires the deferred open exactly once and puts the phone away")
    @MainActor
    func openAndDismiss() {
        let manager = PhoneWidgetManager.shared
        manager.dismiss()

        var openCount = 0
        let card = ToolActionCard(
            kind: .webSearch, appName: "Safari", systemImage: "safari.fill",
            title: "Web Search", detail: "q")
        manager.present(card: card) { openCount += 1 }
        #expect(manager.card == card)

        manager.openAndDismiss()
        #expect(openCount == 1)
        #expect(manager.card == nil)

        // A second tap after dismissal must not re-fire.
        manager.openAndDismiss()
        #expect(openCount == 1)
    }

    @Test("Dismiss drops the action without firing it")
    @MainActor
    func dismissDropsAction() {
        let manager = PhoneWidgetManager.shared
        manager.dismiss()

        var openCount = 0
        let card = ToolActionCard(
            kind: .note, appName: "Notes", systemImage: "note.text",
            title: "New Note", detail: "t")
        manager.present(card: card) { openCount += 1 }
        manager.dismiss()
        #expect(manager.card == nil)
        #expect(openCount == 0)
    }

    @Test("A newer card replaces the current one")
    @MainActor
    func newerCardReplaces() {
        let manager = PhoneWidgetManager.shared
        manager.dismiss()
        defer { manager.dismiss() }

        let first = ToolActionCard(
            kind: .music, appName: "Apple Music", systemImage: "music.note",
            title: "Music Search", detail: "first")
        let second = ToolActionCard(
            kind: .webSearch, appName: "Safari", systemImage: "safari.fill",
            title: "Web Search", detail: "second")
        manager.present(card: first) {}
        manager.present(card: second) {}
        #expect(manager.card == second)
    }

    // MARK: - Drag position

    @Test("Clamp keeps the phone on screen in every direction")
    func offsetClamping() {
        let screen = CGSize(width: 393, height: 852)  // iPhone 15/16/17 class

        // A sane in-range offset passes through untouched.
        let ok = CGSize(width: 40, height: -100)
        #expect(PhoneWidgetManager.clampedOffset(ok, screen: screen) == ok)

        // Dragged far off every edge → pulled back inside.
        let clamped = PhoneWidgetManager.clampedOffset(
            CGSize(width: -2_000, height: 2_000), screen: screen)
        #expect(clamped.width == -PhoneWidgetManager.homeLeadingInset + 8)
        #expect(clamped.height == PhoneWidgetManager.homeBottomInset - 24)

        let farRightUp = PhoneWidgetManager.clampedOffset(
            CGSize(width: 2_000, height: -2_000), screen: screen)
        // Right edge stays within the screen.
        let rightEdge = PhoneWidgetManager.homeLeadingInset + farRightUp.width
            + PhoneWidgetManager.phoneSize.width
        #expect(rightEdge <= screen.width - 8)
        // Top edge stays below the nav-bar area.
        let topEdge = screen.height - PhoneWidgetManager.homeBottomInset
            - PhoneWidgetManager.phoneSize.height + farRightUp.height
        #expect(topEdge >= 70)

        // Degenerate screen (previews): passthrough, no wild math.
        let degenerate = PhoneWidgetManager.clampedOffset(
            CGSize(width: 999, height: 999), screen: .zero)
        #expect(degenerate == CGSize(width: 999, height: 999))
    }

    @Test("Parked position persists across appearances")
    @MainActor
    func offsetPersistence() {
        let manager = PhoneWidgetManager.shared
        let original = manager.loadOffset()
        defer { manager.saveOffset(original) }

        let parked = CGSize(width: 55, height: -120)
        manager.saveOffset(parked)
        #expect(manager.loadOffset() == parked)
    }

    // MARK: - Executor wrapping

    @Test("A card-mapped tool's deferred action presents the phone instead of opening")
    @MainActor
    func executorWrapsIntoWidget() async {
        let manager = PhoneWidgetManager.shared
        manager.dismiss()
        defer { manager.dismiss() }

        let executor = AppFunctionExecutor.shared
        _ = await executor.execute(
            name: AppFunctionTool.searchWeb, arguments: ["query": "phone widget test"])
        #expect(executor.pendingUIAction != nil)

        // Firing the deferred action (what happens after speech ends) must
        // raise the phone, not open Safari.
        executor.pendingUIAction?()
        executor.pendingUIAction = nil
        try? await Task.sleep(for: .milliseconds(150))

        #expect(manager.card?.kind == .webSearch)
        #expect(manager.card?.detail == "phone widget test")
    }
}
