//
//  EnvironmentCatalogTests.swift
//  NeuraLinkTests
//
//  Every selectable environment can actually be shown: its GLB is pinned
//  (an unpinned scene downloads unverified), its picker picture ships in the
//  bundle, and the ids the selection is persisted under are unique.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Testing
@testable import NeuraLink

@Suite("Environment catalogue")
struct EnvironmentCatalogTests {

    @Test("Ids are unique and the three October scenes are offered")
    func idsAreUnique() {
        let ids = EnvironmentCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ["modern_apartment", "pool", "st_bartholomew_cathedral"] {
            #expect(ids.contains(id), "\(id)")
            #expect(EnvironmentCatalog.isInterior(id), "\(id) has a roof, so no rain indoors")
        }
    }

    @Test("Every environment's GLB is pinned by size and SHA-256", arguments: EnvironmentCatalog.all.map(\.id))
    func everySceneIsPinned(id: String) {
        let pin = RemoteAssetRegistry.scene(id).integrity
        #expect(pin != nil, "missing pin for scenes/\(id).glb")
        #expect((pin?.size ?? 0) > 0)
        #expect(pin?.sha256.count == 64)
    }

    @Test("Every environment's picker picture ships in the bundle", arguments: EnvironmentCatalog.all.map(\.previewImage))
    func everyPreviewShips(name: String) {
        // Unit-only builds may not package resources at all.
        guard Bundle.main.path(forResource: "city", ofType: "png") != nil else { return }
        #expect(Bundle.main.path(forResource: name, ofType: "png") != nil, "\(name).png")
    }

    @Test("No environment GLB is bundled: scenes come from the dataset")
    func noSceneShipsInTheBundle() {
        for option in EnvironmentCatalog.all {
            #expect(Bundle.main.path(forResource: option.id, ofType: "glb") == nil, "\(option.id).glb would ship in the app")
        }
    }
}
