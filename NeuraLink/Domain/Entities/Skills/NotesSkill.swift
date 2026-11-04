//
//  NotesSkill.swift
//  NeuraLink
//
//  Creates a note by copying content to clipboard and opening the Notes app.
//
//  Created by Dedicatus on 10/05/2026.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class NotesSkill: Skill {
    static let toolName = AppFunctionTool.createNote
    var pendingUIAction: (() -> Void)?

    /// How long the note stays on the clipboard: long enough to switch to
    /// Notes and paste, short enough that it doesn't linger for other apps.
    static let clipboardLifetime: TimeInterval = 10 * 60

    func execute(arguments: [String: Any]) async -> String {
        let title = arguments["title"] as? String ?? "Note"
        let body = arguments["body"] as? String ?? ""
        return openNotes(title: title, body: body)
    }

    private func openNotes(title: String, body: String) -> String {
        let combined = "\(title)\n\n\(body)"

        if let bearURL = URL(
            string: "bear://x-callback-url/create?title=\(title.urlEncoded)&text=\(body.urlEncoded)"
        ), UIApplication.shared.canOpenURL(bearURL) {
            pendingUIAction = { UIApplication.shared.open(bearURL) }
            return "A new Bear note titled \"\(title)\" is ready on my phone — tap it to open."
        }

        if let notesURL = URL(string: "mobilenotes://"),
            UIApplication.shared.canOpenURL(notesURL) {
            // Copied on the tap, not now: the clipboard is only touched once
            // the user has chosen to act on the note.
            pendingUIAction = {
                Self.copyToClipboard(combined)
                UIApplication.shared.open(notesURL)
            }
            return "Notes is ready on my phone with your note on the clipboard — tap it, then paste!"
        }

        Self.copyToClipboard(combined)
        return "I've copied the note content to your clipboard. Open Notes and paste to create it."
    }

    /// Local-only (no Universal Clipboard hop to the user's other devices)
    /// and self-expiring, since the note is model-written personal content.
    static func copyToClipboard(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(clipboardLifetime)
            ])
    }
}
