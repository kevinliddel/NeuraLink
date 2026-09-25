//
//  PhotoshootShareCapsule.swift
//  NeuraLink
//
//  Save / Share capsule shown after a photoshoot capture.
//

import SwiftUI

struct PhotoshootShareCapsule: View {
    @State private var controller = PhotoshootShareController.shared

    var body: some View {
        if controller.isCapsuleVisible, let image = controller.image {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("Nice shot!")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Button {
                        controller.saveToPhotos()
                    } label: {
                        Label(saveTitle, systemImage: saveSymbol)
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                    .disabled(controller.saveState == .saving || controller.saveState == .saved)
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("NeuraLink photo", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                    }
                    Button {
                        controller.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                    }
                    .accessibilityLabel("Dismiss")
                }
                .tint(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 120)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.isCapsuleVisible)
        }
    }

    private var saveTitle: String {
        switch controller.saveState {
        case .saved: return "Saved"
        case .failed: return "Save failed"
        default: return "Save to Photos"
        }
    }

    private var saveSymbol: String {
        switch controller.saveState {
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .saving: return "arrow.down.circle"
        case .idle: return "square.and.arrow.down"
        }
    }
}
