//
//  VRMRenderProbeTests.swift
//  NeuraLinkTests
//
//  Render probes: a synthetic VRM goes through the real loader and the
//  real skinned MToon pipelines, and the read-back pixels are checked for
//  one property each — an anti-aliased edge, a correctly blended texel, a
//  minified texture that averages instead of aliasing, a data texture read
//  as data. Properties rather than golden images, so the simulator's GPU
//  and a device's give the same verdict. (docs/VRM_RENDERING_PLAN.md)
//
//  Created by Dedicatus on 22/10/2026.
//

import Foundation
import Metal
import Testing
@testable import NeuraLink

@MainActor
@Suite("VRM render probes", .serialized)
struct VRMRenderProbeTests {

    private static let red = SIMD4<Float>(1, 0, 0, 1)

    /// sRGB encoding of a linear value, as the drawable stores it.
    private static func srgb(_ linear: Float) -> Float {
        linear <= 0.003_130_8 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    @Test("A synthetic quad facing the key light renders exactly its base colour")
    func baseColour() async throws {
        let harness = try #require(VRMRenderHarness())
        let model = try await harness.load(SyntheticVRM(material: SyntheticVRM.mtoon(base: Self.red)))
        let image = try #require(harness.render(model))
        let center = image.pixel(64, 64)
        #expect(center.x > 0.97 && center.y < 0.03 && center.z < 0.03 && center.w > 0.97, "\(center)")
        #expect(image.pixel(2, 2).w < 0.03, "the background stays clear")
    }

    // MARK: - Phase 1

    @Test("4× MSAA gives a rolled quad's silhouette partial coverage")
    func antialiasedEdges() async throws {
        func partialEdgePixels(samples: Int) async throws -> Int {
            let harness = try #require(VRMRenderHarness(sampleCount: samples))
            let model = try await harness.load(SyntheticVRM(material: SyntheticVRM.mtoon(base: [1, 1, 1, 1])))
            let image = try #require(harness.render(model, up: [0.35, 1, 0]))
            return stride(from: 3, to: image.bgra.count, by: 4).filter { (26...229).contains(image.bgra[$0]) }.count
        }
        #expect(try await partialEdgePixels(samples: 1) == 0, "one sample: every pixel is in or out")
        #expect(try await partialEdgePixels(samples: 4) > 60, "four samples: the edge is blended")
    }

    @Test("The live scene renders with 4× MSAA")
    func liveSceneSampleCount() {
        #expect(VRMMetalState.sceneSampleCount == 4)
    }

    @Test("A 4× renderer and a 1× renderer never share a cached pipeline")
    func pipelinesKeyedBySampleCount() throws {
        // The live scene is 4×; the portrait/thumbnail renderer is 1×. Sharing
        // the cache entry aborted the app in Metal validation on device.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let live = VRMRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: 4))
        let thumbnail = VRMRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: 1))
        let liveSkinned = try #require(live.skinnedOpaquePipelineState)
        let thumbnailSkinned = try #require(thumbnail.skinnedOpaquePipelineState)
        #expect(liveSkinned !== thumbnailSkinned)
        #expect(live.skinnedBlendPipelineState !== thumbnail.skinnedBlendPipelineState)
        #expect(live.mtoonSkinnedOutlinePipelineState !== thumbnail.mtoonSkinnedOutlinePipelineState)
    }

    @Test("A half-transparent texel blends its own colour over the background")
    func straightAlpha() async throws {
        let harness = try #require(VRMRenderHarness())
        var probe = SyntheticVRM(material: SyntheticVRM.mtoon(baseTexture: 0, alphaMode: "BLEND"))
        probe.images = [TestPNG.solid(size: 4, (255, 0, 0, 128))]
        let model = try await harness.load(probe)
        let image = try #require(harness.render(model, clear: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)))
        let center = image.pixel(64, 64)
        // Straight alpha: red × ½ + white × ½ = (1, ½, ½) in linear light.
        #expect(center.x > 0.97, "red stays full, not darkened by premultiplication: \(center)")
        #expect(abs(center.y - Self.srgb(1 - 128.0 / 255)) < 0.04, "\(center)")
    }

    @Test("A minified checkerboard averages to gray instead of aliasing")
    func minifiedTexture() async throws {
        let harness = try #require(VRMRenderHarness())
        let side = 64
        let checker = (0..<(side * side)).flatMap { index -> [UInt8] in
            let value: UInt8 = (index % side + index / side) % 2 == 0 ? 255 : 0
            return [value, value, value, 255]
        }
        var probe = SyntheticVRM(material: SyntheticVRM.mtoon(baseTexture: 0))
        probe.images = [TestPNG.encode(width: side, height: side, rgba: checker)]
        let model = try await harness.load(probe)
        // About 23 px for 64 texels: ~2.8 texels per pixel.
        let image = try #require(harness.render(model, eye: [0, 1, 4.8]))
        let samples = (60..<68).flatMap { y in (60..<68).map { x in image.pixel(x, y).x } }
        let mean = samples.reduce(0, +) / Float(samples.count)
        let spread = (samples.max() ?? 0) - (samples.min() ?? 0)
        #expect(spread < 0.12, "a mip chain averages the checker: spread \(spread)")
        #expect(abs(mean - Self.srgb(0.5)) < 0.08, "mean \(mean)")
    }

    @Test("A shading-shift texture is read as data, not as sRGB colour")
    func linearDataTexture() async throws {
        let harness = try #require(VRMRenderHarness())
        // Gray 128 read as data is 0.5, remapped to 0: shading = 1 - 0.75 = 0.25,
        // lit (red). Read as sRGB it is 0.22, remapped to -0.57: shading
        // -0.32, shaded (blue).
        var probe = SyntheticVRM(material: SyntheticVRM.mtoon(base: Self.red, mtoon: [
            "shadeColorFactor": [0.0, 0.0, 1.0], "shadingToonyFactor": 0.95, "shadingShiftFactor": -0.75,
            "shadingShiftTexture": ["index": 0, "scale": 1.0]
        ]))
        probe.images = [TestPNG.solid(size: 4, (128, 128, 128, 255))]
        let model = try await harness.load(probe)
        let image = try #require(harness.render(model))
        let center = image.pixel(64, 64)
        #expect(center.x > 0.9 && center.z < 0.1, "lit side expected: \(center)")
    }

    // MARK: - Phase 2

    @Test("Emission adds factor × map; a referenced map that didn't load adds nothing")
    func emission() async throws {
        let harness = try #require(VRMRenderHarness())
        func centre(emissiveTexture: Int?, images: [Data]) async throws -> SIMD4<Float> {
            var extra: [String: Any] = ["emissiveFactor": [1.0, 0.0, 0.0]]
            if let emissiveTexture { extra["emissiveTexture"] = ["index": emissiveTexture] }
            var probe = SyntheticVRM(material: SyntheticVRM.mtoon(base: [0, 0, 0, 1], extra: extra))
            probe.images = images
            let image = try #require(harness.render(try await harness.load(probe)))
            return image.pixel(64, 64)
        }
        let white = TestPNG.solid(size: 4, (255, 255, 255, 255))
        let withMap = try await centre(emissiveTexture: 0, images: [white])
        #expect(withMap.x > 0.95 && withMap.y < 0.05, "factor × white map glows red: \(withMap)")
        let factorOnly = try await centre(emissiveTexture: nil, images: [])
        #expect(factorOnly.x > 0.95, "no map: the factor alone glows (glTF spec): \(factorOnly)")
        let missingMap = try await centre(emissiveTexture: 3, images: [white])
        #expect(missingMap.x < 0.05, "a map that didn't load must not wash the surface: \(missingMap)")
    }

    @Test("UV animation scrolls the texture on the skinned path")
    func uvAnimation() async throws {
        let harness = try #require(VRMRenderHarness())
        // Left half red, right half blue; scrolling half a texture swaps them.
        let stripes = (0..<16).flatMap { index -> [UInt8] in index % 4 < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        var probe = SyntheticVRM(material: SyntheticVRM.mtoon(baseTexture: 0, mtoon: ["uvAnimationScrollXSpeedFactor": 0.5]))
        probe.images = [TestPNG.encode(width: 4, height: 4, rgba: stripes)]
        let model = try await harness.load(probe)
        harness.renderer.materialTimeOverride = 0
        let start = try #require(harness.render(model)).pixel(47, 64)
        harness.renderer.materialTimeOverride = 1
        let later = try #require(harness.render(model)).pixel(47, 64)
        harness.renderer.materialTimeOverride = nil
        #expect(start.x > 0.9 && start.z < 0.1, "t = 0: the left quarter is red: \(start)")
        #expect(later.z > 0.9 && later.x < 0.1, "t = 1 s at 0.5/s: blue has scrolled in: \(later)")
    }

    @Test("Ambient light is brighter from above unless the material equalizes it")
    func hemisphereGI() async throws {
        let harness = try #require(VRMRenderHarness())
        harness.renderer.setAmbientColor(SIMD3<Float>(repeating: 0.5))
        defer { harness.renderer.setAmbientColor(.zero) }
        func brightness(normalY: Float, equalization: Double) async throws -> Float {
            var probe = SyntheticVRM(material: SyntheticVRM.mtoon(
                base: [0.25, 0.25, 0.25, 1], mtoon: ["giEqualizationFactor": equalization]))
            probe.normal = [0, normalY, 0]
            return try #require(harness.render(try await harness.load(probe))).pixel(64, 64).x
        }
        let up = try await brightness(normalY: 1, equalization: 0)
        let down = try await brightness(normalY: -1, equalization: 0)
        #expect(up > down + 0.05, "facing the sky reads brighter: up \(up), down \(down)")
        let upEqualized = try await brightness(normalY: 1, equalization: 1)
        let downEqualized = try await brightness(normalY: -1, equalization: 1)
        #expect(abs(upEqualized - downEqualized) < 0.01, "full equalization flattens it")
    }

    // MARK: - Phase 3

    /// A red sphere (radius 0.3 m at y = 1) with a green or white outline.
    private func outlinedSphere(
        mode: String, width: Double, colour: [Double] = [0, 1, 0], lightingMix: Double = 0
    ) -> SyntheticVRM {
        var probe = SyntheticVRM(material: SyntheticVRM.mtoon(base: Self.red, mtoon: [
            "outlineWidthMode": mode, "outlineWidthFactor": width,
            "outlineColorFactor": colour, "outlineLightingMixFactor": lightingMix
        ]))
        probe.sphereRadius = 0.3
        return probe
    }

    /// Outline pixels (green, not red) across the middle row.
    private func outlinePixels(_ image: RenderedImage) -> Int {
        image.row(image.height / 2).filter { $0.y > 0.5 && $0.x < 0.5 }.count
    }

    /// Screen radius in pixels of a sphere of `radius` at `distance`, 60° FOV.
    private func projectedRadius(_ radius: Float, distance: Float, size: Int) -> Float {
        tan(asin(radius / distance)) / tan(Float.pi / 6) * Float(size) / 2
    }

    @Test("A world-coordinates outline is as wide in meters as the material says")
    func worldOutlineWidth() async throws {
        let harness = try #require(VRMRenderHarness(size: 256))
        let model = try await harness.load(outlinedSphere(mode: "worldCoordinates", width: 0.05))
        let image = try #require(harness.render(model))
        // The hull is a sphere 5 cm larger: a ring of this many pixels each side.
        let ring = projectedRadius(0.35, distance: 1.6, size: 256) - projectedRadius(0.3, distance: 1.6, size: 256)
        let measured = Float(outlinePixels(image)) / 2
        #expect(abs(measured - ring) <= 1.5, "ring \(measured) px, spec \(ring) px")
    }

    @Test("A screen-coordinates outline keeps its on-screen width at any distance")
    func screenOutlineWidth() async throws {
        let harness = try #require(VRMRenderHarness(size: 256))
        let model = try await harness.load(outlinedSphere(mode: "screenCoordinates", width: 0.05))
        let near = outlinePixels(try #require(harness.render(model, eye: [0, 1, 1.6])))
        let far = outlinePixels(try #require(harness.render(model, eye: [0, 1, 3.2])))
        #expect(near >= 6, "visible at all: \(near)")
        #expect(abs(near - far) <= 3, "near \(near) px, far \(far) px")
    }

    @Test("Outline lighting mix 1 takes the surface's lit colour; 0 keeps the outline colour")
    func outlineLightingMix() async throws {
        let harness = try #require(VRMRenderHarness(size: 256))
        func ringPixel(mix: Double) async throws -> SIMD4<Float> {
            let model = try await harness.load(outlinedSphere(
                mode: "worldCoordinates", width: 0.05, colour: [1, 1, 1], lightingMix: mix))
            let image = try #require(harness.render(model))
            let row = image.row(image.height / 2)
            let firstOpaque = try #require(row.firstIndex { $0.w > 0.5 })
            return row[firstOpaque + 2]
        }
        let lit = try await ringPixel(mix: 1)
        #expect(lit.x > 0.8 && lit.y < 0.2, "white × red surface = red: \(lit)")
        let flat = try await ringPixel(mix: 0)
        #expect(flat.x > 0.9 && flat.y > 0.9, "pure outline colour: \(flat)")
    }

    @Test("With MSAA, a cutout edge inside the texture is anti-aliased (alpha to coverage)")
    func cutoutCoverage() async throws {
        let harness = try #require(VRMRenderHarness(sampleCount: 4))
        // Left half opaque white, right half fully transparent.
        let halves = (0..<64).flatMap { index -> [UInt8] in index % 8 < 4 ? [255, 255, 255, 255] : [255, 255, 255, 0] }
        var probe = SyntheticVRM(material: SyntheticVRM.mtoon(baseTexture: 0, alphaMode: "MASK"))
        probe.images = [TestPNG.encode(width: 8, height: 8, rgba: halves)]
        let image = try #require(harness.render(try await harness.load(probe)))
        // Rows through the quad's middle, columns around its centre line.
        let partial = (44..<84).reduce(0) { count, y in
            count + (56..<72).filter { let r = image.pixel($0, y).x; return r > 0.08 && r < 0.92 }.count
        }
        #expect(partial >= 30, "the cut edge has partial pixels: \(partial)")
    }

    // MARK: - Phase 4

    @Test("A part between the key light and the body casts the authored shade onto it")
    func receivedShadow() async throws {
        let harness = try #require(VRMRenderHarness())
        // Red when lit, blue in shade; the key light comes from +X.
        harness.renderer.setLight(0, direction: [-1, 0, 0], color: [1, 1, 1], intensity: 1)
        defer { harness.renderer.setLight(0, direction: [0, 0, -1], color: [1, 1, 1], intensity: 1) }
        func litSide(occluded: Bool, selfShadows: Bool = true) async throws -> SIMD4<Float> {
            var probe = SyntheticVRM(material: SyntheticVRM.mtoon(base: Self.red, mtoon: [
                "shadeColorFactor": [0.0, 0.0, 1.0], "shadingToonyFactor": 0.95
            ]))
            probe.sphereRadius = 0.3
            // A card 0.6 m toward the light, covering the sphere's lit cap.
            if occluded { probe.occluder = (center: [0.6, 1, 0], size: [0.7, 0.4]) }
            harness.renderer.avatarSelfShadowsEnabled = selfShadows
            defer { harness.renderer.avatarSelfShadowsEnabled = true }
            // From the front the lit cap is right of centre; the card is edge-on.
            let image = try #require(harness.render(try await harness.load(probe)))
            let patch = (60..<68).flatMap { y in (72..<79).map { x in image.pixel(x, y) } }
            return patch.reduce(.zero, +) / Float(patch.count)
        }
        let open = try await litSide(occluded: false)
        #expect(open.x > 0.8 && open.z < 0.2, "nothing in the way: lit red \(open)")
        let shadowed = try await litSide(occluded: true)
        // Red stays at the shader's 8 % base-colour floor (0.08 linear ≈ 0.31 sRGB).
        #expect(shadowed.z > 0.8 && shadowed.x < 0.35, "behind the card: the shade colour \(shadowed)")
        let disabled = try await litSide(occluded: true, selfShadows: false)
        #expect(disabled.x > 0.8, "self-shadows off (minimal pressure tier): lit again \(disabled)")
    }
}
