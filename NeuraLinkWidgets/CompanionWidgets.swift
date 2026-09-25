//
//  CompanionWidgets.swift
//  NeuraLinkWidgets
//
//  Home-screen and lock-screen widgets fed by the App Group snapshot
//  (docs/PRESENCE_BEYOND_APP_PLAN.md §P3). No database access, no network;
//  everything comes from `CompanionSnapshotStore.load()`.
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
        // Relative "last chat" text drifts, so refresh every 6 hours even
        // when the app writes nothing.
        let now = Date()
        let entries = (0..<4).map { step in
            CompanionEntry(date: now.addingTimeInterval(Double(step) * 6 * 3_600), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

extension CompanionSnapshot {
    static let placeholder = CompanionSnapshot(
        character: "sonya", displayName: "Sonya", relationshipLabel: "Friends", relationshipScore: 0.62,
        opener: "I kept thinking about that book you mentioned…", memoryLine: "You prefer green tea over coffee.",
        lastChatAt: Date().addingTimeInterval(-3 * 3_600), thumbnailFile: nil, updatedAt: Date())
}

// MARK: - Shared pieces

struct CharacterThumbnail: View {
    let snapshot: CompanionSnapshot
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let file = snapshot.thumbnailFile, let url = CompanionSnapshotStore.thumbnailURL(named: file),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(snapshot.displayName.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }
}

struct RelationshipBar: View {
    let snapshot: CompanionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
                Text(snapshot.relationshipLabel)
                    .font(.caption.weight(.semibold))
            }
            ProgressView(value: snapshot.relationshipScore)
                .tint(.pink)
        }
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
        VStack(spacing: 8) {
            AppLogoMark(size: 44)
            Text("Open NeuraLink to meet your companion")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CharacterThumbnail(snapshot: snapshot, size: 36)
                Text(snapshot.displayName)
                    .font(.headline)
                    .lineLimit(1)
            }
            RelationshipBar(snapshot: snapshot)
            Spacer(minLength: 0)
            Text(snapshot.lastChatDescription(now: entry.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func medium(_ snapshot: CompanionSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                CharacterThumbnail(snapshot: snapshot, size: 48)
                Text(snapshot.displayName)
                    .font(.headline)
                    .lineLimit(1)
                RelationshipBar(snapshot: snapshot)
            }
            .frame(width: 96)
            VStack(alignment: .leading, spacing: 6) {
                let line = snapshot.opener.isEmpty ? snapshot.memoryLine : snapshot.opener
                if line.isEmpty {
                    Text("Say hi — \(snapshot.displayName) is waiting.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("“\(line)”")
                        .font(.subheadline)
                        .italic()
                        .lineLimit(4)
                }
                Spacer(minLength: 0)
                Text(snapshot.lastChatDescription(now: entry.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.neuralink.widget.companion", provider: CompanionProvider()) { entry in
            CompanionWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Companion")
        .description("Your companion's greeting and how close you are.")
        .supportedFamilies([.systemSmall, .systemMedium])
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
                    Text(String(snapshot.displayName.prefix(1)).uppercased())
                        .font(.caption.weight(.bold))
                }
                .gaugeStyle(.accessoryCircularCapacity)
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.displayName)
                        .font(.headline)
                    Text(snapshot.lastChatDescription(now: entry.date))
                        .font(.caption)
                    if !snapshot.opener.isEmpty {
                        Text(snapshot.opener)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
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
        .description("How long since you last talked.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}
