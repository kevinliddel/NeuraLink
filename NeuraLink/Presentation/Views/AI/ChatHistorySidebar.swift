//
//  ChatHistorySidebar.swift
//  NeuraLink
//
//  ChatGPT-style right slide-in panel: the user's profile on top, the chat
//  history list below. Read-only browse view — tapping a conversation opens
//  its transcript; "New Chat" returns to the live 3D avatar with a fresh
//  session. Mirrors the overlay/animation idiom used by ModelSelectionOverlay.
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
    @State private var searchText = ""

    private let panelWidth: CGFloat = 312

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            panel
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .background(Rectangle().fill(.ultraThinMaterial).ignoresSafeArea())
                .transition(.move(edge: .leading))
        }
        .onAppear(perform: reload)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            profileHeader
            Divider()
            newChatButton
            searchField
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

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chats", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, _ in reload() }
        }
        .padding(8)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var listContent: some View {
        if conversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(searchText.isEmpty ? "No chats yet" : "No matches")
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
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .swipeActions(edge: .trailing) {
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
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(preview(convo))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private func reload() {
        conversations = ConversationStore.shared.conversations(matching: searchText)
    }

    private func delete(_ convo: Conversation) {
        ConversationStore.shared.deleteConversation(id: convo.id)
        reload()
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
