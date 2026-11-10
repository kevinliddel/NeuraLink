//
//  CharacterStoryEditorView.swift
//  NeuraLink
//
//  The story sheet of an imported character — Inner life
//  (docs/Companion/LIVING_COMPANION.md): what it says about its own life
//  when the conversation turns to it. Written once from the persona prompt
//  (CharacterStoryGenerator) and editable here line by line; "Write it for
//  me" writes it again. Saved when the screen closes.
//
//  Created by Dedicatus on 10/11/2026.
//

import SwiftUI

struct CharacterStoryEditorView: View {
    let character: String
    let displayName: String

    @State private var everyday: [String] = []
    @State private var tastes: [String] = []
    @State private var people: [String] = []
    @State private var arc: [String] = []
    @State private var stories: [LoreTier: [String]] = [:]
    @State private var isGenerating = false
    @State private var generationFailed = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Button {
                    generate()
                } label: {
                    HStack {
                        Label(isEmpty ? "Write it for me" : "Write it again", systemImage: "sparkles")
                        if isGenerating {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isGenerating || !CharacterStoryGenerator.isAvailable)
            } footer: {
                Text(generationNote)
            }

            lines("Everyday", footer: "Things anyone may know: where they live, their mornings, a dislike, a skill.", $everyday)
            lines("Tastes", footer: "Opinions they will argue for.", $tastes)
            lines("People", footer: "The few named people who keep coming up in their life.", $people)
            ForEach(LoreTier.allCases, id: \.self) { tier in
                lines(tier.title, footer: "Shared once you are \(tier.stage).", binding(for: tier))
            }
            lines("Their storyline", footer: "One small ongoing project, a step per week of knowing each other.", $arc)
        }
        .navigationTitle("\(displayName)'s story")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private var isEmpty: Bool {
        everyday.isEmpty && tastes.isEmpty && people.isEmpty && arc.isEmpty && stories.values.allSatisfy(\.isEmpty)
    }

    private var generationNote: String {
        if generationFailed { return "That did not work. Check the connection and the OpenAI key, then try again." }
        if !CharacterStoryGenerator.isAvailable { return "Writing it needs an OpenAI key. You can still write every line yourself." }
        return "Writes a life from the character's instructions. It replaces what is here; you can edit every line afterwards."
    }

    private func binding(for tier: LoreTier) -> Binding<[String]> {
        Binding(get: { stories[tier] ?? [] }, set: { stories[tier] = $0 })
    }

    private func lines(_ title: String, footer: String, _ items: Binding<[String]>) -> some View {
        Section {
            ForEach(items.wrappedValue.indices, id: \.self) { index in
                TextField("In their own words", text: Binding(
                    get: { index < items.wrappedValue.count ? items.wrappedValue[index] : "" },
                    set: { if index < items.wrappedValue.count { items.wrappedValue[index] = $0 } }), axis: .vertical)
                    .font(.subheadline)
            }
            .onDelete { items.wrappedValue.remove(atOffsets: $0) }
            Button {
                items.wrappedValue.append("")
            } label: {
                Label("Add a line", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    // MARK: - Sheet

    private func load() {
        guard !loaded else { return }
        loaded = true
        show(CharacterStoryProvider.shared.sheet(for: character))
    }

    private func show(_ sheet: CharacterStorySheet) {
        everyday = sheet.everyday
        tastes = sheet.tastes
        people = sheet.people
        arc = sheet.arc
        stories = Dictionary(grouping: sheet.fragments, by: \.tier).mapValues { $0.map(\.text) }
    }

    private var sheet: CharacterStorySheet {
        func kept(_ lines: [String]) -> [String] {
            lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let key = character.lowercased()
        let fragments = LoreTier.allCases.flatMap { tier in
            kept(stories[tier] ?? []).enumerated().map { index, text in
                LoreFragment(id: "\(key).\(tier.rawValue).\(index + 1)", tier: tier, text: text)
            }
        }
        return CharacterStorySheet(
            everyday: kept(everyday), tastes: kept(tastes), people: kept(people), fragments: fragments, arc: kept(arc))
    }

    private func save() {
        guard loaded, CharacterStoryProvider.shared.isEditable(character) else { return }
        CharacterStoryProvider.shared.save(sheet, for: character)
    }

    private func generate() {
        isGenerating = true
        generationFailed = false
        Task {
            let written = await CharacterStoryGenerator.generate(character: character)
            isGenerating = false
            guard let written else {
                generationFailed = true
                return
            }
            show(written)
            save()
        }
    }
}

#Preview {
    NavigationStack {
        CharacterStoryEditorView(character: "imported", displayName: "Mika")
    }
}
