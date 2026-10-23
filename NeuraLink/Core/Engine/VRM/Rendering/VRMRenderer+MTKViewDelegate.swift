//
//  VRMRenderer+MTKViewDelegate.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import MetalKit
import os

// MARK: - MTKViewDelegate

extension VRMRenderer: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let aspect = Float(size.width / size.height)
        projectionMatrix = makePerspective(
            fovyRadians: .pi / 3, aspectRatio: aspect, nearZ: 0.1, farZ: 100.0)
    }

    public func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let descriptor = scenePass(for: view) else {
            return
        }

        // CPU side of the frame (encode + present); Instruments → os_signpost.
        let frameSignpost = NLSignposts.render.beginInterval("frame")
        draw(in: view, commandBuffer: commandBuffer, renderPassDescriptor: descriptor)
        encodeCaptureIfRequested(view: view, commandBuffer: commandBuffer)

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        NLSignposts.render.endInterval("frame", frameSignpost)

        // Add comprehensive error handler for debugging
        commandBuffer.addCompletedHandler { [weak self] cb in
            if cb.status == .error {
                nlLog("[VRMRenderer] ❌ METAL ERROR: Command buffer failed!")
                if let error = cb.error {
                    nlLog("[VRMRenderer] ❌ Error details: \(error)")
                }
                // Log additional debug info
                if let model = self?.model {
                    var totalPrimitives = 0
                    var maxMorphs = 0
                    for mesh in model.meshes {
                        totalPrimitives += mesh.primitives.count
                        for prim in mesh.primitives {
                            maxMorphs = max(maxMorphs, prim.morphTargets.count)
                        }
                    }
                    nlLog(
                        "[VRMRenderer] ❌ Model stats: \(totalPrimitives) primitives, max \(maxMorphs) morphs per primitive"
                    )
                }
            } else if cb.status == .completed {
                // Success - log occasionally for complex models
                if let frameCounter = self?.frameCounter, frameCounter % 300 == 0 {
                    if let model = self?.model {
                        var totalPrimitives = 0
                        for mesh in model.meshes {
                            totalPrimitives += mesh.primitives.count
                        }
                        if totalPrimitives > 50 {
                            nlLog(
                                "[VRMRenderer] ✅ Frame \(frameCounter): Successfully rendered \(totalPrimitives) primitives"
                            )
                        }
                    }
                }
            }
        }

        commandBuffer.commit()
    }
}

extension VRMRenderer {
    /// The view's own pass, or — with MSAA on — memoryless multisampled
    /// targets resolving into the drawable (VRMRenderer+MSAA).
    func scenePass(for view: MTKView) -> MTLRenderPassDescriptor? {
        guard usesMultisampling else { return view.currentRenderPassDescriptor }
        guard let drawable = view.currentDrawable else { return nil }
        return multisamplePassDescriptor(resolvingInto: drawable.texture, clearColor: view.clearColor)
    }
}
