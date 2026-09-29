//
//  AppearanceMaterialLayer.swift
//  NeuraLink
//
//  Renderer-side state for Tier A customization: per-material recolour
//  parameters (read by buildMaterialUniforms every draw) and base-colour
//  texture overrides with their originals remembered for an exact reset.
//
//  Texture overrides swap the MTLTexture *inside* the shared VRMTexture
//  object rather than re-pointing the material: VRoid materials sample the
//  same image as base colour AND as the MToon shade-multiply texture (0.x
//  `_MainTex` doubles as `_ShadeTexture`), so replacing the object at one
//  reference would leave the shadow side showing the old face.
//
//  Owned by VRMRenderer; reset on every loadModel/clearModel. The renderer
//  draws on the main thread and the applier runs on the main actor, but the
//  lock keeps the reads safe should a capture or diagnostic pass ever read
//  from elsewhere.
//

import Foundation
import Metal

public final class AppearanceMaterialLayer: @unchecked Sendable {
    private let lock = NSLock()
    private var recolors: [Int: SlotRecolor] = [:]
    /// texture index → original MTLTexture (nil entry = original was nil).
    private var originalTextures: [Int: MTLTexture?] = [:]

    public init() {}

    // MARK: - Recolour

    public func recolor(forMaterial index: Int) -> SlotRecolor? {
        lock.lock()
        defer { lock.unlock() }
        return recolors[index]
    }

    /// Nil or identity clears the entry.
    public func setRecolor(_ recolor: SlotRecolor?, materialIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let recolor, !recolor.isIdentity {
            recolors[materialIndex] = recolor
        } else {
            recolors.removeValue(forKey: materialIndex)
        }
    }

    public func clearRecolors() {
        lock.lock()
        defer { lock.unlock() }
        recolors.removeAll()
    }

    // MARK: - Texture overrides

    /// Index into `model.textures` of a material's base-colour texture
    /// object, or nil when the material has none.
    public func baseTextureIndex(materialIndex: Int, in model: VRMModel) -> Int? {
        guard materialIndex < model.materials.count,
            let base = model.materials[materialIndex].baseColorTexture
        else { return nil }
        return model.textures.firstIndex { $0 === base }
    }

    /// Replaces the GPU texture shared by every reference to
    /// `model.textures[textureIndex]`. The first override remembers the
    /// original so `restoreTexture` can put it back bit-exactly.
    public func overrideTexture(_ texture: MTLTexture, textureIndex: Int, in model: VRMModel) {
        guard textureIndex < model.textures.count else { return }
        lock.lock()
        if originalTextures[textureIndex] == nil {
            originalTextures[textureIndex] = .some(model.textures[textureIndex].mtlTexture)
        }
        lock.unlock()
        model.textures[textureIndex].mtlTexture = texture
    }

    public func restoreTexture(textureIndex: Int, in model: VRMModel) {
        lock.lock()
        let original = originalTextures.removeValue(forKey: textureIndex)
        lock.unlock()
        guard let original, textureIndex < model.textures.count else { return }
        model.textures[textureIndex].mtlTexture = original
    }

    public func isTextureOverridden(textureIndex: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return originalTextures[textureIndex] != nil
    }

    public func restoreAllTextures(in model: VRMModel) {
        lock.lock()
        let originals = originalTextures
        originalTextures.removeAll()
        lock.unlock()
        for (index, original) in originals where index < model.textures.count {
            model.textures[index].mtlTexture = original
        }
    }

    // MARK: - Lifecycle

    /// Forgets everything without touching a model — for loadModel/clearModel,
    /// where the previous model is already gone.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        recolors.removeAll()
        originalTextures.removeAll()
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recolors.isEmpty && originalTextures.isEmpty
    }
}
