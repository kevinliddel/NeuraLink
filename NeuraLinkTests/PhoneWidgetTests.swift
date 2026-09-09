//
//  PhoneWidgetTests.swift
//  NeuraLinkTests
//
//  The companion's phone widget: tool→card synthesis, manager lifecycle,
//  and the executor wrapping that turns auto-opens into tap-to-open.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Phone Widget", .serialized)
struct PhoneWidgetTests {

    // MARK: - Card synthesis

    @Test("Web search, music, app, and note map to cards")
    func cardMapping() {
        let search = PhoneWidgetManager.card(
            for: AppFunctionTool.searchWeb, arguments: ["query": "best ramen"])
        #expect(search?.kind == .webSearch)
        #expect(search?.appName == "Safari")
        #expect(search?.detail == "best ramen")

        let music = PhoneWidgetManager.card(
            for: AppFunctionTool.playMusic, arguments: ["query": "JVKE"])
        #expect(music?.kind == .music)
        #expect(music?.appName == "Apple Music")

        let app = PhoneWidgetManager.card(
            for: AppFunctionTool.openApp, arguments: ["app": "Maps"])
        #expect(app?.kind == .app)
        #expect(app?.appName == "Maps")

        let note = PhoneWidgetManager.card(
            for: AppFunctionTool.createNote, arguments: ["title": "Groceries", "body": "milk"])
        #expect(note?.kind == .note)
        #expect(note?.detail == "Groceries")
    }

    @Test("Tools without a phone moment map to nil")
    func noCardForOtherTools() {
        #expect(PhoneWidgetManager.card(for: AppFunctionTool.getWeather, arguments: [:]) == nil)
        #expect(PhoneWidgetManager.card(for: AppFunctionTool.setEmotion, arguments: [:]) == nil)
        #expect(PhoneWidgetManager.card(for: AppFunctionTool.createReminder, arguments: [:]) == nil)
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
