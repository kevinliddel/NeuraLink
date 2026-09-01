//
//  SongRecognitionOverlay.swift
//  NeuraLink
//
//  Compact status capsule for the song-recognition feature, rendered as the
//  navigation bar's principal item (between the chat-history and menu
//  buttons) so it never covers the VRM model's face: an animated "listening"
//  state, then the matched song with artwork and Apple Music / YouTube links.
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
                listeningBar
            case .matched(let song):
                matchedBar(song)
            case .noMatch:
                statusBar(
                    icon: "questionmark.circle.fill",
                    tint: .yellow,
                    message: "No match — try getting closer to the speaker"
                )
            case .failed(let message):
                statusBar(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    message: message
                )
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: manager.phase)
    }

    // MARK: - Listening

    private var listeningBar: some View {
        bar {
            PulsingMusicNote(size: 26)

            Text("Listening…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            closeButton { manager.cancel() }
        }
    }

    // MARK: - Match

    private func matchedBar(_ song: RecognizedSong) -> some View {
        bar {
            artwork(song.artworkURL)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            if let url = song.appleMusicLink {
                linkIcon(url: url, icon: "music.note", tint: .pink, label: "Open in Apple Music")
            }
            if let url = song.youtubeLink {
                linkIcon(url: url, icon: "play.rectangle.fill", tint: .red, label: "Open in YouTube")
            }

            closeButton { manager.dismiss() }
        }
    }

    // MARK: - No match / error

    private func statusBar(icon: String, tint: Color, message: String) -> some View {
        bar {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(tint)

            Text(message)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Button {
                manager.dismiss()
                manager.startFromUI()
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry song recognition")

            closeButton { manager.dismiss() }
        }
    }

    // MARK: - Building blocks

    /// HUD capsule idiom (translucent black + hairline stroke), pinned to the
    /// toolbar buttons' 44 pt height so the header row reads as one line.
    private func bar(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.black.opacity(0.4), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    private func artwork(_ url: URL?) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }

    private func linkIcon(url: URL, icon: String, tint: Color, label: String) -> some View {
        Link(destination: url) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.85), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .accessibilityLabel(label)
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
    let size: CGFloat
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<2) { ring in
                Circle()
                    .stroke(.cyan.opacity(0.5), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(animating ? 1.6 : 0.8)
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
                .frame(width: size, height: size)

            Image(systemName: "music.note")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.cyan)
                .symbolEffect(.bounce, options: .repeating, value: animating)
        }
        .frame(width: size + 6, height: size + 6)
        .onAppear { animating = true }
    }
}

#Preview {
    ZStack {
        Color.gray
        SongRecognitionOverlay()
    }
}
