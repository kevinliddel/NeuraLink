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
    /// False for display-only cards (weather) — the view hides "Tap to open".
    private(set) var canOpen = true

    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Shows the phone with `card`; `action` runs when the user taps it —
    /// nil means display-only (the screen itself is the payload; tap just
    /// puts the phone away). A newer card replaces the current one.
    func present(card: ToolActionCard, action: (() -> Void)?) {
        self.card = card
        self.action = action
        self.canOpen = action != nil
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

    // MARK: - Position persistence (drag to park; reappears where left)

    private static let offsetXKey = "com.neuralink.phonewidget.offsetX"
    private static let offsetYKey = "com.neuralink.phonewidget.offsetY"

    /// Rendered size of the phone (kept in sync with PhoneWidgetView) and its
    /// home anchor (bottom-leading padding in ContentView) — the clamp math
    /// needs both.
    nonisolated static let phoneSize = CGSize(width: 148, height: 272)
    nonisolated static let homeLeadingInset: CGFloat = 14
    nonisolated static let homeBottomInset: CGFloat = 150

    /// Where the user last parked the phone, as an offset from its home
    /// (bottom-leading) anchor.
    func loadOffset() -> CGSize {
        let defaults = UserDefaults.standard
        return CGSize(
            width: defaults.double(forKey: Self.offsetXKey),
            height: defaults.double(forKey: Self.offsetYKey))
    }

    func saveOffset(_ offset: CGSize) {
        let defaults = UserDefaults.standard
        defaults.set(offset.width, forKey: Self.offsetXKey)
        defaults.set(offset.height, forKey: Self.offsetYKey)
    }

    /// Keeps the phone reachable: whatever the drag proposes, the device can
    /// never be parked off-screen or under the nav bar. Pure, unit-tested.
    nonisolated static func clampedOffset(_ proposed: CGSize, screen: CGSize) -> CGSize {
        // Degenerate/unknown screen (previews, early layout): trust the caller.
        guard screen.width > 200, screen.height > 400 else { return proposed }
        let minX: CGFloat = -homeLeadingInset + 8
        let maxX = screen.width - phoneSize.width - homeLeadingInset - 8
        // Top edge stays below the nav-bar area (~70 pt)…
        let minY = 70 - (screen.height - homeBottomInset - phoneSize.height)
        // …and the bottom edge stays on screen.
        let maxY = homeBottomInset - 24
        return CGSize(
            width: min(max(proposed.width, minX), maxX),
            height: min(max(proposed.height, CGFloat(minY)), maxY))
    }

    // MARK: - Card synthesis (pure, unit-tested)

    /// Maps a tool call to its phone card. Nil means the tool has no
    /// phone moment (its deferred action, if any, fires directly as before).
    /// `result` feeds display-only cards, whose payload is the tool's answer
    /// rather than its arguments.
    nonisolated static func card(
        for toolName: String, arguments: [String: Any], result: String
    ) -> ToolActionCard? {
        switch toolName {
        case AppFunctionTool.getWeather:
            let location = (arguments["location"] as? String ?? "").capitalized
            return ToolActionCard(
                kind: .weather,
                appName: location.isEmpty ? "Weather" : location,
                systemImage: "cloud.sun.fill",
                title: "Weather",
                detail: String(result.prefix(180)))
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
