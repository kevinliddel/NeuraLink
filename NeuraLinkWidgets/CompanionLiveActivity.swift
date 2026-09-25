//
//  CompanionLiveActivity.swift
//  NeuraLinkWidgets
//
//  Lock-screen banner + Dynamic Island for an active voice session
//  (docs/PRESENCE_BEYOND_APP_PLAN.md §P2).
//

import ActivityKit
import SwiftUI
import WidgetKit

struct CompanionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CompanionActivityAttributes.self) { context in
            LockScreenSessionView(context: context)
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityThumbnail(attributes: context.attributes, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PhaseBadge(phase: context.state.phase)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.displayName)
                            .font(.headline)
                        Text(context.state.lastLine.isEmpty ? "Tap to return to the conversation." : context.state.lastLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } compactLeading: {
                ActivityThumbnail(attributes: context.attributes, size: 22)
            } compactTrailing: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(context.state.phase == .speaking ? .pink : .white)
            } minimal: {
                Image(systemName: context.state.phase.symbol)
            }
        }
    }
}

private struct LockScreenSessionView: View {
    let context: ActivityViewContext<CompanionActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ActivityThumbnail(attributes: context.attributes, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(context.attributes.displayName)
                        .font(.headline)
                    Spacer()
                    PhaseBadge(phase: context.state.phase)
                }
                Text(context.state.lastLine.isEmpty ? "Conversation in progress" : context.state.lastLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
    }
}

private struct PhaseBadge: View {
    let phase: CompanionActivityAttributes.Phase

    var body: some View {
        Label(phase.label, systemImage: phase.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((phase == .speaking ? Color.pink : Color.white).opacity(0.18), in: Capsule())
    }
}

private struct ActivityThumbnail: View {
    let attributes: CompanionActivityAttributes
    let size: CGFloat

    var body: some View {
        Group {
            if let file = attributes.thumbnailFile, let url = CompanionSnapshotStore.thumbnailURL(named: file),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(attributes.displayName.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
