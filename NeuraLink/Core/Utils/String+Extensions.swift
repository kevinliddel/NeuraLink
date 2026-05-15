//
//  String+Extensions.swift
//  NeuraLink
//
//  Created by Dedicatus on 10/05/2026.
//

import Foundation

extension String {
    /// URL-encodes the string for use in query parameters.
    var urlEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
