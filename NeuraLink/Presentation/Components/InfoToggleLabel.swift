//
//  InfoToggleLabel.swift
//  NeuraLink
//
//  Settings label with an ⓘ button that pops a short explanation, so rows
//  stay one line and the details live behind the icon. Used by every
//  toggle / control that needs a description (Autonomy, Memory, Models,
//  Persona).
//

import SwiftUI

/// Title + ⓘ popover. Works as a `Toggle` label, inside a `Label` title
/// slot, or as a section header.
struct InfoToggleLabel: View {
    let title: String
    let info: String

    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfo) {
                Text(info)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    // Claim the full wrapped height — without this the popover
                    // hands the text a ~2-line box and truncates it.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 280)
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("About \(title)")
        }
    }
}
