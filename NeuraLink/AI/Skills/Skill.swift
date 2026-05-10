//
//  Skill.swift
//  NeuraLink
//
//  Protocol every AI tool skill must conform to.
//  Drop a new Skill file into this folder and register it in AppFunctionExecutor — done.
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation

/// A self-contained unit of AI tool capability.
/// Each skill owns its own implementation and may schedule a deferred UI action.
@MainActor
protocol Skill: AnyObject {

    /// The exact tool name string used in the OpenAI function-call schema.
    static var toolName: String { get }

    /// Called by the executor when the AI invokes this skill.
    /// Returns a plain-text result the AI can speak back to the user.
    func execute(arguments: [String: Any]) async -> String

    /// Deferred UI action (e.g. open a URL) to run after the AI finishes speaking.
    var pendingUIAction: (() -> Void)? { get set }
}
