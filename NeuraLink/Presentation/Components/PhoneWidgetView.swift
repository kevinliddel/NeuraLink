//
//  PhoneWidgetView.swift
//  NeuraLink
//
//  The companion's phone — a GTA/Ananta-style mini smartphone that slides
//  in from the corner when a tool call has something ready (Safari search,
//  Apple Music, an app, a note). Tapping the phone performs the actual
//  open; the ✕ (or 45 s of being ignored) puts it away.
//
//  Created by Dedicatus on 09/09/2026.
//

import SwiftUI

struct PhoneWidgetView: View {
    let card: ToolActionCard

    private var manager = PhoneWidgetManager.shared
    @State private var raised = false
    /// Where the user parked the phone (persisted offset from the home anchor).
    @State private var parkedOffset: CGSize = .zero
    /// Live drag translation, folded into `parkedOffset` on release.
    @State private var dragTranslation: CGSize = .zero

    init(card: ToolActionCard) {
        self.card = card
    }

    private var tint: Color {
        switch card.kind {
        case .webSearch: return .blue
        case .music: return .pink
        case .app: return .cyan
        case .note: return .yellow
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            phoneBody
                .rotationEffect(.degrees(raised ? -2 : 10), anchor: .bottomLeading)
                .onTapGesture { manager.openAndDismiss() }
                .accessibilityLabel("\(card.title): \(card.detail). Tap to open \(card.appName).")
                .accessibilityAddTraits(.isButton)

            Button {
                manager.dismiss()
            } label: {
                Image(systemName: "x.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .offset(x: 10, y: -10)
            .accessibilityLabel("Put the phone away")
        }
        .offset(
            x: parkedOffset.width + dragTranslation.width,
            y: parkedOffset.height + dragTranslation.height
        )
        // Drag to park anywhere on screen; min distance keeps taps intact.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    dragTranslation = value.translation
                }
                .onEnded { value in
                    let proposed = CGSize(
                        width: parkedOffset.width + value.translation.width,
                        height: parkedOffset.height + value.translation.height)
                    dragTranslation = .zero
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        parkedOffset = PhoneWidgetManager.clampedOffset(
                            proposed, screen: UIScreen.main.bounds.size)
                    }
                    manager.saveOffset(parkedOffset)
                }
        )
        .onAppear {
            // Reappear where it was last parked (re-clamped — the screen may
            // have rotated since).
            parkedOffset = PhoneWidgetManager.clampedOffset(
                manager.loadOffset(), screen: UIScreen.main.bounds.size)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) {
                raised = true
            }
        }
        .onDisappear { raised = false }
    }

    // MARK: - The device

    private var phoneBody: some View {
        ZStack {
            // Chassis
            RoundedRectangle(cornerRadius: 26)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1.2)
                )
                .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 6)

            // Screen
            RoundedRectangle(cornerRadius: 21)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.07, green: 0.09, blue: 0.16), .black],
                        startPoint: .top, endPoint: .bottom)
                )
                .padding(5)

            screenContent
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
        }
        .frame(width: 148, height: 272)
    }

    private var screenContent: some View {
        VStack(spacing: 0) {
            // Dynamic-island pill + clock
            Capsule()
                .fill(.black)
                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .frame(width: 44, height: 12)
            Text(Date.now, format: .dateTime.hour().minute())
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 6)

            Spacer(minLength: 8)

            // App icon tile
            RoundedRectangle(cornerRadius: 13)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: card.systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: tint.opacity(0.45), radius: 8)

            Text(card.appName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 6)

            Spacer(minLength: 6)

            // The query / detail "message bubble"
            Text(card.detail.isEmpty ? card.title : card.detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

            Spacer(minLength: 8)

            // Call to action
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.forward.app.fill")
                Text("Tap to open")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.9), in: Capsule())

            // Home indicator
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 3)
                .padding(.top, 10)
        }
    }
}

#Preview {
    ZStack {
        Color.gray
        PhoneWidgetView(
            card: ToolActionCard(
                kind: .webSearch, appName: "Safari", systemImage: "safari.fill",
                title: "Web Search", detail: "best ramen near Shibuya"))
    }
}
