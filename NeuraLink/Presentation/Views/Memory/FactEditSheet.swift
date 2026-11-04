//
//  FactEditSheet.swift
//  NeuraLink
//
//  Edit sheet for a knowledge-graph fact (split from MemoryTimelineView).
//

import SwiftUI

// MARK: - Fact editor

struct FactEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var subject: String
    @State private var predicate: String
    @State private var object: String

    let id: Int64
    let onSave: (FactItem) -> Void

    init(fact: FactItem, onSave: @escaping (FactItem) -> Void) {
        self.id = fact.id
        self.onSave = onSave
        _subject = State(initialValue: fact.subject)
        _predicate = State(initialValue: fact.predicate)
        _object = State(initialValue: fact.object)
    }

    private var isValid: Bool {
        ![subject, predicate, object].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Who or what (e.g. User)", text: $subject)
                    TextField("Relationship (e.g. likes)", text: $predicate)
                    TextField("Value (e.g. sushi)", text: $object)
                } header: {
                    Text("Fact")
                } footer: {
                    Text("Reads as: \(subject) \(predicate.replacingOccurrences(of: "_", with: " ")) \(object)")
                }
            }
            .navigationTitle("Edit Fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(FactItem(id: id, subject: subject, predicate: predicate, object: object, timestamp: Date()))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
