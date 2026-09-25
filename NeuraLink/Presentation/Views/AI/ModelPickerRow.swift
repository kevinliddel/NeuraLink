//
//  ModelPickerRow.swift
//  NeuraLink
//
//  One row of AI Settings → Models: a dropdown over the catalog ids for a
//  role plus a free-text field when "Custom…" is chosen
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §B3).
//

import SwiftUI

struct ModelPickerRow: View {
    let role: OpenAIModelCatalog.Role
    @Bindable var settings: OpenAISettings

    @State private var selection: String = ""
    @State private var customText: String = ""

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
                selection: Binding(
                    get: { selection },
                    set: { picked in
                        selection = picked
                        if picked == OpenAIModelCatalog.customID {
                            customText = current
                        } else {
                            apply(picked)
                        }
                    }),
                title: OpenAIModelCatalog.pickerTitle(for:))
            if selection == OpenAIModelCatalog.customID {
                TextField("Model id", text: $customText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { apply(customText) }
                    .onChange(of: customText) { _, value in apply(value) }
            }
            if let note = OpenAIModelCatalog.entries(for: role).first(where: { $0.id == current })?.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            let known = OpenAIModelCatalog.entries(for: role).map(\.id)
            selection = known.contains(current) ? current : OpenAIModelCatalog.customID
            customText = current
        }
    }
}
