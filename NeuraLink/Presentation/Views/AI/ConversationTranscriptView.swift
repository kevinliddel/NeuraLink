//
//  ConversationTranscriptView.swift
//  NeuraLink
//
//  Read-only text transcript of a past conversation: user turns trailing,
//  assistant/tool turns leading. There is no input — live talking always
//  happens in the current/new 3D session. "New Chat" closes this and returns
//  to the live avatar. Assistant messages carry a play button that speaks the
//  text through the TTS matching the current mode (see TranscriptSpeechPlayer).
//
//  Created by Dedicatus on 16/07/2026.
//

import SwiftUI

struct ConversationTranscriptView: View {
    let conversationID: Int64
    /// Dismiss back to the live avatar (keeps the current session).
    var onClose: () -> Void
    /// Start a brand-new session and return to the live avatar.
    var onNewChat: () -> Void

    @State private var messages: [ConversationMessage] = []
    @State private var title: String = "Chat"
    @State private var speech = TranscriptSpeechPlayer()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        bubble(message)
                    }
                }
                .padding()
            }
            .scrollIndicators(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onNewChat()
                    } label: {
                        Label("New Chat", systemImage: "plus.bubble")
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear { speech.stop() }
    }

    @ViewBuilder private func bubble(_ message: ConversationMessage) -> some View {
        HStack(alignment: .top) {
            if message.isUser {
                Spacer(minLength: 40)
                Text(message.content)
                    .padding(10)
                    .background(
                        Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(.white)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.content)
                    // Spoken playback for assistant text only — tool-call rows
                    // are payload dumps, not something to read aloud.
                    if message.isAssistant && message.kind == "message" {
                        playButton(message)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.primary)
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    /// Play / loading / stop control for one assistant message. Disabled (not
    /// hidden) when the current mode can't synthesize — OpenAI mode without a
    /// valid key — so the affordance stays discoverable.
    @ViewBuilder private func playButton(_ message: ConversationMessage) -> some View {
        let phase = speech.phase(for: message.id)
        Button {
            speech.toggle(message)
        } label: {
            ZStack {
                Circle()
                    .fill((phase == .idle ? Color.blue : Color.red).opacity(0.12))
                    .frame(width: 28, height: 28)
                switch phase {
                case .loading:
                    ProgressView()
                        .tint(.secondary)
                        .scaleEffect(0.6)
                case .playing:
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                case .idle:
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: phase)
        }
        .buttonStyle(.borderless)
        .disabled(!speech.isAvailable)
        .opacity(speech.isAvailable ? 1 : 0.35)
        .accessibilityLabel(phase == .idle ? "Play message aloud" : "Stop playback")
    }

    private func load() {
        messages = ConversationStore.shared.messages(conversationID: conversationID)
        if let convo = ConversationStore.shared.conversations().first(where: {
            $0.id == conversationID
        }) {
            title = convo.title
        }
    }
}
