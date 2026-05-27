//
//  RememberFactSkill.swift
//  NeuraLink
//
//  Skill that stores a structured fact about the user in the Knowledge Graph.
//

import Foundation

@MainActor
final class RememberFactSkill: Skill {
    static let toolName = AppFunctionTool.rememberFact
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        guard
            let subject   = arguments["subject"]   as? String,
            let predicate = arguments["predicate"] as? String,
            let object    = arguments["object"]    as? String
        else {
            nlLog(
                "֎ [FunctionCall] remember_fact REJECTED — missing subject/predicate/object. Got: \(arguments)",
                level: .warning
            )
            return "I couldn't store that fact — missing subject, predicate, or object."
        }

        nlLog(
            "֎ [FunctionCall] remember_fact storing → subject=\"\(subject)\" predicate=\"\(predicate)\" object=\"\(object)\"",
            level: .info
        )
        KnowledgeGraphManager.shared.remember(
            subject: subject,
            predicate: predicate,
            object: object
        )

        return "Got it! I'll always remember that \(subject) \(predicate) \(object)."
    }
}
