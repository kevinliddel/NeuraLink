//
//  VRMRenderer+MaterialTextures.swift
//  NeuraLink
//
//  Binds a material's textures for mtoon_fragment_v2, each with its own
//  glTF sampler (VRMSamplerCache). Texture slots 0–7 are base colour, shade
//  multiply, shading shift, normal, emissive, matcap, rim multiply and the
//  UV-animation mask; slot 0 samples with sampler 0, sampler 1 belongs to
//  the avatar shadow map, so slots 1–7 use samplers 2–8.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
@preconcurrency import Metal

extension VRMRenderer {

    static func samplerIndex(forTextureSlot slot: Int) -> Int { slot == 0 ? 0 : slot + 1 }

    /// Binds `texture` at `slot` (nil clears it) with its sampler, or the
    /// default one. True when a texture is bound.
    @discardableResult
    func bindMaterialTexture(_ texture: VRMTexture?, slot: Int, encoder: MTLRenderCommandEncoder) -> Bool {
        let mtlTexture = texture?.mtlTexture
        setFragmentTextureCached(mtlTexture, index: slot, encoder: encoder)
        if let sampler = texture?.sampler ?? samplerStates["default"] {
            encoder.setFragmentSamplerState(sampler, index: Self.samplerIndex(forTextureSlot: slot))
        }
        return mtlTexture != nil
    }

    /// Binds all eight slots for `material` and sets each presence flag to
    /// whether a texture is actually bound (a texture that failed to load
    /// used to keep its flag on and sample an empty slot).
    func bindMaterialTextures(
        _ material: VRMMaterial, model: VRMModel, uniforms: inout MToonMaterialUniforms,
        encoder: MTLRenderCommandEncoder
    ) {
        func texture(_ index: Int?) -> VRMTexture? {
            index.flatMap { $0 < model.textures.count ? model.textures[$0] : nil }
        }
        let mtoon = material.mtoon
        func bind(_ texture: VRMTexture?, _ slot: Int) -> Int32 {
            bindMaterialTexture(texture, slot: slot, encoder: encoder) ? 1 : 0
        }
        uniforms.hasBaseColorTexture = bind(material.baseColorTexture, 0)
        uniforms.hasShadeMultiplyTexture = bind(texture(mtoon?.shadeMultiplyTexture), 1)
        uniforms.hasShadingShiftTexture = bind(texture(mtoon?.shadingShiftTexture?.index), 2)
        if uniforms.hasShadingShiftTexture != 0 {
            uniforms.shadingShiftTextureScale = mtoon?.shadingShiftTexture?.scale ?? 1.0
        }
        uniforms.hasNormalTexture = bind(material.normalTexture, 3)
        uniforms.hasEmissiveTexture = bind(material.emissiveTexture, 4)
        uniforms.hasMatcapTexture = bind(texture(mtoon?.matcapTexture), 5)
        uniforms.hasRimMultiplyTexture = bind(texture(mtoon?.rimMultiplyTexture), 6)
        uniforms.hasUvAnimationMaskTexture = bind(texture(mtoon?.uvAnimationMaskTexture), 7)
    }
}
