//
//  Item.swift
//  NeuraLink
//
//  Created by Dedicatus on 14/04/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
