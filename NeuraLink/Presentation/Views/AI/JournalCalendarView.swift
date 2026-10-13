//
//  JournalCalendarView.swift
//  NeuraLink
//
//  Month grid for the companion's journal — Living Companion
//  (docs/LIVING_COMPANION.md). Dots mark days you talked (grey), diary
//  entries (pink) and keepsakes (purple). Tap a day to filter the journal
//  to it, tap it again to clear; swipe or use the chevrons to change month.
//
//  Created by Dedicatus on 13/10/2026.
//

import SwiftUI

struct JournalCalendarView: View {
    @Binding var month: JournalCalendarModel.Month
    @Binding var selectedDay: Date?
    let activity: [Date: JournalDayActivity]
    let calendar: Calendar
    var now = Date()

    private var today: Date { calendar.startOfDay(for: now) }
    private var currentMonth: JournalCalendarModel.Month {
        JournalCalendarModel.month(containing: now, calendar: calendar)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            weekdayRow
            grid
            legend
        }
        .padding(.vertical, 6)
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.width < -40 {
                    shift(1)
                } else if value.translation.width > 40 {
                    shift(-1)
                }
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Previous month")
                Spacer()
                Text(JournalCalendarModel.title(for: month, calendar: calendar))
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Next month")
            }
            HStack {
                Text(summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if month != currentMonth || selectedDay != today {
                    Button("Today") {
                        withAnimation(.snappy) {
                            month = currentMonth
                            selectedDay = today
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var summaryLine: String {
        let summary = JournalCalendarModel.summary(of: activity, in: month, calendar: calendar)
        guard summary.daysTalked + summary.diaryEntries + summary.keepsakes > 0 else { return "Nothing here yet." }
        var parts = ["Talked on \(summary.daysTalked) \(summary.daysTalked == 1 ? "day" : "days")"]
        if summary.diaryEntries > 0 {
            parts.append("\(summary.diaryEntries) diary \(summary.diaryEntries == 1 ? "entry" : "entries")")
        }
        if summary.keepsakes > 0 {
            parts.append("\(summary.keepsakes) \(summary.keepsakes == 1 ? "keepsake" : "keepsakes")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Grid

    private var weekdayRow: some View {
        HStack(spacing: 4) {
            ForEach(Array(JournalCalendarModel.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 4) {
            ForEach(Array(JournalCalendarModel.grid(for: month, calendar: calendar).enumerated()), id: \.offset) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row.element.enumerated()), id: \.offset) { cell in
                        if let day = cell.element {
                            JournalDayCell(
                                day: day,
                                number: calendar.component(.day, from: day),
                                activity: activity[day],
                                isSelected: selectedDay == day,
                                isToday: day == today,
                                isFuture: day > today
                            ) {
                                withAnimation(.snappy) { selectedDay = selectedDay == day ? nil : day }
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: JournalDayCell.height)
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.secondary, "Talked")
            legendItem(.pink, "Diary")
            legendItem(.purple, "Keepsake")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
        }
    }

    private func shift(_ delta: Int) {
        withAnimation(.snappy) {
            month = JournalCalendarModel.shifted(month, by: delta, calendar: calendar)
            selectedDay = nil
        }
    }
}

/// One day of the grid: the number, and up to three activity dots.
private struct JournalDayCell: View {
    static let height: CGFloat = 44

    let day: Date
    let number: Int
    let activity: JournalDayActivity?
    let isSelected: Bool
    let isToday: Bool
    let isFuture: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(number)")
                    .font(.callout.weight(isSelected || isToday ? .bold : .regular))
                    .monospacedDigit()
                dots
            }
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.pink, lineWidth: 1.5)
                }
            }
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return .pink }
        return isToday ? Color.pink.opacity(0.12) : .clear
    }

    private var foreground: Color {
        if isSelected { return .white }
        return isFuture ? Color.secondary.opacity(0.6) : .primary
    }

    private var dots: some View {
        HStack(spacing: 3) {
            if activity?.talked == true { dot(.secondary) }
            if activity?.diaryEntries.isEmpty == false { dot(.pink) }
            if activity?.keepsakes.isEmpty == false { dot(.purple) }
        }
        .frame(height: 5)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(isSelected ? Color.white : color).frame(width: 5, height: 5)
    }

    private var accessibilityText: String {
        var text = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        guard let activity, !activity.isEmpty else { return text }
        if activity.talked { text += ", talked" }
        if !activity.diaryEntries.isEmpty { text += ", \(activity.diaryEntries.count) diary" }
        if !activity.keepsakes.isEmpty { text += ", \(activity.keepsakes.count) keepsake" }
        return text
    }
}
