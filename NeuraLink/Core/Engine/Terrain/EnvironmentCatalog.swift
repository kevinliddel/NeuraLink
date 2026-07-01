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

    static func == (lhs: EnvironmentOption, rhs: EnvironmentOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum EnvironmentCatalog {
    /// Default placement shared by today's environments (sunk slightly so the
    /// ground plane meets the mesh). Give a new GLB its own value here if needed.
    private static let defaultInstance: EnvironmentRenderer.InstanceConfig =
        (x: 0, y: -0.02, z: 0, rotY: 0, scale: 1.0)

    /// Every selectable environment, in picker order.
    /// It auto-fits to a ~120-unit footprint
    /// (recentered on the origin); the others render at their native size. Tune
    /// the footprint here if needed — the loaded extent + scale are logged.
    static let all: [EnvironmentOption] = [
        EnvironmentOption(
            id: "city", displayName: "City",
            previewImage: "city", instanceConfig: defaultInstance,
            autoFitFootprint: nil, bakedLighting: true),
        EnvironmentOption(
            id: "campus", displayName: "Campus",
            previewImage: "campus", instanceConfig: defaultInstance,
            autoFitFootprint: nil, bakedLighting: true),
        EnvironmentOption(
            id: "apartment", displayName: "Apartment",
            previewImage: "apartment", instanceConfig: defaultInstance,
            autoFitFootprint: nil, bakedLighting: false)
    ]

    /// The option for an id, falling back to the first (default) environment so a
    /// stale or unknown persisted value never leaves the scene without a mesh.
    static func option(for id: String) -> EnvironmentOption {
        all.first { $0.id == id } ?? all[0]
    }
}
