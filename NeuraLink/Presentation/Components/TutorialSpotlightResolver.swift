//
//  TutorialSpotlightResolver.swift
//  NeuraLink
//
//  Decides where the tour's spotlight goes. Controls inside the scene report
//  a real measured frame and are used as-is. Navigation-bar items are hosted
//  by UIKit's bar — a separate hierarchy — so their reported frame may be
//  expressed in the bar's own space rather than the window's; a frame that
//  can't be where that item actually sits is rejected in favour of a
//  geometric estimate from the bar's standard metrics.
//
//  Pure geometry, no SwiftUI — so the fallback rules are unit-testable.
//
//  Created by Dedicatus on 15/09/2026.
//

import CoreGraphics

struct TutorialSpotlightResolver {
    /// Size of the overlay (full screen, safe areas included).
    let size: CGSize
    /// Safe-area insets the overlay draws through.
    let safeAreaTop: CGFloat
    let safeAreaLeading: CGFloat
    let safeAreaTrailing: CGFloat

    /// Standard UIKit navigation-bar metrics, used only for the estimate.
    private static let barHeight: CGFloat = 44
    private static let barItemInset: CGFloat = 16
    private static let barItemSize: CGFloat = 44
    /// How far outside the bar strip a measured frame may sit and still be
    /// believed — bar metrics vary a little by device and title mode.
    private static let barTolerance: CGFloat = 12

    /// The frame to spotlight, or nil when there's nothing trustworthy to
    /// point at (the card is then simply centred).
    func resolve(anchor: TutorialAnchor, measured: CGRect?) -> CGRect? {
        if let measured, isPlausible(measured, for: anchor) { return measured }
        return estimate(for: anchor)
    }

    /// Where a navigation-bar item sits, from the bar's standard metrics.
    /// Nil for everything else: in-scene controls are measured or not shown.
    func estimate(for anchor: TutorialAnchor) -> CGRect? {
        guard anchor.isNavigationBarItem else { return nil }
        let side = Self.barItemSize
        let centerY = safeAreaTop + Self.barHeight / 2
        let centerX: CGFloat =
            anchor == .chatHistory
            ? safeAreaLeading + Self.barItemInset + side / 2
            : size.width - safeAreaTrailing - Self.barItemInset - side / 2
        return CGRect(
            x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
    }

    /// A measured frame is usable when it has real extent, its centre is on
    /// screen, and — for a bar item — it lands in the bar strip on the side
    /// that item is pinned to.
    func isPlausible(_ rect: CGRect, for anchor: TutorialAnchor) -> Bool {
        guard rect.width > 1, rect.height > 1 else { return false }
        guard rect.width <= size.width, rect.height <= size.height else { return false }
        let bounds = CGRect(origin: .zero, size: size)
        guard bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return false }
        guard anchor.isNavigationBarItem else { return true }

        // Well above the status bar's bottom, or below the bar, means the
        // frame is expressed in some other space than the window's.
        let strip = safeAreaTop - Self.barTolerance...(safeAreaTop + Self.barHeight + Self.barTolerance)
        guard strip.contains(rect.midY) else { return false }
        return anchor == .chatHistory ? rect.midX < size.width / 2 : rect.midX > size.width / 2
    }
}
