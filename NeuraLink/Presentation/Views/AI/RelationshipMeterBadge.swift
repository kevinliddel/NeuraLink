//
//  RelationshipMeterBadge.swift
//  NeuraLink
//

import SwiftUI

struct RelationshipMeterBadge: View {
    @State private var companion = CompanionStateStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.pink)

            VStack(alignment: .leading, spacing: 3) {
                Text(companion.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))

                ProgressView(value: companion.score)
                    .tint(.pink)
                    .frame(width: 86)
                    .scaleEffect(x: 1, y: 0.9, anchor: .center)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.32), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .onAppear { companion.refresh() }
    }
}
