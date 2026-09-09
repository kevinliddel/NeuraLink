//
//  ToolActionCard.swift
//  NeuraLink
//
//  What the companion's phone widget shows for a deferred tool action
//  (web search, music, app launch, note) — the GTA/Ananta-style "she holds
//  up her phone" moment. Framework-free entity; colors and layout live in
//  PhoneWidgetView, the open() closure lives in PhoneWidgetManager.
//
//  Created by Dedicatus on 09/09/2026.
//

import Foundation

struct ToolActionCard: Equatable {
    enum Kind: Equatable {
        case webSearch
        case music
        case app
        case note
    }

    let kind: Kind
    /// The destination app's name, shown on the phone screen ("Safari",
    /// "Apple Music", "Maps", "Notes").
    let appName: String
    /// SF Symbol for the app icon tile.
    let systemImage: String
    /// What the action is ("Web Search", "Music Search", …).
    let title: String
    /// The query / note title / detail line.
    let detail: String
}
