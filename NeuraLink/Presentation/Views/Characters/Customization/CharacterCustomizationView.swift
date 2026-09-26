//
//  CharacterCustomizationView.swift
//  NeuraLink
//
//  Customization panel (docs/CHARACTER_CUSTOMIZATION_PLAN.md). Sits over
//  the live scene — the renderer *is* the preview. Each tab shows the other
//  characters as donor cards: Hair and Outfit graft the donor's geometry,
//  Face / Eyes / Skin borrow textures, and every tab can recolour its part.
//  Edits update a draft spec that AppearanceApplier applies immediately;
//  Save persists, Cancel restores the saved look, Reset clears everything.
//

import SwiftUI

struct CharacterCustomizationView: View {
    let slug: String
    let state: VRMMetalState
    var onClose: () -> Void

    @State private var draft = AppearanceSpec()
    @State private var saved = AppearanceSpec()
    @State private var category: CustomizationCategory = .hair
    @State private var donors: [DonorOption] = []
    @State private var isLoadingDonors = false
    @State private var showColour = false
    @State private var didLoad = false

    private var registry = VRMModelRegistry.shared
    private var store = AppearanceStore.shared
    private var applier = AppearanceApplier.shared

    init(slug: String, state: VRMMetalState, onClose: @escaping () -> Void) {
        self.slug = slug
        self.state = state
        self.onClose = onClose
    }

    struct DonorOption: Identifiable, Equatable {
        let entry: VRMModelRegistry.Entry
        /// Texture categories: the slots this donor can supply.
        let slots: [VRoidMaterialSlot]
        var id: URL { entry.url }
    }

    // MARK: - Derived

    private var displayName: String {
        registry.entry(named: slug)?.displayName ?? slug.capitalized
    }

    private var presentSlots: Set<VRoidMaterialSlot> {
        state.currentModel.map(AppearanceApplier.presentSlots) ?? []
    }

    private var categories: [CustomizationCategory] {
        CustomizationCategory.allCases.filter { $0.isAvailable(presentSlots: presentSlots) }
    }

    private var recolorSlots: [VRoidMaterialSlot] {
        category.recolorSlots.filter { presentSlots.contains($0) }
    }

    private var currentRecolor: SlotRecolor {
        recolorSlots.first.flatMap { draft.recolors[$0] } ?? .identity
    }

    /// Donor currently selected on this tab, or nil for "Original".
    private var selectedDonorSlug: String? {
        if let part = category.part { return draft.parts[part] }
        return category.textureSlots.compactMap { draft.textures[$0]?.donorSlug }.first
    }

    private var isDirty: Bool { draft.normalized() != saved.normalized() }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 14) {
            header
            if state.isModelLoaded, state.currentModel != nil {
                categoryTabs
                donorCards
                colourSection
                footer
            } else {
                ProgressView("Loading character…")
                    .tint(.white)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 28).fill(.black.opacity(0.93)))
        .onAppear(perform: loadIfNeeded)
        .onChange(of: state.isModelLoaded) { _, loaded in
            if loaded { loadIfNeeded() }
        }
        .task(id: "\(slug)|\(category.rawValue)|\(state.isModelLoaded)") { await refreshDonors() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Customize \(displayName)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text("Borrow hair, outfits, faces and eyes from your other characters. Nothing is exported.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.75))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close")
        }
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { c in
                    Button {
                        category = c
                        showColour = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: c.systemImage)
                            Text(c.title)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Capsule().fill(category == c ? Color.white : Color.white.opacity(0.12)))
                        .foregroundColor(category == c ? .black : .white)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var donorCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                donorCard(title: "Original", image: nil, isSelected: selectedDonorSlug == nil) { selectDonor(nil) }
                ForEach(donors) { option in
                    donorCard(
                        title: option.entry.displayName,
                        image: thumbnail(for: option.entry),
                        isSelected: selectedDonorSlug == option.entry.name.lowercased()
                    ) { selectDonor(option) }
                }
                if donors.isEmpty && !isLoadingDonors {
                    Text(emptyHint)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 200, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .padding(.vertical, 2)
        }
        .overlay(alignment: .trailing) {
            if isLoadingDonors || applier.isGrafting {
                ProgressView().tint(.white).padding(8)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
        }
        .frame(height: 138)
    }

    private var emptyHint: String {
        category.part != nil
            ? "Add another character to borrow a \(category.title.lowercased()) from."
            : "No other character has a matching \(category.title.lowercased()) texture."
    }

    private func donorCard(title: String, image: UIImage?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.1))
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 96, height: 96)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? Color.white : Color.clear, lineWidth: 3))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 96)
            }
        }
        .buttonStyle(.borderless)
        .opacity(isSelected ? 1 : 0.85)
    }

    private var colourSection: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showColour.toggle() }
            } label: {
                HStack {
                    Image(systemName: "paintpalette")
                    Text(category.colourHint)
                    if !currentRecolor.isIdentity {
                        Circle().fill(Color.white).frame(width: 6, height: 6)
                    }
                    Spacer()
                    Image(systemName: showColour ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .frame(height: 44)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.borderless)
            .disabled(recolorSlots.isEmpty)

            if showColour {
                VStack(spacing: 8) {
                    colourSlider("Hue", value: currentRecolor.hueShift, range: -180...180, format: "%+.0f°") { v in
                        updateRecolor { $0.hueShift = v }
                    }
                    colourSlider("Saturation", value: currentRecolor.saturation, range: 0...2, format: "×%.2f") { v in
                        updateRecolor { $0.saturation = v }
                    }
                    colourSlider("Brightness", value: currentRecolor.brightness, range: 0.5...1.5, format: "×%.2f") { v in
                        updateRecolor { $0.brightness = v }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func colourSlider(
        _ title: String, value: Float, range: ClosedRange<Float>, format: String,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 84, alignment: .leading)
            Slider(
                value: Binding(get: { Double(value) }, set: { onChange(Float($0)) }),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .tint(.white)
            Text(String(format: format, value))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
        .frame(height: 40)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            footerButton("Reset", role: .destructive, prominent: false, action: resetAll)
                .disabled(draft.isEmpty)
            footerButton("Cancel", role: nil, prominent: false, action: cancel)
            footerButton("Save", role: nil, prominent: true, action: save)
                .disabled(!isDirty)
        }
    }

    private func footerButton(_ title: String, role: ButtonRole?, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.12)))
                .foregroundColor(prominent ? .black : (role == .destructive ? Color(red: 1, green: 0.5, blue: 0.5) : .white))
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !didLoad, state.currentModel != nil else { return }
        didLoad = true
        saved = store.spec(for: slug) ?? AppearanceSpec()
        draft = saved
        category = categories.first ?? .hair
    }

    private func updateRecolor(_ mutate: (inout SlotRecolor) -> Void) {
        var recolor = currentRecolor
        mutate(&recolor)
        for slot in recolorSlots {
            if recolor.isIdentity { draft.recolors.removeValue(forKey: slot) } else { draft.recolors[slot] = recolor }
        }
        applier.apply(draft, to: state)
    }

    private func selectDonor(_ option: DonorOption?) {
        if let part = category.part {
            if let option { draft.parts[part] = option.entry.name.lowercased() } else { draft.parts.removeValue(forKey: part) }
        } else {
            for slot in category.textureSlots { draft.textures.removeValue(forKey: slot) }
            if let option {
                for slot in option.slots { draft.textures[slot] = DonorTextureRef(donorSlug: option.entry.name, slot: slot) }
            }
        }
        applier.apply(draft, to: state)
    }

    private func resetAll() {
        draft = AppearanceSpec()
        applier.clear(on: state)
    }

    private func cancel() {
        if saved.isEmpty { applier.clear(on: state) } else { applier.apply(saved, to: state) }
        applier.releaseDonorCache()
        onClose()
    }

    private func save() {
        store.save(draft, for: slug)
        saved = draft.normalized()
        applier.releaseDonorCache()
        nlLog("[Customization] saved look for '\(slug)': \(saved.parts.count) parts, \(saved.textures.count) textures, \(saved.recolors.count) recolours", level: .info)
        onClose()
    }

    // MARK: - Donors

    /// Other registry characters usable on this tab: for part tabs, anyone
    /// who has the part; for texture tabs, anyone whose textures cover at
    /// least one of the tab's slots on this model.
    private func refreshDonors() async {
        guard state.isModelLoaded, let model = state.currentModel else { return }
        isLoadingDonors = true
        defer { isLoadingDonors = false }
        var options: [DonorOption] = []
        for entry in registry.all where entry.name.lowercased() != slug {
            guard !Task.isCancelled else { return }
            guard let scan = await applier.donorScan(slug: entry.name) else { continue }
            if let part = category.part {
                if scan.hasPart(part) { options.append(DonorOption(entry: entry, slots: [])) }
            } else {
                let slots = category.textureSlots.filter { slot in
                    presentSlots.contains(slot) && scan.slots[slot].map { applier.isCompatible(donor: $0, slot: slot, model: model) } == true
                }
                if !slots.isEmpty { options.append(DonorOption(entry: entry, slots: slots)) }
            }
        }
        guard !Task.isCancelled else { return }
        donors = options
    }

    private func thumbnail(for entry: VRMModelRegistry.Entry) -> UIImage? {
        let pngURL = entry.url.deletingPathExtension().appendingPathExtension("png")
        return UIImage(contentsOfFile: pngURL.path)
    }
}
