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

@MainActor
final class NotesSkill: Skill {
    static let toolName = AppFunctionTool.createNote
    var pendingUIAction: (() -> Void)?

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
            return "Created a new note titled \"\(title)\" in Bear."
        }

        UIPasteboard.general.string = combined
        if let notesURL = URL(string: "mobilenotes://"),
            UIApplication.shared.canOpenURL(notesURL) {
            pendingUIAction = { UIApplication.shared.open(notesURL) }
            return "Opened Notes. I've copied your note to the clipboard — paste it in a new note!"
        }

        return "I've copied the note content to your clipboard. Open Notes and paste to create it."
    }
}
