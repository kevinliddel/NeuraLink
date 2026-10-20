//
//  CoplanarLayeringTests.swift
//  NeuraLinkTests
//
//  Duplicate surfaces in an environment GLB are put on layers so the later
//  copy always wins the depth test; everything else stays on layer 0.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Testing
import simd
@testable import NeuraLink

@Suite("Coplanar layering")
struct CoplanarLayeringTests {

    /// A 1×1 floor quad at height `y`, facing up (or down), shifted along x.
    private func floor(y: Float, x: Float = 0, up: Bool = true) -> [CoplanarFace] {
        let positions: [Float] = [x, y, 0, x + 1, y, 0, x + 1, y, 1, x, y, 1]
        // Counter-clockwise seen from above is +y.
        let indices: [UInt32] = up ? [0, 2, 1, 0, 3, 2] : [0, 1, 2, 0, 2, 3]
        return CoplanarLayering.faces(positions: positions, indices: indices, transform: matrix_identity_float4x4)
    }

    @Test("A quad yields one merged axis-aligned face with its facing and extent")
    func facesMerge() throws {
        let faces = floor(y: 0.5)
        #expect(faces.count == 1)
        let face = try #require(faces.first)
        #expect(face.axis == 1 && face.facing == 1 && face.coord == 0.5)
        #expect(face.maxU - face.minU == 1 && face.maxV - face.minV == 1)
        #expect(floor(y: 0.5, up: false).first?.facing == -1)
    }

    @Test("A later copy in the same plane goes one layer up; a third goes two up")
    func duplicatesStack() {
        #expect(CoplanarLayering.layers(faces: [floor(y: 0), floor(y: 0)], tolerance: 0.001) == [0, 1])
        #expect(CoplanarLayering.layers(faces: [floor(y: 0), floor(y: 0.0004), floor(y: 0)], tolerance: 0.001) == [0, 1, 2])
    }

    @Test("Separate planes, opposite facing or side-by-side quads stay on layer 0")
    func distinctSurfacesDoNotStack() {
        #expect(CoplanarLayering.layers(faces: [floor(y: 0), floor(y: 0.01)], tolerance: 0.001) == [0, 0])
        #expect(CoplanarLayering.layers(faces: [floor(y: 0), floor(y: 0, up: false)], tolerance: 0.001) == [0, 0])
        #expect(CoplanarLayering.layers(faces: [floor(y: 0), floor(y: 0, x: 1)], tolerance: 0.001) == [0, 0])
    }

    @Test("Slanted faces are ignored")
    func slantedFacesIgnored() {
        let positions: [Float] = [0, 0, 0, 1, 0.3, 0, 0, 0, 1]
        #expect(CoplanarLayering.faces(positions: positions, indices: [0, 2, 1], transform: matrix_identity_float4x4).isEmpty)
    }
}
