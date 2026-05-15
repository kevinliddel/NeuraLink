//
//  RelationshipMeterBarOverlay.swift
//  NeuraLink
//

import SwiftUI

struct RelationshipMeterBarOverlay: View {
    @Bindable var aiState = RealtimeChatState.shared
    @State private var companion = CompanionStateStore.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 10) {
                Image(systemName: "suit.heart.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.pink)

                VStack(alignment: .leading, spacing: 4) {
                    Text(companion.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))

                    ProgressView(value: companion.score)
                        .tint(.pink)
                        .frame(width: 150)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.black.opacity(0.36), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    aiState.showRelationshipBar = false
                }
            } label: {
                Image(systemName: "x.circle.fill")
                    .foregroundStyle(.white.opacity(0.7))
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .offset(x: 8, y: -8)
        }
        .onAppear { companion.refresh() }
    }
}
