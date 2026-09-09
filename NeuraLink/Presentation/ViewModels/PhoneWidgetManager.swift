//
//  PhoneWidgetManager.swift
//  NeuraLink
//
//  Drives the companion's phone widget (PhoneWidgetView): when a tool call
//  produces a deferred app-open (Safari search, Apple Music, app launch,
//  note), the open no longer fires automatically — AppFunctionExecutor wraps
//  it so that, after the persona finishes speaking, the phone slides in
//  showing what's ready. Tapping the phone performs the actual open;
//  dismissing or ignoring it (45 s) drops the action.
//
//  Created by Dedicatus on 09/09/2026.
//

import Foundation

@Observable
final class PhoneWidgetManager {
    static let shared = PhoneWidgetManager()

    /// Ignored phones put themselves away.
    static let autoDismissAfter: TimeInterval = 45

    /// Non-nil while the phone is on screen.
    private(set) var card: ToolActionCard?

    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Shows the phone with `card`; `action` runs when the user taps it.
    /// A newer card replaces the current one (last tool wins).
    func present(card: ToolActionCard, action: @escaping () -> Void) {
        self.card = card
        self.action = action
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoDismissAfter))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
        nlLog("[PhoneWidget] Presented: \(card.title) — \(card.appName)", level: .info)
    }

    /// The tap: performs the deferred open, then puts the phone away.
    func openAndDismiss() {
        let pending = action
        dismiss()
        pending?()
    }

    /// Puts the phone away without opening anything.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        card = nil
        action = nil
    }

    // MARK: - Card synthesis (pure, unit-tested)

    /// Maps a tool call to its phone card. Nil means the tool has no
    /// phone moment (its deferred action, if any, fires directly as before).
    nonisolated static func card(for toolName: String, arguments: [String: Any]) -> ToolActionCard? {
        switch toolName {
        case AppFunctionTool.searchWeb:
            let query = arguments["query"] as? String ?? ""
            return ToolActionCard(
                kind: .webSearch, appName: "Safari", systemImage: "safari.fill",
                title: "Web Search", detail: query)
        case AppFunctionTool.playMusic:
            let query = arguments["query"] as? String ?? ""
            return ToolActionCard(
                kind: .music, appName: "Apple Music", systemImage: "music.note",
                title: "Music Search", detail: query)
        case AppFunctionTool.openApp:
            let app = arguments["app"] as? String ?? "App"
            return ToolActionCard(
                kind: .app, appName: app, systemImage: "square.grid.2x2.fill",
                title: "Open App", detail: app)
        case AppFunctionTool.createNote:
            let title = arguments["title"] as? String ?? ""
            return ToolActionCard(
                kind: .note, appName: "Notes", systemImage: "note.text",
                title: "New Note", detail: title)
        default:
            return nil
        }
    }
}
