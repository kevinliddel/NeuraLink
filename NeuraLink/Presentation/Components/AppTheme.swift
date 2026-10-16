//
//  AppTheme.swift
//  NeuraLink
//
//  The app's design tokens: corner radii, the brand gradients and chart
//  series colours, the HUD "glass" idiom. Views take their numbers from
//  here so every sheet, card and capsule reads as one product. Text uses
//  the semantic styles (.caption2 … .largeTitle) so Dynamic Type works;
//  fixed point sizes are reserved for decorative glyphs.
//
//  Created by Dedicatus on 14/10/2026.
//

import SwiftUI

enum AppTheme {

    /// Four radii cover the app: chip (icon badges), small (cells, rows),
    /// medium (tiles, cards in a list), large (hero cards, sheets, capsules
    /// that aren't pills).
    enum Radius {
        static let chip: CGFloat = 8
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 22
    }

    /// Tints with a meaning: the same colour always says the same thing.
    enum Tint {
        /// The relationship: meter, journal, "together".
        static let bond = Color.pink
        /// Keepsakes and memory insights.
        static let keepsake = Color.purple
        /// Song recognition and co-listening.
        static let song = Color.cyan
    }

    /// Chart series colours for API usage (voice, transcription, text, vision).
    enum Series {
        static let voice = Color(red: 0.49, green: 0.23, blue: 0.93)
        static let transcription = Color(red: 0.08, green: 0.66, blue: 0.62)
        static let text = Color(red: 0.23, green: 0.51, blue: 0.96)
        static let vision = Color(red: 0.96, green: 0.62, blue: 0.04)
    }

    /// The two hero-card gradients.
    enum Gradient {
        /// Clear-sky blue, shared with the home-screen widget's palette.
        static let memory = LinearGradient(
            colors: [
                Color(red: 0.30, green: 0.58, blue: 0.92), Color(red: 0.17, green: 0.42, blue: 0.84),
                Color(red: 0.09, green: 0.28, blue: 0.66)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        static let usage = LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.55, blue: 0.62), Color(red: 0.25, green: 0.30, blue: 0.85),
                Color(red: 0.49, green: 0.23, blue: 0.93)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// HUD glass over the 3D scene: translucent black with a white hairline.
    enum Glass {
        static let hairline = Color.white.opacity(0.18)
        static let hairlineWidth: CGFloat = 1
    }
}

extension View {
    /// The HUD capsule idiom: translucent black fill plus a white hairline,
    /// on any insettable shape. `opacity` is the fill's; the default suits a
    /// bar over bright skies.
    func hudGlass<S: InsettableShape>(_ shape: S, opacity: Double = 0.4) -> some View {
        background(.black.opacity(opacity), in: shape)
            .overlay(shape.strokeBorder(AppTheme.Glass.hairline, lineWidth: AppTheme.Glass.hairlineWidth))
    }
}
