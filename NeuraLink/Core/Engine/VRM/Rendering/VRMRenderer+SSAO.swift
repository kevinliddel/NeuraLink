//
//  VRMRenderer+SSAO.swift
//  NeuraLink
//
//  Environment depth pre-pass — renders the active environment (city/campus) to a
//  dedicated depth texture using the camera perspective VP. This depth is consumed
//  by the god-ray mask pass to distinguish sky pixels from scene pixels.
//  SSAO has been removed; only the pre-pass and texture resize are kept.

import Foundation
import Metal
import simd

extension VRMRenderer {

    // MARK: - Environment depth texture resize

    /// Creates or recreates the environment depth texture to match a new drawable size.
    /// Called from mtkView(_:drawableSizeWillChange:) and on first draw if size changed.
    func resizeSSAOTextures(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let w = Int(size.width), h = Int(size.height)

        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)
        t?.label = "Environment Depth"
        ssaoDepthTexture = t
    }

    // MARK: - Environment depth pre-pass

    /// Renders only the active environment (city or campus) to `ssaoDepthTexture`
    /// using the camera's perspective VP. Used by the god-ray mask pass.
    /// Must be called after shadow passes but before the main render encoder opens.
    func drawEnvironmentDepthPrePass(commandBuffer: MTLCommandBuffer) {
        guard let depthTex = ssaoDepthTexture,
              UserSettings.shared.showEnvironment
        else { return }

        let vp       = projectionMatrix * viewMatrix
        let selected = UserSettings.shared.selectedEnvironment

        if selected == "city" {
            cityRenderer?.drawShadow(
                commandBuffer: commandBuffer,
                shadowMap: depthTex,
                lightViewProjection: vp,
                clearFirst: true
            )
        } else {
            campusRenderer?.drawShadow(
                commandBuffer: commandBuffer,
                shadowMap: depthTex,
                lightViewProjection: vp,
                clearFirst: true
            )
        }
    }
}
