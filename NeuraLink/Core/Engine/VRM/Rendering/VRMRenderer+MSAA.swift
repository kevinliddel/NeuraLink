//
//  VRMRenderer+MSAA.swift
//  NeuraLink
//
//  Multisampled render targets. With `config.sampleCount > 1` the scene is
//  drawn into MSAA colour and depth that live only in tile memory
//  (memoryless): Apple GPUs resolve colour into the drawable at the end of
//  the pass and never write the samples out, so 4× MSAA costs no RAM on
//  the 4 GB tier. That requires the whole scene in one render pass, which
//  drawCore is; the lens-rain overlay runs afterwards on the resolved image.
//
//  Created by Dedicatus on 16/04/2026.
//

import Metal
import MetalKit

extension VRMRenderer {

    /// (Re)creates the MSAA targets for `size`. False when multisampling is
    /// off or the targets couldn't be made.
    @discardableResult
    public func updateDrawableSize(_ size: CGSize) -> Bool {
        guard usesMultisampling else {
            multisampleTexture = nil
            multisampleDepthTexture = nil
            return false
        }
        if size == currentDrawableSize, multisampleTexture != nil, multisampleDepthTexture != nil { return true }
        currentDrawableSize = size
        multisampleTexture = makeMultisampleTarget(config.colorPixelFormat, size: size, label: "MSAA Colour")
        multisampleDepthTexture = makeMultisampleTarget(.depth32Float, size: size, label: "MSAA Depth")
        return multisampleTexture != nil && multisampleDepthTexture != nil
    }

    /// A pass that draws into the MSAA targets and resolves colour into
    /// `resolve`; depth is discarded. Nil when multisampling is off.
    public func multisamplePassDescriptor(
        resolvingInto resolve: MTLTexture, clearColor: MTLClearColor
    ) -> MTLRenderPassDescriptor? {
        guard updateDrawableSize(CGSize(width: resolve.width, height: resolve.height)),
              let color = multisampleTexture, let depth = multisampleDepthTexture
        else { return nil }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = color
        descriptor.colorAttachments[0].resolveTexture = resolve
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .multisampleResolve
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1
        return descriptor
    }

    private func makeMultisampleTarget(_ format: MTLPixelFormat, size: CGSize, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DMultisample
        descriptor.pixelFormat = format
        descriptor.width = max(1, Int(size.width))
        descriptor.height = max(1, Int(size.height))
        descriptor.sampleCount = config.sampleCount
        descriptor.usage = [.renderTarget]
        #if targetEnvironment(simulator)
        descriptor.storageMode = .private  // the simulator has no tile memory
        #else
        descriptor.storageMode = .memoryless
        #endif
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "\(label) (\(config.sampleCount)×)"
        return texture
    }
}

// MARK: - CLI Rendering Support

extension VRMRenderer {

    public func setDebugMode(_ mode: Int) {
        currentDebugMode = mode
    }
}
