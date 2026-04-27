//
//  RealtimeChatOverlay.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import SwiftUI

struct RealtimeChatOverlay: View {
    private let aiState = RealtimeChatState.shared

    private enum Phase: Equatable {
        case idle, aiResponding
    }

    @State private var phase: Phase = .idle
    @State private var dismissTask: Task<Void, Never>?

    // Old content floats up and fades; new content rises from slightly below
    private static let fadeUp = AnyTransition.asymmetric(
        insertion: .offset(y: 20).combined(with: .opacity),
        removal: .offset(y: -28).combined(with: .opacity)
    )

    var body: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                if phase == .idle {
                    idleHint.transition(Self.fadeUp)
                } else if phase == .aiResponding {
                    aiText.transition(Self.fadeUp)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 60)
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeInOut(duration: 0.45), value: phase)
        .onChange(of: aiState.status) { updatePhase() }
    }

    // MARK: - Phase Views

    @ViewBuilder
    private var idleHint: some View {
        if case .error = aiState.status {
            hint("Connection error", icon: "exclamationmark.circle")
        } else if aiState.status == .preparing {
            hint("Preparing local SLMs…", progress: true)
        } else if aiState.status == .connecting {
            hint("Connecting…", progress: true)
        } else if !OpenAISettings.shared.hasValidKey {
            hint("Tap to configure LLMs", icon: "key.fill")
                .onTapGesture { aiState.showSettings = true }
        } else {
            hint("Start talking", icon: "waveform")
        }
    }

    private var aiText: some View {
        Text(aiState.aiTranscript.isEmpty ? "…" : aiState.aiTranscript)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.88))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Reusable Atoms

    private func hint(_ text: String, icon: String? = nil, progress: Bool = false) -> some View {
        HStack(spacing: 6) {
            if progress {
                ProgressView().tint(.white).scaleEffect(0.65)
            } else if let icon {
                Image(systemName: icon).font(.caption.weight(.semibold))
            }
            Text(text).font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.black.opacity(0.32), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Phase Transitions

    private func updatePhase() {
        switch aiState.status {
        case .listening, .thinking:
            break
        case .speaking:
            transition(to: .aiResponding)
        case .ready:
            scheduleDismissToIdle()
        case .preparing, .connecting, .disconnected, .error:
            transition(to: .idle)
        }
    }

    private func transition(to newPhase: Phase) {
        cancelDismiss()
        guard newPhase != phase else { return }
        withAnimation(.easeInOut(duration: 0.45)) { phase = newPhase }
    }

    // Keep AI text visible while the WebRTC buffer drains, then return to idle
    private func scheduleDismissToIdle() {
        cancelDismiss()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.45)) { phase = .idle }
            }
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }
}
