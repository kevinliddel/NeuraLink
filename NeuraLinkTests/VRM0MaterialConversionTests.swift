//
//  VRM0MaterialConversionTests.swift
//  NeuraLinkTests
//
//  VRM 0.x → runtime material conversion: the materialProperties block is
//  the authoritative alpha/cull source for 0.x (the glTF block is only a
//  courtesy duplicate that VRoid fills in and other exporters leave at
//  defaults). These tests pin the _BlendMode/_Cutoff/_CullMode overrides,
//  the shader-name gate on MToon, the 0.x-gated TransparentWithZWrite
//  inference, and the name-aware materialProperties pairing.
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("VRM 0.x Material Conversion")
struct VRM0MaterialConversionTests {

    // MARK: - Helpers

    /// glTF material as an older exporter writes it: everything at defaults
    /// (OPAQUE, single-sided), truth only in the VRM extension.
    private func bareGLTFMaterial(name: String = "Outfit") throws -> GLTFMaterial {
        try JSONDecoder().decode(
            GLTFMaterial.self, from: Data("{\"name\": \"\(name)\"}".utf8))
    }

    private func vrm0Prop(
        name: String? = "Outfit",
        shader: String? = "VRM/MToon",
        floats: [String: Float] = [:]
    ) -> VRM0MaterialProperty {
        var prop = VRM0MaterialProperty()
        prop.name = name
        prop.shader = shader
        prop.floatProperties = floats
        return prop
    }

    private func makeMaterial(
        _ prop: VRM0MaterialProperty?, gltfName: String = "Outfit"
    ) throws -> VRMMaterial {
        VRMMaterial(
            from: try bareGLTFMaterial(name: gltfName), textures: [],
            vrm0MaterialProperty: prop, vrmVersion: .v0_0)
    }

    // MARK: - _BlendMode is authoritative over the glTF block

    @Test("_BlendMode 2 turns a glTF-OPAQUE material into BLEND")
    func blendModeTransparent() throws {
        let material = try makeMaterial(vrm0Prop(floats: ["_BlendMode": 2, "_ZWrite": 0]))
        #expect(material.alphaMode == "BLEND")
        #expect(material.isTransparentWithZWrite == false)
    }

    @Test("_BlendMode 1 gives MASK with the file's _Cutoff")
    func blendModeCutout() throws {
        let material = try makeMaterial(
            vrm0Prop(floats: ["_BlendMode": 1, "_Cutoff": 0.7]))
        #expect(material.alphaMode == "MASK")
        #expect(material.alphaCutoff == 0.7)
    }

    @Test("_BlendMode 3 is BLEND with depth write")
    func blendModeTransparentZWrite() throws {
        let material = try makeMaterial(vrm0Prop(floats: ["_BlendMode": 3]))
        #expect(material.alphaMode == "BLEND")
        #expect(material.isTransparentWithZWrite == true)
    }

    @Test("_BlendMode 2 with explicit _ZWrite 1 keeps depth write")
    func blendModeTransparentExplicitZWrite() throws {
        let material = try makeMaterial(vrm0Prop(floats: ["_BlendMode": 2, "_ZWrite": 1]))
        #expect(material.alphaMode == "BLEND")
        #expect(material.isTransparentWithZWrite == true)
    }

    @Test("_BlendMode 2 without _ZWrite defaults to no depth write (Unity MToon behavior)")
    func blendModeTransparentDefaultZWrite() throws {
        let material = try makeMaterial(vrm0Prop(floats: ["_BlendMode": 2]))
        #expect(material.isTransparentWithZWrite == false)
    }

    @Test("Missing renderQueue falls back to the per-blend-mode base", arguments: [
        (1, 2450),
        (2, 3000),
        (3, 2500)
    ])
    func renderQueueFallback(blendMode: Int, expectedQueue: Int) throws {
        let material = try makeMaterial(
            vrm0Prop(floats: ["_BlendMode": Float(blendMode)]))
        #expect(material.renderQueue == expectedQueue)
    }

    @Test("Explicit renderQueue wins over the blend-mode fallback")
    func renderQueueExplicit() throws {
        var prop = vrm0Prop(floats: ["_BlendMode": 2])
        prop.renderQueue = 2750
        let material = try makeMaterial(prop)
        #expect(material.renderQueue == 2750)
    }

    // MARK: - _CullMode is authoritative

    @Test("_CullMode 0 makes a glTF-single-sided material double-sided")
    func cullModeOff() throws {
        let material = try makeMaterial(vrm0Prop(floats: ["_CullMode": 0]))
        #expect(material.doubleSided == true)
    }

    @Test("_CullMode 2 stays single-sided")
    func cullModeBack() throws {
        let material = try makeMaterial(vrm0Prop(floats: ["_CullMode": 2]))
        #expect(material.doubleSided == false)
    }

    // MARK: - Shader-name gate

    @Test("VRM/MToon shader gets a toon material")
    func mtoonShader() throws {
        let material = try makeMaterial(vrm0Prop(shader: "VRM/MToon"))
        #expect(material.mtoon != nil)
    }

    @Test("Missing shader string is treated as MToon")
    func nilShader() throws {
        let material = try makeMaterial(vrm0Prop(shader: nil))
        #expect(material.mtoon != nil)
    }

    @Test("Unlit shaders skip toon shading and imply their alpha mode", arguments: [
        ("VRM/UnlitTexture", "OPAQUE", false),
        ("VRM/UnlitCutout", "MASK", false),
        ("VRM/UnlitTransparent", "BLEND", false),
        ("VRM/UnlitTransparentZWrite", "BLEND", true),
        ("Standard", "OPAQUE", false)
    ])
    func unlitShaders(shader: String, expectedAlphaMode: String, expectsZWrite: Bool) throws {
        let material = try makeMaterial(vrm0Prop(shader: shader))
        #expect(material.mtoon == nil)
        #expect(material.alphaMode == expectedAlphaMode)
        #expect(material.isTransparentWithZWrite == expectsZWrite)
    }

    @Test("VRM_USE_GLTFSHADER leaves the glTF settings completely untouched")
    func gltfShaderPassthrough() throws {
        // Spec: "If VRM_USE_GLTFSHADER is specified, use same index of
        // gltf's material settings" — stale property values must not apply.
        var prop = vrm0Prop(shader: "VRM_USE_GLTFSHADER", floats: [
            "_BlendMode": 2, "_CullMode": 0, "_Cutoff": 0.9
        ])
        prop.vectorProperties["_Color"] = [0.5, 0.5, 0.5, 0.5]
        prop.renderQueue = 3000

        let material = try makeMaterial(prop)
        #expect(material.mtoon == nil)
        #expect(material.alphaMode == "OPAQUE")
        #expect(material.alphaCutoff == 0.5)
        #expect(material.doubleSided == false)
        #expect(material.baseColorFactor == SIMD4<Float>(1, 1, 1, 1))
        #expect(material.renderQueue == 2000)
    }

    // MARK: - VRM 1.0 regression guard

    @Test("VRM 1.0 BLEND material without the explicit flag keeps depth write OFF")
    func vrm1BlendNoInference() throws {
        let gltf = try JSONDecoder().decode(
            GLTFMaterial.self,
            from: Data("{\"name\": \"Hair\", \"alphaMode\": \"BLEND\"}".utf8))
        let material = VRMMaterial(from: gltf, textures: [], vrmVersion: .v1_0)
        #expect(material.alphaMode == "BLEND")
        // zWriteEnabled defaults true — the 0.x gate must keep this false.
        #expect(material.isTransparentWithZWrite == false)
    }

    // MARK: - materialProperties pairing

    @Test("Positional pairing wins when names agree")
    func pairingPositional() {
        let props = [vrm0Prop(name: "A"), vrm0Prop(name: "B")]
        #expect(props.vrm0Property(forMaterialNamed: "B", at: 1)?.name == "B")
    }

    @Test("Nil names pair positionally")
    func pairingNilNames() {
        let props = [vrm0Prop(name: nil), vrm0Prop(name: nil)]
        #expect(props.vrm0Property(forMaterialNamed: "Anything", at: 1) != nil)
    }

    @Test("Reordered array is rescued by unique name match")
    func pairingReordered() {
        let props = [vrm0Prop(name: "B"), vrm0Prop(name: "A")]
        #expect(props.vrm0Property(forMaterialNamed: "A", at: 0)?.name == "A")
        #expect(props.vrm0Property(forMaterialNamed: "B", at: 1)?.name == "B")
    }

    @Test("Truncated array without a name match yields nil, not a mispair")
    func pairingTruncated() {
        let props = [vrm0Prop(name: "A")]
        #expect(props.vrm0Property(forMaterialNamed: "Z", at: 3) == nil)
    }

    @Test("Duplicate names skip the ambiguous rescue and keep the positional entry")
    func pairingDuplicateNames() {
        let props = [vrm0Prop(name: "B"), vrm0Prop(name: "A"), vrm0Prop(name: "A")]
        // Two "A" entries → name rescue is ambiguous; pre-fix positional
        // behavior wins over stripping the material's 0.x state entirely.
        #expect(props.vrm0Property(forMaterialNamed: "A", at: 0)?.name == "B")
    }

    @Test("Systematic name differences keep positional pairing (pre-fix behavior)")
    func pairingDifferentNamingSchemes() {
        // Exporter named the arrays differently but kept them aligned.
        let props = [vrm0Prop(name: "mat_01"), vrm0Prop(name: "mat_02")]
        #expect(props.vrm0Property(forMaterialNamed: "Outfit", at: 1)?.name == "mat_02")
    }
}
