//
//  CharacterStoryEditorView.swift
//  NeuraLink
//
//  The story sheet of an imported character — Inner life
//  (docs/Companion/LIVING_COMPANION.md): what it says about its own life
//  when the conversation turns to it. Written once from the persona prompt
//  (CharacterStoryGenerator) and editable here line by line; "Write it for
//  me" writes it again. Saved when the screen closes, and only when
//  something here changed: an untouched editor never overwrites a sheet
//  that was written underneath it.
//
//  Created by Dedicatus on 10/11/2026.
//

import SwiftUI

struct CharacterStoryEditorView: View {
    let character: String
    let displayName: String

    /// One editable line. A story carries its fragment id, so its "shared
    /// on" date stays with it whatever is edited or removed around it.
    private struct Line: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var fragmentID = ""
    }

    @State private var everyday: [Line] = []
    @State private var tastes: [Line] = []
    @State private var people: [Line] = []
    @State private var arc: [Line] = []
    @State private var stories: [LoreTier: [Line]] = [:]
    /// The sheet as last read from or written to storage.
    @State private var baseline = CharacterStorySheet()
    @State private var generation: Task<Void, Never>?
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
                        Label(sheet.isEmpty ? "Write it for me" : "Write it again", systemImage: "sparkles")
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
                lines(tier.title, footer: "Shared once you are \(tier.stage).", binding(for: tier), tier: tier)
            }
            lines("Their storyline", footer: "One small ongoing project, a step per week of knowing each other.", $arc)
        }
        .navigationTitle("\(displayName)'s story")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear {
            // A result that arrives after the screen closed must not replace
            // what is saved now or later.
            generation?.cancel()
            save()
        }
    }

    private var generationNote: String {
        if generationFailed { return "That did not work. Check the connection and the OpenAI key, then try again." }
        if !CharacterStoryGenerator.isAvailable { return "Writing it needs an OpenAI key. You can still write every line yourself." }
        return "Writes a life from the character's instructions. It replaces what is here; you can edit every line afterwards."
    }

    private func binding(for tier: LoreTier) -> Binding<[Line]> {
        Binding(get: { stories[tier] ?? [] }, set: { stories[tier] = $0 })
    }

    private func lines(_ title: String, footer: String, _ items: Binding<[Line]>, tier: LoreTier? = nil) -> some View {
        Section {
            ForEach(items) { $line in
                TextField("In their own words", text: $line.text, axis: .vertical)
                    .font(.subheadline)
            }
            .onDelete { items.wrappedValue.remove(atOffsets: $0) }
            Button {
                let id = tier.map { CharacterStoryProvider.newFragmentID(character: character, tier: $0) } ?? ""
                items.wrappedValue.append(Line(text: "", fragmentID: id))
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

    /// Shows `sheet` and takes it as what storage holds.
    private func show(_ sheet: CharacterStorySheet) {
        everyday = sheet.everyday.map { Line(text: $0) }
        tastes = sheet.tastes.map { Line(text: $0) }
        people = sheet.people.map { Line(text: $0) }
        arc = sheet.arc.map { Line(text: $0) }
        stories = Dictionary(grouping: sheet.fragments, by: \.tier)
            .mapValues { $0.map { Line(text: $0.text, fragmentID: $0.id) } }
        baseline = sheet
    }

    /// The sheet as edited: blank lines dropped.
    private var sheet: CharacterStorySheet {
        func kept(_ lines: [Line]) -> [Line] {
            lines.map { Line(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), fragmentID: $0.fragmentID) }
                .filter { !$0.text.isEmpty }
        }
        let fragments = LoreTier.allCases.flatMap { tier in
            kept(stories[tier] ?? []).map { line in
                LoreFragment(
                    id: line.fragmentID.isEmpty ? CharacterStoryProvider.newFragmentID(character: character, tier: tier) : line.fragmentID,
                    tier: tier, text: line.text)
            }
        }
        return CharacterStorySheet(
            everyday: kept(everyday).map(\.text), tastes: kept(tastes).map(\.text), people: kept(people).map(\.text),
            fragments: fragments, arc: kept(arc).map(\.text))
    }

    /// Writes the edited sheet, only when it differs from what was read:
    /// an editor opened before the import's sheet arrived, and never
    /// touched, must not wipe that sheet on closing.
    private func save() {
        guard loaded, CharacterStoryProvider.shared.isEditable(character) else { return }
        let edited = sheet
        guard edited != baseline else { return }
        if CharacterStoryProvider.shared.save(edited, for: character) { baseline = edited }
    }

    private func generate() {
        isGenerating = true
        generationFailed = false
        let before = sheet
        generation = Task {
            let written = await CharacterStoryGenerator.generate(character: character)
            // The screen closed, or lines were edited while it was writing:
            // the result is dropped rather than laid over them.
            guard !Task.isCancelled else { return }
            isGenerating = false
            guard let written else {
                generationFailed = true
                return
            }
            guard sheet == before else { return }
            let stored = baseline
            show(written)
            if !CharacterStoryProvider.shared.save(written, for: character) {
                // Not stored: still unsaved, so closing the screen tries again.
                baseline = stored
                generationFailed = true
            }
        }
    }
}

#Preview {
    NavigationStack {
        CharacterStoryEditorView(character: "imported", displayName: "Mika")
    }
}
