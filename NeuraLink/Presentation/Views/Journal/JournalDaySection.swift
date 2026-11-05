//
//  JournalDaySection.swift
//  NeuraLink
//
//  What the journal shows under the calendar — Living Companion
//  (docs/Companion/LIVING_COMPANION.md): the selected day's conversations (opening
//  their read-only transcripts), diary entries (a tap on a diary picture
//  opens it full screen) and keepsakes, or, with no day selected, the
//  month's diary and keepsakes newest first.
//
//  Created by Dedicatus on 13/10/2026.
//

import SwiftUI

struct JournalDaySection: View {
    let selectedDay: Date?
    let month: JournalCalendarModel.Month
    let activity: [Date: JournalDayActivity]
    let conversations: [Int64: Conversation]
    let calendar: Calendar
    var now = Date()
    let onClear: () -> Void
    let onOpenConversation: (Int64) -> Void
    let onOpenPicture: (ViewedPicture) -> Void
    let onDelete: (JournalEntry) -> Void

    var body: some View {
        Section {
            if let day = selectedDay {
                dayContent(day)
            } else {
                monthContent
            }
        } header: {
            HStack {
                Text(selectedDay.map(Self.dayTitle) ?? "This month")
                Spacer()
                if selectedDay != nil {
                    Button("All days", action: onClear)
                        .font(.caption)
                        .textCase(nil)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - One day

    @ViewBuilder
    private func dayContent(_ day: Date) -> some View {
        if let dayActivity = activity[day], !dayActivity.isEmpty {
            ForEach(dayActivity.turnsByConversation.sorted { $0.value > $1.value }, id: \.key) { pair in
                // The transcript view carries its own NavigationStack, so it
                // is presented as a sheet rather than pushed.
                Button {
                    onOpenConversation(pair.key)
                } label: {
                    conversationRow(id: pair.key, count: pair.value)
                }
                .buttonStyle(.plain)
            }
            ForEach(dayActivity.diaryEntries) { entry in
                entryRow(entry, showDay: false)
            }
            .onDelete { offsets in
                offsets.map { dayActivity.diaryEntries[$0] }.forEach(onDelete)
            }
            ForEach(dayActivity.keepsakes) { keepsake in
                keepsakeRow(keepsake)
            }
        } else {
            Text(day > now ? "Not yet." : "Nothing on this day.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Whole month

    @ViewBuilder
    private var monthContent: some View {
        let days = JournalCalendarModel.storyDays(in: activity, month: month, calendar: calendar)
        if days.isEmpty {
            Text("No diary entries or keepsakes this month. Tap a day with a dot to see what happened.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        ForEach(days, id: \.self) { day in
            if let dayActivity = activity[day] {
                ForEach(dayActivity.diaryEntries) { entry in
                    entryRow(entry, showDay: true)
                }
                .onDelete { offsets in
                    offsets.map { dayActivity.diaryEntries[$0] }.forEach(onDelete)
                }
                ForEach(dayActivity.keepsakes) { keepsake in
                    keepsakeRow(keepsake)
                }
            }
        }
    }

    // MARK: - Rows

    private func conversationRow(id: Int64, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(of: conversations[id]))
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(count) \(count == 1 ? "message" : "messages") from you")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func entryRow(_ entry: JournalEntry, showDay: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(
                    showDay
                        ? entry.createdAt.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())
                        : entry.createdAt.formatted(date: .omitted, time: .shortened))
            } icon: {
                Image(systemName: "book.closed.fill")
            }
            .font(.caption2)
            .foregroundStyle(.pink)
            Text(entry.diary)
                .font(.subheadline)
            if let url = CompanionSceneCapture.journalURL(named: entry.snapshotFile),
               let picture = UIImage(contentsOfFile: url.path) {
                DiaryPictureButton(
                    picture: picture,
                    caption: entry.createdAt.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()),
                    onOpen: onOpenPicture)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 2)
    }

    private func keepsakeRow(_ keepsake: CompanionMilestone) -> some View {
        HStack(spacing: 10) {
            Image(systemName: keepsake.kind.symbol)
                .foregroundStyle(.purple)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(keepsake.kind.title)
                    .font(.subheadline.weight(.semibold))
                Text(keepsake.kind.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    nonisolated static func dayTitle(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func title(of conversation: Conversation?) -> String {
        let title = conversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled chat" : title
    }
}

/// A diary picture under its entry. A tap opens the full-screen viewer,
/// which grows out of exactly this rectangle and shrinks back into it.
private struct DiaryPictureButton: View {
    let picture: UIImage
    let caption: String
    let onOpen: (ViewedPicture) -> Void

    @State private var probe = WindowFrameProbe()

    private static let label = "A picture of your companion's world that day"
    private static let shape = RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)

    var body: some View {
        // Borderless, so only the picture opens the viewer, not the whole
        // row (a List row with a button otherwise fires on any tap).
        Button {
            onOpen(ViewedPicture(
                image: picture,
                label: Self.label,
                caption: caption,
                sourceFrame: probe.frame,
                sourceCornerRadius: AppTheme.Radius.medium))
        } label: {
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipShape(Self.shape)
                .contentShape(Self.shape)
                .windowFrameProbe(probe)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Self.label)
        .accessibilityHint("Shows the whole picture")
    }
}
