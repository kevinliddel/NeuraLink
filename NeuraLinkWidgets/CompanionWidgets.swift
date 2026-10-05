//
//  CompanionWidgets.swift
//  NeuraLinkWidgets
//
//  Home-screen and lock-screen widgets fed by the App Group snapshot
//  (docs/PRESENCE_BEYOND_APP.md). No database access, no network;
//  everything comes from `CompanionSnapshotStore.load()`. The app rewrites
//  the snapshot whenever the relationship, the memory summary or the
//  character (and how it is dressed) changes, then reloads the timelines.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

struct CompanionEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionSnapshot?
}

struct CompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> CompanionEntry {
        CompanionEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CompanionEntry) -> Void) {
        completion(CompanionEntry(date: Date(), snapshot: CompanionSnapshotStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompanionEntry>) -> Void) {
        let snapshot = CompanionSnapshotStore.load()
        // "Last chat" is relative text, so step it hourly for the first
        // hours (when it changes fastest), then every 6 h.
        let now = Date()
        let offsets: [TimeInterval] = [0, 1, 2, 3, 6, 12, 18, 24].map { $0 * 3_600 }
        let entries = offsets.map { CompanionEntry(date: now.addingTimeInterval($0), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

extension CompanionSnapshot {
    static let placeholder = CompanionSnapshot(
        character: "sonya", displayName: "Sonya", relationshipLabel: "Friends", relationshipScore: 0.62,
        opener: "I kept thinking about that book you mentioned…",
        memoryLine: "You light up whenever we talk about light novels.", memoryTitle: "Between you",
        factCount: 24, daysTogether: 12,
        lastChatAt: Date().addingTimeInterval(-3 * 3_600), thumbnailFile: nil, updatedAt: Date())

    /// The line the medium widget quotes, with what it is.
    var featuredLine: (title: String, text: String)? {
        if !opener.isEmpty { return ("Coming up next time", opener) }
        if !memoryLine.isEmpty { return (memoryTitle ?? "Remembered", memoryLine) }
        return nil
    }

    /// A live portrait is a transparent head-and-shoulders cutout; the stock
    /// thumbnail is an opaque picture that wants a frame.
    var hasLivePortrait: Bool { thumbnailFile?.hasSuffix("_live.png") ?? false }
}

// MARK: - Palette

enum WidgetPalette {
    static let top = Color(red: 0.20, green: 0.13, blue: 0.48)
    static let middle = Color(red: 0.46, green: 0.18, blue: 0.62)
    static let bottom = Color(red: 0.86, green: 0.30, blue: 0.52)
    static let heart = Color(red: 1.00, green: 0.47, blue: 0.62)

    static var background: LinearGradient {
        LinearGradient(colors: [top, middle, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Brand gradient with soft light blooms; plain when the home screen is
/// tinted (accented / vibrant rendering), where colour would be discarded.
struct CompanionBackground: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .fullColor {
            ZStack {
                WidgetPalette.background
                RadialGradient(
                    colors: [.white.opacity(0.28), .clear], center: .init(x: 0.85, y: 0.15),
                    startRadius: 2, endRadius: 140)
                RadialGradient(
                    colors: [WidgetPalette.heart.opacity(0.45), .clear], center: .init(x: 0.15, y: 1.0),
                    startRadius: 2, endRadius: 160)
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - Shared pieces

struct CharacterPortrait: View {
    let snapshot: CompanionSnapshot

    var body: some View {
        if let image = loadImage() {
            if snapshot.hasLivePortrait {
                // The bust is cut by the camera frame at chest height —
                // fade that edge into the background instead of a hard line.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62),
                                    .init(color: .clear, location: 1)],
                            startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 1))
            }
        } else {
            InitialBadge(snapshot: snapshot, size: 56)
        }
    }

    private func loadImage() -> UIImage? {
        guard let file = snapshot.thumbnailFile, let url = CompanionSnapshotStore.thumbnailURL(named: file) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }
}

/// Small round face for tight spots (lock screen, fallback).
struct InitialBadge: View {
    let snapshot: CompanionSnapshot
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.18))
            Text(String(snapshot.displayName.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
    }
}

/// Heart inside a ring that fills with the relationship score.
struct HeartRing: View {
    let score: Double
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: size * 0.12)
            Circle()
                .trim(from: 0, to: max(0.04, min(score, 1)))
                .stroke(
                    AngularGradient(colors: [WidgetPalette.heart, .white], center: .center),
                    style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(WidgetPalette.heart)
                .widgetAccentable()
        }
        .frame(width: size, height: size)
    }
}

/// Relationship label with its ring, e.g. ♥ Friends · 62 %.
struct RelationshipBadge: View {
    let snapshot: CompanionSnapshot
    var ring: CGFloat = 26

    var body: some View {
        HStack(spacing: 7) {
            HeartRing(score: snapshot.relationshipScore, size: ring)
            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.relationshipLabel)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text("\(Int((snapshot.relationshipScore * 100).rounded())) %")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
            }
        }
    }
}

/// Frosted pill with an icon and a short value.
struct StatChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.white.opacity(0.16), in: Capsule())
    }
}

/// App logo used wherever there is no companion yet.
struct AppLogoMark: View {
    var size: CGFloat = 40

    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct EmptyCompanionView: View {
    var body: some View {
        VStack(spacing: 10) {
            AppLogoMark(size: 46)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            Text("Open NeuraLink to meet your companion")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Companion widget (small / medium)

struct CompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CompanionEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            EmptyCompanionView()
        }
    }

    private func small(_ snapshot: CompanionSnapshot) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // The figure bleeds off the bottom-right corner.
            CharacterPortrait(snapshot: snapshot)
                .frame(width: snapshot.hasLivePortrait ? 118 : 64, height: snapshot.hasLivePortrait ? 118 : 64)
                .offset(x: snapshot.hasLivePortrait ? 14 : -12, y: snapshot.hasLivePortrait ? 10 : -12)

            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.displayName)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                RelationshipBadge(snapshot: snapshot, ring: 24)
                Spacer(minLength: 0)
                StatChip(symbol: "bubble.left.fill", text: snapshot.lastChatDescription(now: entry.date))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
        }
    }

    private func medium(_ snapshot: CompanionSnapshot) -> some View {
        HStack(spacing: 0) {
            CharacterPortrait(snapshot: snapshot)
                .frame(width: snapshot.hasLivePortrait ? 128 : 84, height: snapshot.hasLivePortrait ? 150 : 84)
                .frame(width: 118, alignment: .bottom)
                .frame(maxHeight: .infinity, alignment: snapshot.hasLivePortrait ? .bottom : .center)
                .offset(y: snapshot.hasLivePortrait ? 18 : 0)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    Text(snapshot.displayName)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    RelationshipBadge(snapshot: snapshot, ring: 24)
                }
                quoteCard(snapshot)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    StatChip(symbol: "bubble.left.fill", text: snapshot.lastChatDescription(now: entry.date))
                    if let facts = snapshot.factCount, facts > 0 {
                        StatChip(symbol: "brain.head.profile", text: "\(facts)")
                    }
                    if let days = snapshot.daysTogether, days > 0 {
                        StatChip(symbol: "calendar", text: days == 1 ? "1 day" : "\(days) days")
                    }
                }
            }
            .padding(.vertical, 14)
            .padding(.trailing, 14)
        }
    }

    @ViewBuilder private func quoteCard(_ snapshot: CompanionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let featured = snapshot.featuredLine {
                Text(featured.title.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.65))
                Text(featured.text)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            } else {
                Text("Say hi — \(snapshot.displayName) is waiting.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}

struct CompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.neuralink.widget.companion", provider: CompanionProvider()) { entry in
            CompanionWidgetView(entry: entry)
                .containerBackground(for: .widget) { CompanionBackground() }
        }
        .configurationDisplayName("Companion")
        .description("Your companion as they look right now, what they remember and how close you are.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Come-back widget (lock screen)

struct ComeBackWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CompanionEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular:
                Gauge(value: snapshot.relationshipScore) {
                    Image(systemName: "heart.fill")
                } currentValueLabel: {
                    Text(String(snapshot.displayName.prefix(1)).uppercased())
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }
                .gaugeStyle(.accessoryCircular)
                .widgetAccentable()
            case .accessoryInline:
                Label(
                    "\(snapshot.displayName) · \(snapshot.relationshipLabel) · \(snapshot.lastChatDescription(now: entry.date))",
                    systemImage: "heart.fill")
            default:
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .widgetAccentable()
                        Text(snapshot.displayName)
                            .font(.system(.headline, design: .rounded))
                        Text("· \(snapshot.relationshipLabel)")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text(snapshot.lastChatDescription(now: entry.date))
                        .font(.system(.caption, design: .rounded))
                    if let featured = snapshot.featuredLine {
                        Text(featured.text)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            AppLogoMark(size: 28)
        }
    }
}

struct ComeBackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.neuralink.widget.comeback", provider: CompanionProvider()) { entry in
            ComeBackWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Come back")
        .description("How close you are and how long since you last talked.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
