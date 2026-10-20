//
//  EnvironmentCatalog.swift
//  NeuraLink
//
//  Single source of truth for the selectable 3D environments. Drives both the
//  renderer (which GLB + world transform to load) and the settings picker
//  (display name + preview image). An option's `id` doubles as the persisted
//  `UserSettings.selectedEnvironment` value and the GLB basename in the shared
//  HuggingFace dataset's `scenes/` folder (`<id>.glb`).
//

import Foundation

struct EnvironmentOption: Identifiable, Hashable {
    /// Stable id — also the persisted selection value and GLB basename (`<id>.glb`).
    let id: String
    /// Title shown in the settings picker.
    let displayName: String
    /// Preview thumbnail name (bundled under `Models/Environments/<previewImage>.png`).
    let previewImage: String
    /// World placement applied when this environment's GLB is rendered.
    let instanceConfig: EnvironmentRenderer.InstanceConfig
    /// Optional uniform auto-fit target (see `EnvironmentRenderer.autoFitFootprint`).
    /// `nil` keeps the model's native size.
    let autoFitFootprint: Float?
    /// See `EnvironmentRenderer.bakedLighting`. true = textures already lit
    /// (city, campus); false = plain PBR albedo needing runtime lighting.
    let bakedLighting: Bool
    /// True for enclosed interiors (apartment, art gallery): outdoor 3D world
    /// rain is suppressed so it can't fall through the ceiling.
    let isInterior: Bool

    static func == (lhs: EnvironmentOption, rhs: EnvironmentOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum EnvironmentCatalog {
    /// Default placement shared by today's environments (sunk slightly so the
    /// ground plane meets the mesh). Give a new GLB its own value here if needed.
    private static let defaultInstance: EnvironmentRenderer.InstanceConfig =
        (x: 0, y: -0.02, z: 0, rotY: 0, scale: 1.0)

    /// Art gallery: yawed 90° to the viewer's right (`rotY`) and nudged forward
    /// toward the camera (`z`) so the avatar sits better inside it. `z` is world
    /// units — positive = toward the viewer, negative = away; tune to taste.
    private static let galleryInstance: EnvironmentRenderer.InstanceConfig =
        (x: 0, y: -0.02, z: 3, rotY: .pi / 2, scale: 1.0)

    // The three below were placed from the GLBs themselves (floor plans and
    // ray tests in the scene's own units): `scale` converts to metres, `rotY`
    // turns the scene so its best view sits behind the avatar, and `x`/`z`/`y`
    // move a chosen open spot of floor to the origin. Translation applies
    // after rotation (T·R·S), so it is the rotated, scaled spot negated.

    /// Modern apartment: a SketchUp export at 0.002 m per unit (2.9 m
    /// ceiling, 1.8 m fridge). The avatar stands on the rug between the
    /// dining table and the sofa, at (-15.2, -7.6) m, with the TV wall
    /// behind; its model origin is outside the building, and auto-fit's
    /// recentring would have put the avatar inside the sofa.
    private static let modernApartmentInstance: EnvironmentRenderer.InstanceConfig =
        (x: -7.6, y: -0.222, z: 15.2, rotY: -.pi / 2, scale: 0.002)

    /// Pool: modelled in inches (5.5 m hall, 1.8 m deep pool). Its origin is
    /// already open deck with 3 m clear all round, the loungers and the back
    /// wall behind and the pool to the right, so only the units change.
    private static let poolInstance: EnvironmentRenderer.InstanceConfig =
        (x: 0, y: -0.02, z: 0, rotY: 0, scale: 0.0254)

    /// St Bartholomew's: a photogrammetry scan in metres. Its origin sits on
    /// a pew seat, so the avatar moves into the central aisle at (-2.5, -2.2)
    /// m, where the floor is at -1.225, and the scene turns so the altar and
    /// the stained-glass apse are behind them, about 7 m away.
    private static let cathedralInstance: EnvironmentRenderer.InstanceConfig =
        (x: -2.2, y: 1.205, z: 2.5, rotY: -.pi / 2, scale: 1.0)

    /// Every selectable environment, in picker order.
    /// It auto-fits to a ~120-unit footprint
    /// (recentered on the origin); the others render at their native size. Tune
    /// the footprint here if needed — the loaded extent + scale are logged.
    static let all: [EnvironmentOption] = [
        EnvironmentOption(
            id: "city", displayName: "City",
            previewImage: "city", instanceConfig: defaultInstance,
            autoFitFootprint: nil, bakedLighting: true, isInterior: false),
        EnvironmentOption(
            id: "campus", displayName: "Campus",
            previewImage: "campus", instanceConfig: defaultInstance,
            autoFitFootprint: nil, bakedLighting: true, isInterior: false),
        EnvironmentOption(
            id: "apartment", displayName: "Apartment",
            previewImage: "apartment", instanceConfig: defaultInstance,
            autoFitFootprint: nil, bakedLighting: false, isInterior: true),
        EnvironmentOption(
            id: "art_gallery", displayName: "Art Gallery",
            previewImage: "art_gallery", instanceConfig: galleryInstance,
            autoFitFootprint: nil, bakedLighting: true, isInterior: true),
        EnvironmentOption(
            id: "modern_apartment", displayName: "Modern Apartment",
            previewImage: "modern_apartment", instanceConfig: modernApartmentInstance,
            autoFitFootprint: nil, bakedLighting: true, isInterior: true),
        EnvironmentOption(
            id: "pool", displayName: "Pool",
            previewImage: "pool", instanceConfig: poolInstance,
            autoFitFootprint: nil, bakedLighting: false, isInterior: true),
        EnvironmentOption(
            id: "st_bartholomew_cathedral", displayName: "St. Bartholomew's",
            previewImage: "st_bartholomew_cathedral", instanceConfig: cathedralInstance,
            autoFitFootprint: nil, bakedLighting: true, isInterior: true)
    ]

    /// The option for an id, falling back to the first (default) environment so a
    /// stale or unknown persisted value never leaves the scene without a mesh.
    static func option(for id: String) -> EnvironmentOption {
        all.first { $0.id == id } ?? all[0]
    }

    /// True for enclosed interior environments where outdoor 3D world rain must
    /// not fall inside. Keyed by the persisted selection id.
    static func isInterior(_ id: String) -> Bool { option(for: id).isInterior }
}
