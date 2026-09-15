//
//  WindowSafeArea.swift
//  NeuraLink
//
//  The key window's safe-area insets, read straight from UIKit.
//
//  SwiftUI's `GeometryProxy.safeAreaInsets` reports zero inside a reader that
//  ignores the safe area, which is exactly the situation of a full-screen
//  overlay — so anything that needs to know where the status bar ends (the
//  onboarding tour's navigation-bar spotlight) has to ask the window.
//
//  Created by Dedicatus on 15/09/2026.
//

import UIKit

enum WindowSafeArea {
    /// Insets of the active key window, or zero when there isn't one yet.
    static var insets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
    }
}
