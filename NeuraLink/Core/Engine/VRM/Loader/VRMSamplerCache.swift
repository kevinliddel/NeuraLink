//
//  VRMSamplerCache.swift
//  NeuraLink
//
//  One Metal sampler per distinct glTF sampler (wrap and filter modes), so
//  each texture samples the way its file says — a matcap that clamps at its
//  rim (jelsa's MatcapWarp) instead of repeating into a seam.
//
//  Mipmaps stay on whatever the minFilter says: every UniVRM/VRoid file
//  writes LINEAR (9729), which strict glTF reads as "no mipmaps", but it is
//  how Unity's ordinary bilinear setting is exported and Unity still mips
//  those textures. Taking it literally would bring back the shimmer phase 1
//  removed. An explicit *_MIPMAP_NEAREST keeps its nearest mip choice.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import Metal

nonisolated enum VRMSamplerCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var samplers: [String: MTLSamplerState] = [:]

    /// The sampler for `gltf` (nil: glTF's defaults, repeat + linear).
    static func sampler(for gltf: GLTFSampler?, device: MTLDevice) -> MTLSamplerState? {
        let key = "\(ObjectIdentifier(device).hashValue)|\(gltf?.minFilter ?? 0)|\(gltf?.magFilter ?? 0)"
            + "|\(gltf?.wrapS ?? 10_497)|\(gltf?.wrapT ?? 10_497)"
        return lock.withLock {
            if let cached = samplers[key] { return cached }
            let sampler = device.makeSamplerState(descriptor: descriptor(for: gltf))
            samplers[key] = sampler
            return sampler
        }
    }

    static func descriptor(for gltf: GLTFSampler?) -> MTLSamplerDescriptor {
        let descriptor = MTLSamplerDescriptor()
        let nearestMin = [9728, 9984, 9986].contains(gltf?.minFilter ?? 0)
        descriptor.minFilter = nearestMin ? .nearest : .linear
        descriptor.mipFilter = [9984, 9985].contains(gltf?.minFilter ?? 0) ? .nearest : .linear
        descriptor.magFilter = gltf?.magFilter == 9728 ? .nearest : .linear
        descriptor.sAddressMode = addressMode(gltf?.wrapS)
        descriptor.tAddressMode = addressMode(gltf?.wrapT)
        descriptor.maxAnisotropy = nearestMin ? 1 : 16
        descriptor.normalizedCoordinates = true
        return descriptor
    }

    private static func addressMode(_ wrap: Int?) -> MTLSamplerAddressMode {
        switch wrap {
        case 33_071: return .clampToEdge
        case 33_648: return .mirrorRepeat
        default: return .repeat  // 10497 REPEAT, the glTF default
        }
    }
}
