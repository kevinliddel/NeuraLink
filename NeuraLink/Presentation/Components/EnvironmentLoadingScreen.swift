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
            VStack(alignment: .leading, spacing: 16) {
                // After a prolonged stall the escape hatch appears above the
                // status badge (Retry / Continue) so a hung first-install
                // download is never a silent, inescapable spinner.
                if envLoad.isStalled {
                    stallPanel
                }
                statusBadge
            }
            .padding(.leading, 25)
            .padding(.trailing, 16)
            .padding(.bottom, 10)
            .animation(.easeInOut(duration: 0.25), value: envLoad.isStalled)
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
        // No implicit animations here: the log line and the byte counter both
        // update many times per second during a download, and independently
        // animated layout shifts made the two texts visibly overlap mid-frame
        // on device. The progress line's space is always reserved (hidden when
        // empty) so the badge never re-flows.
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
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
            }
            // Real download progress (bytes / %) once the environment mesh
            // starts streaming, so a slow first-install fetch shows movement.
            Text(envLoad.progressText ?? " ")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(foreground.opacity(0.85))
                .lineLimit(1)
                .padding(.leading, 28)
                .opacity(envLoad.progressText == nil ? 0 : 1)
        }
        .shadow(color: shadowColor, radius: 5)
    }

    /// Escape hatch shown after a prolonged download stall: retry the fetch or
    /// continue into the app with the default scene.
    private var stallPanel: some View {
        let onDark = !Self.isDaytime
        let foreground: Color = onDark ? .white : .black
        return VStack(alignment: .leading, spacing: 12) {
            Text("This is taking longer than expected.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    EnvironmentLoadState.shared.requestRetry()
                } label: {
                    Text("Retry").font(.callout.weight(.semibold))
                }
                .buttonStyle(.bordered)

                Button {
                    EnvironmentLoadState.shared.forceReady()
                } label: {
                    Text("Continue to app").font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .tint(foreground)
        .padding(16)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 420, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
