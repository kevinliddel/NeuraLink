//
//  UVCoverageTests.swift
//  NeuraLinkTests
//
//  The donor-compatibility check behind texture borrowing: a donor texture
//  may only be applied when it paints every atlas cell the target slot
//  samples. Pure-function tests on the mask, plus a real-model pin: Sonya's
//  face/eye-white/mouth textures cover Ekaterina's UVs (the VRoid atlas is
//  shared — Phase 0 finding in docs/CHARACTER_CUSTOMIZATION_PLAN.md).
//

import Testing
import Foundation
import Metal
import CoreGraphics
@testable import NeuraLink

@Suite("UV coverage")
struct UVCoverageTests {

    @Test("Rasterizing one triangle marks its bounding cells only")
    func rasterizeTriangle() {
        let uvs: [SIMD2<Float>] = [[0, 0], [0.25, 0], [0, 0.25]]
        let mask = UVCoverageMask.rasterize(uvs: uvs, indices: [0, 1, 2])
        // 0.25 * 64 = 16 → cells 0…16 inclusive (conservative bbox)
        #expect(mask.count == 17 * 17)
        #expect(mask.contains(x: 0, y: 0))
        #expect(mask.contains(x: 16, y: 16))
        #expect(!mask.contains(x: 17, y: 0))
        #expect(!mask.contains(x: 40, y: 40))
    }

    @Test("Coverage fraction is |self ∩ other| / |self|")
    func fraction() {
        var a = UVCoverageMask()
        var b = UVCoverageMask()
        for x in 0..<10 { a.mark(x: x, y: 0) }
        for x in 0..<5 { b.mark(x: x, y: 0) }
        #expect(a.fraction(coveredBy: b) == 0.5)
        #expect(b.fraction(coveredBy: a) == 1.0)
        #expect(UVCoverageMask().fraction(coveredBy: a) == 0)
        a.formUnion(b)
        #expect(a.count == 10)
    }

    @Test("Alpha grid → mask honours the threshold")
    func alphaGrid() {
        let res = UVCoverageMask.resolution
        var alpha = [UInt8](repeating: 0, count: res * res)
        for y in 0..<res { alpha[y * res + 3] = 255 }
        alpha[0] = 100  // below threshold
        let mask = UVCoverageMask.fromAlphaGrid(alpha)
        #expect(mask.count == res)
        #expect(mask.contains(x: 3, y: 10))
        #expect(!mask.contains(x: 0, y: 0))
    }

    @Test("Texture alpha coverage keeps image orientation (row 0 = top)")
    func imageAlphaCoverage() throws {
        // 8×8 image: top half opaque, bottom half transparent.
        let size = 8
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        // CG's origin is bottom-left: fill y ∈ [4, 8) = the TOP half of the image.
        context.fill(CGRect(x: 0, y: 4, width: size, height: 4))
        let image = try #require(context.makeImage())

        let masks = AppearanceTextureFactory.coverageMasks(of: image)
        let res = UVCoverageMask.resolution
        #expect(masks.alpha.contains(x: 5, y: 2), "top rows painted")
        #expect(!masks.alpha.contains(x: 5, y: res - 3), "bottom rows transparent")
        #expect(masks.alpha.count == res * res / 2)
        #expect(masks.color.count == res * res / 2, "colour mask matches alpha for a solid fill")
    }

    @Test("Sonya's shared-atlas textures cover Ekaterina's face UVs")
    func bundledDonorCompatibility() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device — UV coverage reads GPU-shared buffers")
            return
        }
        guard let ekaterina = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm"),
            let sonya = Bundle.main.url(forResource: "Sonya", withExtension: "vrm")
        else {
            Issue.record("Bundled VRMs missing from the test host")
            return
        }
        let target = try await VRMModel.load(from: ekaterina, device: device)
        let scan = try await VRMDonorTextureCache.shared.scan(url: sonya, slug: "sonya")
        #expect(scan.slots[.faceSkin] != nil)
        #expect(scan.slots[.eyeIris] != nil)
        #expect((scan.slots[.hair]?.width ?? 0) > 0)

        // The body slot only passes because the PNG is decoded straight:
        // VRoid keeps skin colour under the alpha-0 texels its outfit hid.
        let body = try #require(scan.slots[.bodySkin])
        let bodyData = try #require(body.loadImageData(), "image bytes come back from the recorded file range")
        let straight = try #require(PNGStraightDecoder.decode(bodyData), "VRoid body texture decodes natively")
        #expect(straight.width == body.width && straight.height == body.height)
        let bodyMasks = try #require(await VRMDonorTextureCache.shared.coverageMasks(for: body))
        #expect(bodyMasks.color.count > bodyMasks.alpha.count, "colour survives under alpha holes")

        let applier = await AppearanceApplier.shared
        for slot: VRoidMaterialSlot in [.faceSkin, .eyeWhite, .mouth] {
            let donor = try #require(scan.slots[slot], "\(slot.rawValue) missing on donor")
            let masks = try #require(await VRMDonorTextureCache.shared.coverageMasks(for: donor))
            let coverage = try #require(await applier.targetCoverage(for: slot, in: target))
            #expect(!coverage.isEmpty, "\(slot.rawValue): target has UV footprint")
            let fraction = coverage.fraction(coveredBy: donor.coverage(for: slot, masks: masks))
            #expect(fraction >= AppearanceApplier.compatibilityThreshold, "\(slot.rawValue): \(fraction)")
            #expect(await applier.isCompatible(donor: donor, slot: slot, model: target))
        }

        // Body: alpha-only coverage is ~0.89 (VRoid punches alpha holes under
        // the outfit) and straight colour ~0.96; the gate counts the donor's
        // own UV footprint too, which makes the shared-atlas body a clean
        // pass — pins both the straight decode and the union rule.
        let bodyCoverage = try #require(await applier.targetCoverage(for: .bodySkin, in: target))
        let bodyFraction = bodyCoverage.fraction(coveredBy: body.coverage(for: .bodySkin, masks: bodyMasks))
        #expect(bodyFraction >= AppearanceApplier.compatibilityThreshold, "bodySkin: \(bodyFraction)")
        #expect(bodyCoverage.fraction(coveredBy: bodyMasks.alpha) < 0.95, "alpha alone would have refused it")
        #expect(bodyCoverage.fraction(coveredBy: bodyMasks.color) > bodyCoverage.fraction(coveredBy: bodyMasks.alpha))

        // Iris: the donor paints only the disc, so alpha alone fails (~0.7)
        // but the shared UV island makes it compatible — the OG "eyes" copy.
        let iris = try #require(scan.slots[.eyeIris])
        #expect(await applier.isCompatible(donor: iris, slot: .eyeIris, model: target))
    }
}
