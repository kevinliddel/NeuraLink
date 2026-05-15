//
//  VRMRenderer+MSAA.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Metal
import MetalKit

// MARK: - MSAA Alpha-to-Coverage Support

extension VRMRenderer {

    @discardableResult
    public func updateDrawableSize(_ size: CGSize) -> Bool {
        guard size != currentDrawableSize || multisampleTexture == nil else {
            return multisampleTexture != nil
        }

        currentDrawableSize = size
        multisampleTexture = nil

        guard usesMultisampling else { return false }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DMultisample
        descriptor.width = Int(size.width)
        descriptor.height = Int(size.height)
        descriptor.pixelFormat = config.colorPixelFormat
        descriptor.sampleCount = config.sampleCount
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        multisampleTexture = device.makeTexture(descriptor: descriptor)
        multisampleTexture?.label = "MSAA Color Texture (\(config.sampleCount)x)"

        return multisampleTexture != nil
    }

    public func getMultisampleRenderPassDescriptor() -> MTLRenderPassDescriptor? {
        guard usesMultisampling, let multisampleTexture = multisampleTexture else { return nil }

        let descriptor = MTLRenderPassDescriptor()
        let colorAttachment = descriptor.colorAttachments[0]
        colorAttachment?.texture = multisampleTexture
        colorAttachment?.loadAction = .clear
        colorAttachment?.storeAction = .multisampleResolve
        colorAttachment?.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

        return descriptor
    }

    public func getResolveRenderPassDescriptor() -> MTLRenderPassDescriptor? {
        return MTLRenderPassDescriptor()
    }

    public func getMASKPipelineDescriptor() -> MTLRenderPipelineDescriptor? {
        guard maskAlphaToCoveragePipelineState != nil else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.isAlphaToCoverageEnabled = true
        descriptor.colorAttachments[0].pixelFormat = config.colorPixelFormat

        return descriptor
    }
}

// MARK: - CLI Rendering Support

extension VRMRenderer {

    public func setDebugMode(_ mode: Int) {
        currentDebugMode = mode
    }
}
