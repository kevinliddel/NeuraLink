//
//  ModelPickerRow.swift
//  NeuraLink
//
//  One row of AI Settings → Models: a dropdown over the curated catalog ids
//  for a role (docs/CHAT_LLM.md).
//

import SwiftUI

struct ModelPickerRow: View {
    let role: OpenAIModelCatalog.Role
    @Bindable var settings: OpenAISettings

    private var current: String {
        switch role {
        case .realtime: return settings.realtimeModel
        case .transcription: return settings.transcriptionModel
        case .text: return settings.textModel
        }
    }

    private func apply(_ id: String) {
        switch role {
        case .realtime: settings.realtimeModel = id
        case .transcription: settings.transcriptionModel = id
        case .text: settings.textModel = id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DropDownSelector(
                items: OpenAIModelCatalog.pickerItems(for: role),
                selection: Binding(get: { current }, set: apply),
                title: OpenAIModelCatalog.pickerTitle(for:))
            if let note = OpenAIModelCatalog.entry(for: current, role: role)?.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
