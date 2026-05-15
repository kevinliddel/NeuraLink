//
//  WebSearchSkill.swift
//  NeuraLink
//
//  Searches the web via Safari.
//
//  Created by Dedicatus on 10/05/2026.
//

import Foundation
import UIKit

@MainActor
final class WebSearchSkill: Skill {
    static let toolName = AppFunctionTool.searchWeb
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        let query = arguments["query"] as? String ?? ""
        return openSafari(query: query)
    }

    private func openSafari(query: String) -> String {
        let isURL = query.hasPrefix("http://") || query.hasPrefix("https://")
        let urlString: String
        if isURL {
            urlString = query
        } else {
            let encoded = query.urlEncoded
            urlString = "https://www.google.com/search?q=\(encoded)"
        }
        guard let url = URL(string: urlString) else {
            return "Could not open Safari for: \(query)"
        }
        pendingUIAction = { UIApplication.shared.open(url) }
        return "Opened Safari to search for \"\(query)\"."
    }
}
