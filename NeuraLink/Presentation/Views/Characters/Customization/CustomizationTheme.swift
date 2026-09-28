//
//  CustomizationTheme.swift
//  NeuraLink
//
//  Shared look for the customization sheet: a dark panel carrying light
//  item tiles, the way a character-creator catalogue reads — the tile is
//  the product shot, the chrome stays out of its way.
//

import SwiftUI

enum CustomizationTheme {
    /// Sheet background.
    static let panel = Color(red: 0.07, green: 0.07, blue: 0.09)
    /// Item tile background — light, so a cut-out part reads against it.
    static let tile = Color(red: 0.93, green: 0.93, blue: 0.95)
    static let tileTop = Color(red: 0.98, green: 0.98, blue: 1.0)
    /// Selection + primary action.
    static let accent = Color(red: 0.36, green: 0.80, blue: 0.76)
    static let control = Color.white.opacity(0.10)
    static let label = Color.white
    static let secondaryLabel = Color.white.opacity(0.55)

    static let tileCorner: CGFloat = 14
    static let tileGap: CGFloat = 10
    /// Four across: more choices per row, and a shorter sheet. The grid
    /// scrolls, so it only has to show enough to invite scrolling.
    static let tileColumns = 4
    /// Default (and largest) height of the tile grid. The sheet can be
    /// dragged shorter than this, never taller.
    static let gridHeight: CGFloat = 172
    /// Dragged all the way down: one row still visible.
    static let gridHeightMin: CGFloat = 84
    /// Touch targets stay at or above this.
    static let controlHeight: CGFloat = 44
    /// Gap between the sheet's sections.
    static let sectionGap: CGFloat = 10

    static var tileFill: LinearGradient {
        LinearGradient(colors: [tileTop, tile], startPoint: .top, endPoint: .bottom)
    }
}
