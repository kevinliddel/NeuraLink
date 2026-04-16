//
//  VRMRenderer+MTKViewDelegate.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import MetalKit

// MARK: - MTKViewDelegate

extension VRMRenderer: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let aspect = Float(size.width / size.height)
        projectionMatrix = makePerspective(
            fovyRadians: .pi / 3, aspectRatio: aspect, nearZ: 0.1, farZ: 100.0)
    }

    public func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let descriptor = view.currentRenderPassDescriptor
        else {
            return
        }

        draw(in: view, commandBuffer: commandBuffer, renderPassDescriptor: descriptor)

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }

        // Add comprehensive error handler for debugging
        commandBuffer.addCompletedHandler { [weak self] cb in
            if cb.status == .error {
                vrmLog("[VRMRenderer] ❌ METAL ERROR: Command buffer failed!")
                if let error = cb.error {
                    vrmLog("[VRMRenderer] ❌ Error details: \(error)")
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
                    vrmLog(
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
                            vrmLog(
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

// MARK: - SpringBone Debug Controls

extension VRMRenderer {
    public func resetSpringBone() {
        // GPU system resets automatically on model load
        vrmLog("[VRMRenderer] SpringBone reset (GPU system resets on model load)")
    }

    public func applySpringBoneForce(
        gravity: SIMD3<Float>? = nil, wind: SIMD3<Float>? = nil, duration: Float = 1.0
    ) {
        if let gravity = gravity {
            temporaryGravity = gravity
        }
        if let wind = wind {
            temporaryWind = wind
        }
        forceTimer = duration
    }

    func updateSpringBoneForces(deltaTime: Float) {
        // Apply temporary forces if timer is active
        if forceTimer > 0 {
            if let gravity = temporaryGravity {
                model?.springBoneGlobalParams?.gravity = gravity
            }
            if let wind = temporaryWind {
                model?.springBoneGlobalParams?.windDirection = simd_normalize(wind)
                model?.springBoneGlobalParams?.windAmplitude = simd_length(wind)
            }
            forceTimer -= deltaTime
        } else if temporaryGravity != nil || temporaryWind != nil {
            // Timer expired - restore initial gravity and clear wind
            // Only restore if we had temporary overrides (don't overwrite initial setup)
            if temporaryGravity != nil {
                model?.springBoneGlobalParams?.gravity = [0, -9.8, 0]
            }
            if temporaryWind != nil {
                model?.springBoneGlobalParams?.windAmplitude = 0
            }
            temporaryGravity = nil
            temporaryWind = nil
        }
    }
}
