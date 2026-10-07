//
//  VRMPartThumbnailRenderer.swift
//  NeuraLink
//
//  Offscreen picture of one part of a model — the hair, the outfit, or the
//  face — for the customization picker cards. Uses a private VRMRenderer
//  (same shaders and lighting as the scene, no sky/terrain) with the model's
//  other primitives hidden, framed on the head or the torso from the
//  humanoid bones, rendered once into a texture and read back as UIImage.
//

import Foundation
import Metal
import MetalKit
import UIKit
import simd

@MainActor
final class VRMPartThumbnailRenderer {

    enum Subject {
        case hair
        /// Hair AND the face it sits on, so a scalp showing through reads as
        /// what it is. Diagnostics only — no tile uses it.
        case head
        case outfit
        case tops
        case bottoms
        case shoes
        /// Just the eyes themselves — no face behind them.
        case eyes
        /// The whole character, head and shoulders, as currently dressed —
        /// the companion widget's picture.
        case portrait
        /// The whole figure from the live scene camera's vantage (level, at
        /// about chest height, the orbit camera's default distance), so a
        /// render shows what the user actually sees. Diagnostics only.
        case figure

        var visibleSlots: Set<VRoidMaterialSlot> {
            switch self {
            case .hair:
                // Hair alone: a part file holds nothing else, and a whole
                // character used as a donor must look the same on the tile.
                return [.hair, .hairBack]
            case .head:
                return [.hair, .hairBack, .faceSkin, .eyeIris, .eyeWhite, .brow, .eyeline, .mouth]
            case .outfit:
                return AppearancePartKind.outfit.slots
            case .tops:
                return AppearancePartKind.tops.slots.union([.bodySkin])
            case .bottoms:
                return AppearancePartKind.bottoms.slots.union([.bodySkin])
            case .shoes:
                return AppearancePartKind.shoes.slots.union([.bodySkin])
            case .eyes:
                return [.eyeIris, .eyeWhite, .eyeHighlight, .eyeExtra, .eyeline, .eyelash]
            case .portrait, .figure:
                return Set(VRoidMaterialSlot.allCases)
            }
        }

        /// Garment tiles drop anything sitting entirely above the neck:
        /// some rigs keep a skin cap up there under the hair, and with the
        /// face hidden it reads as a dark floating head.
        var hidesHead: Bool {
            switch self {
            case .outfit, .tops, .bottoms, .shoes: return true
            case .hair, .head, .eyes, .portrait, .figure: return false
            }
        }

        /// How far above the subject the camera sits, as a fraction of its
        /// distance. Shoes want a raised, looking-down angle: level with
        /// them you see straight into the opening where the foot goes, and
        /// VRoid deletes the foot under a shoe, so that reads as a hole.
        var elevation: Float {
            switch self {
            case .shoes: return 0.55
            case .bottoms: return 0.16
            case .hair, .head, .outfit, .tops, .eyes: return 0.08
            case .portrait: return 0.04
            case .figure: return 0
            }
        }

        /// Slots the camera frames and the picture is cropped to. A garment
        /// is framed on the garment itself even though the body is drawn
        /// behind it, so the tile shows the shoe rather than the leg.
        var framingSlots: Set<VRoidMaterialSlot>? {
            switch self {
            case .tops: return AppearancePartKind.tops.slots
            case .bottoms: return AppearancePartKind.bottoms.slots
            case .shoes: return AppearancePartKind.shoes.slots
            case .hair, .head, .outfit, .eyes, .portrait, .figure: return nil
            }
        }

        /// Slots the finished picture is cut down to. An outfit is framed on
        /// the whole figure but still cut at the neck, because VRoid's body
        /// mesh carries a scalp cap that is painted near-black to hide under
        /// the hair — with the hair off it reads as a floating black head.
        var cropSlots: Set<VRoidMaterialSlot>? {
            switch self {
            case .outfit: return AppearancePartKind.outfit.slots
            case .tops, .bottoms, .shoes: return framingSlots
            case .hair, .head, .eyes, .portrait, .figure: return nil
            }
        }
    }

    private let device: MTLDevice
    private let renderer: VRMRenderer
    private let size: Int

    init?(size: Int = 512) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.size = size
        renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        // Plain backdrop: no sky dome, no ground.
        renderer.skyRenderer = nil
        renderer.terrainRenderer = nil
        renderer.environmentRenderer = nil
        renderer.enableSpringBone = false
    }

    /// Portrait of the LIVE model: grafted parts and texture overrides live
    /// on the model already; recolours live on the scene renderer's layer,
    /// so they are mirrored onto this renderer's for the one draw.
    func renderPortrait(of model: VRMModel, recolorsFrom liveLayer: AppearanceMaterialLayer?) -> UIImage? {
        let layer = renderer.appearanceLayer
        defer { layer.clearRecolors() }
        if let liveLayer {
            for index in model.materials.indices {
                layer.setRecolor(liveLayer.recolor(forMaterial: index), materialIndex: index)
            }
        }
        return render(model: model, subject: .portrait)
    }

    /// Renders `subject` of `model`. The model's hidden-primitive set and
    /// the renderer's model are restored/cleared afterwards.
    func render(model: VRMModel, subject: Subject) -> UIImage? {
        let savedHidden = model.hiddenPrimitives
        defer {
            model.hiddenPrimitives = savedHidden
            renderer.clearModel()
        }
        hideEverythingExcept(subject.visibleSlots, in: model, cuttingAboveNeck: subject.hidesHead)
        model.updateNodeTransforms()

        renderer.loadModel(model)
        renderer.isModelVisible = true
        renderer.enableSpringBone = false
        renderer.lookAtController?.enabled = false
        applyCatalogueLighting()
        frameCamera(on: model, subject: subject)

        guard let color = makeTexture(format: renderer.config.colorPixelFormat, storage: .private, usage: [.renderTarget, .shaderRead]),
            let readback = makeTexture(format: renderer.config.colorPixelFormat, storage: .shared, usage: [.shaderRead]),
            let descriptor = makePassDescriptor(color: color),
            let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return nil }
        let depth = descriptor.depthAttachment.texture ?? color

        renderer.drawOffscreenHeadless(to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: descriptor)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: color, to: readback)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        guard let image = FrameImageConverter.image(from: readback, scale: 2) else { return nil }
        if let slots = subject.cropSlots, var box = model.restBounds(ofSlots: slots) {
            if subject.hidesHead, let neckY = neckHeight(of: model), neckY > box.min.y {
                box.max.y = min(box.max.y, neckY)
            }
            if let rect = projectedRect(of: box, isVRM0: model.isVRM0) {
                return Self.fitted(image, to: rect) ?? Self.croppedToContent(image) ?? image
            }
        }
        return Self.croppedToContent(image) ?? image
    }

    /// Where the garment's own geometry lands in the rendered picture, in
    /// pixels. A garment is drawn over the body so the tile isn't a hollow
    /// shell, but VRoid draws that body as one head-to-toe piece — trimming
    /// to whatever came out opaque would frame the whole character instead
    /// of the shirt. Projecting the garment's box through the same camera
    /// gives the crop the body can't.
    private func projectedRect(
        of box: (min: SIMD3<Float>, max: SIMD3<Float>), isVRM0: Bool
    ) -> CGRect? {
        let clipFromModel = renderer.projectionMatrix * renderer.viewMatrix
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in 0..<8 {
            var point = SIMD3<Float>(
                corner & 1 == 0 ? box.min.x : box.max.x,
                corner & 2 == 0 ? box.min.y : box.max.y,
                corner & 4 == 0 ? box.min.z : box.max.z)
            // The renderer yaws 0.x models 180°, so the box turns with them.
            if isVRM0 { point = SIMD3<Float>(-point.x, point.y, -point.z) }
            let clip = clipFromModel * SIMD4<Float>(point, 1)
            guard clip.w > 0.0001 else { return nil }
            let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
            lo = simd_min(lo, ndc)
            hi = simd_max(hi, ndc)
        }
        guard hi.x > lo.x, hi.y > lo.y else { return nil }
        // Clip space is -1...1 with +Y up; pixels run 0...size with +Y down.
        let side = Float(size)
        return CGRect(
            x: CGFloat((lo.x + 1) * 0.5 * side),
            y: CGFloat((1 - hi.y) * 0.5 * side),
            width: CGFloat((hi.x - lo.x) * 0.5 * side),
            height: CGFloat((hi.y - lo.y) * 0.5 * side))
    }

    /// Trims the transparent margin and re-squares the result, so a hairpiece
    /// and a full outfit both fill their tile instead of floating in whatever
    /// the camera happened to leave around them.
    static func croppedToContent(_ image: UIImage, padding: CGFloat = 0.06) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        return fitted(
            image,
            to: CGRect(
                x: CGFloat(minX), y: CGFloat(minY),
                width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)),
            padding: padding)
    }

    /// Cuts `rect` out of `image` and centres it, untouched, on a square
    /// transparent canvas.
    ///
    /// The crop is letterboxed rather than grown to a square: a T-posed
    /// shirt with sleeves is as wide as the model's whole wingspan, so
    /// squaring its box would reach from the head to the feet and put the
    /// entire character back on the tile. All in pixels.
    static func fitted(_ image: UIImage, to rect: CGRect, padding: CGFloat = 0.06) -> UIImage? {
        guard let cgImage = image.cgImage, rect.width > 0, rect.height > 0 else { return nil }
        let pad = max(rect.width, rect.height) * padding
        let crop = rect.insetBy(dx: -pad, dy: -pad)
        let side = max(crop.width, crop.height)
        let origin = CGPoint(x: (side - crop.width) / 2, y: (side - crop.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // Draw through UIImage so UIKit's flipped context is handled for us
        // (a raw CGContext.draw here would come out upside-down). Everything
        // is in pixels: the renderer is scale 1 and the source is placed at
        // its pixel size, offset so `crop` lands inside the clip.
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            context.cgContext.clip(
                to: CGRect(origin: origin, size: crop.size))
            image.draw(in: CGRect(
                x: origin.x - crop.origin.x, y: origin.y - crop.origin.y,
                width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        }
    }

    // MARK: - Setup

    /// Product-shot lighting rather than the scene's. The scene gets its
    /// ambient from the sky, which this renderer doesn't have, so the
    /// default 0.05 left every surface facing away from the three front
    /// lights at pure black — a shoe's sole read as a hole punched in the
    /// tile. A strong ambient plus a bounce from below keeps unlit faces
    /// as shading instead.
    private func applyCatalogueLighting() {
        renderer.setLight(
            0, direction: SIMD3<Float>(0.25, -0.35, -0.90),
            color: SIMD3<Float>(1.00, 0.99, 0.97), intensity: 0.95)
        renderer.setLight(
            1, direction: SIMD3<Float>(-0.45, -0.15, -0.85),
            color: SIMD3<Float>(0.88, 0.90, 0.96), intensity: 0.55)
        // Bounce: travels upward, so it catches soles and undersides.
        renderer.setLight(
            2, direction: SIMD3<Float>(0.0, 0.75, -0.65),
            color: SIMD3<Float>(0.95, 0.95, 1.00), intensity: 0.45)
        renderer.setAmbientColor(SIMD3<Float>(repeating: 0.42))
    }

    private func hideEverythingExcept(
        _ slots: Set<VRoidMaterialSlot>, in model: VRMModel, cuttingAboveNeck: Bool
    ) {
        let neckY: Float? = cuttingAboveNeck ? neckHeight(of: model) : nil
        // Start from what is already hidden rather than replacing it: on a
        // model that has been grafted, the replaced parts are hidden, and a
        // picture that revealed them would show two pairs of shoes.
        var hidden = model.hiddenPrimitives
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let m = primitive.materialIndex, slots.contains(model.slot(ofMaterial: m)) else {
                    hidden.insert(ObjectIdentifier(primitive))
                    continue
                }
                if let neckY, let range = primitive.restHeightRange(), range.min > neckY {
                    hidden.insert(ObjectIdentifier(primitive))
                }
            }
        }
        model.hiddenPrimitives = hidden
    }

    /// Rest-pose height of the neck, used as the cut line above which a
    /// garment tile shows nothing.
    private func neckHeight(of model: VRMModel) -> Float? {
        for bone in [VRMHumanoidBone.neck, .head] {
            if let index = model.humanoid?.getBoneNode(bone), index < model.nodes.count {
                return model.nodes[index].worldPosition.y
            }
        }
        return nil
    }

    /// Camera on +Z looking at the head (hair/face/eyes) or the torso
    /// (outfit). Bone positions are model space; the renderer yaws 0.x
    /// models by 180°, so the target is yawed the same way.
    private func frameCamera(on model: VRMModel, subject: Subject) {
        func worldPosition(_ bone: VRMHumanoidBone) -> SIMD3<Float>? {
            guard let index = model.humanoid?.getBoneNode(bone), index < model.nodes.count else { return nil }
            let p = model.nodes[index].worldPosition
            return model.isVRM0 ? SIMD3<Float>(-p.x, p.y, -p.z) : p
        }
        let bounds = model.calculateBoundingBox()
        if let slots = subject.framingSlots, let part = model.restBounds(ofSlots: slots) {
            let centre = (part.min + part.max) * 0.5
            let span = part.max - part.min
            let reach = max(max(span.x, span.y), 0.08)
            let aimed = model.isVRM0 ? SIMD3<Float>(-centre.x, centre.y, -centre.z) : centre
            // Vertical FOV is 60°, so this much distance frames `reach` with
            // a little air around it; the crop trims the rest.
            setCamera(target: aimed, distance: reach * 1.05, elevation: subject.elevation)
            return
        }
        let height = max(bounds.max.y - bounds.min.y, 1.0)
        var target: SIMD3<Float>
        var distance: Float
        switch subject {
        case .hair, .head:
            target = worldPosition(.head) ?? SIMD3<Float>(0, height * 0.9, 0)
            target.y += height * 0.03
            distance = height * 0.42
        case .eyes:
            target = worldPosition(.head) ?? SIMD3<Float>(0, height * 0.9, 0)
            target.y += height * 0.025
            distance = height * 0.22
        case .portrait:
            // Head and shoulders, the face a little above centre.
            target = worldPosition(.head) ?? SIMD3<Float>(0, height * 0.9, 0)
            target.y -= height * 0.045
            distance = height * 0.36
        case .outfit, .tops, .bottoms, .shoes:
            let hips = worldPosition(.hips) ?? SIMD3<Float>(0, height * 0.5, 0)
            let neck = worldPosition(.neck) ?? SIMD3<Float>(0, height * 0.85, 0)
            target = (hips + neck) * 0.5
            target.y -= height * 0.03
            distance = height * 0.85
        case .figure:
            // Same framing as VRMMetalState.setupCamera.
            let centre = (bounds.min + bounds.max) * 0.5
            target = SIMD3<Float>(centre.x, centre.y + height * 0.1, centre.z)
            distance = (height * 0.60) / tan(Float.pi / 6) + 0.3
        }
        setCamera(target: target, distance: distance, elevation: subject.elevation)
    }

    private func setCamera(target: SIMD3<Float>, distance: Float, elevation: Float) {
        let eye = target + SIMD3<Float>(0, distance * elevation, distance)
        renderer.viewMatrix = OrthographicCamera.makeLookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
        renderer.projectionMatrix = renderer.makeProjectionMatrix(aspectRatio: 1)
    }

    private func makeTexture(format: MTLPixelFormat, storage: MTLStorageMode, usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        descriptor.storageMode = storage
        descriptor.usage = usage
        return device.makeTexture(descriptor: descriptor)
    }

    private func makePassDescriptor(color: MTLTexture) -> MTLRenderPassDescriptor? {
        // Transparent: the tile supplies its own (light) background, so a
        // part reads as a cut-out catalogue item on any theme.
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let descriptor: MTLRenderPassDescriptor
        let samples: Int
        if renderer.usesMultisampling {
            renderer.updateDrawableSize(CGSize(width: size, height: size))
            guard let msaa = renderer.getMultisampleRenderPassDescriptor() else { return nil }
            msaa.colorAttachments[0].resolveTexture = color
            msaa.colorAttachments[0].clearColor = clear
            descriptor = msaa
            samples = renderer.config.sampleCount
        } else {
            descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = color
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = clear
            samples = 1
        }
        let depthDescriptor = MTLTextureDescriptor()
        depthDescriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
        depthDescriptor.pixelFormat = .depth32Float
        depthDescriptor.width = size
        depthDescriptor.height = size
        depthDescriptor.sampleCount = samples
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = [.renderTarget]
        guard let depth = device.makeTexture(descriptor: depthDescriptor) else { return nil }
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1
        return descriptor
    }
}
