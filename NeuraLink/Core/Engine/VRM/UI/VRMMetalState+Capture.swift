//
//  VRMMetalState+Capture.swift
//  NeuraLink
//
//  Captures the live scene as an image for the photoshoot share. The
//  drawable is made readable for a couple of frames only; the SwiftUI
//  background image (if any) is composited under the transparent scene.
//

import MetalKit
import UIKit

extension VRMMetalState {

    /// Renders the next frame into a UIImage (nil when Metal is unavailable).
    func captureFrame(completion: @escaping @Sendable (UIImage?) -> Void) {
        guard isMetalAvailable, let renderer else {
            completion(nil)
            return
        }
        let background = AppearanceSettings.shared.backgroundUIImage
        mtkView.framebufferOnly = false
        renderer.requestFrameCapture { image in
            let composed = image.map { Self.compose(scene: $0, over: background) }
            Task { @MainActor in
                self.mtkView.framebufferOnly = true
                completion(composed)
            }
        }
    }

    /// Scene over the background (scaled to fill), or the scene alone.
    nonisolated static func compose(scene: UIImage, over background: UIImage?) -> UIImage {
        guard let background else { return scene }
        let size = scene.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = scene.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let aspect = max(size.width / background.size.width, size.height / background.size.height)
            let drawSize = CGSize(width: background.size.width * aspect, height: background.size.height * aspect)
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            background.draw(in: CGRect(origin: origin, size: drawSize))
            scene.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
