//
//  SongRecognitionOverlay.swift
//  NeuraLink
//
//  Pop-up card for the song-recognition feature: an animated "listening"
//  state, then the matched song with artwork and Apple Music / YouTube links.
//  Rendered from ContentView as a top-aligned overlay whenever
//  SongRecognitionManager.phase is non-idle.
//
//  Created by Dedicatus on 31/08/2026.
//

import SwiftUI

struct SongRecognitionOverlay: View {
    private var manager = SongRecognitionManager.shared

    var body: some View {
        Group {
            switch manager.phase {
            case .idle:
                EmptyView()
            case .listening:
                listeningCard
            case .matched(let song):
                matchedCard(song)
            case .noMatch:
                statusCard(
                    icon: "questionmark.circle.fill",
                    tint: .yellow,
                    title: "No match found",
                    subtitle: "Try getting closer to the speaker."
                )
            case .failed(let message):
                statusCard(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Couldn't listen",
                    subtitle: message
                )
            }
        }
    }

    // MARK: - Listening

    private var listeningCard: some View {
        card {
            HStack(spacing: 14) {
                PulsingMusicNote()

                VStack(alignment: .leading, spacing: 3) {
                    Text("Listening…")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Hold your phone toward the music")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }

                Spacer(minLength: 8)

                closeButton { manager.cancel() }
            }
        }
    }

    // MARK: - Match

    private func matchedCard(_ song: RecognizedSong) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    artwork(song.artworkURL)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    closeButton { manager.dismiss() }
                }

                HStack(spacing: 10) {
                    if let url = song.appleMusicLink {
                        linkPill(url: url, icon: "music.note", label: "Apple Music", tint: .pink)
                    }
                    if let url = song.youtubeLink {
                        linkPill(url: url, icon: "play.rectangle.fill", label: "YouTube", tint: .red)
                    }
                }
            }
        }
    }

    // MARK: - No match / error

    private func statusCard(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        card {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(5)
                }

                Spacer(minLength: 8)

                Button {
                    manager.dismiss()
                    manager.startFromUI()
                } label: {
                    Text("Retry")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.cyan.opacity(0.15), in: Capsule())
                        .overlay(Capsule().strokeBorder(.cyan.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry song recognition")

                closeButton { manager.dismiss() }
            }
        }
    }

    // MARK: - Building blocks

    private func card(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(16)
            .background(
                ZStack {
                    Color.black.opacity(0.4)
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.12), lineWidth: 1.5)
                }
            )
            .background(.ultraThinMaterial)
            .cornerRadius(24)
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
    }

    private func artwork(_ url: URL?) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }

    private func linkPill(url: URL, icon: String, label: String, tint: Color) -> some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(tint.opacity(0.8), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .accessibilityLabel("Open in \(label)")
    }

    private func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "x.circle.fill")
                .foregroundStyle(.white.opacity(0.7))
                .font(.title3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }
}

// MARK: - Listening animation

/// Shazam-style pulsing rings around a music note.
private struct PulsingMusicNote: View {
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<2) { ring in
                Circle()
                    .stroke(.cyan.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 40, height: 40)
                    .scaleEffect(animating ? 1.7 : 0.8)
                    .opacity(animating ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 1.6)
                            .repeatForever(autoreverses: false)
                            .delay(Double(ring) * 0.8),
                        value: animating
                    )
            }

            Circle()
                .fill(.cyan.opacity(0.2))
                .frame(width: 40, height: 40)

            Image(systemName: "music.note")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.cyan)
                .symbolEffect(.bounce, options: .repeating, value: animating)
        }
        .frame(width: 48, height: 48)
        .onAppear { animating = true }
    }
}

#Preview {
    ZStack {
        Color.gray
        SongRecognitionOverlay()
    }
}
