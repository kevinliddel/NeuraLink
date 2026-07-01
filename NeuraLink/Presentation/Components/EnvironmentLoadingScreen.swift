//
//  EnvironmentLoadingScreen.swift
//  NeuraLink
//
//  Game-engine-style launch loading screen. Shows a mobile-adapted backdrop
//  that matches the local time of day (`day_time.png` / `night_time.png`)
//  while the 3D environment mesh downloads/loads in the background (see
//  EnvironmentLoadState), then dissolves away with a misty fade to reveal the
//  live scene. A small bottom-left indicator highlights what's loading.
//
//  Created by Dedicatus on 26/05/2026.
//

import SwiftUI

struct EnvironmentLoadingScreen: View {
    @State private var envLoad = EnvironmentLoadState.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Only the backdrop bleeds past the safe area; the status badge
            // stays inside it so the spinner/text are never clipped by the
            // notch, rounded corners, or home indicator.
            backdrop
                .ignoresSafeArea()
            statusBadge
                .padding(.leading, 25)
                .padding(.trailing, 16)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder private var backdrop: some View {
        if let image = Self.backdropImage() {
            // Cover the screen with the image centered (crop the overflow). The
            // explicit GeometryReader frame guarantees the image is centered
            // regardless of the ZStack's bottom-leading alignment or aspect ratio.
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        } else {
            Color.black
        }
    }

    private var statusBadge: some View {
        // Black text on the bright day backdrop, white on the dark night one,
        // each with a contrasting soft shadow so it stays legible either way.
        let onDark = !Self.isDaytime
        let foreground: Color = onDark ? .white : .black
        let shadowColor: Color = onDark ? .black.opacity(0.7) : .white.opacity(0.6)
        return HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(foreground)
            // Live loader/texture log line (game-console feel), tag stripped;
            // a neutral "Loading…" before the first log / in Release builds.
            Text(envLoad.currentLogLine ?? "Loading…")
                .font(.callout.weight(.semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: envLoad.currentLogLine)
        }
        .shadow(color: shadowColor, radius: 5)
    }

    // MARK: - Backdrop selection

    /// Day vs night by the device's local hour (06:00–18:59 = day).
    private static var isDaytime: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return (6..<19).contains(hour)
    }

    /// Loads the time-of-day backdrop from the synchronized `Environments/`
    /// folder (or the bundle root).
    static func backdropImage() -> UIImage? {
        let name = isDaytime ? "day_time" : "night_time"
        for ext in ["png", "jpg", "jpeg"] {
            let candidates = [
                Bundle.main.path(forResource: name, ofType: ext, inDirectory: "Environments"),
                Bundle.main.path(forResource: name, ofType: ext)
            ]
            for case let path? in candidates {
                if let image = UIImage(contentsOfFile: path) { return image }
            }
        }
        return UIImage(named: name)
    }
}

// MARK: - Mist dissolve transition

/// Blurs, fades, and drifts the view slightly outward — used to dissolve the
/// loading screen into the live app like clearing mist.
private struct MistModifier: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
            .scaleEffect(scale)
    }
}

extension AnyTransition {
    static var mist: AnyTransition {
        .modifier(
            active: MistModifier(blur: 30, opacity: 0, scale: 1.12),
            identity: MistModifier(blur: 0, opacity: 1, scale: 1.0)
        )
    }
}
