//
//  ConversationTranscriptView.swift
//  NeuraLink
//
//  Read-only text transcript of a past conversation: user turns trailing,
//  assistant/tool turns leading. There is no input — live talking always
//  happens in the current/new 3D session. "New Chat" closes this and returns
//  to the live avatar.
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onNewChat() } label: {
                        Label("New Chat", systemImage: "plus.bubble")
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private func bubble(_ message: ConversationMessage) -> some View {
        HStack(alignment: .top) {
            if message.isUser {
                Spacer(minLength: 40)
                Text(message.content)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            } else {
                Text(message.content)
                    .padding(10)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.primary)
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private func load() {
        messages = ConversationStore.shared.messages(conversationID: conversationID)
        if let convo = ConversationStore.shared.conversations().first(where: { $0.id == conversationID }) {
            title = convo.title
        }
    }
}
