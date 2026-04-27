//
//  CameraPreviewView.swift
//  NeuraLink
//
//  UIViewRepresentable that renders an AVCaptureSession through an
//  AVCaptureVideoPreviewLayer, using the UIView layerClass override
//  so the layer exactly fills the view without an extra sub-layer.
//

import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraUIView {
        let view = CameraUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: CameraUIView, context: Context) {}
}

// MARK: - CameraUIView

final class CameraUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}
