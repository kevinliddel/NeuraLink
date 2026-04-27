//
//  CameraOverlayView.swift
//  NeuraLink
//
//  FaceTime-style picture-in-picture overlay shown in the top-left corner.
//  Includes a dismiss button and a front/back camera flip button.
//

import SwiftUI

struct CameraOverlayView: View {

    @State private var camera = CameraManager.shared

    private let previewWidth: CGFloat = 120
    private let previewHeight: CGFloat = 160

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                if camera.isActive {
                    pipView
                        .padding(.leading, 16)
                        .transition(
                            .scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                }
                Spacer()
            }
            Spacer()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: camera.isActive)
    }

    // MARK: - Sub-views

    private var pipView: some View {
        ZStack(alignment: .topLeading) {
            cameraFeed
            dismissButton.offset(x: -8, y: -8)
        }
    }

    private var cameraFeed: some View {
        ZStack(alignment: .bottom) {
            CameraPreviewView(session: camera.session)
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)

            flipButton.padding(.bottom, 8)
        }
    }

    private var dismissButton: some View {
        Button {
            camera.stop()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
        .accessibilityLabel("Stop camera")
    }

    private var flipButton: some View {
        Button {
            camera.switchCamera()
        } label: {
            Image(systemName: "camera.rotate.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.4), in: Circle())
        }
        .accessibilityLabel("Flip camera")
    }
}
