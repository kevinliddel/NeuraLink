//
//  CharacterCustomizationView.swift
//  NeuraLink
//
//  Customization sheet (docs/CHARACTER_CUSTOMIZATION.md). Sits over
//  the live scene — the renderer *is* the preview — and reads like a
//  character-creator catalogue: a category rail, a grid of picture tiles
//  for the parts on offer, and colour underneath. Hair, Outfit and the
//  single garments graft the donor's geometry; Eyes borrows its textures. Edits
//  update a draft spec that AppearanceApplier applies immediately; Save
//  persists, Cancel restores the saved look, Reset clears everything.
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
    /// User-set grid height. Capped at the default, so the sheet can be
    /// pulled shorter to see more of the avatar but never taller.
    @State private var gridHeight: CGFloat = CustomizationTheme.gridHeight
    @State private var gridHeightAtDragStart: CGFloat?

    private var registry = VRMModelRegistry.shared
    private var store = AppearanceStore.shared
    private var applier = AppearanceApplier.shared
    private var thumbnails = PartThumbnailStore.shared

    init(slug: String, state: VRMMetalState, onClose: @escaping () -> Void) {
        self.slug = slug
        self.state = state
        self.onClose = onClose
    }

    /// One tile. Donors sharing a fingerprint (the same uniform on different
    /// models) collapse into one; `aliases` lists every slug it stands for.
    struct DonorOption: Identifiable, Equatable {
        let slug: String
        let displayName: String
        /// Dedupe identity.
        let fingerprint: String
        /// Picture file, named after the part ("casual__hair").
        let thumbnailName: String
        var aliases: Set<String>
        /// Texture categories: the slots this donor can supply.
        let slots: [VRoidMaterialSlot]
        var id: String { fingerprint }
    }

    private struct DonorSource {
        let slug: String
        let displayName: String
        /// Model stem the picture is named after.
        let thumbnailBase: String
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

    /// Donor selected on this tab, or nil for "Original".
    private var selectedDonorSlug: String? {
        if let part = category.part { return draft.parts[part] }
        return category.textureSlots.compactMap { draft.textures[$0]?.donorSlug }.first
    }

    private var isDirty: Bool { draft.normalized() != saved.normalized() }

    private var thumbnailSubject: VRMPartThumbnailRenderer.Subject {
        switch category {
        case .hair: return .hair
        case .outfit: return .outfit
        case .tops: return .tops
        case .bottoms: return .bottoms
        case .shoes: return .shoes
        case .eyes: return .eyes
        }
    }

    private var emptyHint: String {
        category.part != nil
            ? "No other model in the library has a \(category.title.lowercased())."
            : "No other model has a matching \(category.title.lowercased()) texture."
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            if state.isModelLoaded, state.currentModel != nil {
                categoryRail
                grid
                    .padding(.top, CustomizationTheme.sectionGap)
                CustomizationColorSection(
                    title: category.colourHint,
                    recolor: currentRecolor,
                    isEnabled: !recolorSlots.isEmpty,
                    isExpanded: $showColour,
                    onChange: applyRecolor)
                    .padding(.top, CustomizationTheme.sectionGap)
                footer
                    .padding(.top, CustomizationTheme.sectionGap)
            } else {
                ProgressView("Loading character…")
                    .tint(.white)
                    .foregroundColor(CustomizationTheme.label)
                    .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(CustomizationTheme.panel)
                .ignoresSafeArea(edges: .bottom))
        .onAppear(perform: loadIfNeeded)
        .onChange(of: state.isModelLoaded) { _, loaded in
            if loaded { loadIfNeeded() }
        }
        .task(id: "\(slug)|\(category.rawValue)|\(state.isModelLoaded)") { await refreshDonors() }
    }

    /// Drag handle: pulling down shortens the sheet by shrinking the tile
    /// grid (which scrolls anyway); pulling up restores it to the default.
    ///
    /// The gesture is measured in GLOBAL space on purpose. Resizing moves
    /// the handle itself, so a local translation is fed back its own result
    /// and the drag stutters and fights the finger. Animations are also
    /// suppressed for the duration — an implicit one would chase every
    /// frame's new height instead of tracking the touch.
    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity, minHeight: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = gridHeightAtDragStart ?? gridHeight
                        if gridHeightAtDragStart == nil { gridHeightAtDragStart = start }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            gridHeight = min(
                                CustomizationTheme.gridHeight,
                                max(CustomizationTheme.gridHeightMin, start - value.translation.height))
                        }
                    }
                    .onEnded { _ in gridHeightAtDragStart = nil })
            .accessibilityLabel("Resize panel")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 40
                switch direction {
                case .increment:
                    gridHeight = min(CustomizationTheme.gridHeight, gridHeight + step)
                case .decrement:
                    gridHeight = max(CustomizationTheme.gridHeightMin, gridHeight - step)
                @unknown default:
                    break
                }
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(displayName)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(CustomizationTheme.label)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(CustomizationTheme.label)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(CustomizationTheme.control))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.bottom, 8)
    }

    private var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { item in
                    let selected = category == item
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            category = item
                            showColour = false
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 15, weight: .medium))
                            Text(item.title)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(selected ? .black : CustomizationTheme.label)
                        .frame(width: 58, height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selected ? CustomizationTheme.accent : CustomizationTheme.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var grid: some View {
        CustomizationItemGrid(
            items: donors,
            emptyHint: emptyHint,
            isLoading: isLoadingDonors || applier.isGrafting,
            height: gridHeight,
            tile: { option in
                CustomizationItemTile(
                    title: option.displayName,
                    image: thumbnails.image(named: option.thumbnailName),
                    isSelected: selectedDonorSlug.map { option.aliases.contains($0) } ?? false,
                    isOriginal: false,
                    action: { selectDonor(option) })
                .onAppear {
                    thumbnails.ensure(
                        named: option.thumbnailName, donorSlug: option.slug, subject: thumbnailSubject)
                }
            },
            originalTile: {
                CustomizationItemTile(
                    title: "Original",
                    image: nil,
                    isSelected: selectedDonorSlug == nil,
                    isOriginal: true,
                    action: { selectDonor(nil) })
            })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: resetAll) {
                Text("Reset")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(draft.isEmpty ? CustomizationTheme.secondaryLabel : CustomizationTheme.label)
                    .frame(maxWidth: .infinity)
                    .frame(height: CustomizationTheme.controlHeight)
                    .background(Capsule().fill(CustomizationTheme.control))
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)

            Button(action: save) {
                Text("Save")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: CustomizationTheme.controlHeight)
                    .background(
                        Capsule().fill(isDirty ? CustomizationTheme.accent : CustomizationTheme.accent.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!isDirty)
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !didLoad, state.currentModel != nil else { return }
        didLoad = true
        saved = store.spec(for: slug) ?? AppearanceSpec()
        draft = saved
        category = categories.first ?? .hair
    }

    private func applyRecolor(_ recolor: SlotRecolor) {
        for slot in recolorSlots {
            if recolor.isIdentity {
                draft.recolors.removeValue(forKey: slot)
            } else {
                draft.recolors[slot] = recolor
            }
        }
        applier.apply(draft, to: state)
    }

    private func selectDonor(_ option: DonorOption?) {
        if let part = category.part {
            if let option {
                draft.parts[part] = option.slug
                // A whole outfit and the single garments cover the same
                // ground. Leaving both set meant the result depended on
                // which graft ran last, so choosing one drops the other.
                for replaced in part.supersedes { draft.parts.removeValue(forKey: replaced) }
            } else {
                draft.parts.removeValue(forKey: part)
            }
        } else {
            for slot in category.textureSlots { draft.textures.removeValue(forKey: slot) }
            if let option {
                for slot in option.slots {
                    draft.textures[slot] = DonorTextureRef(donorSlug: option.slug, slot: slot)
                }
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

    /// Donors usable on this tab — the parts library plus the other
    /// characters. Part tabs need the part; texture tabs need textures that
    /// cover at least one of the tab's slots on this model. Donors with the
    /// same part fingerprint (one uniform worn by several models) collapse
    /// into a single tile.
    private func refreshDonors() async {
        guard state.isModelLoaded, let model = state.currentModel else { return }
        isLoadingDonors = true
        defer { isLoadingDonors = false }
        let category = self.category
        let present = presentSlots
        let applier = self.applier
        // Characters are not offered as SHOE donors. VRoid draws socks and
        // stockings into the outfit material rather than the shoe, so a shoe
        // lifted off a whole character arrives without the legwear that
        // belongs with it and the borrowed leg reads as bare or broken. The
        // library's shoe PARTS carry their legwear, cut in at extraction, so
        // they stay. (Taking the same slice at graft time was tried and
        // produced sheets of stray geometry around the calf.)
        let sources = PartsLibrary.shared.items.filter { $0.serves(category) }
            .map { DonorSource(slug: $0.donorSlug, displayName: $0.displayName, thumbnailBase: $0.modelStem) }
            + registry.all.filter { $0.name.lowercased() != slug && category != .shoes }
                .map {
                    DonorSource(
                        slug: $0.name.lowercased(), displayName: $0.displayName,
                        thumbnailBase: $0.name.lowercased())
                }

        // Inventory every donor concurrently (scans are cheap and cached).
        let scanned: [(Int, DonorScan)] = await withTaskGroup(of: (Int, DonorScan?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { (index, await applier.donorScan(slug: source.slug)) }
            }
            var results: [(Int, DonorScan)] = []
            for await (index, scan) in group {
                if let scan { results.append((index, scan)) }
            }
            return results.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled else { return }

        var options: [DonorOption] = []
        var indexByFingerprint: [String: Int] = [:]
        for (index, scan) in scanned {
            guard !Task.isCancelled else { return }
            let source = sources[index]
            let name = PartThumbnailStore.thumbnailName(base: source.thumbnailBase, category: category)
            let option: DonorOption?
            if let part = category.part {
                option = scan.hasPart(part)
                    ? DonorOption(
                        slug: source.slug, displayName: source.displayName,
                        fingerprint: scan.partFingerprint(part) ?? source.slug,
                        thumbnailName: name, aliases: [source.slug], slots: [])
                    : nil
            } else {
                var slots: [VRoidMaterialSlot] = []
                for slot in category.textureSlots where present.contains(slot) {
                    if let donor = scan.slots[slot], await applier.isCompatible(donor: donor, slot: slot, model: model) {
                        slots.append(slot)
                    }
                }
                // Thumbnail/dedupe identity is the donor's whole category, not
                // the host-dependent compatible subset, so a picture matches
                // on every character.
                option = slots.isEmpty
                    ? nil
                    : DonorOption(
                        slug: source.slug, displayName: source.displayName,
                        fingerprint: scan.fingerprint(forSlots: Set(category.textureSlots)) ?? source.slug,
                        thumbnailName: name, aliases: [source.slug], slots: slots)
            }
            guard let option else { continue }
            if let existing = indexByFingerprint[option.fingerprint] {
                options[existing].aliases.insert(option.slug)
            } else {
                indexByFingerprint[option.fingerprint] = options.count
                options.append(option)
            }
        }
        guard !Task.isCancelled else { return }
        donors = options
    }
}
