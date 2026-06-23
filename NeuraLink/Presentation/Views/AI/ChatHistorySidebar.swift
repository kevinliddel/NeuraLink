//
//  ChatHistorySidebar.swift
//  NeuraLink
//
//  ChatGPT-style left slide-in sidebar: a full-height drawer (flush to the
//  left edge, top-right + bottom-right corners rounded) with the user's
//  profile on top and the chat history below. Each conversation is a distinct
//  inset rounded card (narrower than the drawer). Read-only browse view —
//  tapping a conversation opens its transcript; "New Chat" returns to the live
//  3D avatar. Conversations can be renamed in place.
//

import SwiftUI

struct ChatHistorySidebar: View {
    @Bindable var aiState: RealtimeChatState
    /// Start a fresh session and return to the live avatar.
    var onNewChat: () -> Void
    /// Open a past conversation's read-only transcript.
    var onSelect: (Conversation) -> Void
    /// Open the profile + environment settings.
    var onOpenProfile: () -> Void

    @State private var settings = UserSettings.shared
    @State private var conversations: [Conversation] = []
    @State private var renaming: Conversation?
    @State private var renameText: String = ""

    private let panelWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Full-height drawer flush to the left edge; only the trailing
            // (right) corners are rounded.
            panel
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 22,
                        topTrailingRadius: 22,
                        style: .continuous
                    )
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                )
                .transition(.move(edge: .leading))
        }
        .onAppear(perform: reload)
        .alert("Rename Chat", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            profileHeader
            Divider()
            newChatButton
            Divider()
            listContent
        }
    }

    private var profileHeader: some View {
        Button(action: onOpenProfile) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.name.isEmpty ? "Set up profile" : settings.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Profile & environment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var avatar: some View {
        if let img = settings.profileImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
        }
    }

    private var newChatButton: some View {
        Button(action: onNewChat) {
            Label("New Chat", systemImage: "plus.bubble")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var listContent: some View {
        if conversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No chats yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(groupedSections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { convo in
                            row(convo)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { delete(convo) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button { startRename(convo) } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .contextMenu {
                                    Button { startRename(convo) } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) { delete(convo) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ convo: Conversation) -> some View {
        Button { onSelect(convo) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(convo.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(preview(convo))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.black.opacity(0.3),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private func reload() {
        conversations = ConversationStore.shared.conversations()
    }

    private func delete(_ convo: Conversation) {
        ConversationStore.shared.deleteConversation(id: convo.id)
        reload()
    }

    private func startRename(_ convo: Conversation) {
        renameText = convo.title
        renaming = convo
    }

    private func commitRename() {
        guard let convo = renaming else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            ConversationStore.shared.renameConversation(id: convo.id, title: trimmed)
            reload()
        }
        renaming = nil
    }

    private func preview(_ convo: Conversation) -> String {
        guard let last = ConversationStore.shared.lastMessage(conversationID: convo.id) else {
            return "No messages yet"
        }
        let prefix = last.isUser ? "You: " : ""
        return prefix + last.content.replacingOccurrences(of: "\n", with: " ")
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            aiState.showChatSidebar = false
        }
    }

    // MARK: - Date grouping

    private struct DateGroup { let title: String; let items: [Conversation] }

    private var groupedSections: [DateGroup] {
        let cal = Calendar.current
        let now = Date()
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var week: [Conversation] = []
        var older: [Conversation] = []
        for c in conversations {
            if cal.isDateInToday(c.updatedAt) {
                today.append(c)
            } else if cal.isDateInYesterday(c.updatedAt) {
                yesterday.append(c)
            } else if let days = cal.dateComponents([.day], from: c.updatedAt, to: now).day, days < 7 {
                week.append(c)
            } else {
                older.append(c)
            }
        }
        var sections: [DateGroup] = []
        if !today.isEmpty { sections.append(.init(title: "Today", items: today)) }
        if !yesterday.isEmpty { sections.append(.init(title: "Yesterday", items: yesterday)) }
        if !week.isEmpty { sections.append(.init(title: "Previous 7 Days", items: week)) }
        if !older.isEmpty { sections.append(.init(title: "Older", items: older)) }
        return sections
    }
}
